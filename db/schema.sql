-- IDS706 SQL Quiz: schema, roles, functions, policies.
-- Idempotent: safe to run on every CI push.
-- Data lives in schema "quiz". The browser never touches it directly; it calls the
-- SECURITY DEFINER functions in "public" below through the Supabase REST API (supabase-js rpc()).

create schema if not exists quiz;

-- ---------------------------------------------------------------------------
-- Quiz data: a small university registrar (4 tables, 3 foreign keys)
-- ---------------------------------------------------------------------------
create table if not exists quiz.instructors (
  id          int primary key,
  name        text not null,
  department  text not null,
  hired_year  int  not null
);

create table if not exists quiz.courses (
  id            int primary key,
  code          text not null unique,
  title         text not null,
  credits       int  not null check (credits between 1 and 5),
  instructor_id int  not null references quiz.instructors(id) on delete restrict
);

create table if not exists quiz.students (
  id          int primary key,
  name        text not null,
  major       text not null,
  start_year  int  not null
);

create table if not exists quiz.enrollments (
  id           int primary key,
  student_id   int  not null references quiz.students(id) on delete restrict,
  course_id    int  not null references quiz.courses(id)  on delete restrict,
  term         text not null,
  grade_points numeric(3,2) not null check (grade_points between 0 and 4),
  unique (student_id, course_id, term)
);

-- ---------------------------------------------------------------------------
-- Quiz machinery
-- ---------------------------------------------------------------------------
create table if not exists quiz.questions (
  id          int primary key,
  ord         int  not null unique,
  points      int  not null check (points > 0),
  prompt      text not null,
  hint_sql    text not null,
  hint_result json not null          -- json (not jsonb) keeps column order
);

create table if not exists quiz.submissions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  question_id int  not null references quiz.questions(id),
  sql_text    text not null,
  created_at  timestamptz not null default now()
);

create table if not exists quiz.audit_log (
  id          bigint generated always as identity primary key,
  user_id     uuid not null,
  user_email  text,
  action      text not null check (action in ('run', 'save')),
  question_id int references quiz.questions(id),
  sql_text    text not null,
  row_count   int,
  ok          boolean not null,
  error       text,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Locking down the schema
-- ---------------------------------------------------------------------------
-- API roles get nothing in schema quiz. Only the functions below reach it.
revoke all on schema quiz from public, anon, authenticated;
revoke all on all tables in schema quiz from public, anon, authenticated;

-- Row Level Security on the per-user tables. With no policies for app roles,
-- nothing is readable or writable except through the functions.
alter table quiz.submissions enable row level security;
alter table quiz.audit_log   enable row level security;
alter table quiz.submissions force row level security;
alter table quiz.audit_log   force row level security;

-- Integrity: the audit log is append-only, even for the table owner.
create or replace function quiz.audit_log_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'audit_log is append-only: % is not allowed', tg_op
    using errcode = '42501';
end $$;

drop trigger if exists audit_log_no_change on quiz.audit_log;
create trigger audit_log_no_change
  before update or delete on quiz.audit_log
  for each row execute function quiz.audit_log_immutable();

-- A read-only role that student queries run under. NOLOGIN: nobody can connect as
-- it. It owns quiz.exec_readonly() below, so that SECURITY DEFINER function runs
-- with exactly these privileges: SELECT on the four data tables and nothing else.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'quiz_reader') then
    create role quiz_reader nologin noinherit;
  end if;
end $$;
grant quiz_reader to postgres;
revoke all on schema public from quiz_reader;
grant usage on schema quiz to quiz_reader;
grant select on quiz.instructors, quiz.courses, quiz.students, quiz.enrollments to quiz_reader;
-- quiz_reader must not see other users' answers or the audit log.
revoke all on quiz.questions, quiz.submissions, quiz.audit_log from quiz_reader;

-- Inner sandbox: runs one query with quiz_reader's privileges (SECURITY DEFINER,
-- owned by quiz_reader). Any INSERT/UPDATE/DELETE, and any read of questions,
-- submissions, audit_log or other schemas, fails with "permission denied".
-- Returns the rows as JSON with column order preserved, capped at 200 rows.
create or replace function quiz.exec_readonly(p_sql text, out rows_json json, out row_count int)
language plpgsql security definer
set search_path = quiz, pg_temp
as $$
begin
  execute format(
    'select coalesce(json_agg(row_to_json(t)), ''[]''::json), count(*) from (%s) t',
    'select * from (' || p_sql || ') _q limit 200'
  ) into rows_json, row_count;
end $$;
-- Changing owner needs CREATE on the schema for the new owner; grant it only for
-- this statement, then take it back so student queries cannot create objects.
grant create on schema quiz to quiz_reader;
alter function quiz.exec_readonly(text) owner to quiz_reader;
revoke create on schema quiz from quiz_reader;
revoke all on function quiz.exec_readonly(text) from public, anon, authenticated;
grant execute on function quiz.exec_readonly(text) to postgres;

-- ---------------------------------------------------------------------------
-- Functions the browser calls (schema public so PostgREST exposes them)
-- ---------------------------------------------------------------------------

-- List the questions. Requires sign-in.
create or replace function public.list_questions()
returns json
language plpgsql security definer set search_path = quiz, public as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in to view the quiz' using errcode = '42501';
  end if;
  return (
    select coalesce(json_agg(json_build_object(
             'id', q.id, 'ord', q.ord, 'points', q.points, 'prompt', q.prompt,
             'hint_sql', q.hint_sql, 'hint_result', q.hint_result)
             order by q.ord), '[]'::json)
    from quiz.questions q
  );
end $$;

-- Run one read-only SELECT as quiz_reader and return rows as JSON.
-- Also writes one audit row. Requires sign-in.
create or replace function public.run_quiz_sql(p_question_id int, p_sql text)
returns json
language plpgsql security definer set search_path = quiz, public as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text := auth.jwt() ->> 'email';
  v_sql    text := btrim(coalesce(p_sql, ''));
  v_head   text;
  v_rows   json;
  v_count  int;
  v_err    text;
begin
  if v_uid is null then
    raise exception 'Sign in to run a query' using errcode = '42501';
  end if;

  if v_sql = '' then
    raise exception 'Query is empty';
  end if;
  v_sql := regexp_replace(v_sql, ';\s*$', '');
  if position(';' in v_sql) > 0 then
    raise exception 'Run one statement at a time (no semicolons inside the query)';
  end if;
  v_head := lower(split_part(regexp_replace(v_sql, '^\s*(--[^\n]*\n\s*)*', ''), ' ', 1));
  if v_head not in ('select', 'with', 'table', 'values') then
    raise exception 'Only SELECT queries are allowed here';
  end if;

  begin
    -- The student's query runs inside quiz.exec_readonly() with quiz_reader's
    -- privileges: SELECT on the four quiz tables only, so it cannot write anything.
    select e.rows_json, e.row_count into v_rows, v_count from quiz.exec_readonly(v_sql) e;
  exception when others then
    v_err := sqlerrm;
  end;

  insert into quiz.audit_log (user_id, user_email, action, question_id, sql_text, row_count, ok, error)
  values (v_uid, v_email, 'run', p_question_id, p_sql, v_count, v_err is null, v_err);

  if v_err is not null then
    return json_build_object('ok', false, 'error', v_err);
  end if;
  return json_build_object('ok', true, 'row_count', v_count, 'rows', v_rows,
                           'truncated', v_count >= 200);
end $$;

-- Save an answer for the signed-in user. Also writes one audit row.
create or replace function public.save_answer(p_question_id int, p_sql text)
returns json
language plpgsql security definer set search_path = quiz, public as $$
declare
  v_uid uuid := auth.uid();
  v_id  bigint;
begin
  if v_uid is null then
    raise exception 'Sign in to save an answer' using errcode = '42501';
  end if;
  if btrim(coalesce(p_sql, '')) = '' then
    raise exception 'Nothing to save';
  end if;
  insert into quiz.submissions (user_id, question_id, sql_text)
  values (v_uid, p_question_id, p_sql)
  returning id into v_id;

  insert into quiz.audit_log (user_id, user_email, action, question_id, sql_text, ok)
  values (v_uid, auth.jwt() ->> 'email', 'save', p_question_id, p_sql, true);

  return json_build_object('ok', true, 'submission_id', v_id, 'saved_at', now());
end $$;

-- The signed-in user's latest saved answer per question.
create or replace function public.my_answers()
returns json
language plpgsql security definer set search_path = quiz, public as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in to see your answers' using errcode = '42501';
  end if;
  return (
    select coalesce(json_agg(json_build_object(
             'question_id', s.question_id, 'sql_text', s.sql_text, 'created_at', s.created_at)), '[]'::json)
    from (
      select distinct on (question_id) question_id, sql_text, created_at
      from quiz.submissions
      where user_id = auth.uid()
      order by question_id, created_at desc
    ) s
  );
end $$;

-- The signed-in user's own audit trail (read-only view of the log).
create or replace function public.my_audit_log()
returns json
language plpgsql security definer set search_path = quiz, public as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in to see your activity' using errcode = '42501';
  end if;
  return (
    select coalesce(json_agg(json_build_object(
             'action', a.action, 'question_id', a.question_id, 'row_count', a.row_count,
             'ok', a.ok, 'error', a.error, 'created_at', a.created_at) order by a.created_at desc), '[]'::json)
    from (select * from quiz.audit_log where user_id = auth.uid() order by created_at desc limit 50) a
  );
end $$;

-- Only signed-in users may call these. Supabase grants EXECUTE to anon by default
-- through default privileges, so revoke explicitly.
revoke all on function public.list_questions()            from public, anon;
revoke all on function public.run_quiz_sql(int, text)     from public, anon;
revoke all on function public.save_answer(int, text)      from public, anon;
revoke all on function public.my_answers()                from public, anon;
revoke all on function public.my_audit_log()              from public, anon;
grant execute on function public.list_questions()         to authenticated;
grant execute on function public.run_quiz_sql(int, text)  to authenticated;
grant execute on function public.save_answer(int, text)   to authenticated;
grant execute on function public.my_answers()             to authenticated;
grant execute on function public.my_audit_log()           to authenticated;
