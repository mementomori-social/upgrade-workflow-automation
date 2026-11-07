#!/bin/bash
# Mastodon Bird UI Update Script
# Gets the latest Mastodon Bird UI from https://github.com/rollecode/mastodon-bird-ui and installs it with its own install script.

# This script automates the Mastodon Bird UI update process for local development
# Version: $(head -n1 "$(dirname "${BASH_SOURCE[0]}")/CHANGELOG.md" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "1.0.3")

set -e  # Exit on error

# Basic colors for early error messages
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root (prevent sudo execution)
if [[ "$EUID" -eq 0 ]]; then
  echo -e "${RED}ERROR:${NC} This script should not be run as root or with sudo"
  echo -e "${YELLOW}Please run as the mastodon user:${NC}"
  echo "  su - mastodon"
  echo "  cd ~/upgrade-workflow-automation"
  echo "  bash $(basename "$0")"
  exit 1
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration from .env files if they exist
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env.development" ]]; then
  source "$SCRIPT_DIR/.env.development"
elif [[ -f "$SCRIPT_DIR/.env" ]]; then
  source "$SCRIPT_DIR/.env"
fi

# Default configuration (can be overridden by .env)
MASTODON_DIR="${MASTODON_DIR:-/opt/mastodon}"
MASTODON_USER="${MASTODON_USER:-mastodon}"
BIRD_UI_REPO="${BIRD_UI_REPO:-https://github.com/rollecode/mastodon-bird-ui.git}"
BIRD_UI_DIR="${BIRD_UI_DIR:-$HOME/mastodon-bird-ui}"
YOUR_FORK_REPO="${YOUR_FORK_REPO:-${GITHUB_REPO:-your-org/mastodon}}"
OFFICIAL_MASTODON_REPO="${OFFICIAL_MASTODON_REPO:-${UPSTREAM_REPO:-mastodon/mastodon}}"

# Function to print colored messages
print_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Function to prompt for confirmation
confirm() {
  read -p "$1 (y/n): " -r
  [[ $REPLY =~ ^[Yy]$ ]]
}

# Get version and date from changelog
SCRIPT_VERSION_LINE=$(head -n1 "$SCRIPT_DIR/CHANGELOG.md" 2>/dev/null || echo "### 1.0.1: 2025-08-30")
SCRIPT_VERSION=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "1.0.1")
SCRIPT_DATE=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || echo "2025-08-30")

print_info "Mastodon Bird UI update script ${BLUE}v$SCRIPT_VERSION ($SCRIPT_DATE)${NC}"
print_info "Starting Bird UI update process for local development"

# Check if running as mastodon user
if [[ "$USER" != "$MASTODON_USER" ]]; then
  print_error "This script must be run as the mastodon user"
  echo "Please run one of these commands:"
  echo "  sudo su - mastodon"
  echo "  cd $(realpath "$(dirname "$0")")"
  echo "  bash $(basename "$0")"
  echo
  echo "Or directly:"
  echo "  sudo -u mastodon bash $(realpath "$0")"
  exit 1
fi

# Change to Mastodon directory
cd "$MASTODON_DIR"
print_success "Changed to directory: $MASTODON_DIR"

# Check if Bird UI directory exists
if [[ ! -d "app/javascript/styles/mastodon-bird-ui" ]]; then
  print_error "Mastodon Bird UI directory not found: app/javascript/styles/mastodon-bird-ui"
  print_info "Please ensure Mastodon Bird UI is installed first"
  exit 1
fi

# Ask for version preference
echo
echo "Enter branch to use:"
echo "- Type 'nightly' for the version that targets Mastodon main (Mastodon 5)"
echo "- Type 'main' for the version that targets the latest Mastodon 4 release"
echo "- Press Enter to use nightly (default)"
read -p "Branch: " -r BRANCH_INPUT

# Default to nightly if empty
if [[ -z "$BRANCH_INPUT" ]]; then
  BRANCH="nightly"
  print_info "Using nightly version (default)"
elif [[ "$BRANCH_INPUT" == "nightly" ]]; then
  BRANCH="nightly"
  print_info "Using nightly version"
elif [[ "$BRANCH_INPUT" == "main" ]]; then
  BRANCH="main"
  print_info "Using stable version (main)"
else
  print_error "Invalid branch name: $BRANCH_INPUT"
  print_info "Please use 'main' or 'nightly'"
  exit 1
fi

# Get the Bird UI source at the chosen branch
if [[ -d "$BIRD_UI_DIR/.git" ]]; then
  print_info "Updating Bird UI checkout in $BIRD_UI_DIR..."
  git -C "$BIRD_UI_DIR" fetch --quiet origin
  git -C "$BIRD_UI_DIR" checkout --quiet "$BRANCH"
  git -C "$BIRD_UI_DIR" reset --quiet --hard "origin/$BRANCH"
else
  print_info "Cloning Bird UI into $BIRD_UI_DIR..."
  git clone --quiet --branch "$BRANCH" "$BIRD_UI_REPO" "$BIRD_UI_DIR"
fi

INSTALL_SCRIPT="$BIRD_UI_DIR/scripts/install-to-mastodon.sh"
if [[ ! -f "$INSTALL_SCRIPT" ]]; then
  print_error "Install script not found: $INSTALL_SCRIPT"
  print_info "The '$BRANCH' branch predates the install script, use a newer branch"
  exit 1
fi

BIRD_UI_VERSION=$(grep -m1 '^### ' "$BIRD_UI_DIR/CHANGELOG.md" | sed 's/### \([^:]*\):.*/\1/')
print_info "Installing Mastodon Bird UI $BIRD_UI_VERSION ($BRANCH branch)..."

# Bird UI is the default theme here, with the accessible themes
bash "$INSTALL_SCRIPT" --path "$MASTODON_DIR" --variations --default

echo
print_info "Changed files:"
git status --short -- app/javascript/styles config/themes.yml config/locales/en.yml config/locales/fi.yml

if git diff --quiet && [[ -z "$(git status --porcelain -- app/javascript/styles)" ]]; then
  print_success "Bird UI is already up to date"
  exit 0
fi

echo
if confirm "Commit the update?"; then
  git add app/javascript/styles config/themes.yml config/locales/en.yml config/locales/fi.yml
  git commit --no-verify -m "Update vendored Bird UI"
  print_success "Committed: Update vendored Bird UI ($BIRD_UI_VERSION)"

  if confirm "Push the branch to origin?"; then
    git push
    print_success "Pushed"
  fi
else
  print_warning "Not committed, the changes are in the working tree"
fi

# The production fleet runs templated sidekiq units; the plain unit is legacy
get_sidekiq_services() {
  local services
  services=$(systemctl list-units --all --type=service --plain --no-legend \
    | awk '{print $1}' | grep -E '^mastodon-sidekiq-.+\.service$' | tr '\n' ' ')
  echo "${services:-mastodon-sidekiq}"
}

echo
if confirm "Rebuild assets and restart services?"; then
  print_info "Rebuilding assets..."
  RAILS_ENV=production bundle exec rails assets:precompile

  SIDEKIQ_SERVICES=$(get_sidekiq_services)
  print_info "Restarting mastodon-web and $SIDEKIQ_SERVICES..."
  sudo systemctl restart mastodon-web $SIDEKIQ_SERVICES
  print_success "Assets rebuilt and services restarted"
else
  print_warning "Assets not rebuilt - manual rebuild required for changes to take effect"
  echo "  RAILS_ENV=production bundle exec rails assets:precompile"
  echo "  sudo systemctl restart mastodon-web <sidekiq units>"
fi

echo
print_success "Mastodon Bird UI $BIRD_UI_VERSION ($BRANCH branch) installed"
