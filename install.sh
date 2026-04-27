#!/bin/bash
set -e

#######################################
# Coolify One-Line Installer
#
# Usage:
#   Full install (server setup + Coolify):
#     curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Coolify/main/install.sh | sudo bash
#
#   Coolify only (existing Docker host):
#     curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Coolify/main/install.sh | sudo bash -s -- --coolify-only
#
#######################################

REPO_URL="https://github.com/bauer-group/CS-Coolify.git"
INSTALL_DIR="/opt/coolify"
BRANCH="main"

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
    echo "║                   Self-Hosted Installer                       ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${BLUE}→${NC} $1"; }

#######################################
# Root Check
#######################################
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "This script must be run as root!"
        echo "Please run with: curl -fsSL ... | sudo bash"
        exit 1
    fi
}

#######################################
# Parse Arguments
#######################################
COOLIFY_ONLY=false
INTERACTIVE=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --coolify-only|-c)
            COOLIFY_ONLY=true
            shift
            ;;
        --full|-f)
            COOLIFY_ONLY=false
            shift
            ;;
        --yes|-y)
            INTERACTIVE=false
            shift
            ;;
        --help|-h)
            echo "Coolify Self-Hosted Installer"
            echo ""
            echo "Usage:"
            echo "  curl -fsSL <url>/install.sh | sudo bash [options]"
            echo ""
            echo "Options:"
            echo "  --coolify-only, -c  Install Coolify only (skip server setup)"
            echo "  --full, -f          Full installation with server setup (default)"
            echo "  --yes, -y           Non-interactive mode (no prompts)"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Interactive mode - asks what to install"
            echo "  curl -fsSL <url>/install.sh | sudo bash"
            echo ""
            echo "  # Full server setup + Coolify"
            echo "  curl -fsSL <url>/install.sh | sudo bash -s -- --full"
            echo ""
            echo "  # Coolify only (existing Docker host)"
            echo "  curl -fsSL <url>/install.sh | sudo bash -s -- --coolify-only"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

#######################################
# Check Requirements
#######################################
check_requirements() {
    print_info "Checking requirements..."

    # Check OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [ "$ID" != "ubuntu" ] && [ "$ID" != "debian" ]; then
            print_warning "This script is designed for Ubuntu/Debian. Other distros may work but are untested."
        fi
    fi

    # Check for git
    if ! command -v git &> /dev/null; then
        print_info "Installing git..."
        apt-get update -qq
        apt-get install -y -qq git
    fi

    # Check for curl
    if ! command -v curl &> /dev/null; then
        print_info "Installing curl..."
        apt-get update -qq
        apt-get install -y -qq curl
    fi

    print_success "Requirements satisfied"
}

#######################################
# Check Docker
#######################################
check_docker() {
    if command -v docker &> /dev/null; then
        DOCKER_VERSION=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        print_success "Docker $DOCKER_VERSION found"
        return 0
    else
        return 1
    fi
}

#######################################
# Interactive Mode Selection
#######################################
select_install_mode() {
    if [ "$INTERACTIVE" = false ]; then
        return
    fi

    # Check if Docker is installed
    if check_docker; then
        echo ""
        echo "Docker is already installed on this system."
        echo ""
        echo "Installation options:"
        echo "  1) Coolify only (recommended for existing Docker hosts)"
        echo "  2) Full installation (server setup + Coolify)"
        echo ""
        read -p "Select option [1]: " choice
        choice=${choice:-1}

        case $choice in
            1) COOLIFY_ONLY=true ;;
            2) COOLIFY_ONLY=false ;;
            *) COOLIFY_ONLY=true ;;
        esac
    else
        echo ""
        echo "Docker is not installed on this system."
        echo ""
        echo "Installation options:"
        echo "  1) Full installation (server setup + Docker + Coolify) [recommended]"
        echo "  2) Coolify only (requires Docker to be installed separately)"
        echo ""
        read -p "Select option [1]: " choice
        choice=${choice:-1}

        case $choice in
            1) COOLIFY_ONLY=false ;;
            2)
                print_error "Docker is required but not installed."
                print_info "Please install Docker first or choose full installation."
                exit 1
                ;;
            *) COOLIFY_ONLY=false ;;
        esac
    fi
}

#######################################
# Clone Repository
#######################################
clone_repository() {
    print_info "Downloading Coolify configuration..."

    if [ -d "$INSTALL_DIR/.git" ]; then
        print_info "Existing installation found, updating..."
        cd "$INSTALL_DIR"
        git fetch origin
        git reset --hard origin/$BRANCH
    else
        if [ -d "$INSTALL_DIR" ]; then
            print_warning "Removing existing $INSTALL_DIR (not a git repo)"
            rm -rf "$INSTALL_DIR"
        fi
        git clone --depth 1 --branch $BRANCH "$REPO_URL" "$INSTALL_DIR"
    fi

    cd "$INSTALL_DIR"
    git config core.fileMode false
    chmod +x *.sh server-setup/*.sh 2>/dev/null || true

    print_success "Repository cloned to $INSTALL_DIR"
}

#######################################
# Run Server Setup
#######################################
run_server_setup() {
    print_info "Running server setup..."
    echo ""

    cd "$INSTALL_DIR/server-setup"

    # Run setup scripts
    ./01-system.sh
    ./02-network.sh
    ./03-docker.sh

    print_success "Server setup complete"
}

#######################################
# Run Coolify Setup
#######################################
run_coolify_setup() {
    print_info "Running Coolify setup..."

    cd "$INSTALL_DIR"
    ./setup.sh

    print_success "Coolify setup complete"
}

#######################################
# Start Coolify
#######################################
start_coolify() {
    print_info "Starting Coolify..."

    cd "$INSTALL_DIR"
    ./coolify.sh start

    print_success "Coolify started"
}

#######################################
# Print Summary
#######################################
print_summary() {
    local IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    IP=${IP:-localhost}

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                  Installation Complete!                       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Access Coolify at:"
    echo -e "    ${BLUE}http://${IP}:8000${NC}"
    echo ""
    echo "  Default credentials are shown during setup."
    echo "  Check: cat /opt/coolify/.env | grep ROOT_"
    echo ""
    echo "  Management commands:"
    echo "    cd /opt/coolify"
    echo "    ./coolify.sh status|logs|stop|restart|backup"
    echo ""

    if [ "$COOLIFY_ONLY" = false ]; then
        echo -e "${YELLOW}  A reboot is recommended to apply all system changes.${NC}"
        echo ""
        read -p "  Reboot now? [y/N]: " reboot_choice
        if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
            print_info "Rebooting..."
            reboot
        fi
    fi
}

#######################################
# Main
#######################################
main() {
    print_banner
    check_root
    check_requirements
    select_install_mode

    echo ""
    if [ "$COOLIFY_ONLY" = true ]; then
        print_info "Installation mode: Coolify only"
    else
        print_info "Installation mode: Full (server setup + Coolify)"
    fi
    echo ""

    clone_repository

    if [ "$COOLIFY_ONLY" = false ]; then
        run_server_setup
    else
        # Verify Docker is available for coolify-only mode
        if ! check_docker; then
            print_error "Docker is required but not installed."
            print_info "Please install Docker first or use full installation mode."
            exit 1
        fi
    fi

    run_coolify_setup
    start_coolify
    print_summary
}

main "$@"
