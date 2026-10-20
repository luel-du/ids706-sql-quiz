"""
Integration tests for the quiz database.

They connect with DATABASE_URL (from .env locally, from a GitHub Secret in CI) and
exercise the real functions and grants, impersonating the Supabase API roles the
way PostgREST does: SET ROLE plus a request.jwt.claims setting. Everything runs in
one transaction that is rolled back at the end, so no rows are left behind.

Run:  pytest -q
"""
import json
import os
import pathlib

import psycopg2
import pytest
from dotenv import load_dotenv

load_dotenv(pathlib.Path(__file__).resolve().parents[1] / ".env")

TEST_UID = "00000000-0000-0000-0000-00000000c0de"
CLAIMS = json.dumps({"sub": TEST_UID, "email": "pytest@example.invalid", "role": "authenticated"})


@pytest.fixture(scope="module")
def conn():
    url = os.environ.get("DATABASE_URL")
    if not url:
        pytest.skip("DATABASE_URL is not set")
    c = psycopg2.connect(url)
    yield c
    c.rollback()  # discard every row the tests wrote
    c.close()


@pytest.fixture
def cur(conn):
    """A cursor inside a savepoint, rolled back after each test, with role reset."""
    cur = conn.cursor()
    cur.execute("savepoint t")
    yield cur
    cur.execute("rollback to savepoint t")
    cur.close()


def as_role(cur, role, claims=None):
    cur.execute(f"set local role {role}")  # role names are our own constants, not user input
    if claims:
        cur.execute("select set_config('request.jwt.claims', %s, true)", (claims,))


def run_sql(cur, qid, sql):
    cur.execute("select public.run_quiz_sql(%s, %s)", (qid, sql))
    return cur.fetchone()[0]


# ---------------------------------------------------------------- content

def test_points_sum_to_twenty(cur):
    cur.execute("select sum(points), count(*) from quiz.questions")
    total, n = cur.fetchone()
    assert (total, n) == (20, 5)


def test_every_hint_returns_its_stored_result(cur):
    cur.execute("select id, hint_sql, hint_result from quiz.questions order by id")
    for qid, sql, expected in cur.fetchall():
        cur.execute("savepoint h")
        cur.execute("set local search_path = quiz")
        cur.execute(
            "select coalesce(json_agg(row_to_json(t)), '[]'::json)::text from ("
            + sql.rstrip().rstrip(";") + ") t"
        )
        actual = json.loads(cur.fetchone()[0])
        cur.execute("rollback to savepoint h")
        assert actual == expected, f"question {qid}"


# ---------------------------------------------------------------- gate

@pytest.mark.parametrize("fn", ["run_quiz_sql(1, 'select 1')", "save_answer(1, 'x')",
                                "list_questions()", "my_answers()", "my_audit_log()",
                                "reveal_answer_key(1)"])
def test_anon_is_refused(cur, fn):
    as_role(cur, "anon")
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        cur.execute(f"select public.{fn}")


def test_authenticated_without_a_user_is_refused(cur):
    as_role(cur, "authenticated", json.dumps({"role": "authenticated"}))
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        run_sql(cur, 1, "select 1")


# ---------------------------------------------------------------- running SQL

def test_correct_query_matches(cur):
    as_role(cur, "authenticated", CLAIMS)
    r = run_sql(cur, 1, "select code, title, credits from courses where credits = 4 order by code")
    assert r["ok"] is True and r["matched"] is True and r["row_count"] == 4


def test_wrong_order_does_not_match(cur):
    as_role(cur, "authenticated", CLAIMS)
    r = run_sql(cur, 1, "select code, title, credits from courses where credits = 4 order by code desc")
    assert r["ok"] is True and r["matched"] is False


@pytest.mark.parametrize("sql", [
    "delete from courses",
    "update courses set credits = 1",
    "insert into courses values (99, 'X', 'X', 1, 1)",
    "drop table courses",
    "select 1; drop table courses",
])
def test_non_select_statements_are_rejected_up_front(cur, sql):
    as_role(cur, "authenticated", CLAIMS)
    with pytest.raises(psycopg2.Error):
        run_sql(cur, 1, sql)


@pytest.mark.parametrize("sql", [
    "with x as (update courses set credits = 1 returning *) select * from x",
    "with x as (insert into audit_log(user_id, action, sql_text, ok) values (gen_random_uuid(), 'run', 'fake', true) returning *) select * from x",
    "select * into quiz.hacked from courses",
    "select * from audit_log",
    "select * from submissions",
    "select * from questions",
    "select * from auth.users",
    "select public.save_answer(1, 'x')",
])
def test_sandbox_blocks_writes_and_private_data(cur, sql):
    as_role(cur, "authenticated", CLAIMS)
    r = run_sql(cur, 1, sql)
    assert r["ok"] is False
    assert "permission denied" in r["error"] or "not allowed" in r["error"] or "must be at the top level" in r["error"]


# ---------------------------------------------------------------- audit log and answer key

def test_runs_and_reveals_are_logged(cur):
    as_role(cur, "authenticated", CLAIMS)
    run_sql(cur, 2, "select 1")
    cur.execute("select public.reveal_answer_key(2)")
    key = cur.fetchone()[0]
    assert set(key) == {"question_id", "hint_sql", "hint_result"}
    cur.execute("select public.my_audit_log()")
    actions = [row["action"] for row in cur.fetchone()[0]]
    assert actions[:2] == ["hint", "run"]


def test_list_questions_does_not_leak_the_key(cur):
    as_role(cur, "authenticated", CLAIMS)
    cur.execute("select public.list_questions()")
    q = cur.fetchone()[0][0]
    assert {"id", "ord", "points", "prompt", "columns", "sample_rows", "row_count"} <= set(q)
    assert "hint_sql" not in q and "hint_result" not in q
    assert len(q["sample_rows"]) <= 2


@pytest.mark.parametrize("stmt", ["update quiz.audit_log set ok = false where id = %s",
                                  "delete from quiz.audit_log where id = %s"])
def test_audit_log_is_append_only_even_for_owner(cur, stmt):
    cur.execute("insert into quiz.audit_log (user_id, action, sql_text, ok) values (%s, 'run', 'x', true) returning id", (TEST_UID,))
    rid = cur.fetchone()[0]
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        cur.execute(stmt, (rid,))
