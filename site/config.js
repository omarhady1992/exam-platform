// Public configuration. The anon (publishable) key is safe to publish: every table is locked by RLS and
// all access goes through server functions that never return answer keys.
window.EXAM_CONFIG = {
  SUPABASE_URL: "https://czqtzjkkxpzixiiplvro.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImN6cXR6amtreHB6aXhpaXBsdnJvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTMyOTQyNjQsImV4cCI6MjEwODg3MDI2NH0.N0nEf8vzNLrHFk6O1tQSlD-K-Q1gvH4OdyZlgSx9Zf0", // <- paste the project's anon / publishable key here
  TIME_ZONE: "Africa/Cairo",
};
