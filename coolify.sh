#!/bin/bash
set -e

#######################################
# Coolify Stack Management Script
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="/opt/coolify/.env"

# Colors for output (plain text when not on a terminal, e.g. in the journal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

#######################################
# Helper Functions
#######################################
print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} Coolify Stack Management${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root!"
        echo "Please run with 'sudo $0 $1'."
        exit 1
    fi
}

check_requirements() {
    if [ ! -f "$COMPOSE_FILE" ]; then
        print_error "docker-compose.yml not found: $COMPOSE_FILE"
        exit 1
    fi

    if [ ! -f "$ENV_FILE" ]; then
        print_error ".env file not found: $ENV_FILE"
        echo "Please run 'sudo ./setup.sh' first."
        exit 1
    fi

    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed!"
        exit 1
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_error "Docker Compose is not installed!"
        exit 1
    fi
}

get_compose_cmd() {
    if docker compose version &> /dev/null 2>&1; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

# Containers of the stack. Since Coolify 4.4 realtime and the web terminal
# run inside the coolify container -- there is no coolify-realtime anymore.
STACK_CONTAINERS="coolify coolify-db coolify-redis"

# Containers that earlier versions of this stack ran and that no longer
# belong to it. They are removed explicitly before `up` (not only through
# --remove-orphans) so their host ports, e.g. 6001/6002, are free again.
LEGACY_CONTAINERS="coolify-realtime coolify-watchtower"

BACKUP_DIR="/data/system/backups"

# Update (see do_update)
COOLIFY_IMAGE="ghcr.io/coollabsio/coolify"
ROLLBACK_TAG="pre-update"
UPDATE_LOCK="/run/coolify-update.lock"
PREUPDATE_BACKUPS_KEPT=4
HEALTH_TIMEOUT=300
INIT_TIMEOUT=1800

# Weekly unattended update (replaces Watchtower)
SYSTEMD_DIR="/etc/systemd/system"
UPDATE_UNIT="coolify-update"
UPDATE_SCHEDULE="Sat *-*-* 03:00:00"

is_stack_running() {
    # Check if all Coolify containers are running
    local running=0
    for container in $STACK_CONTAINERS; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            ((running++))
        fi
    done
    [ "$running" -eq 3 ]
}

is_stack_stopped() {
    # Check if all Coolify containers are stopped
    for container in $STACK_CONTAINERS; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            return 1
        fi
    done
    return 0
}

remove_legacy_containers() {
    local container image
    for container in $LEGACY_CONTAINERS; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "Removing obsolete container: $container"
            image=$(docker inspect -f '{{.Image}}' "$container" 2>/dev/null) || image=""
            docker rm -f "$container" >/dev/null
            if [ -n "$image" ]; then
                docker image rm "$image" >/dev/null 2>&1 || true
            fi
        fi
    done
}

ensure_data_dirs() {
    # Bind source added after the initial setup (Coolify 4.4). Docker would
    # create a missing source as root:root, which the app (UID 9999) cannot write.
    local dir="/data/coolify/images"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown 9999:root "$dir"
        chmod 700 "$dir"
    fi
}

compose() {
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${1}$"
}

wait_for_healthy() {
    local container="$1" waited=0
    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        if [ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
                "$container" 2>/dev/null)" = "healthy" ]; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Only /api/health: a rolled-back image may predate the Reverb probe
# that the compose healthcheck now includes.
wait_for_app() {
    local waited=0
    while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
        if docker exec coolify curl -fsS -m 5 http://127.0.0.1:8080/api/health \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

#######################################
# Actions
#######################################
do_start() {
    print_header
    check_root "start"
    check_requirements

    echo "Starting Coolify Stack..."
    echo ""

    ensure_data_dirs
    remove_legacy_containers

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans --wait 2>&1

    echo ""
    print_success "Coolify Stack started!"
    ensure_update_timer || true
    echo ""
    do_status
}

do_stop() {
    print_header
    check_root "stop"
    check_requirements

    echo "Stopping Coolify Stack..."
    echo ""

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down 2>&1

    echo ""
    print_success "Coolify Stack stopped!"
}

do_restart() {
    print_header
    check_root "restart"
    check_requirements

    echo "Restarting Coolify Stack..."
    echo ""

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" restart 2>&1

    echo ""
    print_success "Coolify Stack restarted!"
    echo ""
    do_status
}

do_status() {
    check_requirements

    echo -e "${BLUE}=== Container Status ===${NC}"
    echo ""

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps

    echo ""
    echo -e "${BLUE}=== Access ===${NC}"

    # Port from .env or default
    APP_PORT=$(grep -E "^APPLICATION_PORT=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "8000")
    APP_PORT=${APP_PORT:-8000}

    HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    echo "URL: http://${HOST_IP}:${APP_PORT}"
    echo ""
}

do_logs() {
    check_requirements

    SERVICE="${2:-}"

    cd "$SCRIPT_DIR"

    if [ -n "$SERVICE" ]; then
        echo "Showing logs for: $SERVICE"
        $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f "$SERVICE"
    else
        echo "Showing logs for all services (Ctrl+C to exit)..."
        $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs -f
    fi
}

#######################################
# Update
#
# One code path for the manual and the weekly unattended update:
#   1. sync this repository (update.sh) and continue with the NEW coolify.sh
#   2. validate compose file + .env, pull the images
#   3. nothing new -> stop here (no backup, no restarts)
#   4. backup; the running Coolify image is kept as rollback point
#   5. compose up --wait: depends_on + healthchecks (what Watchtower skipped)
#   6. doctor.sh fix: explicit migrations, caches, workers, verification.
#      The image migrates on start too, but swallows a failure there.
#   7. on failure: restore the database and start the previous version
#######################################

acquire_update_lock() {
    # After the hand-over to the freshly pulled coolify.sh (exec), fd 9 is
    # still open and locked: keep it instead of reopening the lock file.
    if [ "${COOLIFY_UPDATE_LOCKED:-}" = 1 ] && { true >&9; } 2>/dev/null; then
        return 0
    fi
    exec 9>"$UPDATE_LOCK"
    if ! flock -n 9; then
        print_error "Another update is already running."
        exit 1
    fi
    export COOLIFY_UPDATE_LOCKED=1
}

# A manual update over SSH must survive a dropped connection. The run is
# handed to a transient systemd unit and its log is followed here: a hangup
# or Ctrl+C only ends the log view, the update itself carries on.
run_update_detached() {
    local unit follower rc=0
    unit="coolify-update-manual-$(date +%Y%m%d-%H%M%S)"
    echo "Running as systemd unit $unit - a dropped connection does not stop it."
    echo "Full log: journalctl -u $unit"
    echo ""
    journalctl -f --since now -o cat -u "$unit" &
    follower=$!
    sleep 1
    systemd-run --unit="$unit" --collect --wait --quiet \
        --property=TimeoutStartSec=2h --setenv=HOME=/root \
        /bin/bash "$SCRIPT_DIR/coolify.sh" update || rc=$?
    sleep 2   # let journalctl print the last lines
    kill "$follower" 2>/dev/null || true
    exit "$rc"
}

# Pulls the repository via update.sh, then hands over to the freshly pulled
# coolify.sh, so the rest runs with the new code AND the new compose file.
# Skipped when this is no git checkout: update.sh would then re-clone and
# delete the .env that lives in the same directory.
sync_repository() {
    if [ ! -d "$SCRIPT_DIR/.git" ]; then
        print_warning "$SCRIPT_DIR is not a git checkout - repository sync skipped"
        return 0
    fi
    echo -e "${BLUE}[1/6] Updating repository...${NC}"
    # 9>&-: background git maintenance must not inherit the update lock.
    if ! COOLIFY_UPDATE_CHAINED=1 bash "$SCRIPT_DIR/update.sh" 9>&-; then
        print_error "Repository update failed - the stack was not changed."
        exit 1
    fi
    exec bash "$SCRIPT_DIR/coolify.sh" update --no-git
}

# Image IDs the compose file asks for vs. the ones running right now.
wanted_image_ids() {
    local ref
    for ref in $(compose config --images); do
        docker image inspect -f '{{.Id}}' "$ref" 2>/dev/null || echo "missing:$ref"
    done | sort
}

running_image_ids() {
    local container
    for container in $STACK_CONTAINERS; do
        docker inspect -f '{{.Image}}' "$container" 2>/dev/null || echo "missing:$container"
    done | sort
}

legacy_containers_present() {
    local container
    for container in $LEGACY_CONTAINERS; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            return 0
        fi
    done
    return 1
}

# Only stopped during the update (frees ports 6001/6002), removed after it
# succeeded: a rollback to a pre-4.4 version needs coolify-realtime again.
stop_legacy_containers() {
    local container
    for container in $LEGACY_CONTAINERS; do
        if container_running "$container"; then
            echo "Stopping obsolete container: $container"
            docker stop "$container" >/dev/null || true
        fi
    done
}

# Tags the image of the running coolify container as the rollback point.
# The tag also keeps that image from being pruned after the update.
remember_running_image() {
    local image
    image=$(docker inspect -f '{{.Image}}' coolify 2>/dev/null) || return 1
    if ! docker tag "$image" "$COOLIFY_IMAGE:$ROLLBACK_TAG" 2>/dev/null; then
        print_warning "Running Coolify image is no longer tagged - no automatic rollback this time"
        return 1
    fi
}

# The Coolify image reference as the compose file resolves it
# (honours COOLIFY_VERSION from .env).
app_image_ref() {
    compose config --images | grep -m1 "^${COOLIFY_IMAGE}:"
}

# After an abort past the pull: point the tag back at the running image, so
# a later `start` does not silently upgrade without backup and migrations.
restore_app_tag() {
    local rollback_ready="$1" ref
    [ "$rollback_ready" = true ] || return 0
    ref=$(app_image_ref) || return 0
    docker tag "$COOLIFY_IMAGE:$ROLLBACK_TAG" "$ref" 2>/dev/null || true
}

coolify_version() {
    local version
    version=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' coolify 2>/dev/null \
        | sed -n 's/^COOLIFY_VERSION=//p' | head -1) || true
    echo "${version:-unknown}"
}

# Waits until the container's own start-up chain (migrations, seeder,
# app:init) has finished, so doctor.sh never migrates at the same time.
wait_for_init() {
    local waited=0
    while [ "$waited" -lt "$INIT_TIMEOUT" ]; do
        if ! docker top coolify -o pid,args 2>/dev/null \
            | grep -Eq 'artisan (start:migration|start:seeder|app:init)'; then
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    return 1
}

# Database rollback in two steps, so nothing is stopped before the backup
# is known to be usable: prepare (extract, copy, convert to SQL) while
# Coolify still runs, then apply in ONE transaction - all or nothing.
prepare_db_rollback() {
    local archive="$1" tmp
    tmp=$(mktemp -d)
    if ! tar -xzf "$archive" -C "$tmp" ./01_postgres.dump \
        || ! docker cp "$tmp/01_postgres.dump" coolify-db:/tmp/rollback.dump >/dev/null; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    docker exec coolify-db sh -c '
        set -e
        {
            echo "SET client_min_messages = warning;"
            echo "DROP SCHEMA public CASCADE;"
            echo "CREATE SCHEMA public;"
        } > /tmp/rollback.sql
        pg_restore -f - /tmp/rollback.dump >> /tmp/rollback.sql
        rm -f /tmp/rollback.dump
    '
}

apply_db_rollback() {
    # stdout only carries the restore's SELECT results; errors go to stderr.
    docker exec coolify-db psql -U coolify -d coolify -q -v ON_ERROR_STOP=1 \
        --single-transaction -f /tmp/rollback.sql >/dev/null
}

cleanup_db_rollback() {
    docker exec coolify-db rm -f /tmp/rollback.dump /tmp/rollback.sql >/dev/null 2>&1 || true
}

# The newest revision of docker-compose.yml that still runs realtime in its
# own coolify-realtime container - the layout before Coolify 4.4. Taken from
# the history, so it works no matter when the repository was pulled.
legacy_compose_rev() {
    local rev
    for rev in $(git -C "$SCRIPT_DIR" rev-list HEAD -- docker-compose.yml 2>/dev/null); do
        if git -C "$SCRIPT_DIR" show "$rev:docker-compose.yml" 2>/dev/null \
            | grep -q '^  coolify-realtime:'; then
            echo "$rev"
            return 0
        fi
    done
    return 1
}

# Rollback across the 4.4 layout change: a pre-4.4 image has no built-in
# realtime, so it needs the previous compose file and its coolify-realtime
# container (stopped in step 4, not removed).
start_previous_layout() {
    local old_compose="$SCRIPT_DIR/.docker-compose.previous.yml" rev rc=0
    rev=$(legacy_compose_rev) || return 1
    if ! git -C "$SCRIPT_DIR" show "$rev:docker-compose.yml" > "$old_compose" 2>/dev/null; then
        rm -f "$old_compose"
        return 1
    fi
    echo "Starting the previous layout (docker-compose.yml of ${rev:0:7}) ..."
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$old_compose" \
        up -d --no-deps coolify-realtime coolify || rc=1
    rm -f "$old_compose"
    return $rc
}

rollback_update() {
    local archive="$1" rollback_ready="$2" legacy_layout="$3" ref
    echo ""
    print_error "Update failed - rolling back to the previous Coolify version"

    if [ -z "$archive" ] || [ "$rollback_ready" != true ]; then
        print_error "No rollback point (previous image unknown) - manual action required."
        echo "  Full restore: sudo $0 stop && sudo $0 restore $archive"
        return 1
    fi
    ref=$(app_image_ref) || ref=""
    if [ -z "$ref" ]; then
        print_error "Could not resolve the Coolify image from docker-compose.yml."
        return 1
    fi

    echo "Preparing the database restore from $archive ..."
    if ! prepare_db_rollback "$archive"; then
        cleanup_db_rollback
        print_error "The pre-update backup cannot be restored - the new version keeps running."
        echo "  Check: sudo ./doctor.sh check"
        return 1
    fi

    compose stop coolify || true
    if ! apply_db_rollback; then
        cleanup_db_rollback
        print_error "Database restore failed - the database is unchanged (post-update state)."
        compose up -d --no-deps coolify || true
        print_warning "The new version was started again."
        echo "  Full restore: sudo $0 stop && sudo $0 restore $archive"
        return 1
    fi
    cleanup_db_rollback
    print_success "Database restored"

    # Point the configured tag back at the previous image: `start` keeps
    # using it, and the next update's pull moves the tag forward again.
    docker tag "$COOLIFY_IMAGE:$ROLLBACK_TAG" "$ref" || true

    if [ "$legacy_layout" = true ]; then
        if ! start_previous_layout; then
            print_error "Previous docker-compose.yml unknown - cannot restore the pre-4.4 layout."
            compose up -d --no-deps --force-recreate coolify || true
            if wait_for_app; then
                print_warning "Previous version runs WITHOUT realtime and terminal (needs its old layout)."
            fi
            return 1
        fi
        if wait_for_healthy coolify && wait_for_healthy coolify-realtime; then
            print_success "Previous version is running again in its previous layout ($(coolify_version))"
            print_warning "Do not run 'coolify.sh start' before the next successful update -"
            print_warning "it would apply the new layout to the old version."
            return 0
        fi
    else
        compose up -d --no-deps --force-recreate coolify || true
        if wait_for_healthy coolify; then
            print_success "Previous version is running again ($(coolify_version))"
            return 0
        fi
    fi
    print_error "The previous version did not become healthy - manual action required."
    echo "  Full restore: sudo $0 stop && sudo $0 restore $archive"
    return 1
}

prune_preupdate_backups() {
    # Only the archives the update itself created; manual backups stay.
    ls -1t "$BACKUP_DIR"/coolify_backup_preupdate_*.tar.gz 2>/dev/null \
        | tail -n +$((PREUPDATE_BACKUPS_KEPT + 1)) \
        | xargs -r rm -f
}

do_update() {
    print_header
    check_root "update"

    if [ "${2:-}" != "--no-git" ] && [ -t 0 ] && [ -t 1 ] \
        && [ -z "${INVOCATION_ID:-}" ] && has_systemd; then
        run_update_detached
    fi

    acquire_update_lock

    if [ "${2:-}" != "--no-git" ]; then
        sync_repository   # continues in the new coolify.sh after a sync
    fi

    check_requirements
    cd "$SCRIPT_DIR"

    # A stopped stack is left alone; a half-running one is not updated.
    if is_stack_stopped; then
        print_warning "The stack is stopped - update skipped. Start it first: sudo $0 start"
        exit 0
    fi
    if ! is_stack_running; then
        print_error "Not all of: $STACK_CONTAINERS are running - start the stack first: sudo $0 start"
        exit 1
    fi

    echo -e "${BLUE}[2/6] Checking configuration and pulling images...${NC}"
    if ! compose config -q; then
        print_error "docker-compose.yml or .env is invalid - the stack was not changed."
        exit 1
    fi

    # Rollback point, set BEFORE the pull: the pull moves the tag away from
    # the running image, and with Docker's containerd image store an
    # untagged image can no longer be addressed (not even by its ID).
    local old_version rollback_ready=false
    old_version=$(coolify_version)
    if remember_running_image; then
        rollback_ready=true
    fi

    if ! compose pull; then
        restore_app_tag "$rollback_ready"
        print_error "Pulling the images failed - the stack was not changed."
        exit 1
    fi
    ensure_data_dirs

    if [ "$(wanted_image_ids)" = "$(running_image_ids)" ] && ! legacy_containers_present; then
        echo ""
        print_success "All images are current ($(coolify_version)) - nothing to update."
        # Still apply changes to docker-compose.yml or .env, if any.
        if ! compose up -d --remove-orphans --wait --wait-timeout "$HEALTH_TIMEOUT"; then
            print_error "The stack did not become healthy - check: sudo ./doctor.sh check"
            exit 1
        fi
        ensure_update_timer || true
        return 0
    fi

    echo ""
    echo -e "${BLUE}[3/6] Creating pre-update backup...${NC}"
    if ! create_backup "preupdate_"; then
        restore_app_tag "$rollback_ready"
        print_error "Backup failed - update aborted, the stack was not changed."
        exit 1
    fi
    print_success "Backup: $BACKUP_FILE"
    local backup="$BACKUP_FILE"
    prune_preupdate_backups || true

    echo ""
    echo -e "${BLUE}[4/6] Recreating containers...${NC}"
    local legacy_layout=false
    if docker ps -a --format '{{.Names}}' | grep -q '^coolify-realtime$'; then
        legacy_layout=true
    fi
    stop_legacy_containers
    # No --remove-orphans yet: the stopped legacy containers are kept until
    # the update succeeded.
    if ! compose up -d --wait --wait-timeout "$HEALTH_TIMEOUT"; then
        print_warning "Not all containers became healthy yet - continuing with the repair step"
    fi

    echo ""
    echo -e "${BLUE}[5/6] Migrations, caches and workers...${NC}"
    local ok=true
    if ! wait_for_init; then
        print_error "The container's start-up migrations did not finish in time"
        ok=false
    elif ! container_running coolify \
        || ! bash "$SCRIPT_DIR/doctor.sh" fix --yes --force --no-backup; then
        ok=false
    fi

    echo ""
    echo -e "${BLUE}[6/6] Verifying...${NC}"
    local container
    for container in $STACK_CONTAINERS; do
        if wait_for_healthy "$container"; then
            print_success "$container is healthy"
        else
            print_error "$container is not healthy"
            ok=false
        fi
    done

    if [ "$ok" != true ]; then
        if rollback_update "$backup" "$rollback_ready" "$legacy_layout"; then
            print_warning "Update rolled back to $old_version. Pre-update backup: $backup"
        fi
        # Never switch a FRESH timer on after a failure - it would retry
        # within the hour while someone may still be investigating.
        ensure_update_timer refresh || true
        exit 1
    fi

    remove_legacy_containers
    docker image prune -f >/dev/null || true
    ensure_update_timer || true

    echo ""
    print_success "Coolify Stack updated: $old_version -> $(coolify_version)"
    echo "Pre-update backup: $backup"
    echo ""
    do_status
}

#######################################
# Weekly unattended update (systemd timer)
#######################################
write_update_units() {
    cat > "$1/$UPDATE_UNIT.service" <<EOF
[Unit]
Description=Coolify stack update (repository, images, migrations)
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=/bin/bash $SCRIPT_DIR/coolify.sh update
TimeoutStartSec=2h
EOF

    cat > "$1/$UPDATE_UNIT.timer" <<EOF
[Unit]
Description=Weekly Coolify stack update

[Timer]
OnCalendar=$UPDATE_SCHEDULE
Persistent=true
RandomizedDelaySec=15min

[Install]
WantedBy=timers.target
EOF
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

# Installs the timer on first use and keeps its unit files current. An
# existing timer is never re-enabled here, so `autoupdate disable` sticks.
#   $1 = "enable"   also enables and starts it
#   $1 = "refresh"  only refreshes an existing timer, never installs one
ensure_update_timer() {
    local mode="${1:-}" fresh=false tmp unit changed=false
    if ! has_systemd; then
        print_warning "systemd not available - weekly auto-update timer not installed"
        return 0
    fi

    [ -f "$SYSTEMD_DIR/$UPDATE_UNIT.timer" ] || fresh=true
    if [ "$fresh" = true ] && [ "$mode" = "refresh" ]; then
        print_warning "Weekly auto-update not enabled because this update failed."
        echo "  After fixing the cause: sudo $0 autoupdate enable"
        return 0
    fi

    tmp=$(mktemp -d)
    write_update_units "$tmp"
    for unit in "$UPDATE_UNIT.service" "$UPDATE_UNIT.timer"; do
        if ! cmp -s "$tmp/$unit" "$SYSTEMD_DIR/$unit"; then
            cp "$tmp/$unit" "$SYSTEMD_DIR/$unit"
            changed=true
        fi
    done
    rm -rf "$tmp"
    if [ "$changed" = true ]; then
        systemctl daemon-reload || true
    fi

    if [ "$fresh" = true ] || [ "$mode" = "enable" ]; then
        if systemctl enable --now "$UPDATE_UNIT.timer" >/dev/null 2>&1; then
            print_success "Weekly auto-update enabled ($UPDATE_SCHEDULE)"
        else
            print_warning "Could not enable $UPDATE_UNIT.timer - check: systemctl status $UPDATE_UNIT.timer"
        fi
    fi
}

do_autoupdate() {
    check_root "autoupdate"
    case "${2:-status}" in
        enable)
            ensure_update_timer enable
            ;;
        disable)
            if has_systemd; then
                systemctl disable --now "$UPDATE_UNIT.timer" >/dev/null 2>&1 || true
            fi
            print_success "Weekly auto-update disabled (manual: sudo $0 update)"
            ;;
        status)
            if ! has_systemd; then
                print_warning "systemd not available"
                return 0
            fi
            local state
            systemctl list-timers --all "$UPDATE_UNIT.timer" --no-pager || true
            echo ""
            state=$(systemctl is-enabled "$UPDATE_UNIT.timer" 2>/dev/null) || true
            echo "Enabled: ${state:-no}"
            echo "Last run log: journalctl -u $UPDATE_UNIT.service -n 100"
            ;;
        *)
            print_error "Usage: $0 autoupdate [status|enable|disable]"
            exit 1
            ;;
    esac
}

# Online backup of database, Redis, SSH keys and .env into one archive.
# Sets BACKUP_FILE. Returns non-zero instead of exiting, so the update can
# decide what to do. $1 is an optional file-name label, e.g. "preupdate_".
create_backup() {
    local label="${1:-}" timestamp work ok=true
    timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/coolify_backup_${label}${timestamp}.tar.gz"
    work="$BACKUP_DIR/.backup_work_$timestamp"

    # Callers use `if ! create_backup`, which switches errexit off in here:
    # every step that matters is checked explicitly.
    mkdir -p "$work" || return 1

    # 1. PostgreSQL Dump (verified readable before it counts as a backup)
    echo -e "${BLUE}[1/4] PostgreSQL Dump...${NC}"
    if docker exec coolify-db pg_dump -U coolify -d coolify -F c -f /tmp/coolify.dump 2>/dev/null \
        && docker exec coolify-db pg_restore -l /tmp/coolify.dump >/dev/null 2>&1 \
        && docker cp coolify-db:/tmp/coolify.dump "$work/01_postgres.dump" \
        && [ -s "$work/01_postgres.dump" ]; then
        print_success "PostgreSQL dump created"
    else
        print_error "PostgreSQL dump failed!"
        ok=false
    fi
    docker exec coolify-db rm -f /tmp/coolify.dump >/dev/null 2>&1 || true

    # 2. Redis RDB Snapshot
    echo -e "${BLUE}[2/4] Redis Snapshot...${NC}"
    local redis_pw last_save current_save
    redis_pw=$(grep -E "^REDIS_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    last_save=$(docker exec -e REDISCLI_AUTH="$redis_pw" coolify-redis redis-cli LASTSAVE 2>/dev/null) || true
    if docker exec -e REDISCLI_AUTH="$redis_pw" coolify-redis redis-cli BGSAVE 2>/dev/null | grep -q "started\|scheduled"; then
        # Wait for BGSAVE to complete (max 60 seconds)
        for _ in {1..60}; do
            current_save=$(docker exec -e REDISCLI_AUTH="$redis_pw" coolify-redis redis-cli LASTSAVE 2>/dev/null) || true
            if [ "$current_save" != "$last_save" ]; then
                break
            fi
            sleep 1
        done
        if cp /data/system/redis/dump.rdb "$work/02_redis.rdb" 2>/dev/null; then
            print_success "Redis snapshot created"
        else
            print_warning "Redis RDB not found"
        fi
    else
        print_warning "Redis BGSAVE failed, skipped"
    fi

    # 3. SSH-Keys
    echo -e "${BLUE}[3/4] SSH-Keys...${NC}"
    if tar -cf "$work/03_ssh.tar" -C /data/coolify ssh 2>/dev/null; then
        print_success "SSH keys saved"
    else
        print_error "SSH keys backup failed!"
        ok=false
    fi

    # 4. Environment
    echo -e "${BLUE}[4/4] Configuration...${NC}"
    if cp "$ENV_FILE" "$work/04_env.conf"; then
        print_success "Configuration saved"
    else
        print_error "Configuration backup failed!"
        ok=false
    fi

    if [ "$ok" = true ] && tar -czf "$BACKUP_FILE" -C "$work" .; then
        rm -rf "$work"
        chmod 600 "$BACKUP_FILE"
        return 0
    fi
    rm -rf "$work"
    rm -f "$BACKUP_FILE"
    BACKUP_FILE=""
    return 1
}

do_backup() {
    print_header
    check_root "backup"
    check_requirements

    # Check if stack is running
    if ! is_stack_running; then
        print_error "Coolify Stack is not running!"
        echo "For a consistent backup, the stack must be running."
        echo "Start with: $0 start"
        exit 1
    fi

    echo "Creating online backup..."
    echo ""

    if ! create_backup; then
        echo ""
        print_error "Backup failed! Critical components could not be saved."
        exit 1
    fi

    echo ""
    print_success "Backup created: $BACKUP_FILE"
    echo ""
    echo "Size: $(du -h "$BACKUP_FILE" | cut -f1)"
    echo ""
    echo -e "${BLUE}Archive contents:${NC}"
    echo "  01_postgres.dump  - Coolify database"
    echo "  02_redis.rdb      - Redis snapshot"
    echo "  03_ssh.tar        - SSH keys"
    echo "  04_env.conf       - Environment configuration"
    echo ""
    echo "Restore with: $0 restore $BACKUP_FILE"
}

do_restore() {
    print_header
    check_root "restore"

    BACKUP_FILE="${2:-}"

    if [ -z "$BACKUP_FILE" ]; then
        print_error "No backup file specified!"
        echo ""
        echo "Usage: $0 restore <backup-file>"
        echo ""
        echo "Available backups:"
        ls -lh /data/system/backups/coolify_backup_*.tar.gz 2>/dev/null || echo "  No backups found"
        exit 1
    fi

    if [ ! -f "$BACKUP_FILE" ]; then
        print_error "Backup file not found: $BACKUP_FILE"
        exit 1
    fi

    # Check if stack is stopped
    if ! is_stack_stopped; then
        print_error "Coolify Stack is still running!"
        echo "For a safe restore, the stack must be stopped."
        echo "Stop with: $0 stop"
        exit 1
    fi

    check_requirements

    print_warning "WARNING: This will overwrite the current Coolify configuration!"
    echo "Backup: $BACKUP_FILE"
    echo ""
    read -p "Continue? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    RESTORE_WORK="/tmp/coolify_restore_$$"
    mkdir -p "$RESTORE_WORK"

    echo ""
    echo "Extracting backup..."
    tar -xzf "$BACKUP_FILE" -C "$RESTORE_WORK"

    # Validate backup contents
    if [ ! -f "$RESTORE_WORK/01_postgres.dump" ] || [ ! -f "$RESTORE_WORK/04_env.conf" ]; then
        print_error "Invalid backup format!"
        rm -rf "$RESTORE_WORK"
        exit 1
    fi

    echo ""

    # 1. Restore environment
    echo -e "${BLUE}[1/4] Configuration...${NC}"
    cp "$RESTORE_WORK/04_env.conf" "$ENV_FILE"
    chown 9999:root "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    print_success "Configuration restored"

    # 2. Restore SSH-Keys
    echo -e "${BLUE}[2/4] SSH-Keys...${NC}"
    if [ -f "$RESTORE_WORK/03_ssh.tar" ]; then
        tar -xf "$RESTORE_WORK/03_ssh.tar" -C /data/coolify/
        chown -R 9999:root /data/coolify/ssh
        chmod -R 700 /data/coolify/ssh
        chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true
        print_success "SSH keys restored"
    else
        print_warning "No SSH keys in backup"
    fi

    # 3. Restore Redis
    echo -e "${BLUE}[3/4] Redis...${NC}"
    if [ -f "$RESTORE_WORK/02_redis.rdb" ]; then
        cp "$RESTORE_WORK/02_redis.rdb" /data/system/redis/dump.rdb
        chown 999:999 /data/system/redis/dump.rdb
        chmod 600 /data/system/redis/dump.rdb
        print_success "Redis restored"
    else
        print_warning "No Redis snapshot in backup"
    fi

    # 4. Restore PostgreSQL (requires running container)
    echo -e "${BLUE}[4/4] PostgreSQL...${NC}"
    echo "    Starting database temporarily..."

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d database-server

    # Wait for DB
    echo "    Waiting for database..."
    for _ in {1..30}; do
        if docker exec coolify-db pg_isready -U coolify -d coolify &>/dev/null; then
            break
        fi
        sleep 1
    done

    # Clear and restore database
    echo "    Restoring database..."
    docker exec coolify-db dropdb -U coolify --if-exists coolify 2>/dev/null || true
    docker exec coolify-db createdb -U coolify coolify 2>/dev/null || true

    docker cp "$RESTORE_WORK/01_postgres.dump" coolify-db:/tmp/restore.dump
    if docker exec coolify-db pg_restore -U coolify -d coolify /tmp/restore.dump 2>/dev/null; then
        print_success "PostgreSQL restored"
    else
        print_warning "PostgreSQL restore completed with warnings (this can be normal)"
    fi
    docker exec coolify-db rm /tmp/restore.dump

    # Stop DB again
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down

    # Cleanup
    rm -rf "$RESTORE_WORK"

    echo ""
    print_success "Restore completed!"
    echo ""
    echo "Start the stack with: $0 start"
}

do_destroy() {
    print_header
    check_root "destroy"

    print_warning "WARNING: This will completely remove Coolify!"
    echo ""
    echo "This will delete:"
    echo "  - All Docker containers and volumes"
    echo "  - Environment file (.env)"
    echo "  - SSH key from authorized_keys"
    echo ""
    echo "Data in /data/coolify and /data/system will NOT be deleted."
    echo ""
    read -p "Are you sure? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "Destroying Coolify Stack..."

    # Stop and remove containers
    cd "$SCRIPT_DIR"
    if [ -f "$COMPOSE_FILE" ] && [ -f "$ENV_FILE" ]; then
        $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
    fi

    # Remove .env file
    echo "Removing .env file..."
    rm -f "$ENV_FILE"

    # Remove SSH key from authorized_keys
    echo "Removing SSH key from authorized_keys..."
    SSH_PUBKEY="/data/coolify/ssh/keys/id.root@host.docker.internal.pub"
    if [ -f "$SSH_PUBKEY" ] && [ -f ~/.ssh/authorized_keys ]; then
        # Get the key content and remove it from authorized_keys
        KEY_CONTENT=$(cat "$SSH_PUBKEY" 2>/dev/null)
        if [ -n "$KEY_CONTENT" ]; then
            grep -vF "$KEY_CONTENT" ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp 2>/dev/null || true
            mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys 2>/dev/null || true
            chmod 600 ~/.ssh/authorized_keys 2>/dev/null || true
        fi
    fi

    echo ""
    print_success "Coolify Stack destroyed!"
    echo ""
    echo "Remaining data (not deleted):"
    echo "  /data/coolify  - Application data, SSH keys, backups"
    echo "  /data/system   - PostgreSQL, Redis data"
    echo "  /opt/coolify   - Scripts (docker-compose.yml, coolify.sh, etc.)"
    echo ""
    echo "To delete everything:"
    echo "  rm -rf /data/coolify /data/system /opt/coolify"
}

do_help() {
    print_header
    echo "Usage: $0 <command> [options]"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  start             Start the Coolify Stack"
    echo "  stop              Stop the Coolify Stack"
    echo "  restart           Restart the Stack"
    echo "  status            Show status of all containers"
    echo "  logs [service]    Show logs (optional: service name)"
    echo "  update            Update repository + images, run migrations (rollback on failure)"
    echo "  autoupdate [status|enable|disable]"
    echo "                    Weekly unattended update (systemd timer, Sat 03:00)"
    echo "  backup            Create an online backup (stack must be running)"
    echo "  restore <file>    Restore from backup (stack must be stopped)"
    echo "  destroy           Stop and remove all containers and volumes"
    echo "  help              Show this help"
    echo ""
    echo -e "${BLUE}Backup/Restore:${NC}"
    echo "  $0 backup                              # Create backup"
    echo "  $0 restore /data/system/backups/...   # Restore backup"
    echo ""
    echo -e "${BLUE}Examples:${NC}"
    echo "  $0 start"
    echo "  $0 logs coolify"
    echo "  $0 logs database-server"
    echo "  $0 update"
    echo ""
    echo -e "${BLUE}Services:${NC}"
    echo "  coolify, database-server, redis-server"
    echo ""
    echo -e "${BLUE}Diagnostics & Repair:${NC}"
    echo "  ./doctor.sh check   Diagnose the stack (pending migrations, health, ...)"
    echo "  ./doctor.sh fix     Repair after an update (migrations, caches, workers)"
    echo ""
}

#######################################
# Main
#######################################
case "${1:-}" in
    start)
        do_start
        ;;
    stop)
        do_stop
        ;;
    restart)
        do_restart
        ;;
    status)
        do_status
        ;;
    logs)
        do_logs "$@"
        ;;
    update)
        do_update "$@"
        ;;
    autoupdate)
        do_autoupdate "$@"
        ;;
    backup)
        do_backup
        ;;
    restore)
        do_restore "$@"
        ;;
    destroy)
        do_destroy
        ;;
    help|--help|-h|"")
        do_help
        ;;
    *)
        print_error "Unknown command: $1"
        echo ""
        do_help
        exit 1
        ;;
esac

exit 0
