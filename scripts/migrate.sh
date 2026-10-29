#!/usr/bin/env bash
# Applies supabase/migrations/*.sql in order, once each, tracked in private.schema_migrations.
set -euo pipefail
: "${SUPABASE_DB_URL:?SUPABASE_DB_URL not set}"
cd "$(dirname "$0")/.."
PSQL=(psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -X -q)
"${PSQL[@]}" -c "create schema if not exists private; create table if not exists private.schema_migrations(name text primary key, applied_at timestamptz not null default now());"
for f in supabase/migrations/*.sql; do
  name=$(basename "$f")
  if [ "$("${PSQL[@]}" -tA -c "select 1 from private.schema_migrations where name = '$name'")" = "1" ]; then
    echo "skip  $name"; continue
  fi
  echo "apply $name"
  "${PSQL[@]}" --single-transaction -f "$f" -c "insert into private.schema_migrations(name) values ('$name')"
done
echo "verify security"
"${PSQL[@]}" -f supabase/tests/verify_security.sql
