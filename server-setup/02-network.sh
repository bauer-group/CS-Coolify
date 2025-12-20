#!/bin/bash
set -e

#######################################
# Ubuntu 24.04 LTS Network Setup
# Part 2: Network & Limits Configuration
#######################################

source "$(dirname "$0")/lib/common.sh"
source "$(dirname "$0")/lib/config.sh"

check_root

print_header "Network & Limits Setup (2/2)"

#######################################
# 1. Configure Network (Optional)
#######################################
echo "[1/2] Network Configuration..."

if [ -z "$NETWORK_MAC" ] || [ -z "$NETWORK_IPV4" ]; then
    print_warning "Network configuration skipped (no config provided)"
    echo "    Using DHCP or existing configuration"
else
    rm -f /etc/netplan/*.yaml

    # Build addresses section
    ADDRESSES_SECTION=""

    # IPv4 address with netmask
    if [ -n "$NETWORK_IPV4_NETMASK" ]; then
        ADDRESSES_SECTION="        - ${NETWORK_IPV4}/${NETWORK_IPV4_NETMASK}"
    else
        ADDRESSES_SECTION="        - ${NETWORK_IPV4}"
    fi

    # IPv6 addresses (space-separated, can be multiple)
    if [ -n "$NETWORK_IPV6" ]; then
        for ipv6 in $NETWORK_IPV6; do
            ADDRESSES_SECTION="${ADDRESSES_SECTION}
        - ${ipv6}"
        done
    fi

    # Build routes section
    ROUTES_SECTION="      routes:
        - to: default
          via: ${NETWORK_IPV4_GATEWAY}"

    # IPv6 gateway
    if [ -n "$NETWORK_IPV6" ] && [ -n "$NETWORK_IPV6_GATEWAY" ]; then
        ROUTES_SECTION="${ROUTES_SECTION}
        - to: default
          via: ${NETWORK_IPV6_GATEWAY}
          on-link: true"
    fi

    cat > /etc/netplan/01-networking.yaml << EOF
network:
  version: 2
  renderer: networkd

  ethernets:
    eth0:
      match:
        macaddress: "${NETWORK_MAC}"

      addresses:
${ADDRESSES_SECTION}

${ROUTES_SECTION}
EOF

    chmod 600 /etc/netplan/01-networking.yaml

    print_success "Network configuration created"
    echo ""
    echo "    MAC:          $NETWORK_MAC"
    if [ -n "$NETWORK_IPV4_NETMASK" ]; then
        echo "    IPv4:         ${NETWORK_IPV4}/${NETWORK_IPV4_NETMASK}"
    else
        echo "    IPv4:         ${NETWORK_IPV4}"
    fi
    echo "    IPv4 Gateway: $NETWORK_IPV4_GATEWAY"
    if [ -n "$NETWORK_IPV6" ]; then
        echo "    IPv6:         $NETWORK_IPV6"
        echo "    IPv6 Gateway: $NETWORK_IPV6_GATEWAY"
    fi
    echo ""
    print_warning "Run 'netplan apply' to activate (will disconnect SSH!)"
fi

#######################################
# 2. Configure Open File Limits
#######################################
echo "[2/2] Configuring System Limits..."

# Systemd service limits
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/01-nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

mkdir -p /etc/systemd/user.conf.d
cat > /etc/systemd/user.conf.d/01-nofile.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

# Root profile
if ! grep -q "ulimit -n 1048576" /root/.profile 2>/dev/null; then
    echo "" >> /root/.profile
    echo "ulimit -n 1048576" >> /root/.profile
fi

systemctl daemon-reexec

print_success "Open file limit set to 1048576"

echo ""
print_success "Network & Limits setup complete!"
echo ""
echo "A reboot is required to apply all changes."
