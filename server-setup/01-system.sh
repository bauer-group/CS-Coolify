#!/bin/bash
set -e

#######################################
# Ubuntu 24.04 LTS System Setup
# Part 1: System Configuration
#######################################

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/config.sh"

check_root

print_header "System Setup (1/2)"

#######################################
# 1. Disable AppArmor
#######################################
echo "[1/8] Disabling AppArmor..."

if systemctl is-enabled apparmor &>/dev/null; then
    systemctl disable apparmor
    systemctl stop apparmor 2>/dev/null || true
    print_success "AppArmor disabled"
else
    print_success "AppArmor already disabled"
fi

#######################################
# 2. System Update & Essential Packages
#######################################
echo "[2/8] System Update & Packages..."

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get upgrade -y -qq

apt-get install -y -qq \
    ethtool \
    iputils-ping \
    net-tools \
    vim \
    mc \
    wget \
    curl \
    p7zip-full \
    unzip \
    zip \
    nano \
    open-vm-tools \
    apache2-utils \
    ca-certificates \
    gnupg \
    smartmontools \
    htop \
    dmidecode \
    msmtp \
    msmtp-mta \
    telnet \
    git \
    jq \
    fail2ban

print_success "Packages installed"

#######################################
# 3. Configure Unattended Upgrades
#######################################
echo "[3/8] Configuring Unattended Upgrades..."

if [ "${UNATTENDED_UPGRADES:-true}" = "true" ]; then
    # Enable automatic security updates
    apt-get install -y unattended-upgrades update-notifier-common >/dev/null 2>&1 || true

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    systemctl enable unattended-upgrades 2>/dev/null || true
    systemctl start unattended-upgrades 2>/dev/null || true
    print_success "Unattended upgrades enabled (security updates)"
else
    # Disable automatic updates
    if dpkg -l | grep -q unattended-upgrades; then
        echo 'APT::Periodic::Unattended-Upgrade "0";' > /etc/apt/apt.conf.d/20auto-upgrades
        systemctl disable unattended-upgrades 2>/dev/null || true
        systemctl stop unattended-upgrades 2>/dev/null || true
        print_success "Unattended upgrades disabled"
    else
        print_success "Unattended upgrades not installed"
    fi
fi

#######################################
# 4. Disable Firewall (UFW)
#######################################
echo "[4/8] Disabling UFW Firewall..."

if command -v ufw &>/dev/null; then
    ufw disable 2>/dev/null || true
    print_success "UFW disabled"
else
    print_success "UFW not installed"
fi

#######################################
# 5. Configure fail2ban
#######################################
echo "[5/8] Configuring fail2ban..."

cat > /etc/fail2ban/jail.d/01-sshd.conf << 'EOF'
[sshd]
enabled = true
bantime = 86400
findtime = 900
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban

print_success "fail2ban configured (SSH: 5 attempts, 24h ban)"

#######################################
# 6. Disable Multicast DNS
#######################################
echo "[6/8] Disabling Multicast DNS..."

sed -i '/^#*MulticastDNS=/c\MulticastDNS=no' /etc/systemd/resolved.conf
sed -i '/^#*DNSStubListener=/c\DNSStubListener=no' /etc/systemd/resolved.conf

systemctl restart systemd-resolved

print_success "Multicast DNS disabled"

#######################################
# 7. Configure Locale
#######################################
echo "[7/8] Configuring Locale..."

locale-gen "$LOCALE" >/dev/null 2>&1 || true
update-locale LANG="$LOCALE"

print_success "Locale set to $LOCALE"

#######################################
# 8. Configure NTP
#######################################
echo "[8/8] Configuring NTP..."

cat > /etc/systemd/timesyncd.conf << EOF
[Time]
NTP=$NTP_SERVERS
FallbackNTP=$NTP_FALLBACK

RootDistanceMaxSec=3
PollIntervalMinSec=32
PollIntervalMaxSec=2048
ConnectionRetrySec=30
SaveIntervalSec=60
EOF

systemctl restart systemd-timesyncd
systemctl enable systemd-timesyncd

print_success "NTP configured"

echo ""
print_success "System setup complete!"
