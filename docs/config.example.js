// Copy to config.js for local testing. In CI, deploy-pages writes config.js from GitHub Secrets.
// The anon key is a public, rate-limited key; it grants nothing beyond what RLS and function grants allow.
window.QUIZ_CONFIG = {
  supabaseUrl: "https://PROJECT_REF.supabase.co",
  supabaseAnonKey: "eyJ...",
  repoUrl: "https://github.com/luel-du/ids706-sql-quiz",
};
