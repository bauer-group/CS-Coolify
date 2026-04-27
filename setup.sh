#!/bin/bash
set -e

#######################################
# Coolify Setup Script
# Creates folders, SSH keys, .env and
# copies files to /opt/coolify
#######################################

INSTALL_DIR="/opt/coolify"
ENV_FILE="$INSTALL_DIR/.env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load server.conf if exists (for PUSHER_HOST, PUSHER_PORT, etc.)
if [ -f "$SCRIPT_DIR/server-setup/server.conf" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/server-setup/server.conf"
elif [ -f "/opt/coolify/server-setup/server.conf" ]; then
    # shellcheck source=/dev/null
    source "/opt/coolify/server-setup/server.conf"
fi

#######################################
# Colors and Output
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║     ██████╗ ██████╗  ██████╗ ██╗     ██╗███████╗██╗   ██╗     ║"
    echo "║    ██╔════╝██╔═══██╗██╔═══██╗██║     ██║██╔════╝╚██╗ ██╔╝     ║"
    echo "║    ██║     ██║   ██║██║   ██║██║     ██║█████╗   ╚████╔╝      ║"
    echo "║    ██║     ██║   ██║██║   ██║██║     ██║██╔══╝    ╚██╔╝       ║"
    echo "║    ╚██████╗╚██████╔╝╚██████╔╝███████╗██║██║        ██║        ║"
    echo "║     ╚═════╝ ╚═════╝  ╚═════╝ ╚══════╝╚═╝╚═╝        ╚═╝        ║"
    echo "║                                                               ║"
    echo "║                      Setup Script                             ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

#######################################
# Root Check
#######################################
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root!"
    echo "Please run with 'sudo ./setup.sh'."
    exit 1
fi

print_banner

#######################################
# 1. Create folder structure
#######################################
echo "[1/6] Creating folder structure..."

# Coolify data folders (mapped into container)
mkdir -p /data/coolify/{ssh,applications,databases,backups,services}
mkdir -p /data/coolify/ssh/{keys,mux}

# Coolify host folders (for dynamically created containers via SSH)
mkdir -p /data/coolify/{proxy,webhooks-during-maintenance,sentinel}
mkdir -p /data/coolify/proxy/dynamic

# System folders for databases and backups
mkdir -p /data/system/{postgres,redis,backups}

# Installation folder
mkdir -p "$INSTALL_DIR"

print_success "Folders created"

#######################################
# 2. Copy files to /opt/coolify
#######################################
echo "[2/6] Installing files..."

# Check if we're already running from /opt/coolify
if [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    echo "    Copying files from $SCRIPT_DIR to $INSTALL_DIR..."

    # Copy main files
    cp -f "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/" 2>/dev/null || true
    cp -f "$SCRIPT_DIR/coolify.sh" "$INSTALL_DIR/" 2>/dev/null || true
    cp -f "$SCRIPT_DIR/setup.sh" "$INSTALL_DIR/" 2>/dev/null || true
    cp -f "$SCRIPT_DIR/update.sh" "$INSTALL_DIR/" 2>/dev/null || true
    cp -f "$SCRIPT_DIR/README.md" "$INSTALL_DIR/" 2>/dev/null || true

    # Copy server-setup directory if exists
    if [ -d "$SCRIPT_DIR/server-setup" ]; then
        cp -rf "$SCRIPT_DIR/server-setup" "$INSTALL_DIR/"
    fi

    print_success "Files installed to $INSTALL_DIR"
else
    print_warning "Already running from $INSTALL_DIR - skipping copy"
fi

# Make scripts executable
chmod +x "$INSTALL_DIR/coolify.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/setup.sh" 2>/dev/null || true
chmod +x "$INSTALL_DIR/update.sh" 2>/dev/null || true

#######################################
# 3. Generate SSH key (if not exists)
#######################################
echo "[3/6] Checking SSH keys..."

SSH_KEY="/data/coolify/ssh/keys/id.root@host.docker.internal"

if [ ! -f "$SSH_KEY" ]; then
    echo "    Generating SSH key..."
    ssh-keygen -f "$SSH_KEY" -t ed25519 -N '' -C root@coolify

    # Add public key to authorized_keys
    mkdir -p ~/.ssh
    cat "${SSH_KEY}.pub" >> ~/.ssh/authorized_keys

    # Remove duplicates
    sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys

    chmod 600 ~/.ssh/authorized_keys
    print_success "SSH key created and authorized_keys updated"
else
    print_warning "SSH key already exists"
fi

#######################################
# 4. Create .env file (if not exists)
#######################################
echo "[4/6] Checking .env file..."

if [ ! -f "$ENV_FILE" ]; then
    echo "    Creating new .env file with random values..."

    # Generate secure random values (matching official Coolify install.sh)
    # APP_ID: 16 bytes hex = 32 characters
    GEN_APP_ID=$(openssl rand -hex 16)

    # APP_KEY: Laravel format with base64 prefix
    GEN_APP_KEY="base64:$(openssl rand -base64 32)"

    # PUSHER keys: 32 bytes hex = 64 characters each
    GEN_PUSHER_APP_ID=$(openssl rand -hex 32)
    GEN_PUSHER_APP_KEY=$(openssl rand -hex 32)
    GEN_PUSHER_APP_SECRET=$(openssl rand -hex 32)

    # Alphanumeric passwords (no special characters for DB compatibility)
    GEN_DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    GEN_REDIS_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

    # Root password needs at least one symbol for Coolify validation
    # Safe symbols that won't be interpreted by shell: @ # % _ - .
    # Avoid: $ ` ! \ ' " ( ) { } [ ] < > | & ; * ? ~
    SAFE_SYMBOLS='@#%-_.'
    RANDOM_SYMBOL=${SAFE_SYMBOLS:$((RANDOM % ${#SAFE_SYMBOLS})):1}
    GEN_ROOT_PASSWORD="$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 12)${RANDOM_SYMBOL}$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 11)"

    # Pre-compute values that need command substitution
    GEN_DATE=$(date)
    GEN_SERVER=$(hostname)
    GEN_EMAIL="admin@$(hostname -f 2>/dev/null || echo "localhost")"
    GEN_TIMEZONE=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    GEN_SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    GEN_SERVER_IP=${GEN_SERVER_IP:-localhost}
    # Use PUSHER_HOST from config if set, otherwise use server IP
    GEN_PUSHER_HOST=${PUSHER_HOST:-$GEN_SERVER_IP}
    GEN_PUSHER_PORT=${PUSHER_PORT:-6001}

    # Create .env (using 'EOF' to prevent any variable expansion, then write values explicitly)
    cat > "$ENV_FILE" << 'ENVFILE'
###############################################################################
# Coolify Environment Configuration
###############################################################################

###############################################################################
# APPLICATION - Required
###############################################################################
ENVFILE

    # Write generated values (escaped to handle special characters)
    {
        echo "# Generated: $GEN_DATE"
        echo "# Server: $GEN_SERVER"
        echo ""
        echo "APP_ID=$GEN_APP_ID"
        echo "APP_KEY=$GEN_APP_KEY"
        echo ""
        echo "###############################################################################"
        echo "# DATABASE (PostgreSQL) - Required"
        echo "###############################################################################"
        echo "DB_PASSWORD=$GEN_DB_PASSWORD"
        echo ""
        echo "###############################################################################"
        echo "# REDIS - Required"
        echo "###############################################################################"
        echo "REDIS_PASSWORD=$GEN_REDIS_PASSWORD"
        echo ""
        echo "###############################################################################"
        echo "# PUSHER/SOKETI (Realtime) - Required"
        echo "# PUSHER_HOST must be reachable from browser (IP or FQDN, NOT container name)"
        echo "###############################################################################"
        echo "PUSHER_APP_ID=$GEN_PUSHER_APP_ID"
        echo "PUSHER_APP_KEY=$GEN_PUSHER_APP_KEY"
        echo "PUSHER_APP_SECRET=$GEN_PUSHER_APP_SECRET"
        echo "PUSHER_HOST=$GEN_PUSHER_HOST"
        echo "PUSHER_PORT=$GEN_PUSHER_PORT"
        echo ""
        echo "###############################################################################"
        echo "# ROOT USER (Admin Account) - Required"
        echo "###############################################################################"
        echo "ROOT_USERNAME=admin"
        echo "ROOT_USER_EMAIL=$GEN_EMAIL"
        echo "ROOT_USER_PASSWORD=$GEN_ROOT_PASSWORD"
        echo ""
    } >> "$ENV_FILE"

    # Append static configuration
    cat >> "$ENV_FILE" << ENVFILE
###############################################################################
# VERSIONS - Optional (defaults in docker-compose.yml)
###############################################################################
#COOLIFY_VERSION=latest
#POSTGRES_VERSION=18
#REDIS_VERSION=8
#SOCKETI_VERSION=latest

###############################################################################
# TIMEZONE - Optional (automatically detected from host)
###############################################################################
TIME_ZONE=$GEN_TIMEZONE

###############################################################################
# NETWORK - Optional (defaults in docker-compose.yml)
# IMPORTANT: Do NOT change REALTIME_PORT or TERMINAL_PORT unless necessary!
# Coolify UI expects these on 6001/6002 by default.
###############################################################################
#APPLICATION_PORT=8000
#REALTIME_PORT=6001
#TERMINAL_PORT=6002

###############################################################################
# PHP SETTINGS - Optional (defaults in docker-compose.yml)
###############################################################################
#COOLIFY_PHP_MEMORY_LIMIT=256M
#COOLIFY_PHP_FPM_PM_CONTROL=dynamic
#COOLIFY_PHP_FPM_PM_START_SERVERS=2
#COOLIFY_PHP_FPM_PM_MIN_SPARE_SERVERS=2
#COOLIFY_PHP_FPM_PM_MAX_SPARE_SERVERS=10

###############################################################################
# DATABASE SETTINGS - Optional
###############################################################################
#DATABASE_POOLMAXSIZE=100

###############################################################################
# REDIS SETTINGS - Optional (defaults in docker-compose.yml)
###############################################################################
#REDIS_MEMORYLIMIT=1gb

ENVFILE

    print_success ".env file created"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  GENERATED CREDENTIALS                 ║${NC}"
    echo -e "${GREEN}╠════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Username: ${BLUE}admin${NC}                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Password: ${BLUE}${GEN_ROOT_PASSWORD}${NC}  ${GREEN}║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
else
    print_warning ".env file already exists - no changes"
fi

#######################################
# 5. Set permissions
#######################################
echo "[5/6] Setting permissions..."

# Coolify folders (User 9999 = www-data in container)
chown -R 9999:root /data/coolify
chmod -R 700 /data/coolify

# SSH keys more restrictive
chmod 600 /data/coolify/ssh/keys/* 2>/dev/null || true

# PostgreSQL (User 999 = postgres in official image)
chown -R 999:999 /data/system/postgres
chmod -R 700 /data/system/postgres

# Redis (User 999 = redis in official image)
chown -R 999:999 /data/system/redis
chmod -R 700 /data/system/redis

# .env file - readable by Coolify container (User 9999), read_only mount
chown 9999:root "$ENV_FILE"
chmod 600 "$ENV_FILE"

print_success "Permissions set"

#######################################
# 6. Summary
#######################################
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Setup Complete!                            ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Installation:${NC} $INSTALL_DIR"
echo -e "${BLUE}Config file:${NC}  $ENV_FILE"
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "  1. Optional: Edit $ENV_FILE (email, timezone, etc.)"
echo "  2. Start Coolify:"
echo -e "     ${BLUE}cd $INSTALL_DIR && sudo ./coolify.sh start${NC}"
echo ""
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
IP=${IP:-localhost}
echo -e "  3. Access Coolify at: ${BLUE}http://${IP}:8000${NC}"
echo ""
echo -e "${YELLOW}Management:${NC}"
echo "  ./coolify.sh start|stop|restart|status|logs|update|backup|restore|destroy|help"
echo ""
echo -e "${YELLOW}Updates:${NC}"
echo "  ./update.sh        - Update scripts from Git repository"
echo "  ./coolify.sh update - Update Docker images"
echo ""
