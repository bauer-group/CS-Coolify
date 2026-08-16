#!/bin/bash
set -euo pipefail

#######################################
# Coolify Doctor
#
# Diagnostics and repair tooling for a running Coolify stack.
#
# The recurring case this exists for: after a container image update the
# database migrations have not been applied, and Coolify then fails with
# "Undefined column ..." until they are. `doctor.sh check` detects that
# state, `doctor.sh fix` repairs it (backup -> migrate -> caches -> workers).
#
# Everything here is a thin, auditable wrapper around commands you could
# also type by hand -- the value is in the preconditions, the safety
# backup, the TTY handling and the verification afterwards.
#
# Usage:
#   sudo ./doctor.sh check                 # read-only diagnosis, exit 1 on problems
#   sudo ./doctor.sh fix                   # guided post-update repair
#   sudo ./doctor.sh fix --dry-run         # show what fix would do
#   sudo ./doctor.sh migrate               # migrations only
#   sudo ./doctor.sh cache                 # clear + rebuild Laravel caches
#   sudo ./doctor.sh workers               # restart queue workers
#        ./doctor.sh artisan migrate:status
#        ./doctor.sh psql "SELECT count(*) FROM applications;"
#        ./doctor.sh logs 200
#
# Configuration via environment variables:
#   COOLIFY_CONTAINER           (default: coolify)
#   COOLIFY_DB_CONTAINER        (default: coolify-db)
#   COOLIFY_REDIS_CONTAINER     (default: coolify-redis)
#   COOLIFY_REALTIME_CONTAINER  (default: coolify-realtime)
#   COOLIFY_DB_NAME             (default: coolify)
#   COOLIFY_DB_USER             (default: coolify)
#   BACKUP_DIR                  (default: /data/system/backups)
#######################################

#######################################
# Constants
#######################################
COOLIFY_CONTAINER="${COOLIFY_CONTAINER:-coolify}"
COOLIFY_DB_CONTAINER="${COOLIFY_DB_CONTAINER:-coolify-db}"
COOLIFY_REDIS_CONTAINER="${COOLIFY_REDIS_CONTAINER:-coolify-redis}"
COOLIFY_REALTIME_CONTAINER="${COOLIFY_REALTIME_CONTAINER:-coolify-realtime}"
COOLIFY_DB_NAME="${COOLIFY_DB_NAME:-coolify}"
COOLIFY_DB_USER="${COOLIFY_DB_USER:-coolify}"
BACKUP_DIR="${BACKUP_DIR:-/data/system/backups}"

APP_DIR="/var/www/html"
LARAVEL_LOG="$APP_DIR/storage/logs/laravel.log"
CONFIG_CACHE="$APP_DIR/bootstrap/cache/config.php"

#######################################
# Colors and Output
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_step()    { echo -e "${BLUE}»${NC} $1"; }
print_section() { echo ""; echo -e "${BLUE}$1${NC}"; }
die() { print_error "$1"; exit 1; }

# Findings of the `check` run. Only ISSUES influence the exit code --
# warnings are worth reporting but are not, on their own, a broken stack.
ISSUES=0
WARNINGS=0

check_ok()   { printf '  %b✓%b %-32s %s\n' "$GREEN"  "$NC" "$1" "${2:-}"; }
check_warn() { printf '  %b!%b %-32s %s\n' "$YELLOW" "$NC" "$1" "${2:-}"; WARNINGS=$((WARNINGS + 1)); }
check_fail() { printf '  %b✗%b %-32s %s\n' "$RED"    "$NC" "$1" "${2:-}"; ISSUES=$((ISSUES + 1)); }
check_info() { printf '    %-32s %s\n' "$1" "${2:-}"; }

#######################################
# Options
#######################################
DRY_RUN=false
ASSUME_YES=false
FORCE=false
DO_BACKUP=true
EXPECT_COLUMNS=()
CURRENT_COMMAND="fix"   # only used to print an accurate hint in error messages

usage() {
    cat <<'EOF'
Coolify Doctor - diagnostics and repair for a running Coolify stack

Usage:
  sudo ./doctor.sh <command> [options]

Commands:
  check                  Read-only diagnosis of the whole stack.
                         Exits 1 when a problem was found (cron/monitoring safe).
  fix                    Guided post-update repair:
                         backup -> migrations -> caches -> queue workers -> verify
  migrate                Apply pending database migrations only
  cache                  Clear and rebuild the Laravel caches only
  workers                Restart the queue workers (Horizon) only
  artisan <args...>      Run any artisan command inside the Coolify container
  psql [sql]             Open a psql shell, or run a single statement
  logs [lines]           Show the Laravel application log (default: 100 lines)
  help                   Show this help

Options (for check / fix / migrate / cache / workers):
  -n, --dry-run          Show what would happen, change nothing.
                         For migrations this prints the actual SQL
                         (php artisan migrate --pretend).
  -y, --yes              Assume "yes" for all prompts
      --force            Pass --force to `artisan migrate`, i.e. skip Laravel's
                         production confirmation prompt. Off by default: the
                         interactive prompt is an extra pair of eyes, and it is
                         what has always worked here. Required when running
                         without a terminal (cron, CI, `| bash`).
      --no-backup        Skip the safety database dump before migrating
      --expect-column <table.column>
                         Verify that this column exists after the repair.
                         Repeatable. Use the column from the error message,
                         e.g. --expect-column applications.domain_dns_statuses

Examples:
  sudo ./doctor.sh check
  sudo ./doctor.sh fix --dry-run
  sudo ./doctor.sh fix --expect-column applications.domain_dns_statuses
  sudo ./doctor.sh migrate --force --yes
       ./doctor.sh artisan migrate:status
       ./doctor.sh psql "SELECT count(*) FROM applications;"

Notes:
  `check`, `artisan`, `psql` and `logs` are read-only and do not require root
  (only access to the Docker daemon). `fix`, `migrate`, `cache` and `workers`
  change state and require root.
EOF
}

parse_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -n|--dry-run)    DRY_RUN=true; shift ;;
            -y|--yes)        ASSUME_YES=true; shift ;;
            --force)         FORCE=true; shift ;;
            --no-backup)     DO_BACKUP=false; shift ;;
            --expect-column)
                [ -n "${2:-}" ] || die "--expect-column needs a <table>.<column> value."
                validate_table_column "$2"
                EXPECT_COLUMNS+=("$2")
                shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *)               die "Unknown option: $1 (use --help)" ;;
        esac
    done
}

# Only [A-Za-z0-9_] is allowed on either side of the dot, so the value can be
# interpolated into SQL further down without any quoting hazard.
validate_table_column() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$' \
        || die "Invalid --expect-column value: '$1' (expected <table>.<column>)"
}

#######################################
# Environment helpers
#######################################
have_tty() { [ -t 0 ] && [ -t 1 ]; }

check_root() {
    [ "$(id -u)" -eq 0 ] || die "This command must be run as root (use sudo)."
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker not found."
    docker info >/dev/null 2>&1 \
        || die "No access to the Docker daemon. Is it running, and do you need sudo?"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -qx "$1"
}

container_health() {
    docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$1" 2>/dev/null || printf 'unknown'
}

require_container() {
    container_running "$1" \
        || die "Container '$1' is not running. Start the stack: sudo ./coolify.sh start"
}

# The Coolify container must actually be the Laravel app, otherwise every
# artisan call below would fail with a confusing error.
require_app() {
    require_container "$COOLIFY_CONTAINER"
    docker exec "$COOLIFY_CONTAINER" test -f "$APP_DIR/artisan" 2>/dev/null \
        || die "No Laravel app found in '$COOLIFY_CONTAINER' ($APP_DIR/artisan missing)."
}

confirm() {
    local prompt="$1" default="${2:-n}" answer
    [ "$ASSUME_YES" = "true" ] && return 0
    [ "$DRY_RUN" = "true" ] && return 0
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    read -r -p "$prompt" answer </dev/tty || answer=""
    answer="${answer:-$default}"
    case "$answer" in [YyJj]*) return 0 ;; *) return 1 ;; esac
}

#######################################
# artisan / psql wrappers
#######################################

# Non-interactive artisan call. Use for anything that must not block.
artisan() {
    docker exec "$COOLIFY_CONTAINER" php artisan "$@"
}

# Interactive artisan call -- allocates a TTY so Laravel's prompts work.
artisan_tty() {
    docker exec -it "$COOLIFY_CONTAINER" php artisan "$@"
}

# Interactive if we have a terminal, silent otherwise. For the passthrough.
artisan_auto() {
    if have_tty; then artisan_tty "$@"; else artisan "$@"; fi
}

# Prints a command instead of running it (--dry-run).
show_dry_run() {
    printf '  %b[dry-run]%b docker exec %s php artisan %s\n' \
        "$YELLOW" "$NC" "$COOLIFY_CONTAINER" "$*"
}

psql_query() {
    docker exec "$COOLIFY_DB_CONTAINER" \
        psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -v ON_ERROR_STOP=1 -tAc "$1" 2>/dev/null
}

#######################################
# Migration state
#######################################

# Echoes the number of pending migrations, or "?" when the status could not
# be determined (database down, app broken, ...).
count_pending() {
    local out rc=0
    out=$(artisan migrate:status 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '?'
        return 0
    fi
    printf '%s' "$(printf '%s\n' "$out" | grep -ci 'pending' || true)"
}

show_pending() {
    local out rc=0
    out=$(artisan migrate:status 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        print_warning "Could not read the migration status:"
        printf '%s\n' "$out" | sed 's/^/    /' | head -20
        return 0
    fi
    printf '%s\n' "$out" | grep -i 'pending' | sed 's/^/    /' | head -40 || true
}

# Best-effort Coolify version. Never fails the caller.
coolify_version() {
    local v=""
    v=$(docker exec "$COOLIFY_CONTAINER" cat "$APP_DIR/versions.json" 2>/dev/null \
        | tr -d ' \n' | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4) || true
    if [ -z "$v" ]; then
        v=$(docker inspect --format '{{.Config.Image}}' "$COOLIFY_CONTAINER" 2>/dev/null) || true
    fi
    printf '%s' "${v:-unknown}"
}

#######################################
# Safety backup
#######################################
BACKUP_FILE=""

# Dumps ONLY the Coolify database, in PostgreSQL's custom format.
#
# Deliberately not `./coolify.sh backup`: that one refuses to run unless all
# four stack containers are up, which is exactly what is often not the case
# on a broken instance. A schema migration can only damage the database, so
# the database is what we protect here. For a full archive (Redis, SSH keys,
# .env) run `sudo ./coolify.sh backup` beforehand.
create_db_backup() {
    if [ "$DRY_RUN" = "true" ]; then
        print_step "[dry-run] would dump $COOLIFY_DB_NAME to $BACKUP_DIR/"
        return 0
    fi

    container_running "$COOLIFY_DB_CONTAINER" \
        || die "Database container '$COOLIFY_DB_CONTAINER' is not running - cannot back up."

    mkdir -p "$BACKUP_DIR"
    local target
    target="$BACKUP_DIR/coolify_db_$(date +%Y%m%d_%H%M%S).dump"

    # Dump to a file inside the container and copy it out, rather than
    # redirecting stdout: `docker exec -t` would allocate a pseudo-TTY and
    # inject CR bytes into the stream, silently corrupting the dump.
    docker exec "$COOLIFY_DB_CONTAINER" \
        pg_dump -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -F c -f /tmp/doctor_backup.dump \
        || die "pg_dump failed - check COOLIFY_DB_USER / COOLIFY_DB_NAME."

    docker cp "$COOLIFY_DB_CONTAINER:/tmp/doctor_backup.dump" "$target" >/dev/null
    docker exec "$COOLIFY_DB_CONTAINER" rm -f /tmp/doctor_backup.dump || true

    [ -s "$target" ] || { rm -f "$target"; die "Backup is empty - aborting."; }
    chmod 600 "$target"
    BACKUP_FILE="$target"
    print_success "Database backup: $target ($(du -h "$target" | cut -f1))"
}

print_restore_hint() {
    [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] || return 0
    echo ""
    print_warning "A database backup was taken before the change:"
    echo "    $BACKUP_FILE"
    echo "  Restore it with:"
    echo "    sudo ./coolify.sh stop"
    echo "    docker start $COOLIFY_DB_CONTAINER"
    echo "    docker exec -i $COOLIFY_DB_CONTAINER pg_restore -U $COOLIFY_DB_USER \\"
    echo "        -d $COOLIFY_DB_NAME --clean --if-exists < $BACKUP_FILE"
}

on_exit() {
    local code=$?
    [ "$code" -ne 0 ] && print_restore_hint
    return 0
}

#######################################
# Repair steps
#######################################

# Coolify runs with APP_ENV=production, so Laravel's ConfirmableTrait asks
# "Are you sure you want to run this command?" before migrating. That prompt
# needs a real TTY: without one Symfony answers with the default (no) and the
# migration is CANCELLED while the command still looks like it succeeded.
# So refuse loudly instead of no-op'ing -- and refuse EARLY, before a backup
# is taken and before anything else is touched.
require_tty_for_migrate() {
    [ "$DRY_RUN" = "true" ] && return 0
    [ "$FORCE" = "true" ] && return 0
    have_tty && return 0
    die "No terminal available, so Laravel's production confirmation cannot be answered.
  Re-run from an interactive shell, or skip the prompt with --force:
      sudo ./doctor.sh $CURRENT_COMMAND --force"
}

run_migrations() {
    print_header "Database migrations"

    if [ "$DRY_RUN" = "true" ]; then
        print_step "Showing the SQL that would be executed (nothing is written) ..."
        echo ""
        # --pretend makes Laravel print the statements instead of running
        # them. --force is still required: confirmToProceed() runs BEFORE
        # --pretend is evaluated, so without it this would block on the
        # production confirmation prompt. --pretend wins over --force,
        # nothing is written.
        artisan migrate --pretend --force || print_warning "migrate --pretend returned an error."
        return 0
    fi

    if [ "$FORCE" = "true" ]; then
        print_step "Running: php artisan migrate --force"
        artisan migrate --force
    else
        require_tty_for_migrate
        print_step "Running: php artisan migrate"
        print_warning "Laravel will ask for confirmation (production environment) - answer 'yes'."
        echo ""
        artisan_tty migrate
    fi
    print_success "Migrations applied"
}

rebuild_caches() {
    print_header "Laravel caches"
    # A stale cached config/route file after an image update produces the
    # same symptoms as a missing migration, so this always runs.
    if [ "$DRY_RUN" = "true" ]; then
        show_dry_run optimize:clear
        show_dry_run optimize
        return 0
    fi

    print_step "php artisan optimize:clear"
    artisan optimize:clear
    print_success "Config, route, view, event and application caches cleared"

    print_step "php artisan optimize"
    artisan optimize
    print_success "Caches rebuilt"
}

restart_workers() {
    print_header "Queue workers"
    # Without a restart the Horizon workers keep running the old code from
    # memory and reproduce the very error that was just fixed.
    if [ "$DRY_RUN" = "true" ]; then
        show_dry_run horizon:terminate
        return 0
    fi

    if artisan horizon:terminate >/dev/null 2>&1; then
        print_success "Horizon terminated - the supervisor restarts the workers"
    else
        print_warning "horizon:terminate failed, falling back to queue:restart"
        if artisan queue:restart >/dev/null 2>&1; then
            print_success "Queue workers signalled to restart"
        else
            print_warning "queue:restart failed too - restart the container: sudo ./coolify.sh restart"
        fi
    fi
}

# Verifies the columns given via --expect-column. Returns non-zero if any
# of them is missing.
verify_expected_columns() {
    [ "${#EXPECT_COLUMNS[@]}" -gt 0 ] || return 0
    container_running "$COOLIFY_DB_CONTAINER" || {
        print_warning "Database container not running - skipping column checks."
        return 0
    }

    local spec table column found rc=0
    for spec in "${EXPECT_COLUMNS[@]}"; do
        table="${spec%%.*}"
        column="${spec#*.}"
        found=$(psql_query "SELECT 1 FROM information_schema.columns
                            WHERE table_schema='public'
                              AND table_name='${table}'
                              AND column_name='${column}';" || true)
        if [ "$found" = "1" ]; then
            print_success "Column exists: ${table}.${column}"
        else
            print_error "Column MISSING: ${table}.${column}"
            rc=1
        fi
    done
    return $rc
}

#######################################
# Command: check
#######################################
do_check() {
    require_docker
    print_header "Coolify Doctor - diagnosis"

    ##### Containers #####
    print_section "Containers"
    local c health
    for c in "$COOLIFY_CONTAINER" "$COOLIFY_DB_CONTAINER" \
             "$COOLIFY_REDIS_CONTAINER" "$COOLIFY_REALTIME_CONTAINER"; do
        if container_running "$c"; then
            health=$(container_health "$c")
            case "$health" in
                healthy)   check_ok   "$c" "running (healthy)" ;;
                none)      check_ok   "$c" "running" ;;
                starting)  check_warn "$c" "running (health: starting)" ;;
                *)         check_fail "$c" "running (health: $health)" ;;
            esac
        else
            check_fail "$c" "NOT running"
        fi
    done

    # Everything below needs the app container; stop early if it is gone.
    if ! container_running "$COOLIFY_CONTAINER"; then
        print_section "Result"
        print_error "The Coolify container is not running - start the stack first:"
        echo "    sudo ./coolify.sh start"
        return 1
    fi

    check_info "coolify version" "$(coolify_version)"

    ##### Services #####
    print_section "Services"
    if docker exec "$COOLIFY_CONTAINER" curl -fsS -m 5 http://127.0.0.1:8080/api/health \
        >/dev/null 2>&1; then
        check_ok "application health endpoint" "responding"
    else
        check_fail "application health endpoint" "no response on :8080/api/health"
    fi

    if container_running "$COOLIFY_DB_CONTAINER"; then
        if docker exec "$COOLIFY_DB_CONTAINER" \
            pg_isready -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" >/dev/null 2>&1; then
            check_ok "postgres" "accepting connections"
        else
            check_fail "postgres" "not accepting connections"
        fi
    fi

    if container_running "$COOLIFY_REDIS_CONTAINER"; then
        # REDISCLI_AUTH is set inside the container by docker-compose.yml.
        if docker exec "$COOLIFY_REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            check_ok "redis" "PONG"
        else
            check_fail "redis" "no PONG"
        fi
    fi

    ##### Database / migrations #####
    print_section "Database"
    local pending
    pending=$(count_pending)
    case "$pending" in
        0)  check_ok   "pending migrations" "none" ;;
        \?) check_fail "pending migrations" "could not be determined (see below)" ;;
        *)  check_fail "pending migrations" "$pending outstanding" ;;
    esac
    if [ "$pending" != "0" ]; then
        echo ""
        show_pending
        echo ""
    fi

    if container_running "$COOLIFY_DB_CONTAINER"; then
        local failed
        failed=$(psql_query "SELECT CASE
                               WHEN to_regclass('public.failed_jobs') IS NULL THEN -1
                               ELSE (SELECT count(*) FROM public.failed_jobs)
                             END;" || printf '')
        case "${failed:-}" in
            ""|-1) check_info "failed jobs" "table not present" ;;
            0)     check_ok   "failed jobs" "none" ;;
            *)     check_warn "failed jobs" "$failed in the queue (php artisan queue:failed)" ;;
        esac
    fi

    if [ "${#EXPECT_COLUMNS[@]}" -gt 0 ]; then
        echo ""
        verify_expected_columns || ISSUES=$((ISSUES + 1))
    fi

    ##### Application #####
    print_section "Application"
    if docker exec "$COOLIFY_CONTAINER" test -f "$CONFIG_CACHE" 2>/dev/null; then
        check_info "config cache" "present (cleared by: doctor.sh cache)"
    else
        check_info "config cache" "absent"
    fi

    if artisan horizon:status >/dev/null 2>&1; then
        check_ok "horizon" "running"
    else
        # horizon:status does not exist in every Horizon version, so a
        # failure here is not proof that the workers are down.
        check_warn "horizon" "status unavailable - check './doctor.sh logs'"
    fi

    local errors
    errors=$(docker exec "$COOLIFY_CONTAINER" sh -c \
        "tail -n 500 '$LARAVEL_LOG' 2>/dev/null | grep -c 'ERROR' || true" 2>/dev/null || printf '0')
    errors="${errors:-0}"
    if [ "$errors" -gt 0 ] 2>/dev/null; then
        check_warn "recent log errors" "$errors ERROR lines in the last 500"
    else
        check_ok "recent log errors" "none in the last 500 lines"
    fi

    ##### Resources #####
    print_section "Resources"
    local mount usage
    for mount in /data /var/lib/docker; do
        [ -d "$mount" ] || continue
        usage=$(df -P "$mount" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}') || usage=""
        [ -n "$usage" ] || continue
        if [ "$usage" -ge 90 ]; then
            check_fail "disk $mount" "${usage}% used"
        elif [ "$usage" -ge 80 ]; then
            check_warn "disk $mount" "${usage}% used"
        else
            check_ok "disk $mount" "${usage}% used"
        fi
    done

    ##### Result #####
    print_section "Result"
    if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        print_success "No problems found."
        return 0
    fi
    if [ "$ISSUES" -eq 0 ]; then
        print_warning "$WARNINGS warning(s), no blocking problems."
        return 0
    fi

    print_error "$ISSUES problem(s) found, $WARNINGS warning(s)."
    if [ "$pending" != "0" ]; then
        echo ""
        echo "  Outstanding migrations are the usual cause after an update. Repair with:"
        echo "    sudo ./doctor.sh fix --dry-run   # preview first"
        echo "    sudo ./doctor.sh fix"
    fi
    return 1
}

#######################################
# Command: fix
#######################################
do_fix() {
    check_root
    require_docker
    require_app
    trap on_exit EXIT

    print_header "Coolify Doctor - repair"
    [ "$DRY_RUN" = "true" ] && print_warning "DRY RUN - nothing will be changed."
    echo "Container:  $COOLIFY_CONTAINER (version: $(coolify_version))"
    echo "Database:   $COOLIFY_DB_CONTAINER / $COOLIFY_DB_NAME"

    ##### 1. Assess #####
    print_header "Migration status"
    local pending
    pending=$(count_pending)
    if [ "$pending" = "?" ]; then
        print_warning "Migration status could not be read:"
        show_pending
    elif [ "$pending" -eq 0 ]; then
        print_success "No pending migrations."
        print_step "Caches and workers are still refreshed - a stale cached config"
        print_step "after an update produces the same symptoms."
    else
        print_warning "$pending pending migration(s):"
        echo ""
        show_pending
    fi

    # Fail fast: refuse an impossible interactive migration BEFORE the backup.
    if [ "$pending" != "0" ]; then
        require_tty_for_migrate
    fi

    ##### 2. Plan #####
    print_header "Plan"
    if [ "$pending" = "0" ]; then
        echo "  1. Database backup            skipped (no schema change)"
    elif [ "$DO_BACKUP" = "true" ]; then
        echo "  1. Database backup            $BACKUP_DIR/"
    else
        echo "  1. Database backup            SKIPPED (--no-backup)"
    fi
    if [ "$FORCE" = "true" ]; then
        echo "  2. php artisan migrate        --force (no confirmation prompt)"
    else
        echo "  2. php artisan migrate        interactive, Laravel asks for confirmation"
    fi
    echo "  3. php artisan optimize:clear + optimize"
    echo "  4. php artisan horizon:terminate  (fallback: queue:restart)"
    if [ "${#EXPECT_COLUMNS[@]}" -gt 0 ]; then
        echo "  5. Verify: no pending migrations + ${EXPECT_COLUMNS[*]}"
    else
        echo "  5. Verify: no pending migrations left"
    fi
    echo ""

    if [ "$DRY_RUN" != "true" ]; then
        confirm "Proceed?" "y" || die "Aborted by user."
    fi

    ##### 3. Backup #####
    if [ "$pending" = "0" ]; then
        :
    elif [ "$DO_BACKUP" = "true" ]; then
        print_header "Database backup"
        create_db_backup
    else
        print_warning "Backup skipped (--no-backup)."
    fi

    ##### 4-6. Repair #####
    if [ "$pending" = "0" ]; then
        print_header "Database migrations"
        print_step "Skipped - nothing pending."
    else
        run_migrations
    fi
    rebuild_caches
    restart_workers

    ##### 7. Verify #####
    print_header "Verification"
    if [ "$DRY_RUN" = "true" ]; then
        print_warning "DRY RUN complete - nothing was changed."
        echo "Re-run without --dry-run to apply the repair."
        trap - EXIT
        return 0
    fi

    local remaining verify_failed=false
    remaining=$(count_pending)
    if [ "$remaining" = "0" ]; then
        print_success "No pending migrations left."
    elif [ "$remaining" = "?" ]; then
        print_error "Migration status could not be verified."
        verify_failed=true
    else
        print_error "$remaining migration(s) still pending:"
        show_pending
        verify_failed=true
    fi

    verify_expected_columns || verify_failed=true

    if docker exec "$COOLIFY_CONTAINER" curl -fsS -m 10 http://127.0.0.1:8080/api/health \
        >/dev/null 2>&1; then
        print_success "Application health endpoint responds."
    else
        print_warning "Health endpoint does not respond (yet) - the app may still be booting."
    fi

    trap - EXIT
    print_header "Done"
    if [ "$verify_failed" = "true" ]; then
        print_error "The repair did not fully succeed."
        echo ""
        echo "  Likely the container image is older than the database expects."
        echo "  Pull the current images and repeat:"
        echo "    sudo ./coolify.sh update && sudo ./doctor.sh fix"
        print_restore_hint
        return 1
    fi

    print_success "Repair completed."
    [ -n "$BACKUP_FILE" ] && echo "  Backup: $BACKUP_FILE"
    echo "  Watch the logs: sudo ./coolify.sh logs coolify"
    return 0
}

#######################################
# Command: migrate / cache / workers
#######################################
do_migrate_only() {
    check_root
    require_docker
    require_app
    trap on_exit EXIT

    local pending
    pending=$(count_pending)
    print_header "Migration status"
    if [ "$pending" = "?" ]; then
        print_warning "Migration status could not be read:"
        show_pending
    elif [ "$pending" -eq 0 ]; then
        print_success "No pending migrations - nothing to do."
        trap - EXIT
        return 0
    else
        print_warning "$pending pending migration(s):"
        echo ""
        show_pending
    fi

    # Fail fast: refuse an impossible interactive migration BEFORE the backup.
    require_tty_for_migrate

    if [ "$DRY_RUN" != "true" ]; then
        confirm "Run the migrations now?" "y" || die "Aborted by user."
        if [ "$DO_BACKUP" = "true" ]; then
            print_header "Database backup"
            create_db_backup
        fi
    fi

    run_migrations
    trap - EXIT

    if [ "$DRY_RUN" != "true" ]; then
        print_warning "Remember to refresh caches and workers afterwards:"
        echo "    sudo ./doctor.sh cache && sudo ./doctor.sh workers"
    fi
}

do_cache_only() {
    check_root
    require_docker
    require_app
    rebuild_caches
}

do_workers_only() {
    check_root
    require_docker
    require_app
    restart_workers
}

#######################################
# Command: artisan / psql / logs
#######################################
do_artisan() {
    [ $# -gt 0 ] || die "No artisan command given. Example: ./doctor.sh artisan migrate:status"
    require_docker
    require_app
    artisan_auto "$@"
}

do_psql() {
    require_docker
    require_container "$COOLIFY_DB_CONTAINER"
    if [ $# -gt 0 ]; then
        docker exec -i "$COOLIFY_DB_CONTAINER" \
            psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -v ON_ERROR_STOP=1 -c "$*"
    else
        have_tty || die "An interactive psql shell needs a terminal.
  Pass the statement as an argument instead:
      ./doctor.sh psql \"SELECT count(*) FROM applications;\""
        docker exec -it "$COOLIFY_DB_CONTAINER" \
            psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME"
    fi
}

do_logs() {
    local lines="${1:-100}"
    printf '%s' "$lines" | grep -Eq '^[0-9]+$' || die "Invalid line count: $lines"
    require_docker
    require_container "$COOLIFY_CONTAINER"

    if docker exec "$COOLIFY_CONTAINER" test -f "$LARAVEL_LOG" 2>/dev/null; then
        docker exec "$COOLIFY_CONTAINER" tail -n "$lines" "$LARAVEL_LOG"
    else
        print_warning "$LARAVEL_LOG not found - showing container logs instead."
        docker logs --tail "$lines" "$COOLIFY_CONTAINER"
    fi
}

#######################################
# Dispatch
#######################################
main() {
    local cmd="${1:-help}"
    if [ $# -gt 0 ]; then shift; fi
    CURRENT_COMMAND="$cmd"

    case "$cmd" in
        # Pass the remaining arguments through verbatim.
        artisan) do_artisan "$@" ;;
        psql)    do_psql "$@" ;;
        logs)    do_logs "$@" ;;

        check)   parse_options "$@"; do_check ;;
        fix)     parse_options "$@"; do_fix ;;
        migrate) parse_options "$@"; do_migrate_only ;;
        cache)   parse_options "$@"; do_cache_only ;;
        workers) parse_options "$@"; do_workers_only ;;

        help|-h|--help) usage ;;
        *)
            print_error "Unknown command: $cmd"
            echo ""
            usage
            exit 1
            ;;
    esac
}

main "$@"
