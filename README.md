# Coolify Self-Hosted Stack

A production-ready, self-hosted deployment of [Coolify](https://coolify.io) with automated setup, backup/restore functionality, and weekly auto-updates.

## Features

- **One-command setup** - Automated folder structure, SSH keys, and secure credential generation
- **Online backup/restore** - Consistent backups without downtime using `pg_dump` and Redis `BGSAVE`
- **Auto-updates** - Weekly container updates via Watchtower (Saturdays at 3:00 AM)
- **IPv6 ready** - Dual-stack network configuration out of the box
- **Security focused** - Proper file permissions, no default passwords, read-only config mounts

## Architecture

```
                                    +------------------+
                                    |    Watchtower    |
                                    |  (Auto-Updates)  |
                                    +------------------+
                                             |
+------------------+    +------------------+ | +------------------+
|     Coolify      |    |      Soketi      | | |    PostgreSQL    |
|   Application    |--->|    (Realtime)    | | |    (Database)    |
|    Port 6000     |    |   Ports 6001/2   | | |                  |
+------------------+    +------------------+ | +------------------+
         |                                   |          |
         +-----------------------------------+----------+
                              |
                    +------------------+
                    |      Redis       |
                    |     (Cache)      |
                    +------------------+
```

## Quick Start

### Option A: Fresh Ubuntu 24.04 Server (Recommended)

```bash
# 1. Run interactive server setup (installs Docker, configures system)
cd server-setup
sudo ./install.sh
# System will reboot

# 2. After reboot, run Coolify setup
cd /opt/coolify
sudo ./setup.sh

# 3. Start Coolify
sudo ./coolify.sh start
```

### Option B: Cloud-Init (Automated)

Use `server-setup/cloud-init.yaml` when provisioning a new VPS:

- Fully automated Ubuntu 24.04 setup
- Docker pre-installed with IPv6 support
- Coolify folders prepared
- Just copy files and start

### Option C: Existing Docker Host

```bash
# 1. Copy files to your server
cd /opt/coolify

# 2. Run setup (creates folders, SSH keys, .env)
sudo ./setup.sh

# 3. Start the stack
sudo ./coolify.sh start

# 4. Access Coolify at http://<server-ip>:6000
```

## Requirements

- Linux server (Ubuntu 24.04 LTS recommended)
- Docker 20.10+ with Compose v2
- Root access
- Ports: 6000 (Coolify), 6001-6002 (Soketi/Realtime)

## File Structure

```
/opt/coolify/                # Installation directory
├── docker-compose.yml       # Stack definition
├── setup.sh                 # Coolify setup script
├── coolify.sh               # Management script
├── README.md                # This file
├── .env                     # Environment configuration (generated)
└── server-setup/            # Server provisioning scripts
    ├── install.sh           # Interactive main installer
    ├── 01-system.sh         # System packages & configuration
    ├── 02-network.sh        # Network & file limits
    ├── 03-docker.sh         # Docker installation
    ├── cloud-init.yaml      # Cloud-init for automated setup
    ├── server.conf.example  # Example configuration file
    └── lib/                 # Shared libraries
        ├── common.sh        # Common functions
        └── config.sh        # Configuration loader

/data/coolify/               # Coolify application data
├── ssh/                     # SSH keys for host access
├── applications/            # Deployed application configs
├── databases/               # Database configurations
├── services/                # Service configurations
├── backups/                 # Coolify-managed backups
├── proxy/                   # Traefik proxy config (auto-generated)
└── webhooks-during-maintenance/

/data/system/                # System services data
├── postgres/                # PostgreSQL data
├── redis/                   # Redis data
└── backups/                 # Script-generated backups
```

## Management Commands

```bash
sudo ./coolify.sh <command>
```

| Command | Description |
|---------|-------------|
| `start` | Start the Coolify stack |
| `stop` | Stop all containers |
| `restart` | Restart all containers |
| `status` | Show container status and access URL |
| `logs [service]` | Show logs (all or specific service) |
| `update` | Pull latest images and recreate containers |
| `backup` | Create online backup (stack must be running) |
| `restore <file>` | Restore from backup (stack must be stopped) |
| `destroy` | Remove all containers and volumes |
| `help` | Show help message |

### Examples

```bash
# View logs for specific service
sudo ./coolify.sh logs coolify
sudo ./coolify.sh logs database-server

# Create backup
sudo ./coolify.sh backup

# Restore from backup
sudo ./coolify.sh stop
sudo ./coolify.sh restore /data/system/backups/coolify_backup_20241219_143022.tar.gz
sudo ./coolify.sh start
```

## Backup & Restore

### What's Included in Backups

| File | Description |
|------|-------------|
| `01_postgres.dump` | Coolify database (all projects, servers, deployments) |
| `02_redis.rdb` | Redis snapshot (sessions, queues, cache) |
| `03_ssh.tar` | SSH keys for host access |
| `04_env.conf` | Environment configuration |

### What's NOT Included

- Deployed application data (managed by Coolify's built-in backup)
- Docker volumes of deployed services
- Application databases

### Backup Requirements

- **Creating backup**: Stack must be running (online backup)
- **Restoring backup**: Stack must be stopped

## Configuration

### Environment Variables

Edit `/opt/coolify/.env` to customize:

| Variable | Default | Description |
|----------|---------|-------------|
| `APPLICATION_PORT` | 6000 | Coolify web interface port |
| `COOLIFY_VERSION` | latest | Coolify image version |
| `POSTGRES_VERSION` | 18 | PostgreSQL version |
| `REDIS_VERSION` | 8 | Redis version |
| `TIME_ZONE` | (from host) | Container timezone |
| `COOLIFY_PHP_MEMORY_LIMIT` | 256M | PHP memory limit |
| `REDIS_MEMORYLIMIT` | 1gb | Redis max memory |
| `DATABASE_POOLMAXSIZE` | 100 | PostgreSQL max connections |

### Auto-Updates

Watchtower automatically updates containers weekly:
- **Schedule**: Every Saturday at 03:00 (server timezone)
- **Scope**: Only containers with `com.centurylinklabs.watchtower.enable=true` label
- **Behavior**: Rolling restart, automatic cleanup of old images

To disable auto-updates, remove or stop the watchtower service:
```bash
docker stop COOLIFY_WATCHTOWER
```

## Services

| Container | Image | Purpose |
|-----------|-------|---------|
| COOLIFY_APPLICATION | ghcr.io/coollabsio/coolify | Main application |
| COOLIFY_REALTIME | ghcr.io/coollabsio/coolify-realtime | WebSocket server (Soketi) |
| COOLIFY_DATABASE | postgres:18 | PostgreSQL database |
| COOLIFY_REDIS | redis:8 | Cache and queue |
| COOLIFY_WATCHTOWER | containrrr/watchtower | Auto-update service |

## Troubleshooting

### Stack won't start

```bash
# Check Docker is running
sudo systemctl status docker

# Check for port conflicts
sudo netstat -tlnp | grep -E '6000|6001|6002'

# View detailed logs
sudo ./coolify.sh logs
```

### Database connection issues

```bash
# Check database health
docker exec COOLIFY_DATABASE pg_isready -U coolify -d coolify

# View database logs
sudo ./coolify.sh logs database-server
```

### Reset everything

```bash
# Stop and remove containers/volumes
sudo ./coolify.sh destroy

# Remove all data (DESTRUCTIVE!)
sudo rm -rf /data/coolify /data/system /opt/coolify/.env

# Start fresh
sudo ./setup.sh
sudo ./coolify.sh start
```

## Server Setup Scripts

The `server-setup/` folder contains modular scripts for preparing a fresh Ubuntu 24.04 server.

### Interactive Installation

```bash
cd server-setup
sudo ./install.sh
```

The installer will:

1. Display a banner and check for root permissions
2. Look for an existing `server.conf` configuration file
3. If no config found, offer three options:
   - **Interactive setup**: Answer questions for hostname, locale, network
   - **Create config file**: Copy example and edit manually
   - **Use defaults**: Proceed with default settings
4. Run all setup scripts in sequence (system, network, Docker)
5. Offer to reboot when complete

### Configuration File

Create `server-setup/server.conf` from the example:

```bash
cp server.conf.example server.conf
nano server.conf
```

Configuration options:

| Variable               | Default        | Description                                              |
|------------------------|----------------|----------------------------------------------------------|
| `HOSTNAME`             | coolify-server | Server hostname                                          |
| `LOCALE`               | de_DE.UTF-8    | System locale                                            |
| `TIMEZONE`             | Europe/Berlin  | Timezone                                                 |
| `NETWORK_MAC`          | (empty)        | NIC MAC address for netplan                              |
| `NETWORK_IPV4`         | (empty)        | IPv4 address (e.g., 159.195.67.101)                      |
| `NETWORK_IPV4_NETMASK` | (empty)        | IPv4 netmask CIDR (e.g., 22)                             |
| `NETWORK_IPV4_GATEWAY` | (empty)        | IPv4 gateway                                             |
| `NETWORK_IPV6`         | (empty)        | IPv6 addresses, space-separated with prefix              |
| `NETWORK_IPV6_GATEWAY` | fe80::1        | IPv6 gateway                                             |

**Network examples:**

```bash
# Single IPv6 address
NETWORK_IPV6="2a0a:4cc0:c2:17d6::1/64"

# Multiple IPv6 addresses (space-separated)
NETWORK_IPV6="2a0a:4cc0:c2:17d6::1/64 2a0a:4cc0:c2:17d6::2/64 2a0a:4cc0:c2:17d6::3/64"
```

### Setup Scripts

| Script          | Description                                                            |
|-----------------|------------------------------------------------------------------------|
| `install.sh`    | Main interactive installer                                             |
| `01-system.sh`  | Disables AppArmor, installs packages, configures fail2ban, NTP, locale |
| `02-network.sh` | Creates netplan config (if network vars set), configures file limits   |
| `03-docker.sh`  | Installs Docker CE with IPv6 support, creates docker-support service  |

### Cloud-Init (Automated)

Cloud-init pulls scripts from a Git repository and executes them automatically.

**Setup:**

1. Push this repository to your own Git hosting (GitHub, GitLab, etc.)
2. Edit `server-setup/cloud-init.yaml`:
   - Set `GIT_REPO_URL` to your repository URL in the runcmd section
   - Customize `server.conf` in the write_files section with your network settings
   - Add your SSH public key to the users section
3. Copy the cloud-init.yaml content to your cloud provider's user-data field
4. Server boots, clones repo, runs setup scripts, and reboots

**What happens:**

1. Cloud-init installs git, curl, ca-certificates
2. Writes `server.conf` with your configuration
3. Clones your repository to `/opt/coolify`
4. Runs `01-system.sh`, `02-network.sh`, `03-docker.sh`
5. Reboots to apply changes

**After reboot:**

```bash
cd /opt/coolify
sudo ./setup.sh
sudo ./coolify.sh start
```

## Security Considerations

- All passwords are randomly generated during setup
- SSH keys use Ed25519 (modern, secure)
- `.env` file is mounted read-only into containers
- Database and Redis are not exposed to host network
- File permissions follow principle of least privilege

## License

This deployment configuration is provided as-is. Coolify itself is licensed under the [Apache 2.0 License](https://github.com/coollabsio/coolify/blob/main/LICENSE).

## Links

- [Coolify Documentation](https://coolify.io/docs)
- [Coolify GitHub](https://github.com/coollabsio/coolify)
- [Coolify Discord](https://discord.gg/coolify)
