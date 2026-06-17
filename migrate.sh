#!/bin/bash
set -euo pipefail

#######################################
# Coolify Host Migration Script
#
# Migrates this custom Coolify stack to a NEW host over SSH (push model).
# Runs on the SOURCE server and orchestrates the destination.
#
# What it does (in order, source never stopped -> fully reversible):
#   1. Online control-plane backup via ./coolify.sh backup
#      (PostgreSQL dump + Redis snapshot + SSH keys + .env)
#   2. Optional: export selected Docker named volumes of deployed apps
#      (briefly stops only the affected app containers for consistency)
#   3. Stream repo + backup + volume archives to the destination
#   4. On destination: setup.sh -> restore -> re-add SSH key ->
#      optional hostname/domain rewrite -> start -> health check
#
# The destination side runs the hidden "__import" subcommand of this
# very file (transferred with the repo), so all logic lives here.
#######################################

#######################################
# Constants
#######################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COOLIFY_SH="$SCRIPT_DIR/coolify.sh"
ENV_FILE="/opt/coolify/.env"
STAGING_DIR="/data/system/migration_staging"   # used on the destination
COOLIFY_PUBKEY="/data/coolify/ssh/keys/id.root@host.docker.internal.pub"

#######################################
# Colors and Output
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_step()    { echo -e "${BLUE}»${NC} $1"; }
die() { print_error "$1"; exit 1; }

# Ask a yes/no question (reads from the terminal so it works even when
# stdin is occupied). Honors ASSUME_YES for full automation.
confirm() {
    local prompt="$1" default="${2:-n}" answer
    if [ "${ASSUME_YES:-false}" = "true" ]; then
        return 0
    fi
    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    read -r -p "$prompt" answer </dev/tty || answer=""
    answer="${answer:-$default}"
    case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

check_root() {
    [ "$(id -u)" -eq 0 ] || die "This script must be run as root (use sudo)."
}

#######################################
# Argument parsing
#######################################
usage() {
    cat <<'EOF'
Coolify Host Migration

Usage:
  sudo ./migrate.sh --dest <host> --key <ssh_key> [options]

Required:
  --dest <host>          Destination host or IP (root SSH access)
  --key <path>           Path to the SSH private key for the destination

Volume options (deployed app data):
  --all-volumes          Migrate ALL Docker named volumes (no prompt)
  --no-volumes           Control plane only (skip app volumes)
  (default)              Interactively select which volumes to migrate

Hostname / domain change (optional):
  --new-hostname <name>  Set the OS hostname on the destination
  --old-domain <fqdn>    Old domain to rewrite in Coolify's database
  --new-domain <fqdn>    New domain (also written to PUSHER_HOST)
                         --old-domain and --new-domain must be given together

Behavior:
  --yes                  Assume "yes" for all prompts (full automation)
  --live-volumes         Export volumes WITHOUT stopping app containers
                         (faster, but risks inconsistent stateful data)
  -h, --help             Show this help

Examples:
  sudo ./migrate.sh --dest 203.0.113.10 --key ~/.ssh/migrate_key
  sudo ./migrate.sh --dest new.example.com --key ~/.ssh/migrate_key \
       --new-hostname coolify-prod --old-domain old.example.com \
       --new-domain new.example.com --all-volumes --yes
EOF
}

DEST=""
SSH_KEY=""
NEW_HOSTNAME=""
OLD_DOMAIN=""
NEW_DOMAIN=""
VOLUME_MODE="select"        # select | all | none
ASSUME_YES=false
STOP_FOR_VOLUMES=true

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dest) DEST="${2:-}"; shift 2 ;;
            --key) SSH_KEY="${2:-}"; shift 2 ;;
            --new-hostname) NEW_HOSTNAME="${2:-}"; shift 2 ;;
            --old-domain) OLD_DOMAIN="${2:-}"; shift 2 ;;
            --new-domain) NEW_DOMAIN="${2:-}"; shift 2 ;;
            --all-volumes) VOLUME_MODE="all"; shift ;;
            --no-volumes) VOLUME_MODE="none"; shift ;;
            --live-volumes) STOP_FOR_VOLUMES=false; shift ;;
            --yes|-y) ASSUME_YES=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown option: $1 (use --help)" ;;
        esac
    done
}

# Reject anything that is not a plausible hostname/FQDN to keep it out of
# shell interpolation and SQL further down.
validate_fqdn() {
    local v="$1"
    if ! printf '%s' "$v" | grep -Eq '^[A-Za-z0-9._-]+$'; then
        die "Invalid hostname/domain value: '$v' (only A-Z a-z 0-9 . _ - allowed)"
    fi
}

#######################################
# SOURCE side
#######################################
SSH_OPTS=(-o "StrictHostKeyChecking=accept-new" -o "ConnectTimeout=10" \
          -o "ServerAliveInterval=30" -o "ServerAliveCountMax=10")

ssh_dest() { ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "root@${DEST}" "$@"; }
scp_dest() { scp -i "$SSH_KEY" "${SSH_OPTS[@]}" "$@"; }

# Containers (running) that mount a given named volume.
containers_using_volume() {
    docker ps --filter "volume=$1" --format '{{.Names}}' 2>/dev/null || true
}

preflight() {
    print_header "Preflight checks"

    [ -n "$DEST" ] || die "No destination set (--dest)."
    [ -n "$SSH_KEY" ] || die "No SSH key set (--key)."
    [ -f "$SSH_KEY" ] || die "SSH key file not found: $SSH_KEY"
    [ -x "$COOLIFY_SH" ] || die "coolify.sh not found next to migrate.sh."
    [ -f "$ENV_FILE" ] || die ".env not found ($ENV_FILE). Is this a Coolify host?"
    command -v docker >/dev/null 2>&1 || die "Docker not found on source."

    if [ -n "$OLD_DOMAIN$NEW_DOMAIN" ]; then
        [ -n "$OLD_DOMAIN" ] && [ -n "$NEW_DOMAIN" ] || \
            die "--old-domain and --new-domain must be given together."
        validate_fqdn "$OLD_DOMAIN"; validate_fqdn "$NEW_DOMAIN"
    fi
    [ -n "$NEW_HOSTNAME" ] && validate_fqdn "$NEW_HOSTNAME"

    # Source stack must run for a consistent online backup + volume discovery.
    if ! docker ps --format '{{.Names}}' | grep -q '^coolify$'; then
        die "Coolify stack is not running. Start it first: ./coolify.sh start"
    fi
    print_success "Source stack is running"

    # Destination reachable over SSH as root.
    print_step "Testing SSH to root@${DEST} ..."
    ssh_dest "exit" 2>/dev/null || die "SSH connection to $DEST failed."
    print_success "SSH connection OK"

    # Destination must already have a WORKING Docker (we do not provision the
    # OS here). Distinguish "not installed" from "installed but daemon down".
    print_step "Checking Docker on destination ..."
    if ! ssh_dest "command -v docker >/dev/null 2>&1"; then
        print_error "Docker is not installed on the destination ($DEST)."
        echo "  Provision the destination first, e.g.:"
        echo "    cd /opt/coolify/server-setup && sudo ./install.sh"
        echo "  (or install Docker manually), then re-run this migration."
        exit 1
    fi
    if ! ssh_dest "docker info >/dev/null 2>&1"; then
        print_error "Docker is installed but the daemon is not running on $DEST."
        echo "  Start it on the destination:  sudo systemctl enable --now docker"
        exit 1
    fi
    print_success "Docker installed and running on destination"

    # Warn loudly if the destination already hosts a Coolify install.
    if ssh_dest "test -f /opt/coolify/.env" 2>/dev/null; then
        print_warning "Destination already has /opt/coolify/.env — it WILL be overwritten."
        confirm "Continue and overwrite the destination Coolify?" "n" \
            || die "Aborted by user."
    fi
}

# Returns the path of the freshly created control-plane backup.
create_backup() {
    print_header "Control-plane backup (online)" >&2
    print_step "Running ./coolify.sh backup ..." >&2
    # coolify.sh writes the archive to /data/system/backups and prints the path.
    "$COOLIFY_SH" backup >&2
    local latest
    latest=$(ls -1t /data/system/backups/coolify_backup_*.tar.gz 2>/dev/null | head -n1 || true)
    [ -n "$latest" ] && [ -f "$latest" ] || die "Backup file not found after backup run."
    print_success "Backup ready: $latest" >&2
    printf '%s\n' "$latest"
}

# Echoes the list of volumes to migrate (one per line) on stdout.
select_volumes() {
    local all_vols=() chosen=()
    mapfile -t all_vols < <(docker volume ls --format '{{.Name}}' 2>/dev/null | sort)

    if [ "${#all_vols[@]}" -eq 0 ] || [ "$VOLUME_MODE" = "none" ]; then
        return 0
    fi
    if [ "$VOLUME_MODE" = "all" ]; then
        printf '%s\n' "${all_vols[@]}"
        return 0
    fi

    # Interactive selection.
    print_header "Select app volumes to migrate" >&2
    echo "Found ${#all_vols[@]} Docker named volume(s):" >&2
    local i=1 v size
    for v in "${all_vols[@]}"; do
        size=$(du -sh "/var/lib/docker/volumes/$v/_data" 2>/dev/null | cut -f1 || echo '?')
        printf '  %2d) %-50s %8s\n' "$i" "$v" "$size" >&2
        i=$((i + 1))
    done
    echo "" >&2
    echo "Select volumes to migrate:" >&2
    echo "  all   - migrate every volume listed above" >&2
    echo "  none  - skip app volumes (migrate control plane only)" >&2
    echo "  1 3 4 - migrate specific volumes by number (space-separated)" >&2
    local reply
    read -r -p "> " reply </dev/tty || reply="none"

    case "$reply" in
        all|ALL) chosen=("${all_vols[@]}") ;;
        none|NONE|"") chosen=() ;;
        *)
            local n
            for n in $reply; do
                if printf '%s' "$n" | grep -Eq '^[0-9]+$' \
                   && [ "$n" -ge 1 ] && [ "$n" -le "${#all_vols[@]}" ]; then
                    chosen+=("${all_vols[$((n - 1))]}")
                else
                    print_warning "Ignoring invalid selection: $n" >&2
                fi
            done
            ;;
    esac
    [ "${#chosen[@]}" -gt 0 ] && printf '%s\n' "${chosen[@]}"
    return 0
}

# Globals used by the trap so we can resume containers on failure.
STOPPED_CONTAINERS=()
WORK_DIR=""

cleanup_on_error() {
    local code=$?
    if [ "${#STOPPED_CONTAINERS[@]}" -gt 0 ]; then
        print_warning "Restarting app containers that were stopped for export ..."
        docker start "${STOPPED_CONTAINERS[@]}" >/dev/null 2>&1 || true
    fi
    [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null || true
    [ "$code" -ne 0 ] && print_error "Migration aborted (exit $code). Source is unchanged."
}

# Exports the chosen volumes into $WORK_DIR. Stops the using containers
# first (unless --live-volumes), then restarts them immediately.
export_volumes() {
    local -n _vols=$1
    [ "${#_vols[@]}" -gt 0 ] || return 0

    print_header "Exporting ${#_vols[@]} volume(s)"
    local v users
    for v in "${_vols[@]}"; do
        users=$(containers_using_volume "$v")
        if [ "$STOP_FOR_VOLUMES" = "true" ] && [ -n "$users" ]; then
            print_step "Stopping for consistency: $users"
            # shellcheck disable=SC2086
            docker stop $users >/dev/null
            # shellcheck disable=SC2206
            STOPPED_CONTAINERS+=($users)
        elif [ -n "$users" ]; then
            print_warning "Live export of $v (in use by: $users) — may be inconsistent"
        fi

        print_step "Archiving volume $v ..."
        tar --numeric-owner -czf "$WORK_DIR/vol_${v}.tar.gz" \
            -C "/var/lib/docker/volumes/$v/_data" . \
            || die "Failed to archive volume $v"

        if [ -n "$users" ] && [ "$STOP_FOR_VOLUMES" = "true" ]; then
            # shellcheck disable=SC2086
            docker start $users >/dev/null
            # remove these from the to-restart-on-error list
            STOPPED_CONTAINERS=()
        fi
        print_success "Exported $v"
    done
}

do_migrate() {
    check_root
    trap cleanup_on_error EXIT

    print_header "Coolify Host Migration"
    echo "Source:      $(hostname) ($(hostname -I 2>/dev/null | awk '{print $1}'))"
    echo "Destination: $DEST"
    [ -n "$NEW_HOSTNAME" ] && echo "New hostname: $NEW_HOSTNAME"
    [ -n "$NEW_DOMAIN" ]   && echo "Domain:       $OLD_DOMAIN -> $NEW_DOMAIN"
    echo ""

    preflight

    confirm "Proceed with the migration?" "y" || die "Aborted by user."

    # Staging work dir on the source.
    WORK_DIR="/data/system/migration_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$WORK_DIR"

    # 1. Online control-plane backup.
    local backup_file
    backup_file=$(create_backup)
    cp "$backup_file" "$WORK_DIR/"

    # 2. Volume selection + export.
    local vols=()
    mapfile -t vols < <(select_volumes)
    if [ "${#vols[@]}" -gt 0 ]; then
        export_volumes vols
    else
        print_warning "No app volumes selected — migrating control plane only."
    fi

    # 3. Integrity manifest (verified on the destination before restore).
    print_step "Writing checksum manifest ..."
    ( cd "$WORK_DIR" && sha256sum ./* > manifest.sha256 )
    print_success "Manifest written"

    # 4. Transfer: repo (without secrets), then the staging payload.
    print_header "Transfer to destination"

    print_step "Streaming repository to ${DEST}:/opt/coolify ..."
    tar -czf - -C /opt --exclude='coolify/.env' --exclude='coolify/.git' coolify \
        | ssh_dest "mkdir -p /opt && tar -xzf - -C /opt && chmod +x /opt/coolify/*.sh"
    print_success "Repository transferred"

    print_step "Copying migration payload to destination staging ..."
    ssh_dest "rm -rf '$STAGING_DIR' && mkdir -p '$STAGING_DIR'"
    scp_dest "$WORK_DIR"/* "root@${DEST}:$STAGING_DIR/" >/dev/null
    print_success "Payload transferred"

    # 5. Trigger the import on the destination.
    print_header "Importing on destination"
    local remote_args=(__import \
        --backup "$STAGING_DIR/$(basename "$backup_file")" \
        --staging "$STAGING_DIR")
    [ -n "$NEW_HOSTNAME" ] && remote_args+=(--new-hostname "$NEW_HOSTNAME")
    [ -n "$NEW_DOMAIN" ] && remote_args+=(--old-domain "$OLD_DOMAIN" --new-domain "$NEW_DOMAIN")

    ssh_dest "bash /opt/coolify/migrate.sh ${remote_args[*]}" \
        || die "Remote import failed. Source is untouched and still running."

    # 6. Done. Source intentionally left running for verification.
    rm -rf "$WORK_DIR"; WORK_DIR=""
    trap - EXIT

    print_header "Migration complete"
    print_success "Coolify is now running on $DEST"
    echo ""
    echo "Next steps:"
    echo "  1. Verify the new instance (login, projects, deployments)."
    echo "  2. Update DNS / reverse proxy to point at the destination."
    echo "  3. Once verified, decommission the source:"
    echo "       sudo ./coolify.sh stop"
    echo ""
    print_warning "The SOURCE is still running. Nothing here was changed."
}

#######################################
# DESTINATION side (invoked over SSH as: migrate.sh __import ...)
#######################################
IMPORT_BACKUP=""
IMPORT_STAGING=""

parse_import_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --backup) IMPORT_BACKUP="${2:-}"; shift 2 ;;
            --staging) IMPORT_STAGING="${2:-}"; shift 2 ;;
            --new-hostname) NEW_HOSTNAME="${2:-}"; shift 2 ;;
            --old-domain) OLD_DOMAIN="${2:-}"; shift 2 ;;
            --new-domain) NEW_DOMAIN="${2:-}"; shift 2 ;;
            *) die "Unknown import option: $1" ;;
        esac
    done
}

verify_manifest() {
    [ -f "$IMPORT_STAGING/manifest.sha256" ] || die "No checksum manifest in staging."
    print_step "Verifying payload integrity ..."
    ( cd "$IMPORT_STAGING" && sha256sum -c manifest.sha256 >/dev/null ) \
        || die "Checksum verification failed — transfer corrupted."
    print_success "Payload integrity OK"
}

# Recreate each transferred volume and load its data.
import_volumes() {
    local archive vol
    shopt -s nullglob
    for archive in "$IMPORT_STAGING"/vol_*.tar.gz; do
        vol="$(basename "$archive")"; vol="${vol#vol_}"; vol="${vol%.tar.gz}"
        print_step "Restoring volume $vol ..."
        docker volume create "$vol" >/dev/null
        tar --numeric-owner -xzf "$archive" \
            -C "/var/lib/docker/volumes/$vol/_data" \
            || die "Failed to restore volume $vol"
        print_success "Restored $vol"
    done
    shopt -u nullglob
}

# Coolify must be able to SSH into the new host's localhost. Re-add its
# public key to root's authorized_keys (deduplicated).
reauthorize_ssh_key() {
    [ -f "$COOLIFY_PUBKEY" ] || { print_warning "Coolify public key missing — skipping"; return; }
    mkdir -p /root/.ssh; chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    if ! grep -qFf "$COOLIFY_PUBKEY" /root/.ssh/authorized_keys 2>/dev/null; then
        cat "$COOLIFY_PUBKEY" >> /root/.ssh/authorized_keys
    fi
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    print_success "Coolify SSH key authorized on destination"
}

apply_hostname() {
    [ -n "$NEW_HOSTNAME" ] || return 0
    print_step "Setting OS hostname to $NEW_HOSTNAME ..."
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null \
        || print_warning "hostnamectl failed (non-systemd host?)"
    print_success "Hostname set"
}

# Rewrite PUSHER_HOST in .env and the FQDNs stored inside Coolify's DB.
apply_domain_rewrite() {
    [ -n "$NEW_DOMAIN" ] || return 0
    validate_fqdn "$OLD_DOMAIN"; validate_fqdn "$NEW_DOMAIN"

    print_step "Updating PUSHER_HOST in .env -> $NEW_DOMAIN ..."
    if grep -q '^PUSHER_HOST=' "$ENV_FILE"; then
        sed -i "s|^PUSHER_HOST=.*|PUSHER_HOST=${NEW_DOMAIN}|" "$ENV_FILE"
        print_success "PUSHER_HOST updated"
    fi

    print_step "Rewriting domains in Coolify database ($OLD_DOMAIN -> $NEW_DOMAIN) ..."
    cd /opt/coolify
    local compose; compose=$(get_compose_cmd)
    $compose --env-file "$ENV_FILE" -f docker-compose.yml up -d database-server >/dev/null
    for _ in {1..30}; do
        docker exec coolify-db pg_isready -U coolify -d coolify >/dev/null 2>&1 && break
        sleep 1
    done

    # Only known FQDN columns are touched, each guarded by existence checks,
    # all in one transaction. Values are pre-validated above.
    docker exec -i coolify-db psql -U coolify -d coolify -v ON_ERROR_STOP=1 >/dev/null <<SQL
BEGIN;
DO \$\$
DECLARE t_c RECORD;
BEGIN
  FOR t_c IN
    SELECT table_name, column_name FROM information_schema.columns
    WHERE table_schema='public' AND column_name='fqdn'
      AND table_name IN ('instance_settings','applications','service_applications')
  LOOP
    EXECUTE format(
      'UPDATE public.%I SET %I = replace(%I, %L, %L) WHERE %I LIKE %L',
      t_c.table_name, t_c.column_name, t_c.column_name,
      '${OLD_DOMAIN}', '${NEW_DOMAIN}', t_c.column_name, '%${OLD_DOMAIN}%');
  END LOOP;
END
\$\$;
COMMIT;
SQL
    $compose --env-file "$ENV_FILE" -f docker-compose.yml down >/dev/null
    print_success "Database domains rewritten"
}

# Minimal copy of coolify.sh's compose detection (import runs standalone).
get_compose_cmd() {
    if docker compose version >/dev/null 2>&1; then echo "docker compose"; else echo "docker-compose"; fi
}

do_import() {
    check_root
    print_header "Coolify Import (destination)"

    [ -f "$IMPORT_BACKUP" ] || die "Backup file not found: $IMPORT_BACKUP"
    [ -d "$IMPORT_STAGING" ] || die "Staging dir not found: $IMPORT_STAGING"

    verify_manifest

    # 1. Folder structure, permissions, throwaway .env (overwritten by restore).
    print_step "Preparing destination (setup.sh) ..."
    bash /opt/coolify/setup.sh >/dev/null
    print_success "Destination prepared"

    # 2. Recreate app volumes (before restore, so apps find their data).
    import_volumes

    # 3. Restore the control plane (env, ssh, redis, postgres).
    print_step "Restoring control plane ..."
    echo "yes" | bash /opt/coolify/coolify.sh restore "$IMPORT_BACKUP" >/dev/null
    print_success "Control plane restored"

    # 4. Make Coolify reachable on the new host.
    reauthorize_ssh_key
    apply_hostname
    apply_domain_rewrite

    # 5. Start the stack.
    print_step "Starting Coolify stack ..."
    bash /opt/coolify/coolify.sh start >/dev/null
    print_success "Stack started"

    # 6. Health check.
    print_step "Waiting for Coolify to become healthy ..."
    local ok=false
    for _ in {1..30}; do
        if docker exec coolify curl -fsS http://127.0.0.1:8080/api/health >/dev/null 2>&1; then
            ok=true; break
        fi
        sleep 2
    done
    $ok && print_success "Coolify is healthy" || print_warning "Health check timed out — check 'coolify.sh logs'"

    # 7. Cleanup staging payload.
    rm -rf "$IMPORT_STAGING"
    print_success "Import finished"
}

#######################################
# Dispatch
#######################################
main() {
    if [ "${1:-}" = "__import" ]; then
        shift
        parse_import_args "$@"
        do_import
    else
        parse_args "$@"
        if [ -z "$DEST" ] && [ -z "$SSH_KEY" ]; then
            usage; exit 0
        fi
        do_migrate
    fi
}

main "$@"
