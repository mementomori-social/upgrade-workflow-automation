#!/bin/bash

# Mastodon Local Development Upgrade Script
# This script automates the Mastodon upgrade process for the development environment
# Version: $(head -n1 "$(dirname "${BASH_SOURCE[0]}")/CHANGELOG.md" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "1.0.3")

set -e  # Exit on error

# Basic colors for early error messages
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if running as root (prevent sudo execution)
if [[ "$EUID" -eq 0 ]]; then
  echo ""
  echo -e "${RED}ERROR:${NC} This script should not be run as root or with sudo"
  echo ""
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

# Default configuration (can be overridden by .env.development or .env)
MASTODON_DIR="${MASTODON_DIR:-/opt/mastodon}"
MASTODON_USER="${MASTODON_USER:-mastodon}"
YOUR_FORK_REPO="${YOUR_FORK_REPO:-${GITHUB_REPO:-your-org/mastodon}}"
OFFICIAL_MASTODON_REPO="${OFFICIAL_MASTODON_REPO:-${UPSTREAM_REPO:-mastodon/mastodon}}"
API_URL="${API_URL:-https://your-instance.com/api/v1/instance}"
UPGRADE_LOG="${UPGRADE_LOG:-$HOME/mastodon-upgrades.log}"
NODE_VERSION="${NODE_VERSION:-22.18.0}"
SCRIPTS_DIR="${SCRIPTS_DIR:-$SCRIPT_DIR}"
INSTANCE_URL="${INSTANCE_URL:-https://your-instance.com}"
TEST_URL="${TEST_URL:-https://your-test-instance.com}"
STATUS_URL="${STATUS_URL:-https://status.your-instance.com}"
MAINTENANCE_URL="${MAINTENANCE_URL:-https://your-status-page-url/maintenances}"
LOCAL_BACKUP_DIR="${LOCAL_BACKUP_DIR:-$SCRIPT_DIR}"
LOCAL_DB_NAME="${LOCAL_DB_NAME:-mastodon_development}"

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
  read -p "Press Enter when done: " response
  return 0
}

# Function to prompt for confirmation
confirm() {
  read -p "$1 (y/n): " -r
  [[ $REPLY =~ ^[Yy]$ ]]
}

# Function to check for unstaged changes and offer to stash
check_and_stash_changes() {
  # Check for incomplete merge first
  if [[ -f "$MASTODON_DIR/.git/MERGE_HEAD" ]]; then
    print_error "Incomplete merge detected in your repository"
    print_warning "This likely happened because a previous script run was interrupted"
    echo
    echo "Conflicted files:"
    git diff --name-only --diff-filter=U 2>/dev/null | while read file; do
      echo "  - $file"
    done
    echo
    echo "This needs to be resolved before continuing."
    if confirm "Abort the incomplete merge and start fresh?"; then
      print_info "Aborting incomplete merge..."
      git merge --abort
      print_success "Merge aborted - repository is now clean"
    else
      print_error "Cannot proceed with incomplete merge"
      echo "Please resolve the merge manually before running this script:"
      echo "  1. To abort: git merge --abort"
      echo "  2. To complete: fix conflicts, then git add . && git commit"
      exit 1
    fi
  fi

  # First, restore any tracked .env* files to avoid blocking checkout/pull
  local env_changes=$(git diff-files --name-only | grep '\.env' || true)
  if [[ -n "$env_changes" ]]; then
    print_info "Restoring tracked .env files to avoid conflicts..."
    echo "$env_changes" | while read file; do
      git restore "$file"
      echo "  Restored: $file"
    done
  fi

  # Check for remaining unstaged changes (non-.env files)
  local unstaged_files=$(git diff-files --name-only)

  if [[ -n "$unstaged_files" ]]; then
    print_warning "You have unstaged changes in your working directory:"
    echo "$unstaged_files" | while read file; do
      echo " M $file"
    done
    echo
    if confirm "Would you like to stash these changes?"; then
      print_info "Stashing changes..."
      git stash push -m "Auto-stash before upgrade on $(date '+%Y-%m-%d %H:%M:%S')"
      print_success "Changes stashed successfully"
      echo "To restore your changes later, run: git stash pop"
      return 0
    else
      print_error "Cannot proceed with unstaged changes"
      echo "Please either:"
      echo "  1. Stash your changes: git stash"
      echo "  2. Commit your changes: git add . && git commit"
      echo "  3. Discard your changes: git restore ."
      exit 1
    fi
  fi
}

# Function to get all sidekiq services
get_sidekiq_services() {
  local services=$(systemctl list-units --all --type=service --plain --no-legend | grep 'mastodon-sidekiq' | awk '{print $1}' | tr '\n' ' ')
  if [[ -n "$services" ]]; then
    echo "$services"
  else
    # Fallback to single service name
    echo "mastodon-sidekiq"
  fi
}

# Helper function to format bytes to human readable (GB if >= 1000MB, otherwise MB)
format_size() {
  local bytes=$1
  local mb=$((bytes / 1024 / 1024))
  if [[ $mb -ge 1000 ]]; then
    local gb_int=$((mb / 1024))
    local gb_dec=$(( (mb % 1024) * 10 / 1024 ))
    echo "${gb_int}.${gb_dec}GB"
  else
    echo "${mb}MB"
  fi
}

# Function to backup local development database
backup_local_database() {
  # Ensure PostgreSQL is running first
  if ! systemctl is-active --quiet postgresql; then
    print_info "Starting PostgreSQL for backup..."
    sudo systemctl start postgresql
    sleep 2
    if ! systemctl is-active --quiet postgresql; then
      print_warning "Could not start PostgreSQL, skipping automatic backup"
      return 1
    fi
  fi

  print_info "Checking disk space for local database backup..."

  # Get database size
  local db_size=$(psql -d "$LOCAL_DB_NAME" -t -c "SELECT pg_database_size('$LOCAL_DB_NAME');" 2>/dev/null | tr -d ' ')
  if [[ -z "$db_size" || "$db_size" == "0" ]]; then
    print_warning "Could not determine database size, skipping automatic backup"
    return 1
  fi

  # Convert to human readable
  local db_size_human=$(format_size $db_size)
  print_info "Local database size: $db_size_human"

  # Check available disk space in backup directory
  local available_space=$(df -B1 "$LOCAL_BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
  local available_human=$(format_size $available_space)

  # Need at least 2x database size for safety (compressed backup + overhead)
  local required_space=$((db_size * 2))
  local required_human=$(format_size $required_space)

  print_info "Available disk space: $available_human (need ~$required_human)"

  if [[ "$available_space" -lt "$required_space" ]]; then
    print_error "Insufficient disk space for backup"
    print_warning "Available: $available_human, Required: ~$required_human"
    if ! confirm "Continue without local backup?"; then
      exit 1
    fi
    return 1
  fi

  # Create backup filename with timestamp
  local backup_file="$LOCAL_BACKUP_DIR/${LOCAL_DB_NAME}_$(date +%Y-%m-%d_%H-%M).backup"

  print_info "Creating local database backup..."
  print_info "Backup file: $backup_file"

  if pg_dump \
    --format=custom \
    --no-owner \
    --compress=5 \
    --file="$backup_file" \
    "$LOCAL_DB_NAME" 2>/dev/null; then

    local backup_size=$(du -h "$backup_file" | cut -f1)
    print_success "Local database backed up successfully ($backup_size)"
    echo "Backup location: $backup_file"
    return 0
  else
    print_error "Local database backup failed"
    if ! confirm "Continue without local backup?"; then
      exit 1
    fi
    return 1
  fi
}

# Function to check and fix ICU library issues with native gems
check_and_fix_native_gems() {
  print_info "Checking native gem compatibility..."

  # Try to load charlock_holmes to detect ICU version mismatches
  if ! bundle exec ruby -e "require 'charlock_holmes'" 2>/dev/null; then
    local error_output=$(bundle exec ruby -e "require 'charlock_holmes'" 2>&1)

    # Check if it's an ICU library error
    if echo "$error_output" | grep -q "libicudata.so"; then
      print_warning "ICU library version mismatch detected"
      print_info "Rebuilding native gems against current ICU version..."

      # Uninstall and reinstall charlock_holmes to recompile against current ICU
      gem uninstall charlock_holmes -x -I 2>/dev/null || true

      # Reinstall will happen during bundle install
      print_success "Native gem will be recompiled during bundle install"
      return 0
    fi
  fi

  print_success "Native gems are compatible"
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

# Get version and date from changelog
SCRIPT_VERSION_LINE=$(head -n1 "$SCRIPT_DIR/CHANGELOG.md" 2>/dev/null || echo "### 1.0.1: 2025-08-30")
SCRIPT_VERSION=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "1.0.1")
SCRIPT_DATE=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || echo "2025-08-30")

print_info "Mastodon local development upgrade script ${BLUE}v$SCRIPT_VERSION ($SCRIPT_DATE)${NC}"
print_info "Starting upgrade process for local development environment"

# Step 0a: Local development database backup (optional)
echo
if confirm "Create local development database backup first?"; then
  backup_local_database
else
  print_info "Skipping local database backup"
fi

# Step 0b: Production database backup (manual - takes longest)
echo
print_warning "NEXT: Start production database backup now (takes 30+ minutes)"
echo
echo "To create a backup, run these commands on the database server:"
echo
echo "ssh -p ${DB_PORT:-5432} ${DB_USER:-your-db-user}@${DB_HOST:-your.db.server.ip}"
echo "sudo su -"
echo "ionice -c2 -n7 nice -n19 pg_dump \\"
echo "  --host=localhost \\"
echo "  --username=mastodon \\"
echo "  --port=5432 \\"
echo "  --format=custom \\"
echo "  --no-owner \\"
echo "  --compress=5 \\"
echo "  --verbose \\"
echo "  --file=\"${BACKUP_DIR:-/tmp/mastodon-backups}/mastodon_production_\$(date +%Y-%m-%d_%H-%M).backup\""
echo
print_warning "This may take 30+ minutes and cause slowness"
print_info "Start this backup now, then continue with the script"
prompt_action "Database backup started"

# Step 1: Create maintenance announcements
echo
print_warning "FIRST: Create maintenance announcements"
echo
echo "1. Create Mastodon announcement:"
echo "   URL: $INSTANCE_URL/admin/announcements/new"
echo "   Message:"
echo "We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience. Status: $STATUS_URL"
echo
# Calculate maintenance window (current time + 2 hours)
MAINTENANCE_START=$(LC_TIME=en_US.UTF-8 date "+%m/%d/%Y, %I:%M %p")
MAINTENANCE_END=$(LC_TIME=en_US.UTF-8 date -d "+2 hours" "+%m/%d/%Y, %I:%M %p")
TIMEZONE=$(date +"%Z")

echo "2. Create maintenance window:"
echo "   URL: $MAINTENANCE_URL"
echo "   Title: Server maintenance"
echo "   From: $MAINTENANCE_START $TIMEZONE"
echo "   To: $MAINTENANCE_END $TIMEZONE"
echo "   Message:"
echo "We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience."
echo
prompt_action "Announcements created"

# Check and start services automatically
print_info "Checking and starting required services..."
SERVICES_TO_START=""

# Detect all sidekiq services
SIDEKIQ_SERVICES=$(get_sidekiq_services)
print_info "Detected sidekiq services: $SIDEKIQ_SERVICES"

# Check nginx, web and streaming services
for service in nginx mastodon-web mastodon-streaming; do
  if systemctl is-active --quiet "$service"; then
    print_success "$service is already running"
  else
    print_warning "$service is not running - starting it..."
    SERVICES_TO_START="$SERVICES_TO_START $service"
  fi
done

# Check all sidekiq services
for service in $SIDEKIQ_SERVICES; do
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
    # Extract org/repo from configured YOUR_FORK_REPO
    if [[ -n "$YOUR_FORK_REPO" && "$url" =~ $YOUR_FORK_REPO ]]; then
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
  print_error "Could not find remote for your fork (check YOUR_FORK_REPO in .env.development)"
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
  print_warning "Your fork is $COMMITS_BEHIND commits behind $OFFICIAL_MASTODON_REPO:main"
  echo "This information will be saved for documentation purposes"
else
  print_success "Your fork is up to date with $OFFICIAL_MASTODON_REPO:main"
fi

# Step 2-3: GitHub sync via CLI
echo
if command -v gh &> /dev/null; then
  # Check if GitHub CLI is authenticated
  if ! gh auth status &>/dev/null; then
    print_warning "GitHub CLI found but not authenticated"
    echo -e "${BLUE}🔑 Starting authentication process...${NC}"
    gh auth login

    # Verify authentication succeeded
    if ! gh auth status &>/dev/null; then
      print_error "GitHub CLI authentication failed"
      echo "Please run 'gh auth login' manually and then restart this script."
      exit 1
    fi
    print_success "GitHub CLI authenticated successfully"
  fi
  
  print_info "Syncing fork via GitHub CLI..."
  if gh repo sync "$YOUR_FORK_REPO" --source "$OFFICIAL_MASTODON_REPO"; then
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

    # Detect package manager and install
    if command -v pacman &> /dev/null; then
      # Arch Linux
      if sudo pacman -Sy --noconfirm github-cli; then
        print_success "GitHub CLI installed successfully"
      else
        print_error "Failed to install GitHub CLI via pacman"
        exit 1
      fi
    elif command -v apt &> /dev/null; then
      # Debian/Ubuntu
      if sudo apt update && sudo apt install -y gh; then
        print_success "GitHub CLI installed successfully"
      else
        print_error "Failed to install GitHub CLI via apt"
        exit 1
      fi
    elif command -v dnf &> /dev/null; then
      # Fedora/RHEL
      if sudo dnf install -y gh; then
        print_success "GitHub CLI installed successfully"
      else
        print_error "Failed to install GitHub CLI via dnf"
        exit 1
      fi
    elif command -v yum &> /dev/null; then
      # CentOS/older RHEL
      if sudo yum install -y gh; then
        print_success "GitHub CLI installed successfully"
      else
        print_error "Failed to install GitHub CLI via yum"
        exit 1
      fi
    elif command -v brew &> /dev/null; then
      # macOS/Homebrew
      if brew install gh; then
        print_success "GitHub CLI installed successfully"
      else
        print_error "Failed to install GitHub CLI via brew"
        exit 1
      fi
    else
      print_error "Unknown package manager"
      print_error "Please install GitHub CLI manually for your distribution"
      echo "Visit: https://github.com/cli/cli#installation"
      exit 1
    fi

    # Check if already authenticated
    if gh auth status &>/dev/null; then
      print_success "GitHub CLI already authenticated"
    else
      print_warning "GitHub CLI needs authentication"
      echo "Starting authentication process..."
      gh auth login

      # Verify authentication succeeded
      if gh auth status &>/dev/null; then
        print_success "GitHub CLI authenticated successfully"
      else
        print_error "GitHub CLI authentication failed"
        echo "Please run 'gh auth login' manually and then restart this script."
        exit 1
      fi
    fi
  else
    print_error "GitHub CLI is required for fork synchronization"
    echo "Please install it manually:"
    echo "  - Arch: sudo pacman -S github-cli"
    echo "  - Debian/Ubuntu: sudo apt install gh"
    echo "  - Fedora: sudo dnf install gh"
    echo "  - macOS: brew install gh"
    echo ""
    echo "Then authenticate: gh auth login"
    exit 1
  fi
fi

# Step 4: Fetch all changes
print_info "Fetching all changes..."
git fetch --all
print_success "Fetched all changes"

# Step 5: Choose between stable or nightly version
echo
print_info "Detecting latest stable version..."
LATEST_STABLE=$(git tag -l 'v*' --sort=-version:refname | grep -v -E '(alpha|beta|rc)' | head -n1)
if [[ -n "$LATEST_STABLE" ]]; then
  print_success "Latest stable version found: $LATEST_STABLE"
else
  print_warning "Could not detect latest stable version"
  LATEST_STABLE="unknown"
fi

echo
echo "Enter version to use:"
echo "- Type 'main' for nightly/development version"
echo "- Type version number (e.g., '4.5.0' or 'v4.5.0') for specific release"
if [[ "$LATEST_STABLE" != "unknown" ]]; then
  echo "- Press Enter to use latest stable: $LATEST_STABLE"
fi
read -p "Version: " -r VERSION_INPUT

# Default to latest stable if empty
if [[ -z "$VERSION_INPUT" && "$LATEST_STABLE" != "unknown" ]]; then
  VERSION_INPUT="$LATEST_STABLE"
fi

# Process the version input
if [[ "$VERSION_INPUT" == "main" ]]; then
  print_info "Checking out and updating main branch..."
  git fetch --all
  yarn cache clean
  check_and_stash_changes
  git checkout main
  git pull $UPSTREAM_REMOTE main

  # Show latest main commit info
  MAIN_COMMIT_HASH=$(git rev-parse --short HEAD)
  MAIN_COMMIT_MSG=$(git log -1 --pretty=format:"%s" HEAD)
  MAIN_COMMIT_DATE=$(git log -1 --pretty=format:"%cr" HEAD)
  print_success "Latest main commit: $MAIN_COMMIT_HASH - $MAIN_COMMIT_MSG"
  print_info "  Date: $MAIN_COMMIT_DATE"
  print_info "  Link: https://github.com/$OFFICIAL_MASTODON_REPO/commit/$MAIN_COMMIT_HASH"
else
  # Add 'v' prefix if not present
  if [[ ! "$VERSION_INPUT" =~ ^v ]]; then
    VERSION_INPUT="v$VERSION_INPUT"
  fi

  print_info "Checking out version $VERSION_INPUT..."
  yarn cache clean
  git fetch
  check_and_stash_changes
  git checkout "$VERSION_INPUT"
  print_success "Checked out $VERSION_INPUT"
fi
print_success "Branch checked out and updated"

# Check if Ruby version needs updating
print_info "Checking Ruby version requirements..."
if [[ -f ".ruby-version" ]]; then
  REQUIRED_RUBY=$(cat .ruby-version)
  print_info "Required Ruby version: $REQUIRED_RUBY"
  if ! rbenv versions | grep -q "$REQUIRED_RUBY"; then
    print_warning "Ruby $REQUIRED_RUBY is not installed"
    print_info "Updating ruby-build definitions..."
    git -C ~/.rbenv/plugins/ruby-build pull || print_warning "Could not update ruby-build (continuing anyway)"
    
    if confirm "Install Ruby $REQUIRED_RUBY?"; then
      if rbenv install "$REQUIRED_RUBY"; then
        print_success "Ruby $REQUIRED_RUBY installed"
      else
        print_error "Failed to install Ruby $REQUIRED_RUBY"
        print_warning "Continuing with current Ruby version, but build may fail"
      fi
    else
      print_warning "Continuing with current Ruby version, but build may fail"
    fi
  else
    print_success "Ruby $REQUIRED_RUBY is already installed"
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

# Enable corepack for yarn
print_info "Enabling corepack for yarn..."
if command -v corepack &> /dev/null; then
  corepack enable
  print_success "Corepack enabled"
else
  print_warning "Corepack not found - attempting to enable via npm"
  if command -v npm &> /dev/null; then
    npm install -g corepack
    corepack enable
    print_success "Corepack installed and enabled"
  else
    print_error "Cannot enable corepack - npm not found"
    exit 1
  fi
fi

# Step 6: Build
print_info "Installing dependencies and building assets..."

# Check and install required bundler version
if [[ -f "Gemfile.lock" ]]; then
  REQUIRED_BUNDLER=$(grep -A 1 "BUNDLED WITH" Gemfile.lock | tail -n 1 | tr -d '[:space:]')
  if [[ -n "$REQUIRED_BUNDLER" ]]; then
    print_info "Checking bundler version (required: $REQUIRED_BUNDLER)..."
    if ! gem list bundler -i -v "$REQUIRED_BUNDLER" &>/dev/null; then
      print_warning "Installing bundler $REQUIRED_BUNDLER..."
      gem install bundler -v "$REQUIRED_BUNDLER"
      print_success "Bundler $REQUIRED_BUNDLER installed"
    else
      print_success "Bundler $REQUIRED_BUNDLER already installed"
    fi
  fi
fi

# Check for ICU library compatibility issues before bundle install
check_and_fix_native_gems

echo -e "${YELLOW}  ⏳ Running bundle install...${NC}"
bundle install
echo -e "${YELLOW}  ⏳ Running yarn install...${NC}"
# Set corepack to auto-confirm downloads
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
yarn install --immutable
echo -e "${YELLOW}  ⏳ Precompiling assets...${NC}"
RAILS_ENV=development bundle exec rails assets:precompile
print_success "Build completed"

# Step 7: Check migrations
print_info "Checking for pending migrations..."
PENDING_MIGRATIONS=$(RAILS_ENV=development bundle exec rails db:migrate:status | grep down || true)
if [[ -n "$PENDING_MIGRATIONS" ]]; then
  print_warning "Pending migrations found:"
  echo "$PENDING_MIGRATIONS"
  
  # Step 8: Run migrations
  if confirm "Run migrations?"; then
    RAILS_ENV=development bundle exec rails db:migrate
    print_success "Migrations completed"
  fi
else
  print_info "No pending migrations"
fi

# Step 9: Clear cache if needed
if confirm "Clear cache before restart?"; then
  RAILS_ENV=development /opt/mastodon/bin/tootctl cache clear
  print_success "Cache cleared"
fi

# Step 10: Restart services
print_info "Restarting Mastodon services..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web $SIDEKIQ_SERVICES mastodon-streaming
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
  RAILS_ENV=development bin/tootctl search deploy --reset-chewy

  print_info "Rebuilding search index (this may take a while)..."
  RAILS_ENV=development bin/tootctl search deploy --only accounts --concurrency 16 --batch_size 4096
  RAILS_ENV=development bin/tootctl search deploy --only statuses --concurrency 16 --batch_size 4096
  print_success "Search index rebuilt"
fi

# Step 13: Final restart
print_info "Final restart of services..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web $SIDEKIQ_SERVICES mastodon-streaming
  sleep 5
  sudo systemctl restart postgresql
fi
print_success "Final restart completed"

# Step 14-15: Create new branch and merge mods
print_info "Preparing branch: $NEW_BRANCH"

# Check if branch already exists
if git show-ref --verify --quiet "refs/heads/$NEW_BRANCH"; then
  print_warning "Branch '$NEW_BRANCH' already exists"
  echo "What would you like to do?"
  echo "1. Use existing branch (checkout)"
  echo "2. Delete and create new branch"
  echo "3. Exit script"
  read -p "Enter choice (1/2/3): " -r

  case $REPLY in
    1)
      print_info "Checking out existing branch: $NEW_BRANCH"
      git checkout "$NEW_BRANCH"
      print_success "Checked out existing branch"
      ;;
    2)
      print_warning "Deleting existing branch: $NEW_BRANCH"
      git branch -D "$NEW_BRANCH"
      print_info "Creating new branch: $NEW_BRANCH"
      git branch "$NEW_BRANCH"
      git checkout "$NEW_BRANCH"
      print_success "New branch created and checked out"
      ;;
    3)
      print_info "Exiting script"
      exit 0
      ;;
    *)
      print_error "Invalid choice"
      exit 1
      ;;
  esac
else
  print_info "Creating new branch: $NEW_BRANCH"
  git branch "$NEW_BRANCH"
  git checkout "$NEW_BRANCH"
  print_success "New branch created and checked out"
fi

# Ask which branch to merge customizations from
echo
echo "Merge customizations from which branch?"
echo "- Press Enter to use default: [$CURRENT_VERSION]"
echo "- Type a branch name to merge from that instead"
echo "- Type 'skip' to skip merging (use upstream only)"
read -p "Branch: " -r MERGE_BRANCH_INPUT

# Determine which branch to merge
if [[ -z "$MERGE_BRANCH_INPUT" ]]; then
  BRANCH_TO_MERGE="$CURRENT_VERSION"
elif [[ "$MERGE_BRANCH_INPUT" == "skip" ]]; then
  BRANCH_TO_MERGE=""
  print_info "Skipping merge - using upstream only"
else
  BRANCH_TO_MERGE="$MERGE_BRANCH_INPUT"
fi

if [[ -n "$BRANCH_TO_MERGE" ]]; then
  print_info "Attempting to merge $BRANCH_TO_MERGE..."
  if git merge "$BRANCH_TO_MERGE"; then
    print_success "Merge successful"
  else
    print_error "Merge conflicts detected"
    echo
    echo "Conflicted files:"
    git diff --name-only --diff-filter=U | while read file; do
      echo "  - $file"
    done
    echo
    echo "Options:"
    echo "  1) Resolve conflicts manually (opens in another terminal), then continue"
    echo "  2) Abort merge and skip your customizations (use upstream only)"
    echo "  3) Abort script and resolve later"
    echo
    read -p "Choose option (1/2/3): " -r MERGE_OPTION

    case "$MERGE_OPTION" in
      1)
        print_info "Please resolve conflicts in another terminal"
        echo "After resolving, run: git add . && git commit"
        prompt_action "Merge conflicts resolved and committed"
        ;;
      2)
        print_warning "Aborting merge - your customizations will NOT be included"
        git merge --abort
        print_info "You can manually cherry-pick changes from $BRANCH_TO_MERGE later if needed"
        ;;
      3)
        print_error "Script aborted - merge in progress"
        echo "To resolve later:"
        echo "  1. Fix conflicts in the listed files"
        echo "  2. Run: git add . && git commit"
        echo "  3. Re-run this script"
        exit 1
        ;;
      *)
        print_error "Invalid option - aborting script"
        exit 1
        ;;
    esac
  fi
fi

# Step 17: Update version in .env.production
print_info "Updating version metadata in .env.production..."
if [[ -f ".env.production" ]]; then
  # Detect if Bird UI is installed
  BIRD_UI_VERSION=""
  if [[ -f "app/javascript/styles/mastodon-bird-ui/layout-single-column.scss" ]]; then
    # Try to detect Bird UI version from comments in the file
    BIRD_UI_VERSION=" + Mastodon Bird UI"
  fi
  
  # Update MASTODON_VERSION_METADATA
  if grep -q "^MASTODON_VERSION_METADATA=" .env.production; then
    sed -i "s/^MASTODON_VERSION_METADATA=.*/MASTODON_VERSION_METADATA='$NEW_BRANCH$BIRD_UI_VERSION'/" .env.production
    print_success "Version metadata updated to: $NEW_BRANCH$BIRD_UI_VERSION"
  else
    echo "MASTODON_VERSION_METADATA='$NEW_BRANCH$BIRD_UI_VERSION'" >> .env.production
    print_success "Version metadata added: $NEW_BRANCH$BIRD_UI_VERSION"
  fi
  
  # Update GITHUB_REPOSITORY for comparison link
  GITHUB_COMPARE="mastodon/mastodon/compare/main...${YOUR_FORK_REPO:-mementomori-social/mastodon}:$NEW_BRANCH"
  if grep -q "^GITHUB_REPOSITORY=" .env.production; then
    sed -i "s|^GITHUB_REPOSITORY=.*|GITHUB_REPOSITORY=$GITHUB_COMPARE|" .env.production
    print_success "GitHub repository comparison updated"
  else
    echo "GITHUB_REPOSITORY=$GITHUB_COMPARE" >> .env.production
    print_success "GitHub repository comparison added"
  fi
else
  print_warning ".env.production not found, skipping version update"
fi

# Step 18: Recompile with new branch
print_info "Recompiling with new branch..."
yarn cache clean
rm -rf node_modules

# Check and install required bundler version (in case it changed after merge)
if [[ -f "Gemfile.lock" ]]; then
  REQUIRED_BUNDLER=$(grep -A 1 "BUNDLED WITH" Gemfile.lock | tail -n 1 | tr -d '[:space:]')
  if [[ -n "$REQUIRED_BUNDLER" ]]; then
    if ! gem list bundler -i -v "$REQUIRED_BUNDLER" &>/dev/null; then
      print_warning "Installing bundler $REQUIRED_BUNDLER..."
      gem install bundler -v "$REQUIRED_BUNDLER"
      print_success "Bundler $REQUIRED_BUNDLER installed"
    fi
  fi
fi

# Check for ICU library compatibility issues before bundle install
check_and_fix_native_gems

bundle install
yarn install --immutable
RAILS_ENV=development bundle exec rails assets:precompile

# Clear toot cache before restart
print_info "Clearing toot cache..."
RAILS_ENV=development /opt/mastodon/bin/tootctl cache clear

print_info "Restarting services (this may take a moment)..."
if command -v restart-mastodon &> /dev/null; then
  restart-mastodon
else
  sudo systemctl restart mastodon-web $SIDEKIQ_SERVICES mastodon-streaming
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
if [[ "$ORIGINAL_COMMITS_BEHIND" -gt 0 ]]; then
  print_warning "  Commits synced: $ORIGINAL_COMMITS_BEHIND from upstream"
else
  print_success "  Fork was up to date with upstream"
fi
print_info "  Next step: Run production upgrade script"
echo
print_info "Upgrade history saved to: $UPGRADE_LOG"
