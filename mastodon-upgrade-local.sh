#!/bin/bash

# Mastodon Local Development Upgrade Script
# This script automates the Mastodon upgrade process for the development environment

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Load configuration from .env file if it exists
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  source "$SCRIPT_DIR/.env"
fi

# Default configuration (can be overridden by .env)
MASTODON_DIR="${MASTODON_DIR:-/opt/mastodon}"
MASTODON_USER="${MASTODON_USER:-mastodon}"
GITHUB_REPO="${GITHUB_REPO:-your-org/mastodon}"
UPSTREAM_REPO="${UPSTREAM_REPO:-mastodon/mastodon}"
API_URL="${API_URL:-https://your-instance.com/api/v1/instance}"
UPGRADE_LOG="${UPGRADE_LOG:-$HOME/mastodon-upgrades.log}"
NODE_VERSION="${NODE_VERSION:-22.18.0}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"
INSTANCE_URL="${INSTANCE_URL:-https://your-instance.com}"
TEST_URL="${TEST_URL:-https://your-test-instance.com}"
STATUS_URL="${STATUS_URL:-https://status.your-instance.com}"
MAINTENANCE_URL="${MAINTENANCE_URL:-https://your-status-page-url/maintenances}"

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

# Function to prompt for user action
prompt_action() {
  echo -e "${YELLOW}[ACTION REQUIRED]${NC} $1"
  read -p "Press Enter when done, or type 'skip' to skip: " response
  if [[ "$response" == "skip" ]]; then
    print_warning "Skipped: $1"
    return 1
  fi
  return 0
}

# Function to prompt for confirmation
confirm() {
  read -p "$1 (y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

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

print_info "Starting Mastodon upgrade process for local development environment"

# Step 0: Create maintenance announcements
echo
print_warning "FIRST: Create maintenance announcements"
echo
echo "1. Create Mastodon announcement:"
echo "   URL: $INSTANCE_URL/admin/announcements/new"
echo "   Message: We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience. Status: $STATUS_URL"
echo
# Calculate maintenance window (current time + 2 hours)
MAINTENANCE_START=$(date "+%m/%d/%Y %I:%M %p")
MAINTENANCE_END=$(date -d "+2 hours" "+%m/%d/%Y %I:%M %p")
TIMEZONE=$(date +"%Z")

echo "2. Create maintenance window:"
echo "   URL: $MAINTENANCE_URL"
echo "   Title: Server maintenance"
echo "   From: $MAINTENANCE_START $TIMEZONE"
echo "   To: $MAINTENANCE_END $TIMEZONE"
echo "   Message: We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience."
echo
prompt_action "Announcements created"

# Check and start services automatically
print_info "Checking and starting required services..."
SERVICES_TO_START=""

for service in mastodon-web mastodon-sidekiq mastodon-streaming; do
  if systemctl is-active --quiet "$service"; then
    print_success "$service is already running"
  else
    print_warning "$service is not running - starting it..."
    SERVICES_TO_START="$SERVICES_TO_START $service"
  fi
done

if [[ -n "$SERVICES_TO_START" ]]; then
  print_info "Starting services:$SERVICES_TO_START"
  sudo systemctl start $SERVICES_TO_START
  sleep 3
  
  # Verify they started
  for service in $SERVICES_TO_START; do
    if systemctl is-active --quiet "$service"; then
      print_success "$service started successfully"
    else
      print_error "Failed to start $service"
      if ! confirm "Continue anyway?"; then
        exit 1
      fi
    fi
  done
fi

# Check and start PostgreSQL
if ! systemctl is-active --quiet postgresql; then
  print_warning "PostgreSQL is not running - starting it..."
  sudo systemctl start postgresql
  sleep 2
  if systemctl is-active --quiet postgresql; then
    print_success "PostgreSQL started successfully"
  else
    print_error "Failed to start PostgreSQL"
    if ! confirm "Continue anyway?"; then
      exit 1
    fi
  fi
else
  print_success "PostgreSQL is already running"
fi

# Get current version from production
print_info "Fetching current production version..."
CURRENT_VERSION=$(curl -s "$API_URL" | grep -o '"version":"[^"]*' | cut -d'"' -f4 | grep -o 'mementomods-[0-9-]*' || echo "")
if [[ -z "$CURRENT_VERSION" ]]; then
  print_warning "Could not fetch current version from API"
  read -p "Enter the previous branch name (e.g., mementomods-2025-08-24): " CURRENT_VERSION
fi
print_info "Current production branch: $CURRENT_VERSION"

# Generate new branch name based on today's date
NEW_BRANCH="mementomods-$(date +%Y-%m-%d)"
print_info "New branch will be: $NEW_BRANCH"

# Change to Mastodon directory
cd "$MASTODON_DIR"
print_success "Changed to directory: $MASTODON_DIR"

# Auto-detect git remotes
print_info "Detecting git remotes..."
ORIGIN_REMOTE=""
UPSTREAM_REMOTE=""

# Parse git remote -v output
while read -r remote url type; do
  if [[ "$type" == "(fetch)" ]]; then
    # Extract org/repo from configured GITHUB_REPO
    if [[ -n "$GITHUB_REPO" && "$url" =~ $GITHUB_REPO ]]; then
      ORIGIN_REMOTE="$remote"
      print_info "Found your fork remote: $remote -> $url"
    elif [[ "$url" =~ mastodon/mastodon ]] || [[ "$url" =~ tootsuite/mastodon ]]; then
      UPSTREAM_REMOTE="$remote"
      print_info "Found upstream remote: $remote -> $url"
    fi
  fi
done < <(git remote -v)

# Validate remotes
if [[ -z "$ORIGIN_REMOTE" ]]; then
  print_error "Could not find remote for your fork (check GITHUB_REPO in .env)"
  read -p "Enter the remote name for your fork: " ORIGIN_REMOTE
fi

if [[ -z "$UPSTREAM_REMOTE" ]]; then
  print_error "Could not find remote for upstream (mastodon/mastodon)"
  read -p "Enter the remote name for upstream: " UPSTREAM_REMOTE
fi

print_success "Using remotes: origin=$ORIGIN_REMOTE, upstream=$UPSTREAM_REMOTE"

# Step 1: Check how many commits behind
print_info "Checking how many commits behind upstream..."
git fetch $UPSTREAM_REMOTE main --quiet
COMMITS_BEHIND=$(git rev-list --count HEAD..$UPSTREAM_REMOTE/main 2>/dev/null || echo "0")
ORIGINAL_COMMITS_BEHIND=$COMMITS_BEHIND  # Save for documentation
if [[ "$COMMITS_BEHIND" -gt 0 ]]; then
  print_warning "Your fork is $COMMITS_BEHIND commits behind $UPSTREAM_REPO:main"
  echo "This information will be saved for documentation purposes"
else
  print_success "Your fork is up to date with $UPSTREAM_REPO:main"
fi

# Step 2-3: GitHub sync via CLI
echo
if command -v gh &> /dev/null; then
  # Check if GitHub CLI is authenticated
  if ! gh auth status &>/dev/null; then
    print_warning "GitHub CLI found but not authenticated"
    echo -e "${BLUE}🔑 Please authenticate with GitHub CLI:${NC}"
    echo "  gh auth login"
    echo
    echo "After authentication, restart this script to continue."
    exit 0
  fi
  
  print_info "Syncing fork via GitHub CLI..."
  if gh repo sync "$GITHUB_REPO" --source "$UPSTREAM_REPO"; then
    print_success "Fork synced successfully"
  else
    print_error "Fork sync failed"
    echo "This might be due to:"
    echo "- Permission issues"
    echo "- Repository not found"
    echo "- Network connectivity"
    echo
    print_warning "Please sync manually:"
    echo "1. Go to https://github.com/$GITHUB_REPO/tree/main"
    echo "2. Click 'Sync fork' to sync with upstream main"
    prompt_action "Manual GitHub sync completed"
  fi
else
  print_warning "GitHub CLI not found. Installing..."
  if confirm "Install GitHub CLI automatically?"; then
    echo -e "${BLUE}📦 Installing GitHub CLI...${NC}"
    if sudo apt update && sudo apt install -y gh; then
      print_success "GitHub CLI installed successfully"
      print_warning "You'll need to authenticate: gh auth login"
      echo "Please run 'gh auth login' and then restart this script."
      exit 0
    else
      print_error "Failed to install GitHub CLI"
      print_warning "Please install manually and sync fork:"
      echo "1. sudo apt install gh"
      echo "2. gh auth login"
      echo "3. Go to https://github.com/$GITHUB_REPO/tree/main"
      echo "4. Click 'Sync fork' to sync with upstream main"
      prompt_action "Manual setup completed"
    fi
  else
    print_warning "Please sync manually:"
    echo "1. Go to https://github.com/$GITHUB_REPO/tree/main"
    echo "2. Verify: Your branch is $COMMITS_BEHIND commits behind $UPSTREAM_REPO:main"
    echo "3. Click 'Sync fork' to sync with upstream main"
    prompt_action "Manual GitHub sync completed"
  fi
fi

# Step 4: Fetch all changes
print_info "Fetching all changes..."
git fetch --all
print_success "Fetched all changes"

# Step 5: Choose between stable or nightly version
echo
print_info "Detecting latest stable version..."
LATEST_STABLE=$(git tag -l 'v*' --sort=-version:refname | head -n1)
if [[ -n "$LATEST_STABLE" ]]; then
  print_success "Latest stable version found: $LATEST_STABLE"
  if confirm "Use nightly (main) version instead of last stable ($LATEST_STABLE)?"; then
    print_info "Checking out and updating main branch..."
    git fetch --all
    yarn cache clean
    git checkout main
    git pull $UPSTREAM_REMOTE main
    
    # Show latest main commit info
    MAIN_COMMIT_HASH=$(git rev-parse --short HEAD)
    MAIN_COMMIT_MSG=$(git log -1 --pretty=format:"%s" HEAD)
    MAIN_COMMIT_DATE=$(git log -1 --pretty=format:"%cr" HEAD)
    print_success "Latest main commit: $MAIN_COMMIT_HASH - $MAIN_COMMIT_MSG"
    print_info "  Date: $MAIN_COMMIT_DATE"
    print_info "  Link: https://github.com/$UPSTREAM_REPO/commit/$MAIN_COMMIT_HASH"
  else
    print_info "Checking out stable version $LATEST_STABLE..."
    yarn cache clean
    git fetch
    git checkout "$LATEST_STABLE"
  fi
else
  print_warning "Could not detect latest stable version"
  if confirm "Use main branch (nightly)?"; then
    print_info "Checking out and updating main branch..."
    git fetch --all
    yarn cache clean
    git checkout main
    git pull $UPSTREAM_REMOTE main
    
    # Show latest main commit info
    MAIN_COMMIT_HASH=$(git rev-parse --short HEAD)
    MAIN_COMMIT_MSG=$(git log -1 --pretty=format:"%s" HEAD)
    MAIN_COMMIT_DATE=$(git log -1 --pretty=format:"%cr" HEAD)
    print_success "Latest main commit: $MAIN_COMMIT_HASH - $MAIN_COMMIT_MSG"
    print_info "  Date: $MAIN_COMMIT_DATE"
    print_info "  Link: https://github.com/$UPSTREAM_REPO/commit/$MAIN_COMMIT_HASH"
  else
    read -p "Enter the version tag (e.g., v4.4.0): " VERSION_TAG
    print_info "Checking out $VERSION_TAG..."
    yarn cache clean
    git fetch
    git checkout "$VERSION_TAG"
  fi
fi
print_success "Branch checked out and updated"

# Check if Ruby version needs updating
print_info "Checking Ruby version requirements..."
if [[ -f ".ruby-version" ]]; then
  REQUIRED_RUBY=$(cat .ruby-version)
  print_info "Required Ruby version: $REQUIRED_RUBY"
  if ! rbenv versions | grep -q "$REQUIRED_RUBY"; then
    if confirm "Ruby $REQUIRED_RUBY is not installed. Install it?"; then
      rbenv install "$REQUIRED_RUBY"
      print_success "Ruby $REQUIRED_RUBY installed"
    fi
  fi
fi

# Check and set Node.js version
print_info "Checking Node.js version requirements..."
if command -v nvm &> /dev/null || [[ -f "$HOME/.nvm/nvm.sh" ]]; then
  # Load nvm if not already loaded
  if ! command -v nvm &> /dev/null; then
    source "$HOME/.nvm/nvm.sh"
  fi
  
  CURRENT_NODE=$(node --version 2>/dev/null | sed 's/v//' || echo "none")
  print_info "Required Node.js version: v$NODE_VERSION"
  print_info "Current Node.js version: v$CURRENT_NODE"
  
  if [[ "$CURRENT_NODE" != "$NODE_VERSION" ]]; then
    print_info "Installing/switching to Node.js v$NODE_VERSION..."
    nvm install "$NODE_VERSION"
    nvm use "$NODE_VERSION"
    nvm alias default "$NODE_VERSION"
    print_success "Node.js v$NODE_VERSION activated"
  else
    print_success "Node.js v$NODE_VERSION already active"
  fi
else
  print_warning "nvm not found. Please install Node.js v$NODE_VERSION manually"
  echo "Current Node.js version: $(node --version 2>/dev/null || echo 'not installed')"
fi

# Step 6: Build
print_info "Installing dependencies and building assets..."
echo -e "${YELLOW}  ⏳ Running bundle install...${NC}"
bundle install
echo -e "${YELLOW}  ⏳ Running yarn install...${NC}"
# Set corepack to auto-confirm downloads
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
yarn install --immutable
echo -e "${YELLOW}  ⏳ Precompiling assets...${NC}"
RAILS_ENV=production bundle exec rails assets:precompile
print_success "Build completed"

# Step 7: Check migrations
print_info "Checking for pending migrations..."
PENDING_MIGRATIONS=$(RAILS_ENV=production bundle exec rails db:migrate:status | grep down || true)
if [[ -n "$PENDING_MIGRATIONS" ]]; then
  print_warning "Pending migrations found:"
  echo "$PENDING_MIGRATIONS"
  
  # Step 8: Run migrations
  if confirm "Run migrations?"; then
    RAILS_ENV=production bundle exec rails db:migrate
    print_success "Migrations completed"
  fi
  
  # Check for manual migrations
  if confirm "Do you need to run specific migrations manually?"; then
    read -p "Enter migration VERSION (e.g., 20230724160715): " MIGRATION_VERSION
    RAILS_ENV=production bundle exec rails db:migrate:up VERSION="$MIGRATION_VERSION"
    print_success "Manual migration completed"
  fi
else
  print_info "No pending migrations"
fi

# Step 9: Clear cache if needed
if confirm "Clear cache before restart?"; then
  RAILS_ENV=production /opt/mastodon/bin/tootctl cache clear
  print_success "Cache cleared"
fi

# Step 10: Restart services
print_info "Restarting Mastodon services..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  sleep 5
  sudo systemctl restart postgresql
fi
print_success "Services restarted"

# Manual testing checklist
echo
print_warning "Please test the following at ${BLUE}$TEST_URL${NC}:"
echo "[ ] Audio notifications work"
echo "[ ] Emoji picker works"
echo "[ ] Everything seems normal"
echo "[ ] Different feeds work (bookmarks, favs...)"
echo "[ ] Toot edits work from the arrow"
echo "[ ] Site loads and functions properly"
echo
print_info "Test URL: $TEST_URL"
prompt_action "Testing completed"

# Step 11-12: Search index
if confirm "Reset and rebuild search index?"; then
  # Start Elasticsearch if needed
  if ! systemctl is-active --quiet elasticsearch; then
    print_info "Starting Elasticsearch..."
    sudo service elasticsearch start
    sleep 5
  fi
  
  print_info "Resetting search index..."
  RAILS_ENV=production bin/tootctl search deploy --reset-chewy
  
  print_info "Rebuilding search index (this may take a while)..."
  RAILS_ENV=production bin/tootctl search deploy --only accounts --concurrency 16 --batch_size 4096
  RAILS_ENV=production bin/tootctl search deploy --only statuses --concurrency 16 --batch_size 4096
  print_success "Search index rebuilt"
fi

# Step 13: Final restart
print_info "Final restart of services..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  sleep 5
  sudo systemctl restart postgresql
fi
print_success "Final restart completed"

# Step 14-15: Create new branch and merge mods
print_info "Creating new branch: $NEW_BRANCH"
git branch "$NEW_BRANCH"
git checkout "$NEW_BRANCH"
print_success "New branch created and checked out"

if [[ -n "$CURRENT_VERSION" ]]; then
  print_info "Attempting to merge $CURRENT_VERSION..."
  if git merge "$CURRENT_VERSION"; then
    print_success "Merge successful"
  else
    print_error "Merge failed - manual intervention required"
    echo "Please resolve conflicts and then continue"
    prompt_action "Merge conflicts resolved"
    
    # Ask about manual mods only if merge failed
    if confirm "Do you need to manually apply additional mods from the previous branch?"; then
      print_warning "Please apply any additional mods from $CURRENT_VERSION on top of $NEW_BRANCH"
      prompt_action "Additional mods applied"
    fi
  fi
else
  print_warning "No previous version detected for merging"
fi

# Step 17: Update version in .env.production
print_info "Updating version in .env.production..."
if [[ -f ".env.production" ]]; then
  # Update the version line automatically
  if grep -q "^MASTODON_VERSION_METADATA=" .env.production; then
    sed -i "s/^MASTODON_VERSION_METADATA=.*/MASTODON_VERSION_METADATA=\"+$NEW_BRANCH\"/" .env.production
    print_success "Version updated to +$NEW_BRANCH in .env.production"
  else
    echo "MASTODON_VERSION_METADATA=\"+$NEW_BRANCH\"" >> .env.production
    print_success "Version metadata added to .env.production: +$NEW_BRANCH"
  fi
else
  print_warning ".env.production not found, skipping version update"
fi

# Step 18: Recompile with new branch
print_info "Recompiling with new branch..."
yarn cache clean
rm -rf node_modules
bundle install
yarn install --immutable
RAILS_ENV=production bundle exec rails assets:precompile

# Clear toot cache before restart
print_info "Clearing toot cache..."
RAILS_ENV=production /opt/mastodon/bin/tootctl cache clear

print_info "Restarting services (this may take a moment)..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web mastodon-sidekiq mastodon-streaming
  sleep 5
  sudo systemctl restart postgresql
fi
print_success "Recompiled and restarted"

# Step 19: Final testing and git push (search rebuild not needed for local)
print_info "Local development upgrade process completed"

# Step 20: Final testing and git push
print_warning "Final testing phase - please verify everything works at $TEST_URL"
prompt_action "Final testing completed"

if confirm "Push changes to git (to $ORIGIN_REMOTE)?"; then
  print_info "Pushing to git..."
  git push --set-upstream $ORIGIN_REMOTE "$NEW_BRANCH"
  print_success "Changes pushed to $ORIGIN_REMOTE"
fi

# Save upgrade information to log file
# UPGRADE_LOG is now set in configuration section
echo "$(date '+%Y-%m-%d %H:%M:%S') - Upgrade completed: $CURRENT_VERSION -> $NEW_BRANCH (was $ORIGINAL_COMMITS_BEHIND commits behind)" >> "$UPGRADE_LOG"

echo
print_success "Local development upgrade completed!"
print_info "UPGRADE SUMMARY:"
print_success "  New branch: $NEW_BRANCH"
print_info "  Previous branch: $CURRENT_VERSION"
print_warning "  Commits behind upstream (before sync): $ORIGINAL_COMMITS_BEHIND"
print_info "  Next step: Run production upgrade script at $SCRIPTS_DIR/mastodon-upgrade-production.sh"
echo
print_info "Documentation note: This branch was $ORIGINAL_COMMITS_BEHIND commits behind $UPSTREAM_REPO:main"
print_info "Upgrade history saved to: $UPGRADE_LOG"