-- IDS706 SQL Quiz: seed data. Idempotent: data tables are rebuilt, questions are upserted
-- (so students' saved answers and the audit log, which reference questions, survive re-runs).
-- All people and courses are fictional.
-- Run inside one transaction: psql -1 -f db/seed.sql, or via scripts/seed_and_verify.py.

delete from quiz.enrollments;
delete from quiz.courses;
delete from quiz.students;
delete from quiz.instructors;

insert into quiz.instructors (id, name, department, hired_year) values
  (1, 'Maria Chen',      'Computer Science',    2012),
  (2, 'David Okafor',    'Statistics',          2016),
  (3, 'Priya Raman',     'Computer Science',    2019),
  (4, 'James Whitfield', 'Mathematics',         2008),
  (5, 'Sofia Alvarez',   'Information Science', 2021),
  (6, 'Daniel Kim',      'Statistics',          2014);

insert into quiz.courses (id, code, title, credits, instructor_id) values
  (1,  'CS201',   'Data Structures',      4, 1),
  (2,  'CS305',   'Database Systems',     4, 3),
  (3,  'CS410',   'Data Engineering',     3, 1),
  (4,  'STAT210', 'Probability',          4, 2),
  (5,  'STAT320', 'Statistical Learning', 3, 6),
  (6,  'MATH150', 'Linear Algebra',       4, 4),
  (7,  'MATH240', 'Discrete Mathematics', 3, 4),
  (8,  'INFO110', 'Data Ethics',          2, 5),
  (9,  'INFO330', 'Data Visualization',   3, 5),
  (10, 'STAT250', 'Regression Analysis',  3, 2);

insert into quiz.students (id, name, major, start_year) values
  (1,  'Ava Thompson',    'Computer Science',    2023),
  (2,  'Liam Patel',      'Statistics',          2022),
  (3,  'Noah Garcia',     'Mathematics',         2023),
  (4,  'Emma Nguyen',     'Computer Science',    2024),
  (5,  'Olivia Brooks',   'Information Science', 2022),
  (6,  'Ethan Rossi',     'Statistics',          2023),
  (7,  'Mia Johansson',   'Computer Science',    2024),
  (8,  'Lucas Haddad',    'Mathematics',         2022),
  (9,  'Isabella Moreau', 'Information Science', 2023),
  (10, 'Mason Reyes',     'Computer Science',    2022),
  (11, 'Chloe Adeyemi',   'Statistics',          2024),
  (12, 'Benjamin Sato',   'Mathematics',         2023),
  (13, 'Zoe Fischer',     'Information Science', 2024),
  (14, 'Elijah Novak',    'Computer Science',    2023),
  (15, 'Grace Mbeki',     'Statistics',          2022);

-- Every student takes three courses: two in Fall 2025, one in Spring 2026.
insert into quiz.enrollments (id, student_id, course_id, term, grade_points) values
  (1,  1,  1,  'Fall 2025',   3.70), (2,  1,  2,  'Fall 2025',   3.30), (3,  1,  6,  'Spring 2026', 4.00),
  (4,  2,  4,  'Fall 2025',   3.00), (5,  2,  5,  'Fall 2025',   3.30), (6,  2,  6,  'Spring 2026', 2.70),
  (7,  3,  6,  'Fall 2025',   3.70), (8,  3,  7,  'Fall 2025',   4.00), (9,  3,  4,  'Spring 2026', 3.30),
  (10, 4,  1,  'Fall 2025',   2.30), (11, 4,  8,  'Fall 2025',   3.00), (12, 4,  6,  'Spring 2026', 3.00),
  (13, 5,  8,  'Fall 2025',   4.00), (14, 5,  9,  'Fall 2025',   3.70), (15, 5,  2,  'Spring 2026', 3.00),
  (16, 6,  4,  'Fall 2025',   2.00), (17, 6,  10, 'Fall 2025',   2.70), (18, 6,  7,  'Spring 2026', 3.00),
  (19, 7,  1,  'Fall 2025',   4.00), (20, 7,  2,  'Fall 2025',   3.70), (21, 7,  3,  'Spring 2026', 3.30),
  (22, 8,  6,  'Fall 2025',   2.00), (23, 8,  7,  'Fall 2025',   2.30), (24, 8,  4,  'Spring 2026', 2.70),
  (25, 9,  8,  'Fall 2025',   3.30), (26, 9,  9,  'Fall 2025',   4.00), (27, 9,  10, 'Spring 2026', 3.00),
  (28, 10, 2,  'Fall 2025',   3.00), (29, 10, 3,  'Fall 2025',   3.70), (30, 10, 5,  'Spring 2026', 3.30),
  (31, 11, 4,  'Fall 2025',   3.70), (32, 11, 10, 'Fall 2025',   4.00), (33, 11, 8,  'Spring 2026', 3.70),
  (34, 12, 6,  'Fall 2025',   4.00), (35, 12, 7,  'Fall 2025',   3.70), (36, 12, 1,  'Spring 2026', 3.00),
  (37, 13, 8,  'Fall 2025',   2.70), (38, 13, 9,  'Fall 2025',   3.00), (39, 13, 1,  'Spring 2026', 2.00),
  (40, 14, 1,  'Fall 2025',   3.30), (41, 14, 3,  'Fall 2025',   4.00), (42, 14, 7,  'Spring 2026', 3.70),
  (43, 15, 4,  'Fall 2025',   4.00), (44, 15, 5,  'Fall 2025',   3.70), (45, 15, 10, 'Spring 2026', 3.30);

-- ---------------------------------------------------------------------------
-- The quiz: 5 questions x 4 points = 20 points.
-- hint_result is the exact JSON the hint_sql returns against this seed; CI verifies it.
-- ---------------------------------------------------------------------------
insert into quiz.questions (id, ord, points, prompt, hint_sql, hint_result) values
(1, 1, 4,
 'List the code, title, and credits of every course worth 4 credits. Order the rows by code.',
 $q$select code, title, credits
from courses
where credits = 4
order by code;$q$,
 $j$[{"code":"CS201","title":"Data Structures","credits":4}, {"code":"CS305","title":"Database Systems","credits":4}, {"code":"MATH150","title":"Linear Algebra","credits":4}, {"code":"STAT210","title":"Probability","credits":4}]$j$),

(2, 2, 4,
 'Show each course title together with the name of its instructor (call the column instructor). Sort by instructor name, then by title.',
 $q$select c.title, i.name as instructor
from courses c
join instructors i on i.id = c.instructor_id
order by i.name, c.title;$q$,
 $j$[{"title":"Statistical Learning","instructor":"Daniel Kim"}, {"title":"Probability","instructor":"David Okafor"}, {"title":"Regression Analysis","instructor":"David Okafor"}, {"title":"Discrete Mathematics","instructor":"James Whitfield"}, {"title":"Linear Algebra","instructor":"James Whitfield"}, {"title":"Data Engineering","instructor":"Maria Chen"}, {"title":"Data Structures","instructor":"Maria Chen"}, {"title":"Database Systems","instructor":"Priya Raman"}, {"title":"Data Ethics","instructor":"Sofia Alvarez"}, {"title":"Data Visualization","instructor":"Sofia Alvarez"}]$j$),

(3, 3, 4,
 'How many students are enrolled in each course? Show the course title and the count (call it students), largest count first, then by title.',
 $q$select c.title, count(*) as students
from enrollments e
join courses c on c.id = e.course_id
group by c.title
order by students desc, c.title;$q$,
 $j$[{"title":"Data Structures","students":6}, {"title":"Linear Algebra","students":6}, {"title":"Probability","students":6}, {"title":"Data Ethics","students":5}, {"title":"Discrete Mathematics","students":5}, {"title":"Database Systems","students":4}, {"title":"Regression Analysis","students":4}, {"title":"Data Engineering","students":3}, {"title":"Data Visualization","students":3}, {"title":"Statistical Learning","students":3}]$j$),

(4, 4, 4,
 'What is the average grade (grade_points) earned across each instructor''s courses? Show the instructor name and the average rounded to 2 decimals (call it avg_grade), highest first, then by name.',
 $q$select i.name as instructor, round(avg(e.grade_points), 2) as avg_grade
from instructors i
join courses c on c.instructor_id = i.id
join enrollments e on e.course_id = c.id
group by i.name
order by avg_grade desc, i.name;$q$,
 $j$[{"instructor":"Daniel Kim","avg_grade":3.43}, {"instructor":"Sofia Alvarez","avg_grade":3.43}, {"instructor":"James Whitfield","avg_grade":3.28}, {"instructor":"Maria Chen","avg_grade":3.26}, {"instructor":"Priya Raman","avg_grade":3.25}, {"instructor":"David Okafor","avg_grade":3.17}]$j$),

(5, 5, 4,
 'Which students have earned more total credits than the average student? Show the student name and total credits (call it total_credits), highest first, then by name.',
 $q$with totals as (
  select s.name, sum(c.credits) as total_credits
  from students s
  join enrollments e on e.student_id = s.id
  join courses c on c.id = e.course_id
  group by s.id, s.name
)
select name, total_credits
from totals
where total_credits > (select avg(total_credits) from totals)
order by total_credits desc, name;$q$,
 $j$[{"name":"Ava Thompson","total_credits":12}, {"name":"Benjamin Sato","total_credits":11}, {"name":"Liam Patel","total_credits":11}, {"name":"Lucas Haddad","total_credits":11}, {"name":"Mia Johansson","total_credits":11}, {"name":"Noah Garcia","total_credits":11}]$j$)
on conflict (id) do update set
  ord = excluded.ord, points = excluded.points, prompt = excluded.prompt,
  hint_sql = excluded.hint_sql, hint_result = excluded.hint_result;

