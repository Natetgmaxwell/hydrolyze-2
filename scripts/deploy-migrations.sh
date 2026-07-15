#!/usr/bin/env bash
#
# deploy-migrations.sh — Hydrolyze Supabase migration deployment.
#
# PURPOSE
#   Apply SQL migrations from supabase/migrations to the configured Supabase
#   PostgreSQL database. Applied versions are recorded in
#   supabase_migrations.schema_migrations so repeated runs are idempotent.
#
# USAGE
#   bash scripts/deploy-migrations.sh --check
#   bash scripts/deploy-migrations.sh --dry-run --apply
#   bash scripts/deploy-migrations.sh --apply [--force]
#   bash scripts/deploy-migrations.sh --migration <file>
#   bash scripts/deploy-migrations.sh --help
#
# MODES
#   --check              Test the connection and list recorded migrations.
#                        This is the default when no mode is supplied.
#   --apply              Apply every pending migration in filename order.
#   --migration <file>   Apply one migration from supabase/migrations.
#   --dry-run            Print planned database operations without connecting.
#   --force              Skip the confirmation required for 4+ migrations.
#   --help, -h           Print this help text and exit.
#
# CONFIGURATION
#   DATABASE_URL is loaded from the first file below that defines it:
#     1. /Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/.env
#     2. ~/.config/hydrolyze/.env
#
# EXIT CODES
#   0   Connection check or requested deployment succeeded.
#   1   Connection, bootstrap, or migration execution failed.
#   2   Arguments, configuration, or local migration files are invalid.
#
# SAFETY
#   Each migration and its tracking INSERT share one PostgreSQL transaction.
#   A failed migration rolls back, prints ✗, and stops all later migrations.
#   Existing migration-level BEGIN/COMMIT wrappers are preserved; the tracking
#   row is inserted immediately before their COMMIT.
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Fixed Hydrolyze paths and defaults
# ---------------------------------------------------------------------------

PROJECT_ROOT='/Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2'
MIGRATIONS_DIR="${PROJECT_ROOT}/supabase/migrations"
PROJECT_ENV="${PROJECT_ROOT}/.env"
HOME_ENV="${HOME}/.config/hydrolyze/.env"

MODE='check'
MODE_SET=0
MIGRATION_ARG=''
DRY_RUN=0
FORCE=0
ENV_SOURCE=''
DATABASE_URL=''

# Filename expansion must follow bytewise chronological order. Supabase
# migration names begin with fixed-width timestamps, so this is chronological.
export LC_ALL=C

# ---------------------------------------------------------------------------
# Help and argument parsing
# ---------------------------------------------------------------------------

print_help() {
  cat <<'HELP'
Hydrolyze Supabase migration deployment

Usage:
  deploy-migrations.sh [--check] [--dry-run]
  deploy-migrations.sh --apply [--dry-run] [--force]
  deploy-migrations.sh --migration <file> [--dry-run]
  deploy-migrations.sh --help

Modes:
  --check              Test the connection and list recorded migrations.
                       This is the default when no mode is supplied.
  --apply              Apply all pending *.sql files in filename order.
  --migration <file>   Apply one file from supabase/migrations.

Options:
  --dry-run            Print planned operations without contacting the database.
  --force              Skip confirmation when 4 or more migrations are pending.
  --help, -h           Show this help and exit.

Configuration lookup order:
  1. /Users/nathanmaxwell/Documents/VS Code/Hydrolyze 2/.env
  2. ~/.config/hydrolyze/.env

Each applied migration runs atomically with its schema_migrations tracking row.
HELP
  exit 0
}

blocked_usage() {
  echo "BLOCKED: $1" >&2
  echo "Run '$0 --help' for usage." >&2
  exit 2
}

# Only one execution mode may be selected. Repeating the same mode is harmless,
# but combining --check, --apply, and --migration is rejected.
select_mode() {
  local requested="$1"
  if [[ "$MODE_SET" -eq 1 && "$MODE" != "$requested" ]]; then
    blocked_usage "choose only one of --check, --apply, or --migration."
  fi
  MODE="$requested"
  MODE_SET=1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --check)
      select_mode 'check'
      shift
      ;;
    --apply)
      select_mode 'apply'
      shift
      ;;
    --migration)
      if [[ "$#" -lt 2 || -z "$2" || "$2" == --* ]]; then
        blocked_usage '--migration requires a .sql filename.'
      fi
      if [[ -n "$MIGRATION_ARG" ]]; then
        blocked_usage '--migration may be supplied only once.'
      fi
      select_mode 'migration'
      MIGRATION_ARG="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      print_help
      ;;
    --*)
      blocked_usage "unknown flag: $1"
      ;;
    *)
      blocked_usage "unexpected positional argument: $1"
      ;;
  esac
done

# Help intentionally works without local dependencies. Every operational mode,
# including dry-run, verifies that the command it plans to use is installed.
if ! command -v psql >/dev/null 2>&1; then
  echo "BLOCKED: psql is not on PATH. Install it with 'brew install postgresql'." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# DATABASE_URL loading
# ---------------------------------------------------------------------------

# Source an env file rather than parsing it as ad hoc text, preserving standard
# shell quoting for passwords and query parameters. nounset is relaxed only
# while a trusted local env file is being sourced.
source_env_file() {
  local env_file="$1"
  local source_status=0

  set +u
  set -a
  # shellcheck disable=SC1090
  if source "$env_file"; then
    source_status=0
  else
    source_status=$?
  fi
  set +a
  set -u

  if [[ "$source_status" -ne 0 ]]; then
    echo "BLOCKED: could not source DATABASE_URL from $env_file" >&2
    exit 2
  fi
}

# Project-local configuration wins. The home-folder fallback is consulted only
# when the project file is absent or does not define a non-empty DATABASE_URL.
if [[ -f "$PROJECT_ENV" ]]; then
  source_env_file "$PROJECT_ENV"
  if [[ -n "${DATABASE_URL:-}" ]]; then
    ENV_SOURCE="$PROJECT_ENV"
  fi
fi

if [[ -z "${DATABASE_URL:-}" && -f "$HOME_ENV" ]]; then
  source_env_file "$HOME_ENV"
  if [[ -n "${DATABASE_URL:-}" ]]; then
    ENV_SOURCE="$HOME_ENV"
  fi
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo 'BLOCKED: DATABASE_URL is not set.' >&2
  echo "  checked: $PROJECT_ENV" >&2
  echo "  checked: $HOME_ENV" >&2
  exit 2
fi

# -X ignores ~/.psqlrc so operator-local formatting or variables cannot change
# deployment behavior. --no-password prevents an unexpected interactive prompt.
PSQL=(psql -X --no-password -v ON_ERROR_STOP=1 "$DATABASE_URL")

# ---------------------------------------------------------------------------
# Migration discovery and metadata
# ---------------------------------------------------------------------------

validate_migration_filename() {
  local file="$1"
  local base="${file##*/}"
  local stem="${base%.sql}"

  if [[ "$base" == "$stem" || ! "$stem" =~ ^[0-9]+_.+ ]]; then
    echo "BLOCKED: migration must be named <version>_<name>.sql: $file" >&2
    return 2
  fi
}

# Resolve either a basename or an absolute path, then require the selected file
# to live directly in Hydrolyze's migration directory.
resolve_specific_migration() {
  local requested="$1"
  local candidate
  local candidate_dir
  local migrations_dir_real

  if [[ "$requested" == */* ]]; then
    candidate="$requested"
  else
    candidate="${MIGRATIONS_DIR}/${requested}"
  fi

  if [[ ! -f "$candidate" ]]; then
    echo "BLOCKED: migration file not found: $candidate" >&2
    return 2
  fi

  candidate_dir="$(cd "$(dirname "$candidate")" && pwd -P)"
  migrations_dir_real="$(cd "$MIGRATIONS_DIR" && pwd -P)"
  if [[ "$candidate_dir" != "$migrations_dir_real" ]]; then
    echo "BLOCKED: --migration must select a file in $MIGRATIONS_DIR" >&2
    return 2
  fi

  candidate="${candidate_dir}/${candidate##*/}"
  validate_migration_filename "$candidate" || return $?
  printf '%s\n' "$candidate"
}

collect_all_migrations() {
  if [[ ! -d "$MIGRATIONS_DIR" ]]; then
    echo "BLOCKED: migration directory not found: $MIGRATIONS_DIR" >&2
    return 2
  fi

  shopt -s nullglob
  ALL_MIGRATIONS=("$MIGRATIONS_DIR"/*.sql)
  shopt -u nullglob

  if [[ "${#ALL_MIGRATIONS[@]}" -eq 0 ]]; then
    echo "BLOCKED: no .sql migrations found in $MIGRATIONS_DIR" >&2
    return 2
  fi

  local file
  for file in "${ALL_MIGRATIONS[@]}"; do
    validate_migration_filename "$file" || return $?
  done
}

# ---------------------------------------------------------------------------
# Database connection and migration history bootstrap
# ---------------------------------------------------------------------------

connection_test() {
  echo 'Testing Supabase PostgreSQL connection...'
  if ! "${PSQL[@]}" -qAt -c 'select 1' >/dev/null; then
    echo 'BLOCKED: psql connection test failed.' >&2
    exit 1
  fi
  echo 'Connection OK.'
}

# This bookkeeping DDL is intentionally idempotent. ALTER covers an older table
# that may have been created with only the version column.
bootstrap_migration_history() {
  if ! "${PSQL[@]}" -q <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text PRIMARY KEY,
  name text
);
ALTER TABLE supabase_migrations.schema_migrations
  ADD COLUMN IF NOT EXISTS name text;
SQL
  then
    echo 'BLOCKED: could not bootstrap supabase_migrations.schema_migrations.' >&2
    exit 1
  fi
}

list_recorded_migrations() {
  echo
  echo 'Recorded migrations in supabase_migrations.schema_migrations:'
  "${PSQL[@]}" -P pager=off -c \
    "SELECT version, COALESCE(name, '') AS name FROM supabase_migrations.schema_migrations ORDER BY version;"
}

# Return 0 when a version is recorded, 1 when pending, and 2 for a query error.
# Versions are digits validated from filenames, so embedding one as a SQL
# literal cannot introduce arbitrary SQL.
is_migration_applied() {
  local file="$1"
  local base="${file##*/}"
  local stem="${base%.sql}"
  local version="${stem%%_*}"
  local result

  if ! result="$("${PSQL[@]}" -qAt -c \
      "SELECT EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations WHERE version = '$version');")"; then
    echo "BLOCKED: could not check migration version $version." >&2
    return 2
  fi

  [[ "$result" == 't' ]]
}

# ---------------------------------------------------------------------------
# Per-migration atomic execution
# ---------------------------------------------------------------------------

# Count standalone transaction controls. Most historical Hydrolyze migrations
# include exactly one outer BEGIN/COMMIT pair, while newer one-line migrations
# rely on this deployer to supply the transaction. Ambiguous transaction control
# is rejected rather than risking a partially committed migration.
transaction_control_counts() {
  local file="$1"
  local line
  local begin_count=0
  local commit_count=0
  local begin_pattern='^[[:space:]]*BEGIN([[:space:]]+(WORK|TRANSACTION))?[[:space:]]*;[[:space:]]*(--.*)?$'
  local commit_pattern='^[[:space:]]*COMMIT([[:space:]]+(WORK|TRANSACTION))?[[:space:]]*;[[:space:]]*(--.*)?$'

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $begin_pattern ]]; then
      begin_count=$((begin_count + 1))
    fi
    if [[ "$line" =~ $commit_pattern ]]; then
      commit_count=$((commit_count + 1))
    fi
  done < "$file"

  printf '%s %s\n' "$begin_count" "$commit_count"
}

# Stream a migration that already owns its transaction. The tracking INSERT is
# emitted immediately before the sole COMMIT, making the migration and history
# update one atomic unit.
stream_existing_transaction() {
  local file="$1"
  local insert_sql="$2"
  local line
  local commit_pattern='^[[:space:]]*COMMIT([[:space:]]+(WORK|TRANSACTION))?[[:space:]]*;[[:space:]]*(--.*)?$'

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $commit_pattern ]]; then
      printf '%s\n' "$insert_sql"
    fi
    printf '%s\n' "$line"
  done < "$file"
}

# Stream a migration without transaction controls inside a deployer-owned
# BEGIN/COMMIT pair, with the tracking INSERT before COMMIT.
stream_managed_transaction() {
  local file="$1"
  local insert_sql="$2"
  local line

  printf 'BEGIN;\n'
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
  done < "$file"
  printf '\n%s\nCOMMIT;\n' "$insert_sql"
}

apply_migration() {
  local file="$1"
  local base="${file##*/}"
  local stem="${base%.sql}"
  local version="${stem%%_*}"
  local name="${stem#*_}"
  local escaped_name="${name//\'/\'\'}"
  local insert_sql="INSERT INTO supabase_migrations.schema_migrations (version, name) VALUES ('$version', '$escaped_name');"
  local counts
  local begin_count
  local commit_count

  echo "$file — applying"

  counts="$(transaction_control_counts "$file")"
  begin_count="${counts%% *}"
  commit_count="${counts##* }"

  if [[ "$begin_count" -eq 1 && "$commit_count" -eq 1 ]]; then
    if ! stream_existing_transaction "$file" "$insert_sql" | "${PSQL[@]}"; then
      echo "✗ $file failed; no later migration was attempted." >&2
      return 1
    fi
  elif [[ "$begin_count" -eq 0 && "$commit_count" -eq 0 ]]; then
    if ! stream_managed_transaction "$file" "$insert_sql" | "${PSQL[@]}"; then
      echo "✗ $file failed; no later migration was attempted." >&2
      return 1
    fi
  else
    echo "✗ $file has ambiguous transaction controls (BEGIN=$begin_count, COMMIT=$commit_count)." >&2
    echo '  Expected either no standalone controls or one outer BEGIN/COMMIT pair.' >&2
    return 1
  fi

  echo "✓ $file"
}

# ---------------------------------------------------------------------------
# Dry-run planning
# ---------------------------------------------------------------------------

print_dry_run() {
  local file

  echo 'Hydrolyze Supabase migration deployment (dry-run)'
  echo "  env source : $ENV_SOURCE"
  echo "  mode       : $MODE"
  echo '  database   : not contacted'
  echo
  echo 'Would test connection:'
  echo '  psql "$DATABASE_URL" -X --no-password -v ON_ERROR_STOP=1 -c "select 1"'
  echo 'Would create supabase_migrations.schema_migrations if it does not exist.'

  case "$MODE" in
    check)
      echo 'Would list recorded versions ordered by version; no migration would run.'
      ;;
    apply)
      collect_all_migrations
      echo 'Would check each local migration below and atomically apply it only if pending:'
      for file in "${ALL_MIGRATIONS[@]}"; do
        echo "  $file"
      done
      echo 'Pending status and the 4+ confirmation threshold require a non-dry-run connection.'
      ;;
    migration)
      file="$(resolve_specific_migration "$MIGRATION_ARG")"
      echo 'Would check and, only if pending, atomically apply:'
      echo "  $file"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then
  print_dry_run
  exit 0
fi

connection_test
bootstrap_migration_history

if [[ "$MODE" == 'check' ]]; then
  list_recorded_migrations
  exit 0
fi

TARGET_MIGRATIONS=()
if [[ "$MODE" == 'migration' ]]; then
  TARGET_MIGRATIONS=("$(resolve_specific_migration "$MIGRATION_ARG")")
else
  collect_all_migrations
  TARGET_MIGRATIONS=("${ALL_MIGRATIONS[@]}")
fi

# Query each version in chronological order and retain only pending files.
PENDING_MIGRATIONS=()
for file in "${TARGET_MIGRATIONS[@]}"; do
  if is_migration_applied "$file"; then
    echo "$file — already applied"
  else
    status=$?
    if [[ "$status" -eq 2 ]]; then
      exit 1
    fi
    PENDING_MIGRATIONS+=("$file")
  fi
done

pending_count="${#PENDING_MIGRATIONS[@]}"
if [[ "$pending_count" -eq 0 ]]; then
  echo 'No pending migrations.'
  exit 0
fi

echo
if [[ "$pending_count" -eq 1 ]]; then
  echo '1 migration is pending.'
else
  echo "$pending_count migrations are pending."
fi
printf '  %s\n' "${PENDING_MIGRATIONS[@]}"

# One to three pending files run immediately. Four or more require an explicit
# operator decision, and non-interactive callers must opt in with --force.
if [[ "$pending_count" -ge 4 && "$FORCE" -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo 'BLOCKED: 4 or more migrations are pending in a non-interactive shell.' >&2
    echo '  Review the list and rerun with --force to apply them.' >&2
    exit 2
  fi

  reply=''
  if ! read -r -p "Apply all $pending_count pending migrations? [y/N] " reply; then
    echo
    echo 'BLOCKED: confirmation could not be read.' >&2
    exit 2
  fi
  case "$reply" in
    y|Y|yes|Yes|YES) ;;
    *)
      echo 'Migration deployment cancelled.'
      exit 0
      ;;
  esac
fi

for file in "${PENDING_MIGRATIONS[@]}"; do
  if ! apply_migration "$file"; then
    exit 1
  fi
done

echo
echo 'All requested migrations are applied.'
exit 0
