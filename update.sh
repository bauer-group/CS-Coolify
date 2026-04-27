#!/bin/bash
set -e

#######################################
# Coolify Update Script
# Updates from Git repository without
# conflicts from local file changes
#######################################

INSTALL_DIR="/opt/coolify"
REPO_URL="https://github.com/bauer-group/CS-Coolify.git"

#######################################
# Colors and Output
#######################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }

#######################################
# Root Check
#######################################
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root!"
    echo "Please run with 'sudo ./update.sh'."
    exit 1
fi

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                    Coolify Updater                            ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

cd "$INSTALL_DIR"

#######################################
# Ignore file permission changes
#######################################
git config core.fileMode false

#######################################
# Check if git repo exists
#######################################
if [ ! -d ".git" ]; then
    print_warning "No git repository found. Cloning fresh..."
    cd /opt
    rm -rf coolify
    git clone "$REPO_URL" coolify
    cd coolify
    git config core.fileMode false
    print_success "Repository cloned"
else
    #######################################
    # Stash local changes, pull, restore
    #######################################
    echo "[1/3] Stashing local changes..."

    # Check for local changes
    if git diff --quiet && git diff --cached --quiet; then
        print_success "No local changes to stash"
        STASHED=false
    else
        git stash push -m "auto-stash before update $(date +%Y%m%d-%H%M%S)"
        print_success "Local changes stashed"
        STASHED=true
    fi

    echo "[2/3] Pulling latest changes..."
    if git pull; then
        print_success "Repository updated"
    else
        print_error "Git pull failed"
        if [ "$STASHED" = true ]; then
            echo "    Restoring stashed changes..."
            git stash pop
        fi
        exit 1
    fi

    echo "[3/3] Restoring local changes..."
    if [ "$STASHED" = true ]; then
        if git stash pop; then
            print_success "Local changes restored"
        else
            print_warning "Merge conflict - your changes are in 'git stash list'"
            echo "    Resolve manually with: git stash show -p | git apply"
        fi
    else
        print_success "No changes to restore"
    fi
fi

#######################################
# Fix permissions on scripts
#######################################
echo ""
echo "Setting executable permissions..."
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
chmod +x "$INSTALL_DIR/server-setup"/*.sh 2>/dev/null || true
print_success "Permissions set"

#######################################
# Summary
#######################################
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    Update Complete!                           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Show current version
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
echo -e "${BLUE}Branch:${NC}  $BRANCH"
echo -e "${BLUE}Commit:${NC}  $COMMIT"
echo ""

echo -e "${YELLOW}Next:${NC} Run './coolify.sh update' to update Docker images"
echo ""
