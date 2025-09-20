#!/bin/bash

# Mastodon Production Upgrade Script
# This script automates the Mastodon upgrade process for the production environment
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
if [[ -f "$SCRIPT_DIR/.env.production" ]]; then
  source "$SCRIPT_DIR/.env.production"
elif [[ -f "$SCRIPT_DIR/.env" ]]; then
  source "$SCRIPT_DIR/.env"
fi

# Default configuration (can be overridden by .env)
MASTODON_DIR="${PRODUCTION_MASTODON_DIR:-/home/mastodon/live}"
MASTODON_USER="${MASTODON_USER:-mastodon}"
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT:-36424}"
DB_USER="${DB_USER}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/mastodon-backups}"
API_URL="${API_URL:-https://your-instance.com/api/v1/instance}"

# Support both old and new variable names for backward compatibility
YOUR_FORK_REPO="${YOUR_FORK_REPO:-${GITHUB_REPO}}"
OFFICIAL_MASTODON_REPO="${OFFICIAL_MASTODON_REPO:-${UPSTREAM_REPO:-mastodon/mastodon}}"

# Validate required environment variables
if [[ -z "$DB_HOST" ]]; then
  print_error "DB_HOST not set. Please configure in .env file."
  exit 1
fi

if [[ -z "$DB_USER" ]]; then
  print_error "DB_USER not set. Please configure in .env file."
  exit 1
fi

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

# Function to show maintenance messages
show_maintenance_messages() {
  echo
  print_warning "FIRST: Create maintenance announcements (skip if already done in local script)"
  echo
  echo "1. Create Mastodon announcement:"
  echo "   URL: ${INSTANCE_URL:-https://mementomori.social}/admin/announcements/new"
  echo "   Message:"
  echo "We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience. Status: ${STATUS_URL:-https://status.mementomori.social}"
  echo
  # Calculate maintenance window (current time + 2 hours)
  MAINTENANCE_START=$(date "+%m/%d/%Y %I:%M %p")
  MAINTENANCE_END=$(date -d "+2 hours" "+%m/%d/%Y %I:%M %p")
  TIMEZONE=$(date +"%Z")
  
  echo "2. Create maintenance window:"
  echo "   URL: ${MAINTENANCE_URL:-https://uptime.betterstack.com/team/t5969/status-pages/165860/maintenances}"
  echo "   Title: Server maintenance"
  echo "   From: $MAINTENANCE_START $TIMEZONE"
  echo "   To: $MAINTENANCE_END $TIMEZONE"
  echo "   Message:"
  echo "We'll be performing Mastodon software upgrades soon. May cause some visible notifications or even a minor downtime. Sorry for the inconvenience, and thank you for your patience."
  echo
}

# Function to prompt for confirmation
confirm() {
  read -p "$1 (y/n): " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]]
}

# Get version and date from changelog
SCRIPT_VERSION_LINE=$(head -n1 "$SCRIPT_DIR/CHANGELOG.md" 2>/dev/null || echo "### 1.0.1: 2025-08-30")
SCRIPT_VERSION=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "1.0.1")
SCRIPT_DATE=$(echo "$SCRIPT_VERSION_LINE" | grep -o '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}' || echo "2025-08-30")

print_info "Mastodon production upgrade script ${BLUE}v$SCRIPT_VERSION ($SCRIPT_DATE)${NC}"
print_info "Starting Mastodon PRODUCTION upgrade process"
echo "================================================"
print_warning "THIS WILL AFFECT THE LIVE PRODUCTION INSTANCE!"
echo

# Check if services are currently running
print_info "Checking current service status..."
SERVICE_CHECK=0
for service in mastodon-web mastodon-sidekiq mastodon-streaming; do
  if systemctl is-active --quiet "$service"; then
    print_success "$service is running"
  else
    print_warning "$service is not running"
    SERVICE_CHECK=1
  fi
done

if [[ $SERVICE_CHECK -ne 0 ]]; then
  print_warning "Some services are not running. This may indicate issues with the current installation."
  if ! confirm "Continue anyway?"; then
    print_info "Upgrade cancelled"
    exit 0
  fi
fi

# Show maintenance messages for copy-paste
show_maintenance_messages

if ! confirm "Are you sure you want to continue with the production upgrade?"; then
  print_info "Upgrade cancelled"
  exit 0
fi

# Change to Mastodon directory first to detect remotes
cd "$MASTODON_DIR"
print_success "Changed to directory: $MASTODON_DIR"

# Auto-detect git remotes
print_info "Detecting git remotes..."
UPSTREAM_REMOTE=""
ORIGIN_REMOTE=""

# Parse git remote -v output
while read -r remote url type; do
  if [[ "$type" == "(fetch)" ]]; then
    # Extract org/repo from configured YOUR_FORK_REPO
    if [[ -n "$YOUR_FORK_REPO" && "$url" =~ $YOUR_FORK_REPO ]]; then
      UPSTREAM_REMOTE="$remote"
      print_info "Found your fork remote: $remote -> $url"
    elif [[ "$url" =~ mastodon/mastodon ]] || [[ "$url" =~ tootsuite/mastodon ]]; then
      # In production, this is just for reference
      ORIGIN_REMOTE="$remote"
      print_info "Found original mastodon remote: $remote -> $url"
    fi
  fi
done < <(git remote -v)

# Validate remotes
if [[ -z "$UPSTREAM_REMOTE" ]]; then
  print_error "Could not find remote for your fork (check YOUR_FORK_REPO in .env)"
  read -p "Enter the remote name for your fork: " UPSTREAM_REMOTE
fi

print_success "Using remote for your fork: $UPSTREAM_REMOTE"

# Auto-detect newest mementomods branch from development
print_info "Detecting newest mementomods branch from $UPSTREAM_REMOTE..."
git fetch $UPSTREAM_REMOTE --quiet
NEW_BRANCH=$(git branch -r | grep "$UPSTREAM_REMOTE/mementomods-" | sed "s|.*$UPSTREAM_REMOTE/||" | sort -V | tail -n1)

if [[ -n "$NEW_BRANCH" ]]; then
  print_success "Found newest branch: $NEW_BRANCH"
  if ! confirm "Deploy branch $NEW_BRANCH to production?"; then
    print_info "Deployment cancelled"
    exit 0
  fi
else
  print_warning "Could not auto-detect mementomods branch"
  read -p "Enter the new branch name from development (e.g., mementomods-2025-08-25): " NEW_BRANCH
  if [[ -z "$NEW_BRANCH" ]]; then
    print_error "Branch name is required"
    exit 1
  fi
fi

# Step 1: Database backup
print_warning "Database backup is required before proceeding (may already be running from local script)"
echo "To create a backup, run these commands on the database server:"
echo
echo "ssh -p $DB_PORT $DB_USER@$DB_HOST"
echo "sudo su -"
echo "ionice -c2 -n7 nice -n19 pg_dump \\"
echo "  --host=localhost \\"
echo "  --username=mastodon \\"
echo "  --dbname=mastodon_production \\"
echo "  --format=directory \\"
echo "  --jobs=2 \\"
echo "  --compress=5 \\"
echo "  --verbose \\"
echo "  --file=\"$BACKUP_DIR/mastodon_production_\$(date +%Y-%m-%d_%H-%M).backup\""
echo
print_warning "This may take 30+ minutes and cause slowness"
prompt_action "Database backup completed"



# Step 2: Fetch changes
print_info "Fetching changes from $UPSTREAM_REMOTE..."
git fetch --all
git checkout -b "$UPSTREAM_REMOTE/$NEW_BRANCH"
git pull $UPSTREAM_REMOTE "$NEW_BRANCH" --rebase
print_success "Changes fetched and branch checked out"

# Step 3: Verify changes
print_info "Showing recent commits..."
git log --oneline -10
if ! confirm "Do the changes look correct?"; then
  print_error "Aborting upgrade"
  exit 1
fi

# Step 4: Update version in .env.production
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
  
  # Optionally allow manual editing
  if confirm "Do you want to manually edit .env.production for additional changes?"; then
    nano -w +62 .env.production
  fi
else
  print_warning ".env.production not found, skipping version update"
fi

# Check Ruby version
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

# Step 5: Rebuild
print_info "Rebuilding application (this may take a while)..."
yarn cache clean
rm -rf node_modules
bundle install
yarn install --immutable
RAILS_ENV=production bundle exec rails assets:precompile
print_success "Application rebuilt"

# Check for libvips version issue
if grep -q "Incompatible libvips version" /tmp/build_output 2>/dev/null; then
  print_error "libvips version incompatible"
  echo "Please install libvips >= 8.13 from source:"
  echo "https://github.com/libvips/libvips/wiki/Build-for-Ubuntu#building-from-source"
  prompt_action "libvips updated"
  
  # Retry build
  print_info "Retrying build..."
  RAILS_ENV=production bundle exec rails assets:precompile
fi

# Step 6: Check and run migrations
print_info "Checking for pending migrations..."
PENDING_MIGRATIONS=$(RAILS_ENV=production bundle exec rails db:migrate:status | grep down || true)
if [[ -n "$PENDING_MIGRATIONS" ]]; then
  print_warning "Pending migrations found:"
  echo "$PENDING_MIGRATIONS"
  
  if confirm "Run migrations? (This will affect the live database)"; then
    RAILS_ENV=production bundle exec rails db:migrate
    print_success "Migrations completed"
  else
    print_error "Migrations are required to continue"
    exit 1
  fi
else
  print_info "No pending migrations"
fi

# Step 7: Clear cache
print_info "Clearing cache..."
RAILS_ENV=production /home/mastodon/live/bin/tootctl cache clear
print_success "Cache cleared"


# Step 8: Restart services
print_warning "About to restart Mastodon services - this will cause a brief interruption"
if confirm "Restart services now?"; then
  print_info "Restarting Mastodon services..."
  
  # Restart services in the same order as /usr/local/bin/restart-mastodon
  sudo systemctl restart mastodon-sidekiq.service
  sudo systemctl restart mastodon-streaming.service
  sudo systemctl restart mastodon-web.service
  
  # Restart specific sidekiq workers
  sudo systemctl restart mastodon-sidekiq-1-default@35.service
  sudo systemctl restart mastodon-sidekiq-2-default@35.service
  sudo systemctl restart mastodon-sidekiq-1-ingress@25.service
  sudo systemctl restart mastodon-sidekiq-2-ingress@25.service
  sudo systemctl restart mastodon-sidekiq-pull@40.service
  sudo systemctl restart mastodon-sidekiq-push@35.service
  sudo systemctl restart mastodon-sidekiq-mailers@20.service
  sudo systemctl restart mastodon-sidekiq-scheduler@5.service
  
  # Check if fasp service exists before restarting
  if systemctl list-units --all | grep -q "mastodon-sidekiq-fasp@1"; then
    sudo systemctl restart mastodon-sidekiq-fasp@1.service
  fi
  
  print_success "Services restarted"
else
  print_warning "Services not restarted - manual restart required!"
  echo "Run the service restart commands manually"
fi

# Step 11: Monitor logs
print_info "Opening debug logs in 5 seconds..."
print_info "Press Ctrl+C to exit log monitoring"
sleep 5

echo
print_info "Monitoring for FATAL errors (Ctrl+C to stop):"
timeout 30 sudo journalctl -u mastodon-web.service -f | grep FATAL || true

echo
print_success "Production upgrade completed!"
echo "================================================"
echo "Deployed branch: $NEW_BRANCH"
echo
print_warning "Please verify the following:"
echo "[ ] Site is accessible at your instance URL"
echo "[ ] Users can log in"
echo "[ ] Posting works"
echo "[ ] Federation is working"
echo "[ ] Search is functional"
echo
print_info "To monitor logs:"
echo "  sudo journalctl -u mastodon-web.service -f"
echo "  sudo journalctl -u mastodon-sidekiq.service -f"
echo "  sudo journalctl -u mastodon-streaming.service -f"
echo
print_info "Optional: Search index maintenance (run in screen/tmux):"
echo "  # Reset search index (WARNING: Takes hours!):"
echo "  RAILS_ENV=production bin/tootctl search deploy --reset-chewy"
echo
echo "  # Or just rebuild search index (faster):"
echo "  RAILS_ENV=production bin/tootctl search deploy --only accounts --concurrency 16 --batch_size 4096"
echo "  RAILS_ENV=production bin/tootctl search deploy --only statuses --concurrency 16 --batch_size 4096"
echo
print_warning "Only run search index commands if search is not working properly!"
