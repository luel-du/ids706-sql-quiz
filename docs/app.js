/* IDS706 SQL Quiz: browser app.
 * Talks only to Supabase: Auth for sign-in, and four Postgres functions through rpc().
 * Every call uses named parameters; no SQL is built by string concatenation here.
 * The database refuses run/save for signed-out users even if this page is bypassed.
 */
(function () {
  const cfg = window.QUIZ_CONFIG || {};
  const $ = (id) => document.getElementById(id);

  if (!cfg.supabaseUrl || !cfg.supabaseAnonKey) {
    $("auth-msg").textContent = "Missing config.js (SUPABASE_URL / SUPABASE_ANON_KEY). See README.";
    $("auth-msg").className = "msg bad";
    return;
  }
  const sb = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
  if (cfg.repoUrl) $("repo-link").href = cfg.repoUrl;

  let questions = [];
  let answers = {};      // question_id -> latest saved sql
  let current = null;    // current question object

  // ---------- helpers ----------
  function setMsg(el, text, kind) { el.textContent = text || ""; el.className = "msg" + (kind ? " " + kind : ""); }
  function errText(e) { return (e && (e.message || e.error_description || e.hint)) || String(e); }

  function renderTable(container, rows, opts) {
    container.innerHTML = "";
    if (!Array.isArray(rows)) { container.textContent = ""; return; }
    const note = document.createElement("p");
    note.className = "muted small";
    if (rows.length === 0) { note.textContent = "0 rows"; container.appendChild(note); return; }
    const cols = Object.keys(rows[0]);
    const table = document.createElement("table");
    table.className = "grid";
    const thead = table.createTHead().insertRow();
    cols.forEach((c) => { const th = document.createElement("th"); th.textContent = c; thead.appendChild(th); });
    const tbody = table.createTBody();
    rows.forEach((r) => {
      const tr = tbody.insertRow();
      cols.forEach((c) => {
        const td = tr.insertCell();
        const v = r[c];
        td.textContent = v === null || v === undefined ? "NULL" : (typeof v === "object" ? JSON.stringify(v) : String(v));
        if (typeof v === "number") td.className = "num";
      });
    });
    container.appendChild(table);
    note.textContent = rows.length + (rows.length === 1 ? " row" : " rows") + ((opts && opts.truncated) ? " (showing the first 200)" : "");
    container.appendChild(note);
  }

  // ---------- auth ----------
  async function refreshSession() {
    const { data } = await sb.auth.getSession();
    const user = data.session && data.session.user;
    $("auth").hidden = !!user;
    $("quiz").hidden = !user;
    $("btn-signout").hidden = !user;
    $("user-email").textContent = user ? user.email : "";
    if (user) await loadQuiz();
  }

  $("auth-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    setMsg($("auth-msg"), "Signing in...");
    const { error } = await sb.auth.signInWithPassword({ email: $("email").value.trim(), password: $("password").value });
    if (error) return setMsg($("auth-msg"), errText(error), "bad");
    setMsg($("auth-msg"), "");
  });

  $("btn-signup").addEventListener("click", async () => {
    const email = $("email").value.trim(), password = $("password").value;
    if (!email || password.length < 6) return setMsg($("auth-msg"), "Enter an email and a password of at least 6 characters.", "bad");
    setMsg($("auth-msg"), "Creating account...");
    const { data, error } = await sb.auth.signUp({ email, password });
    if (error) return setMsg($("auth-msg"), errText(error), "bad");
    if (data.session) return setMsg($("auth-msg"), "Account created. You are signed in.", "ok");
    setMsg($("auth-msg"), "Account created. Check your email for a confirmation link, then sign in.", "ok");
  });

  $("btn-signout").addEventListener("click", async () => { await sb.auth.signOut(); });
  sb.auth.onAuthStateChange(() => { refreshSession(); });

  // ---------- quiz ----------
  async function loadQuiz() {
    const [q, a] = await Promise.all([sb.rpc("list_questions"), sb.rpc("my_answers")]);
    if (q.error) return setMsg($("run-msg"), "Could not load questions: " + errText(q.error), "bad");
    questions = q.data || [];
    answers = {};
    (a.data || []).forEach((row) => { answers[row.question_id] = row.sql_text; });
    renderQuestionList();
    $("total-points").textContent = questions.reduce((s, x) => s + x.points, 0);
    if (!current && questions.length) selectQuestion(questions[0].id);
    else if (current) selectQuestion(current.id, true);
  }

  function renderQuestionList() {
    const ol = $("question-list");
    ol.innerHTML = "";
    questions.forEach((q) => {
      const li = document.createElement("li");
      li.dataset.id = q.id;
      if (current && current.id === q.id) li.classList.add("active");
      const left = document.createElement("span");
      left.textContent = "Q" + q.ord + " · " + q.points + " pts";
      const right = document.createElement("span");
      right.className = "saved";
      right.textContent = answers[q.id] ? "saved" : "";
      li.append(left, right);
      li.addEventListener("click", () => selectQuestion(q.id));
      ol.appendChild(li);
    });
  }

  function selectQuestion(id, keepEditor) {
    current = questions.find((q) => q.id === id);
    if (!current) return;
    document.querySelectorAll("#question-list li").forEach((li) => li.classList.toggle("active", Number(li.dataset.id) === id));
    $("q-points").textContent = current.points + " points";
    $("q-title").textContent = "Question " + current.ord;
    $("q-prompt").textContent = current.prompt;
    if (!keepEditor) $("sql").value = answers[id] || "";
    $("result").innerHTML = "";
    setMsg($("run-msg"), "");
    $("hint").open = false;
    $("hint-sql").textContent = current.hint_sql;
    renderTable($("hint-result"), current.hint_result);
  }

  $("btn-hint").addEventListener("click", () => { $("hint").open = !$("hint").open; if ($("hint").open) $("hint").scrollIntoView({ behavior: "smooth", block: "nearest" }); });

  $("btn-run").addEventListener("click", async () => {
    if (!current) return;
    const sql = $("sql").value;
    setMsg($("run-msg"), "Running...");
    $("btn-run").disabled = true;
    try {
      const { data, error } = await sb.rpc("run_quiz_sql", { p_question_id: current.id, p_sql: sql });
      if (error) throw error;
      if (!data.ok) { $("result").innerHTML = ""; return setMsg($("run-msg"), "Error: " + data.error, "bad"); }
      renderTable($("result"), data.rows, { truncated: data.truncated });
      const match = JSON.stringify(data.rows) === JSON.stringify(current.hint_result);
      setMsg($("run-msg"), match ? "Result matches the expected answer." : "Ran. Compare with the hint.", match ? "ok" : "");
    } catch (e) {
      $("result").innerHTML = "";
      setMsg($("run-msg"), "Error: " + errText(e), "bad");
    } finally {
      $("btn-run").disabled = false;
      loadAudit();
    }
  });

  $("btn-save").addEventListener("click", async () => {
    if (!current) return;
    setMsg($("run-msg"), "Saving...");
    try {
      const { data, error } = await sb.rpc("save_answer", { p_question_id: current.id, p_sql: $("sql").value });
      if (error) throw error;
      answers[current.id] = $("sql").value;
      renderQuestionList();
      setMsg($("run-msg"), "Saved (submission #" + data.submission_id + ").", "ok");
    } catch (e) {
      setMsg($("run-msg"), "Error: " + errText(e), "bad");
    } finally {
      loadAudit();
    }
  });

  async function loadAudit() {
    const { data, error } = await sb.rpc("my_audit_log");
    if (error) { $("audit").textContent = errText(error); return; }
    renderTable($("audit"), (data || []).map((r) => ({
      when: new Date(r.created_at).toLocaleString(), action: r.action, question: r.question_id,
      ok: r.ok, rows: r.row_count, error: r.error,
    })));
  }

  refreshSession();
})();
