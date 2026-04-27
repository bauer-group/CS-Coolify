#!/bin/bash
set -e

#######################################
# Server Installation Script
# Interactive setup for Ubuntu 24.04
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

#######################################
# Banner
#######################################
clear
echo -e "${BLUE}"
cat << 'EOF'
   ____            _ _  __         ____
  / ___|___   ___ | (_)/ _|_   _  / ___|  ___ _ ____   _____ _ __
 | |   / _ \ / _ \| | | |_| | | | \___ \ / _ \ '__\ \ / / _ \ '__|
 | |__| (_) | (_) | | |  _| |_| |  ___) |  __/ |   \ V /  __/ |
  \____\___/ \___/|_|_|_|  \__, | |____/ \___|_|    \_/ \___|_|
                           |___/
  Server Setup for Ubuntu 24.04 LTS
EOF
echo -e "${NC}"
echo ""

#######################################
# Root Check
#######################################
check_root

#######################################
# Configuration Mode
#######################################
print_header "Configuration"

CONFIG_FILE="$SCRIPT_DIR/server.conf"

if [ -f "$CONFIG_FILE" ]; then
    print_info "Found existing configuration: $CONFIG_FILE"
    echo ""
    cat "$CONFIG_FILE" | grep -v "^#" | grep -v "^$" | head -20
    echo ""
    if confirm "Use this configuration?" "y"; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        INTERACTIVE=false
    else
        INTERACTIVE=true
    fi
else
    print_info "No configuration file found."
    echo ""
    echo "Options:"
    echo "  1) Interactive setup (answer questions)"
    echo "  2) Create config file and edit manually"
    echo "  3) Skip configuration (use defaults)"
    echo ""
    read -p "Choose [1-3]: " choice

    case "$choice" in
        1) INTERACTIVE=true ;;
        2)
            cp "$SCRIPT_DIR/server.conf.example" "$CONFIG_FILE"
            print_success "Created $CONFIG_FILE"
            echo ""
            echo "Please edit the configuration file and run this script again:"
            echo "  nano $CONFIG_FILE"
            echo "  $0"
            exit 0
            ;;
        *)
            INTERACTIVE=false
            print_warning "Using default configuration"
            ;;
    esac
fi

#######################################
# Interactive Configuration
#######################################
if [ "$INTERACTIVE" = true ]; then
    print_header "Server Configuration"

    # Hostname
    read -p "Hostname [coolify-server]: " input
    HOSTNAME="${input:-coolify-server}"

    # Locale
    echo ""
    echo "Locale options:"
    echo "  1) de_DE.UTF-8 (German)"
    echo "  2) en_US.UTF-8 (English US)"
    echo "  3) en_GB.UTF-8 (English UK)"
    echo "  4) Custom"
    read -p "Choose [1]: " choice
    case "$choice" in
        2) LOCALE="en_US.UTF-8" ;;
        3) LOCALE="en_GB.UTF-8" ;;
        4) read -p "Enter locale: " LOCALE ;;
        *) LOCALE="de_DE.UTF-8" ;;
    esac

    # Timezone
    read -p "Timezone [UTC]: " input
    TIMEZONE="${input:-UTC}"

    # Network Configuration
    print_header "Network Configuration"

    echo "Do you want to configure static networking?"
    echo "(Required for netcup and similar providers)"
    echo ""
    if confirm "Configure network?" "n"; then
        echo ""
        read -p "MAC address (e.g., 0a:e7:f9:c2:a8:59): " NETWORK_MAC

        echo ""
        echo "IPv4 Configuration:"
        read -p "  IPv4 address (e.g., 159.195.67.101): " NETWORK_IPV4
        read -p "  Netmask CIDR (e.g., 22): " NETWORK_IPV4_NETMASK
        read -p "  Gateway (e.g., 159.195.64.1): " NETWORK_IPV4_GATEWAY

        echo ""
        if confirm "Configure IPv6?" "y"; then
            echo "  Enter IPv6 addresses (space-separated for multiple)"
            echo "  Include prefix length, e.g., 2a0a:4cc0:c2:17d6::1/64"
            read -p "  IPv6 addresses: " NETWORK_IPV6
            read -p "  IPv6 Gateway [fe80::1]: " input
            NETWORK_IPV6_GATEWAY="${input:-fe80::1}"
        fi
    fi

    # Save configuration
    echo ""
    if confirm "Save configuration to server.conf?" "y"; then
        cat > "$CONFIG_FILE" << EOF
#######################################
# Server Configuration
# Generated: $(date)
#######################################

HOSTNAME="$HOSTNAME"
LOCALE="$LOCALE"
TIMEZONE="$TIMEZONE"

NTP_SERVERS="time.bauer-group.com 0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org"
NTP_FALLBACK="ptbtime1.ptb.de ptbtime2.ptb.de ptbtime3.ptb.de"

NETWORK_MAC="$NETWORK_MAC"
NETWORK_IPV4="$NETWORK_IPV4"
NETWORK_IPV4_NETMASK="$NETWORK_IPV4_NETMASK"
NETWORK_IPV4_GATEWAY="$NETWORK_IPV4_GATEWAY"
NETWORK_IPV6="$NETWORK_IPV6"
NETWORK_IPV6_GATEWAY="$NETWORK_IPV6_GATEWAY"
EOF
        print_success "Configuration saved to $CONFIG_FILE"
    fi
fi

# Export configuration
export HOSTNAME LOCALE TIMEZONE
export NTP_SERVERS NTP_FALLBACK
export NETWORK_MAC NETWORK_IPV4 NETWORK_IPV4_NETMASK NETWORK_IPV4_GATEWAY
export NETWORK_IPV6 NETWORK_IPV6_GATEWAY

#######################################
# Summary
#######################################
print_header "Installation Summary"

echo "Server Settings:"
echo "  Hostname:  $HOSTNAME"
echo "  Locale:    $LOCALE"
echo "  Timezone:  $TIMEZONE"
echo ""

if [ -n "$NETWORK_MAC" ] && [ -n "$NETWORK_IPV4" ]; then
    echo "Network Configuration:"
    echo "  MAC:          $NETWORK_MAC"
    if [ -n "$NETWORK_IPV4_NETMASK" ]; then
        echo "  IPv4:         ${NETWORK_IPV4}/${NETWORK_IPV4_NETMASK}"
    else
        echo "  IPv4:         $NETWORK_IPV4"
    fi
    echo "  IPv4 Gateway: $NETWORK_IPV4_GATEWAY"
    if [ -n "$NETWORK_IPV6" ]; then
        echo "  IPv6:         $NETWORK_IPV6"
        echo "  IPv6 Gateway: $NETWORK_IPV6_GATEWAY"
    fi
    echo ""
else
    echo "Network: Using DHCP / existing configuration"
    echo ""
fi

echo "Installation Steps:"
echo "  1. System packages & configuration"
echo "  2. Network & system limits"
echo "  3. Docker with IPv6 support"
echo "  4. Reboot"
echo ""

if ! confirm "Start installation?" "y"; then
    echo "Aborted."
    exit 0
fi

#######################################
# Run Installation Scripts
#######################################
print_header "Starting Installation"

# Set hostname
echo "Setting hostname to $HOSTNAME..."
hostnamectl set-hostname "$HOSTNAME"
print_success "Hostname set"

# Run setup scripts
echo ""
bash "$SCRIPT_DIR/01-system.sh"

echo ""
bash "$SCRIPT_DIR/02-network.sh"

echo ""
bash "$SCRIPT_DIR/03-docker.sh"

#######################################
# Final Summary
#######################################
print_header "Installation Complete"

echo "Completed:"
echo "  ✓ System packages installed"
echo "  ✓ fail2ban configured"
echo "  ✓ AppArmor & UFW disabled"
echo "  ✓ Multicast DNS disabled"
echo "  ✓ NTP configured"
echo "  ✓ File limits configured"
if [ -n "$NETWORK_MAC" ] && [ -n "$NETWORK_IPV4" ]; then
    echo "  ✓ Network configuration created"
fi
echo "  ✓ Docker installed with IPv6 support"
echo ""

echo "Next Steps:"
echo "  1. Reboot the server"
echo "  2. Copy Coolify files to /opt/coolify/"
echo "  3. Run: cd /opt/coolify && sudo ./setup.sh"
echo "  4. Run: sudo ./coolify.sh start"
echo ""

if confirm "Reboot now?" "y"; then
    print_warning "Rebooting in 5 seconds..."
    sleep 5
    reboot
else
    print_warning "Please reboot manually to apply all changes."
fi
