#!/usr/bin/env python3
"""
Seed the quiz database and verify every question's hint.

Runs in GitHub Actions on every push (reads DATABASE_URL from a GitHub Secret)
and locally (reads DATABASE_URL from .env).

Steps
  1. Connect to Supabase Postgres through the session pooler (sslmode=require is in the URL).
  2. Apply db/schema.sql and db/seed.sql (both idempotent).            [skip with --verify-only]
  3. Check that the question points sum to 20.
  4. Run every question's hint_sql and compare the rows to the stored hint_result.
Exit code 1 on any mismatch, so a drift between seed data and hints turns CI red.

All queries that take values use psycopg2 parameters (%s), never string formatting.
The one deliberate exception is executing our own stored hint_sql, which is quiz
content written by the TA, not user input.
"""
import json
import os
import pathlib
import sys

import psycopg2
from dotenv import load_dotenv

ROOT = pathlib.Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")

EXPECTED_TOTAL_POINTS = 20


def mask(url: str) -> str:
    """Show host and database only, never the password."""
    try:
        from urllib.parse import urlsplit
        p = urlsplit(url)
        return f"{p.hostname}:{p.port}{p.path} as {p.username}"
    except Exception:  # pragma: no cover
        return "<unparseable url>"


def main() -> int:
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL is not set. Locally: copy .env.example to .env. In CI: add the GitHub Secret.")
        return 2
    verify_only = "--verify-only" in sys.argv

    print(f"Connecting to {mask(url)} ...")
    conn = psycopg2.connect(url)
    try:
        with conn, conn.cursor() as cur:
            cur.execute("select current_user, version()")
            user, version = cur.fetchone()
            print(f"Connected as {user}. {version.split(',')[0]}")

            if not verify_only:
                for name in ("schema.sql", "seed.sql"):
                    sql = (ROOT / "db" / name).read_text()
                    cur.execute(sql)
                    print(f"Applied db/{name}")
                conn.commit()

            cur.execute(
                """
                select (select count(*) from quiz.instructors),
                       (select count(*) from quiz.courses),
                       (select count(*) from quiz.students),
                       (select count(*) from quiz.enrollments)
                """
            )
            ins, crs, stu, enr = cur.fetchone()
            print(f"Rows: {ins} instructors, {crs} courses, {stu} students, {enr} enrollments")

            cur.execute("select coalesce(sum(points), 0), count(*) from quiz.questions")
            total, nq = cur.fetchone()
            print(f"Quiz: {nq} questions, {total} points")
            ok = True
            if total != EXPECTED_TOTAL_POINTS:
                print(f"FAIL: points sum to {total}, expected {EXPECTED_TOTAL_POINTS}")
                ok = False

            cur.execute("select id, ord, points, hint_sql, hint_result from quiz.questions order by ord")
            questions = cur.fetchall()
            for qid, ord_, points, hint_sql, hint_result in questions:
                # Same shape the browser gets from run_quiz_sql(): json rows with column order kept.
                cur.execute("savepoint q")
                cur.execute("set local search_path = quiz")
                cur.execute(
                    "select coalesce(json_agg(row_to_json(t)), '[]'::json)::text from ("
                    + hint_sql.rstrip().rstrip(";")
                    + ") t"
                )
                actual = json.loads(cur.fetchone()[0])
                cur.execute("rollback to savepoint q")
                expected = hint_result if isinstance(hint_result, list) else json.loads(hint_result)
                if actual == expected:
                    print(f"Q{ord_} OK ({points} pts, {len(actual)} rows)")
                else:
                    ok = False
                    print(f"Q{ord_} MISMATCH ({points} pts)")
                    print("  expected:", json.dumps(expected)[:300])
                    print("  actual:  ", json.dumps(actual)[:300])

            # Sanity check on the gate: anon must not be able to execute the quiz functions.
            cur.execute(
                """
                select p.proname, has_function_privilege('anon', p.oid, 'execute')
                from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public'
                  and p.proname in ('run_quiz_sql', 'save_answer', 'list_questions', 'my_answers', 'my_audit_log', 'reveal_answer_key')
                order by 1
                """
            )
            for fn, anon_can in cur.fetchall():
                status = "FAIL" if anon_can else "ok"
                print(f"anon may call {fn}: {anon_can} [{status}]")
                ok = ok and not anon_can
    finally:
        conn.close()

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
