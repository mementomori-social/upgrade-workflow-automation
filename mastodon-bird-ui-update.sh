#!/bin/bash
# Mastodon Bird UI Update Script
# Gets the latest mastodon-bird-ui from https://github.com/ronilaukkarinen/mastodon-bird-ui and applies it to use on your supported Mastodon fork.

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

# Detect OS for sed command differences
OS_TYPE="linux"
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS_TYPE="mac"
  print_info "Detected macOS environment"
else
  print_info "Detected Linux environment"
fi

# Ask for version preference
echo
echo "Enter branch to use:"
echo "- Type 'nightly' for nightly/release candidate version"
echo "- Type 'main' for stable version"
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

# Check write permissions
if [[ ! -w "app/javascript/styles/mastodon-bird-ui" ]]; then
  print_error "No write permission to app/javascript/styles/mastodon-bird-ui"
  print_info "Please check file ownership. Current user: $USER"
  print_info "Directory owner: $(stat -c '%U' app/javascript/styles/mastodon-bird-ui 2>/dev/null || echo 'unknown')"
  print_info "You may need to run:"
  echo "  sudo chown -R $USER:$USER app/javascript/styles/mastodon-bird-ui"
  exit 1
fi

# Download and process CSS files
print_info "Downloading Mastodon Bird UI CSS files..."

# Download single column layout using temp file approach
print_info "Downloading single column layout..."
TEMP_FILE="/tmp/bird-ui-single-column-$$.css"
if wget --no-check-certificate --no-cache --no-cookies --no-http-keep-alive \
  "https://raw.githubusercontent.com/ronilaukkarinen/mastodon-bird-ui/$BRANCH/layout-single-column.css" \
  -O "$TEMP_FILE"; then
  mv "$TEMP_FILE" app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  print_success "Single column layout downloaded"
else
  print_error "Failed to download single column layout"
  rm -f "$TEMP_FILE"
  exit 1
fi

# Download multiple column layout using temp file approach
print_info "Downloading multiple column layout..."
TEMP_FILE="/tmp/bird-ui-multiple-columns-$$.css"
if wget --no-check-certificate --no-cache --no-cookies --no-http-keep-alive \
  "https://raw.githubusercontent.com/ronilaukkarinen/mastodon-bird-ui/$BRANCH/layout-multiple-columns.css" \
  -O "$TEMP_FILE"; then
  mv "$TEMP_FILE" app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
  print_success "Multiple column layout downloaded"
else
  print_error "Failed to download multiple column layout"
  rm -f "$TEMP_FILE"
  exit 1
fi

# Apply theme replacements based on OS
print_info "Applying theme replacements..."

if [[ "$OS_TYPE" == "mac" ]]; then
  # macOS sed commands (with backup files)
  print_info "Applying macOS-specific sed commands..."
  
  # Single column replacements
  sed -i'.bak' -e 's/theme-contrast/theme-mastodon-bird-ui-contrast/g' app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  sed -i'.bak' -e 's/.theme-mastodon-light/[class\*='\''theme-mastodon-bird-ui-light'\'']/g' app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  
  # Multiple column replacements  
  sed -i'.bak' -e 's/theme-contrast/theme-mastodon-bird-ui-contrast/g' app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
  sed -i'.bak' -e 's/.theme-mastodon-light/[class\*='\''theme-mastodon-bird-ui-light'\'']/g' app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
  
  # Clean up backup files
  rm -f app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss.bak
  rm -f app/javascript/styles/mastodon-bird-ui/layout-single-column.scss.bak
  
else
  # Linux sed commands (no backup files)
  print_info "Applying Linux-specific sed commands..."
  
  # Single column replacements
  sed -i 's/theme-contrast/theme-mastodon-bird-ui-contrast/g' app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  sed -i 's/.theme-mastodon-light/[class\*='\''theme-mastodon-bird-ui-light'\'']/g' app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  
  # Multiple column replacements
  sed -i 's/theme-contrast/theme-mastodon-bird-ui-contrast/g' app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
  sed -i 's/.theme-mastodon-light/[class\*='\''theme-mastodon-bird-ui-light'\'']/g' app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
fi

print_success "Theme replacements applied"

# Show what was updated
echo
print_info "Updated files:"
print_success "  ✓ app/javascript/styles/mastodon-bird-ui/layout-single-column.scss"
print_success "  ✓ app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss"

# Optional: Commit and push changes
echo
if confirm "Commit and push changes to git?"; then
  # Detect current Bird UI version if possible
  BIRD_UI_VERSION="latest"
  if [[ "$BRANCH" == "nightly" ]]; then
    BIRD_UI_VERSION="nightly"
  fi
  
  print_info "Adding files to git..."
  git add app/javascript/styles/mastodon-bird-ui/layout-single-column.scss
  git add app/javascript/styles/mastodon-bird-ui/layout-multiple-columns.scss
  
  print_info "Committing changes..."
  git commit --no-verify -m "Update to Mastodon Bird UI $BIRD_UI_VERSION ($BRANCH branch)"
  
  print_info "Pushing to origin..."
  git push
  
  print_success "Changes committed and pushed"
else
  print_warning "Changes not committed - manual commit required"
  echo "To commit manually:"
  echo "  git add app/javascript/styles/mastodon-bird-ui/"
  echo "  git commit -m 'Update to Mastodon Bird UI $BIRD_UI_VERSION'"
  echo "  git push"
fi

# Optional: Rebuild assets and restart services
echo
if confirm "Rebuild assets and restart services for immediate effect?"; then
  print_info "Rebuilding assets..."
  RAILS_ENV=production bundle exec rails assets:precompile
  
  print_info "Restarting Mastodon services..."
  sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  sleep 5
  sudo systemctl restart postgresql
  
  print_success "Assets rebuilt and services restarted"
else
  print_warning "Assets not rebuilt - manual rebuild required for changes to take effect"
  echo "To rebuild manually:"
  echo "  RAILS_ENV=production bundle exec rails assets:precompile"
  echo "  sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming"
fi

echo
print_success "Mastodon Bird UI update completed!"
print_info "SUMMARY:"
print_success "  Bird UI version: $BIRD_UI_VERSION ($BRANCH branch)"
print_success "  OS detected: $OS_TYPE"
print_info "  Files updated: layout-single-column.scss, layout-multiple-columns.scss"
