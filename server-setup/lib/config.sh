#!/bin/bash
#######################################
# Configuration Library
# Loads config from file or environment
#######################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/server.conf}"

# Load config file if exists
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

#######################################
# Server Configuration
#######################################
HOSTNAME="${HOSTNAME:-coolify-server}"
LOCALE="${LOCALE:-de_DE.UTF-8}"
TIMEZONE="${TIMEZONE:-Europe/Berlin}"

#######################################
# NTP Configuration
#######################################
NTP_SERVERS="${NTP_SERVERS:-time.bauer-group.com 0.de.pool.ntp.org 1.de.pool.ntp.org 2.de.pool.ntp.org 3.de.pool.ntp.org}"
NTP_FALLBACK="${NTP_FALLBACK:-ptbtime1.ptb.de ptbtime2.ptb.de ptbtime3.ptb.de}"

#######################################
# Network Configuration
#######################################
NETWORK_MAC="${NETWORK_MAC:-}"

# IPv4 Configuration
NETWORK_IPV4="${NETWORK_IPV4:-}"
NETWORK_IPV4_NETMASK="${NETWORK_IPV4_NETMASK:-}"
NETWORK_IPV4_GATEWAY="${NETWORK_IPV4_GATEWAY:-}"

# IPv6 Configuration (space-separated for multiple addresses)
NETWORK_IPV6="${NETWORK_IPV6:-}"
NETWORK_IPV6_GATEWAY="${NETWORK_IPV6_GATEWAY:-fe80::1}"

#######################################
# Export all variables
#######################################
export HOSTNAME LOCALE TIMEZONE
export NTP_SERVERS NTP_FALLBACK
export NETWORK_MAC
export NETWORK_IPV4 NETWORK_IPV4_NETMASK NETWORK_IPV4_GATEWAY
export NETWORK_IPV6 NETWORK_IPV6_GATEWAY
