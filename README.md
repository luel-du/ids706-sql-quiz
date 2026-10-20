# IDS706 SQL Quiz

[![CI](https://github.com/luel-du/ids706-sql-quiz/actions/workflows/ci.yml/badge.svg)](https://github.com/luel-du/ids706-sql-quiz/actions/workflows/ci.yml)
[![Live site](https://img.shields.io/badge/live%20site-GitHub%20Pages-2ea44f)](https://luel-du.github.io/ids706-sql-quiz/)
[![Database](https://img.shields.io/badge/database-Supabase%20Postgres%2017-3ecf8e)](https://supabase.com)

A 20-point SQL quiz that runs against a live PostgreSQL database. A student signs in, opens a
question, writes SQL, runs it, and sees the rows. The database and authentication are hosted on
Supabase, the quiz page is a static site on GitHub Pages, and GitHub Actions seeds the database and
verifies every answer key on each push.

**Live quiz:** https://luel-du.github.io/ids706-sql-quiz/

## Contents

- [Features](#features)
- [Architecture](#architecture)
- [Taking the quiz](#taking-the-quiz)
- [Data model](#data-model)
- [Configuration](#configuration)
- [Deploying your own copy](#deploying-your-own-copy)
- [Continuous integration](#continuous-integration)
- [Security model](#security-model)
- [Project structure](#project-structure)
- [Troubleshooting](#troubleshooting)

## Features

- **Live SQL execution.** Queries run against hosted Postgres and return real rows, capped at 200.
- **Authentication gate.** Supabase Auth with email and password. Signed-out users cannot run or save; the database itself refuses the call, not just the page.
- **Sandboxed queries.** Student SQL executes under a read-only role that can see only the four quiz tables.
- **Five questions, 20 points.** Each question ships with a hint showing the expected SQL and the expected result table. The page reports when a run matches the expected result exactly.
- **Saved answers.** The latest saved answer per question is restored on the next sign-in.
- **Append-only audit log.** Every run and save is recorded. The log cannot be updated or deleted, even by the table owner.
- **Verified answer keys.** CI re-runs every hint query on every push and fails if a result drifts from the stored hint.
- **No secrets in the repository.** The database password lives only in a local `.env` and in a GitHub Actions secret.

## Architecture

```mermaid
flowchart LR
  B[Student's browser<br/>GitHub Pages static page] -- "1. sign in" --> A[Supabase Auth]
  B -- "2. rpc: run_quiz_sql / save_answer<br/>(with the user's token)" --> P[(Supabase Postgres<br/>schema quiz)]
  G[GitHub Actions<br/>DATABASE_URL secret] -- "seed + verify" --> P
  G -- "publish docs/" --> B
```

| Component | Technology | Role |
| --- | --- | --- |
| Quiz page | HTML, CSS, vanilla JavaScript, `supabase-js` 2.45 | Sign-in form, question list, SQL editor, result table, hint panel, audit panel |
| Authentication | Supabase Auth | Email and password accounts; issues the token the page sends with every call |
| Database | Supabase Postgres 17, schema `quiz` | Four data tables, questions, submissions, audit log, and the functions the page calls |
| Automation | GitHub Actions | Seeds and verifies the database with a secret, then deploys the page to GitHub Pages |

Request flow for a single **Run**:

1. The page calls `run_quiz_sql(question_id, sql)` through the Supabase REST API, passing the signed-in user's token.
2. The function confirms `auth.uid()` is present, rejects anything that is not a single `SELECT` or `WITH` statement, and hands the text to `quiz.exec_readonly()`.
3. `exec_readonly()` is a `SECURITY DEFINER` function owned by `quiz_reader`, a `NOLOGIN` role with `SELECT` on the four data tables and no other privilege. The query runs with exactly those rights.
4. The rows come back as JSON with column order preserved. One row is appended to `quiz.audit_log` recording user, question, SQL text, row count, and success or error.
5. The page renders the table and compares it with the stored expected result for that question.

## Taking the quiz

1. Open the [live quiz](https://luel-du.github.io/ids706-sql-quiz/) and click **Create account**. Any email address and a password of at least six characters work. With email confirmation disabled in the Supabase project (see [Deploying your own copy](#deploying-your-own-copy)), you are signed in immediately.
2. Select a question in the left panel and read the prompt.
3. Write SQL in the editor and click **Run**, or press Ctrl+Enter. Table names need no schema prefix, for example `select * from courses`. One statement per run.
4. Compare your rows with **Show hint**, which reveals the expected SQL and expected result. A check mark appears next to the question when your result matches exactly.
5. Click **Save answer** to store your SQL. **My activity** lists your own audit-log entries.

## Data model

The topic is a small university registrar. Four tables, three foreign keys, and one many-to-many bridge table give room for filters, joins across two to four tables, aggregates, and subqueries.

| Table | Columns | Keys |
| --- | --- | --- |
| `instructors` | id, name, department, hired_year | PK `id` |
| `courses` | id, code, title, credits, instructor_id | PK `id`; FK `instructor_id` --> `instructors`; UNIQUE `code` |
| `students` | id, name, major, start_year | PK `id` |
| `enrollments` | id, student_id, course_id, term, grade_points | PK `id`; FK `student_id` --> `students`; FK `course_id` --> `courses`; UNIQUE (`student_id`, `course_id`, `term`) |

Seed volume: 6 instructors, 10 courses, 15 students, 45 enrollments. All names are fictional. Three further tables support the quiz itself: `questions`, `submissions`, and `audit_log`.

### The questions

Five questions at 4 points each. They progress from a single-table filter and sort, through two- and three-table joins with aggregates, to a query that compares each student against an average. Prompts, expected SQL, and expected results are stored in `quiz.questions` and shown in the app to signed-in users. Grading compares result sets, not SQL text.

## Configuration

All configuration is through three values. Locally they live in `.env` (git-ignored); in GitHub they are repository secrets with the same names.

| Name | Purpose | Where to find it in Supabase |
| --- | --- | --- |
| `DATABASE_URL` | Session-pooler connection string used by the seed-and-verify script. Must end with `?sslmode=require`. | Project Settings --> Database --> Connection string --> Session pooler |
| `SUPABASE_URL` | Project URL the browser talks to | Project Settings --> API |
| `SUPABASE_ANON_KEY` | Public key the browser sends with every request. Grants nothing beyond what the function grants and RLS allow. | Project Settings --> API --> `anon` `public` (the newer `publishable` key also works) |

`.env.example` lists the names with placeholder values.

## Deploying your own copy

### 1. Supabase

1. Create a free project at https://supabase.com and note the database password.
2. Collect the three values from the [Configuration](#configuration) table.
3. Under **Authentication --> Sign In / Providers --> Email**, switch **Confirm email** off. Sign-ups then complete without an email round-trip, which also avoids the built-in mailer's hourly limit. Leaving it on works too; students then confirm by email before signing in.

### 2. Local machine

```bash
git clone https://github.com/luel-du/ids706-sql-quiz.git
cd ids706-sql-quiz
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env              # fill in the three values
python scripts/seed_and_verify.py
```

The script creates the schema, roles, functions, and policies, loads the seed data, and verifies the five hints. Expected output ends with `Q1 OK` through `Q5 OK` and `RESULT: PASS`. Add `--verify-only` to skip the apply step.

To run the page locally:

```bash
cp docs/config.example.js docs/config.js   # fill in SUPABASE_URL and SUPABASE_ANON_KEY
python -m http.server -d docs 8000          # open http://localhost:8000
```

### 3. GitHub

1. Push the repository to GitHub.
2. Under **Settings --> Secrets and variables --> Actions**, add `DATABASE_URL`, `SUPABASE_URL`, and `SUPABASE_ANON_KEY`.
3. Under **Settings --> Pages**, set **Source** to **GitHub Actions**.
4. Push to `main` or run the **CI** workflow manually. The site is published at `https://<account>.github.io/<repository>/`.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on manual dispatch.

| Job | Steps | Secrets used |
| --- | --- | --- |
| **Seed database and verify quiz hints** | Install Python dependencies; run `scripts/seed_and_verify.py`, which connects through the session pooler, applies `db/schema.sql` and `db/seed.sql`, checks that points sum to 20, re-runs each hint query and compares it with the stored result, and confirms the `anon` role cannot execute any quiz function | `DATABASE_URL` |
| **Deploy quiz site to GitHub Pages** | Write `docs/config.js` from secrets; upload `docs/` and deploy with `actions/deploy-pages` | `SUPABASE_URL`, `SUPABASE_ANON_KEY` |

The deploy job runs only after verification passes. GitHub masks secret values in logs. The workflow file contains no credentials.

## Security model

| Concern | Mechanism |
| --- | --- |
| Signed-out users cannot run or save | `EXECUTE` on the five public functions is granted to `authenticated` only and revoked from `anon` and `public`. Each function also raises if `auth.uid()` is null. |
| Student SQL cannot modify data | Queries execute inside `quiz.exec_readonly()`, owned by `quiz_reader`, a `NOLOGIN` role with `SELECT` on the four data tables only. Any write, and any read of `questions`, `submissions`, `audit_log`, or other schemas, fails with `permission denied`. Only a single `SELECT` or `WITH` statement is accepted; semicolons are rejected. |
| Students cannot see each other's answers | `submissions` and `audit_log` have Row Level Security enabled and forced with no policies for application roles. They are reachable only through functions that filter on `auth.uid()`. |
| The audit log cannot be altered | A `BEFORE UPDATE OR DELETE` trigger raises an exception for every role, including the table owner. |
| No SQL built from strings in application code | The page calls functions through `rpc()` with named parameters. The CI script uses psycopg2 `%s` parameters. The only dynamic SQL is the student's own query, which is the sandboxed feature itself. |
| Runaway queries | Supabase sets `statement_timeout` to 8 seconds for the `authenticated` role. Results are capped at 200 rows. |
| Secrets | The database password exists only in a local `.env` and in a GitHub Actions secret. The browser receives the anon key, which is public by design. |

## Project structure

```
.
|-- README.md
|-- .env.example                 variable names with placeholders
|-- .gitignore                   .env, docs/config.js, .venv/
|-- requirements.txt             psycopg2-binary, python-dotenv (pinned)
|-- db/
|   |-- schema.sql               schema quiz: tables, read-only role, functions, RLS, audit trigger (idempotent)
|   `-- seed.sql                 seed data and the five questions with hint SQL and hint results (idempotent)
|-- scripts/
|   `-- seed_and_verify.py       applies db/*.sql, verifies every hint, checks anon has no access
|-- docs/                        GitHub Pages site
|   |-- index.html
|   |-- app.js
|   |-- styles.css
|   `-- config.example.js        template for the local config.js (CI writes the real one from secrets)
`-- .github/workflows/
    `-- ci.yml                   seed-and-verify job, then deploy-pages job
```

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `permission denied for function run_quiz_sql` in the browser | You are signed out. Sign in. |
| `Missing config.js` on the page | Locally, copy `docs/config.example.js` to `docs/config.js`. In CI, check the two `SUPABASE_*` secrets. |
| `email rate limit exceeded` when creating an account | Confirm email is on and the built-in mailer's hourly limit was hit. Turn Confirm email off in Supabase, or wait an hour. |
| CI: `DATABASE_URL is not set` | Add the repository secret. |
| CI: connection error | Use the **Session pooler** connection string with `?sslmode=require`, not the direct connection. |
| CI: `Q3 MISMATCH` or similar | Seed data and a stored hint drifted apart. Fix `db/seed.sql` and push again. |

---

Built for IDS706 Data Engineering. Course topic and data are fictional and intended for teaching SQL.
