/* IDS706 SQL Quiz: browser app.
 * Talks only to Supabase: Auth for sign-in, and Postgres functions through rpc().
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
  let matched = {};      // question_id -> true when a run matched the expected result (this session only)
  let keys = {};         // question_id -> revealed answer key {hint_sql, hint_result}
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
    if (opts && opts.totalRows !== undefined) {
      const more = opts.totalRows - rows.length;
      note.textContent = more > 0 ? "... and " + more + " more " + (more === 1 ? "row" : "rows") + " (" + opts.totalRows + " in total)" : opts.totalRows + (opts.totalRows === 1 ? " row" : " rows") + " in total";
    } else {
      note.textContent = rows.length + (rows.length === 1 ? " row" : " rows") + ((opts && opts.truncated) ? " (showing the first 200)" : "");
    }
    container.appendChild(note);
  }

  // ---------- auth ----------
  // Forget everything from the previous session: questions, editor text, results,
  // match marks, revealed answer keys, and the activity panel.
  function resetState() {
    questions = []; answers = {}; matched = {}; keys = {}; current = null;
    $("question-list").innerHTML = "";
    $("total-points").textContent = "";
    $("q-points").textContent = ""; $("q-title").textContent = "Pick a question"; $("q-prompt").textContent = "";
    $("q-shape").textContent = ""; $("q-sample").innerHTML = "";
    $("sql").value = "";
    $("result").innerHTML = ""; $("audit").innerHTML = "";
    $("hint").hidden = true; $("hint-sql").textContent = ""; $("hint-result").innerHTML = "";
    $("btn-hint").textContent = "Reveal answer key";
    setMsg($("run-msg"), "");
  }

  let currentUserId = null;
  async function refreshSession() {
    const { data } = await sb.auth.getSession();
    const user = data.session && data.session.user;
    if (!user || user.id !== currentUserId) resetState();   // signed out, or a different user signed in
    currentUserId = user ? user.id : null;
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

  $("btn-signout").addEventListener("click", async () => {
    $("quiz").hidden = true;
    resetState();
    try { await sb.auth.signOut(); } catch (e) { /* local session is cleared regardless */ }
    await refreshSession();
  });
  sb.auth.onAuthStateChange(() => { refreshSession(); });
  // A page restored from the back/forward cache keeps its old DOM; re-check the session.
  window.addEventListener("pageshow", (ev) => { if (ev.persisted) refreshSession(); });

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
      right.textContent = [matched[q.id] ? "\u2713 match" : "", answers[q.id] ? "saved" : ""].filter(Boolean).join(" \u00b7 ");
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
    $("q-shape").textContent = (current.columns || []).length + " column" + (current.columns.length === 1 ? "" : "s") + " (" + (current.columns || []).join(", ") + "), " + current.row_count + " row" + (current.row_count === 1 ? "" : "s");
    renderTable($("q-sample"), current.sample_rows || [], { totalRows: current.row_count });
    showKey(keys[id]);
  }

  function showKey(key) {
    $("hint").hidden = !key;
    $("btn-hint").textContent = key ? "Hide answer key" : "Reveal answer key";
    if (!key) return;
    $("hint-sql").textContent = key.hint_sql;
    renderTable($("hint-result"), key.hint_result);
  }

  $("btn-hint").addEventListener("click", async () => {
    if (!current) return;
    if (!$("hint").hidden) { $("hint").hidden = true; $("btn-hint").textContent = "Reveal answer key"; return; }
    if (keys[current.id]) { showKey(keys[current.id]); return; }
    if (!window.confirm("Reveal the full answer key for question " + current.ord + "? This shows the expected SQL and result, and the reveal is recorded in your activity log.")) return;
    $("btn-hint").disabled = true;
    try {
      const { data, error } = await sb.rpc("reveal_answer_key", { p_question_id: current.id });
      if (error) throw error;
      keys[current.id] = data;
      showKey(data);
      $("hint").scrollIntoView({ behavior: "smooth", block: "nearest" });
    } catch (e) {
      setMsg($("run-msg"), "Error: " + errText(e), "bad");
    } finally {
      $("btn-hint").disabled = false;
      loadAudit();
    }
  });

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
      const match = data.matched === true;
      if (match) matched[current.id] = true;
      renderQuestionList();
      setMsg($("run-msg"), match ? "Result matches the expected output." : "Ran. Compare with the expected output above.", match ? "ok" : "");
    } catch (e) {
      $("result").innerHTML = "";
      setMsg($("run-msg"), "Error: " + errText(e), "bad");
    } finally {
      $("btn-run").disabled = false;
      loadAudit();
    }
  });

  // Ctrl+Enter (or Cmd+Enter) in the editor runs the query.
  $("sql").addEventListener("keydown", (ev) => {
    if ((ev.ctrlKey || ev.metaKey) && ev.key === "Enter") { ev.preventDefault(); $("btn-run").click(); }
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
      ok: r.ok, matched: r.action === "run" ? r.matched : null, rows: r.row_count, error: r.error,
    })));
  }

  refreshSession();
})();
