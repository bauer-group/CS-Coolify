#!/bin/bash
set -e

#######################################
# Coolify Setup Script
# Creates folders, SSH keys and .env
#######################################

#######################################
# Root Check
#######################################
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root!"
    echo "Please run with 'sudo ./setup.sh'."
    exit 1
fi

ENV_FILE="/opt/coolify/.env"

echo "=== Coolify Setup Script ==="
echo ""

#######################################
# 1. Create folder structure
#######################################
echo "[1/5] Creating folder structure..."

# Coolify data folders (mapped into container)
mkdir -p /data/coolify/{ssh,applications,databases,backups,services}
mkdir -p /data/coolify/ssh/{keys,mux}

# Coolify host folders (for dynamically created containers via SSH)
mkdir -p /data/coolify/{proxy,webhooks-during-maintenance,sentinel}
mkdir -p /data/coolify/proxy/dynamic

# System folders for databases and backups
mkdir -p /data/system/{postgres,redis,backups}

# Config folder
mkdir -p /opt/coolify

echo "    Folders created."

#######################################
# 2. Generate SSH key (if not exists)
#######################################
echo "[2/5] Checking SSH keys..."

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
    echo "    SSH key created and authorized_keys updated."
else
    echo "    SSH key already exists."
fi

#######################################
# 3. Create .env file (if not exists)
#######################################
echo "[3/5] Checking .env file..."

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
    GEN_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)

    # Create .env
    cat > "$ENV_FILE" << EOF
###############################################################################
# Coolify Environment Configuration
# Generated: $(date)
# Server: $(hostname)
###############################################################################

###############################################################################
# APPLICATION - Required
###############################################################################
APP_ID=${GEN_APP_ID}
APP_KEY=${GEN_APP_KEY}

###############################################################################
# DATABASE (PostgreSQL) - Required
###############################################################################
DB_PASSWORD=${GEN_DB_PASSWORD}

###############################################################################
# REDIS - Required
###############################################################################
REDIS_PASSWORD=${GEN_REDIS_PASSWORD}

###############################################################################
# PUSHER/SOKETI (Realtime) - Required
###############################################################################
PUSHER_APP_ID=${GEN_PUSHER_APP_ID}
PUSHER_APP_KEY=${GEN_PUSHER_APP_KEY}
PUSHER_APP_SECRET=${GEN_PUSHER_APP_SECRET}

###############################################################################
# ROOT USER (Admin Account) - Required
###############################################################################
ROOT_USERNAME=admin
ROOT_USER_EMAIL=admin@$(hostname -f 2>/dev/null || echo "localhost")
ROOT_USER_PASSWORD=${GEN_ROOT_PASSWORD}

###############################################################################
# VERSIONS - Optional (defaults in docker-compose.yml)
###############################################################################
#COOLIFY_VERSION=latest
#POSTGRES_VERSION=18
#REDIS_VERSION=8
#SOCKETI_VERSION=1.0.10

###############################################################################
# TIMEZONE - Optional (automatically detected from host)
###############################################################################
TIME_ZONE=$(cat /etc/timezone 2>/dev/null || echo "UTC")

###############################################################################
# NETWORK - Optional (defaults in docker-compose.yml)
###############################################################################
#APPLICATION_PORT=6000

###############################################################################
# PHP SETTINGS - Optional (defaults in docker-compose.yml)
###############################################################################
#COOLIFY_PHP_MEMORY_LIMIT=256M
#COOLIFY_PHP_FPM_PM_CONTROL=dynamic
#COOLIFY_PHP_FPM_PM_START_SERVERS=1
#COOLIFY_PHP_FPM_PM_MIN_SPARE_SERVERS=1
#COOLIFY_PHP_FPM_PM_MAX_SPARE_SERVERS=10

###############################################################################
# DATABASE SETTINGS - Optional
###############################################################################
#DATABASE_POOLMAXSIZE=100

###############################################################################
# REDIS SETTINGS - Optional (defaults in docker-compose.yml)
###############################################################################
#REDIS_MEMORYLIMIT=1gb

EOF

    echo "    .env file created."
    echo ""
    echo "    +----------------------------------------+"
    echo "    |  GENERATED CREDENTIALS                 |"
    echo "    +----------------------------------------+"
    echo "    |  Username: admin                       |"
    echo "    |  Password: ${GEN_ROOT_PASSWORD}  |"
    echo "    +----------------------------------------+"
    echo ""
else
    echo "    .env file already exists - no changes."
fi

#######################################
# 4. Set permissions
#######################################
echo "[4/5] Setting permissions..."

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

# Make management script executable
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/coolify.sh" ]; then
    chmod +x "$SCRIPT_DIR/coolify.sh"
fi

echo "    Permissions set."

#######################################
# 5. Summary
#######################################
echo "[5/5] Setup completed!"
echo ""
echo "=== Folder Structure ==="
echo "/data/coolify/"
echo "  ssh/  applications/  databases/  backups/  services/"
echo "  proxy/  webhooks-during-maintenance/"
echo ""
echo "/data/system/"
echo "  postgres/  redis/  backups/"
echo ""
echo "/opt/coolify/"
echo "  .env"
echo ""
echo "=== Configuration ==="
echo "ENV file: $ENV_FILE"
echo ""
echo "=== Next Steps ==="
echo "1. Optional: Edit .env (email, timezone, etc.)"
echo "2. ./coolify.sh start"
echo "3. Browser: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost"):6000"
echo ""
echo "=== Management ==="
echo "./coolify.sh start|stop|restart|status|logs|update|backup|restore|destroy|help"
echo ""
