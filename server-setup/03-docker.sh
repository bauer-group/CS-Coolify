#!/bin/bash
set -e

#######################################
# Docker Installation Script
# For Ubuntu 24.04 LTS
#######################################

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/config.sh"

check_root

print_header "Docker Installation"

#######################################
# 1. Remove Old Docker Packages
#######################################
echo "[1/5] Removing old Docker packages..."

for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    apt-get remove -y "$pkg" 2>/dev/null || true
done

print_success "Old packages removed"

#######################################
# 2. Add Docker Repository
#######################################
echo "[2/5] Adding Docker repository..."

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq

print_success "Docker repository added"

#######################################
# 3. Install Docker
#######################################
echo "[3/5] Installing Docker..."

apt-get install -y -qq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

print_success "Docker installed"

#######################################
# 4. Configure Docker
#######################################
echo "[4/5] Configuring Docker..."

# Kernel parameters
cat > /etc/sysctl.d/98-docker.conf << 'EOF'
# Docker Engine Values
vm.max_map_count=4194304
EOF

sysctl -p /etc/sysctl.d/98-docker.conf >/dev/null 2>&1 || true

# Docker daemon configuration with IPv6 support and log rotation
# Network ranges (full 10.0.0.0/8 split in half):
#   - docker0 bridge:    10.0.0.0/9   (10.0-127.x.x),   fdff::/17 (IPv6)
#   - container pools:   10.128.0.0/9 (10.128-255.x.x), fdff:8000::/17 -> /64 per network (IPv6)
mkdir -p /etc/docker/
cat > /etc/docker/daemon.json << 'EOF'
{
  "bip": "10.0.0.1/9",
  "ipv6": true,
  "fixed-cidr-v6": "fdff::/17",
  "default-address-pools": [
    {
      "base": "10.128.0.0/9",
      "size": 24
    },
    {
      "base": "fdff:8000::/17",
      "size": 64
    }
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

print_success "Docker configured with IPv6 support"

#######################################
# 5. IPv6 NAT Support Service
#######################################
echo "[5/5] Creating IPv6 NAT service..."

# NAT for all Docker IPv6 traffic (fdff::/16 covers both bridge and pool)
cat > /usr/lib/systemd/system/docker-support.service << 'EOF'
[Unit]
Description=IPv6 NAT for Docker Networks
BindsTo=docker.service
After=docker.service
ReloadPropagatedFrom=docker.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip6tables -t nat -A POSTROUTING -s fdff::/16 ! -o docker0 -j MASQUERADE
ExecStop=/usr/sbin/ip6tables -t nat -D POSTROUTING -s fdff::/16 ! -o docker0 -j MASQUERADE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /usr/lib/systemd/system/docker-support.service
systemctl daemon-reload

# Enable and start services
systemctl enable docker-support
systemctl enable docker
systemctl restart docker
systemctl start docker-support 2>/dev/null || true

print_success "Docker services enabled"

#######################################
# Verification
#######################################
echo ""
print_header "Verification"

echo "Docker version:"
docker --version
echo ""

echo "Docker Compose version:"
docker compose version
echo ""

print_success "Docker installation complete!"
