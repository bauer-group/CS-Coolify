#!/bin/bash
set -e

#######################################
# Coolify Stack Management Script
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="/opt/coolify/.env"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

is_stack_running() {
    # Check if all Coolify containers are running
    local running=0
    for container in coolify coolify-db coolify-redis coolify-realtime; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            ((running++))
        fi
    done
    [ "$running" -eq 4 ]
}

is_stack_stopped() {
    # Check if all Coolify containers are stopped
    for container in coolify coolify-db coolify-redis coolify-realtime; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            return 1
        fi
    done
    return 0
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

    cd "$SCRIPT_DIR"
    $(get_compose_cmd) --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --wait 2>&1

    echo ""
    print_success "Coolify Stack started!"
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

do_update() {
    print_header
    check_root "update"
    check_requirements

    echo "Updating Coolify Stack..."
    echo ""

    cd "$SCRIPT_DIR"
    COMPOSE_CMD=$(get_compose_cmd)

    # 1. Pull new images
    echo -e "${BLUE}[1/3] Pulling new images...${NC}"
    $COMPOSE_CMD --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull

    echo ""

    # 2. Recreate containers with new images
    echo -e "${BLUE}[2/3] Updating containers...${NC}"
    $COMPOSE_CMD --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans

    echo ""

    # 3. Cleanup old images
    echo -e "${BLUE}[3/3] Cleaning up old images...${NC}"
    docker image prune -f

    echo ""
    print_success "Coolify Stack updated!"
    echo ""
    do_status
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

    BACKUP_DIR="/data/system/backups"
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/coolify_backup_$TIMESTAMP.tar.gz"
    BACKUP_WORK="$BACKUP_DIR/.backup_work_$TIMESTAMP"

    mkdir -p "$BACKUP_WORK"

    echo "Creating online backup..."
    echo ""

    BACKUP_OK=true

    # 1. PostgreSQL Dump
    echo -e "${BLUE}[1/4] PostgreSQL Dump...${NC}"
    if docker exec coolify-db pg_dump -U coolify -d coolify -F c -f /tmp/coolify.dump 2>/dev/null; then
        docker cp coolify-db:/tmp/coolify.dump "$BACKUP_WORK/01_postgres.dump"
        docker exec coolify-db rm /tmp/coolify.dump
        print_success "PostgreSQL dump created"
    else
        print_error "PostgreSQL dump failed!"
        BACKUP_OK=false
    fi

    # 2. Redis RDB Snapshot
    echo -e "${BLUE}[2/4] Redis Snapshot...${NC}"
    REDIS_PW=$(grep -E "^REDIS_PASSWORD=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2)
    LAST_SAVE=$(docker exec -e REDISCLI_AUTH="$REDIS_PW" coolify-redis redis-cli LASTSAVE 2>/dev/null)
    if docker exec -e REDISCLI_AUTH="$REDIS_PW" coolify-redis redis-cli BGSAVE 2>/dev/null | grep -q "started\|scheduled"; then
        # Wait for BGSAVE to complete (max 60 seconds)
        for _ in {1..60}; do
            CURRENT_SAVE=$(docker exec -e REDISCLI_AUTH="$REDIS_PW" coolify-redis redis-cli LASTSAVE 2>/dev/null)
            if [ "$CURRENT_SAVE" != "$LAST_SAVE" ]; then
                break
            fi
            sleep 1
        done
        if cp /data/system/redis/dump.rdb "$BACKUP_WORK/02_redis.rdb" 2>/dev/null; then
            print_success "Redis snapshot created"
        else
            print_warning "Redis RDB not found"
        fi
    else
        print_warning "Redis BGSAVE failed, skipped"
    fi

    # 3. SSH-Keys
    echo -e "${BLUE}[3/4] SSH-Keys...${NC}"
    if tar -cf "$BACKUP_WORK/03_ssh.tar" -C /data/coolify ssh 2>/dev/null; then
        print_success "SSH keys saved"
    else
        print_error "SSH keys backup failed!"
        BACKUP_OK=false
    fi

    # 4. Environment
    echo -e "${BLUE}[4/4] Configuration...${NC}"
    if cp "$ENV_FILE" "$BACKUP_WORK/04_env.conf"; then
        print_success "Configuration saved"
    else
        print_error "Configuration backup failed!"
        BACKUP_OK=false
    fi

    echo ""

    # Create archive
    if [ "$BACKUP_OK" = true ]; then
        tar -czf "$BACKUP_FILE" -C "$BACKUP_WORK" .
        rm -rf "$BACKUP_WORK"

        print_success "Backup created: $BACKUP_FILE"
        echo ""
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        echo "Size: $BACKUP_SIZE"
        echo ""
        echo -e "${BLUE}Archive contents:${NC}"
        echo "  01_postgres.dump  - Coolify database"
        echo "  02_redis.rdb      - Redis snapshot"
        echo "  03_ssh.tar        - SSH keys"
        echo "  04_env.conf       - Environment configuration"
        echo ""
        echo "Restore with: $0 restore $BACKUP_FILE"
    else
        rm -rf "$BACKUP_WORK"
        print_error "Backup failed! Critical components could not be saved."
        exit 1
    fi
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
    echo "  update            Update all containers to latest version"
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
    echo "  coolify, coolify-realtime, database-server, redis-server, watchtower"
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
        do_update
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
