// Public configuration. The anon (publishable) key is safe to publish: every table is locked by RLS and
// all access goes through server functions that never return answer keys.
window.EXAM_CONFIG = {
  SUPABASE_URL: "https://czqtzjkkxpzixiiplvro.supabase.co",
  SUPABASE_ANON_KEY: "", // <- paste the project's anon / publishable key here
  TIME_ZONE: "Africa/Cairo",
};
