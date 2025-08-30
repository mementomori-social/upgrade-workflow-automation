#!/bin/bash

# Mastodon Production Upgrade Script
# This script automates the Mastodon upgrade process for the production environment

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
MASTODON_DIR="${PRODUCTION_MASTODON_DIR:-/home/mastodon/live}"
MASTODON_USER="${MASTODON_USER:-mastodon}"
DB_HOST="${DB_HOST}"
DB_PORT="${DB_PORT:-36424}"
DB_USER="${DB_USER}"
BACKUP_DIR="${BACKUP_DIR:-/tmp/mastodon-backups}"
API_URL="${API_URL:-https://your-instance.com/api/v1/instance}"

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

if ! confirm "Are you sure you want to continue with the production upgrade?"; then
  print_info "Upgrade cancelled"
  exit 0
fi

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
print_warning "Database backup is required before proceeding"
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

# Check if running as mastodon user
if [[ "$USER" != "$MASTODON_USER" ]]; then
  print_warning "Please run this script as the mastodon user on the production server"
  echo "sudo su - mastodon"
  exit 1
fi

# Change to Mastodon directory
cd "$MASTODON_DIR"
print_success "Changed to directory: $MASTODON_DIR"

# Auto-detect git remotes
print_info "Detecting git remotes..."
UPSTREAM_REMOTE=""
ORIGIN_REMOTE=""

# Parse git remote -v output
while read -r remote url type; do
  if [[ "$type" == "(fetch)" ]]; then
    # Extract org/repo from configured GITHUB_REPO
    if [[ -n "$GITHUB_REPO" && "$url" =~ $GITHUB_REPO ]]; then
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
  print_error "Could not find remote for your fork (check GITHUB_REPO in .env)"
  read -p "Enter the remote name for your fork: " UPSTREAM_REMOTE
fi

print_success "Using remote for your fork: $UPSTREAM_REMOTE"

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
print_info "Updating version in .env.production..."
if confirm "Edit .env.production to update version?"; then
  nano -w +62 .env.production
fi

# Check Ruby version
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

# Step 8: Search index reset (optional due to time)
if confirm "Reset search index? (This will take a LONG time - recommend running in screen)"; then
  print_warning "This operation can take hours. Consider running in a screen session."
  if confirm "Continue with search index reset?"; then
    print_info "Resetting search index..."
    RAILS_ENV=production bin/tootctl search deploy --reset-chewy
    print_success "Search index reset"
  fi
fi

# Step 9: Rebuild search index (if needed)
if confirm "Rebuild search index? (This will take a while)"; then
  print_info "Rebuilding search index for accounts..."
  RAILS_ENV=production bin/tootctl search deploy --only accounts --concurrency 16 --batch_size 4096
  
  print_info "Rebuilding search index for statuses..."
  RAILS_ENV=production bin/tootctl search deploy --only statuses --concurrency 16 --batch_size 4096
  print_success "Search index rebuilt"
fi

# Step 10: Restart services
print_warning "About to restart Mastodon services - this will cause a brief outage"
if confirm "Restart services now?"; then
  print_info "Restarting Mastodon services..."
  
  # Stop services in proper order
  sudo systemctl stop mastodon-web.service
  sudo systemctl stop mastodon-streaming.service
  sudo systemctl stop mastodon-sidekiq.service
  
  # Stop specific sidekiq workers
  sudo systemctl stop mastodon-sidekiq-1-default@35.service
  sudo systemctl stop mastodon-sidekiq-2-default@35.service
  sudo systemctl stop mastodon-sidekiq-1-ingress@25.service
  sudo systemctl stop mastodon-sidekiq-2-ingress@25.service
  sudo systemctl stop mastodon-sidekiq-pull@40.service
  sudo systemctl stop mastodon-sidekiq-push@35.service
  sudo systemctl stop mastodon-sidekiq-mailers@20.service
  sudo systemctl stop mastodon-sidekiq-scheduler@5.service
  sudo systemctl stop mastodon-fasp.service
  
  # Start services in proper order
  sudo systemctl start mastodon-sidekiq.service
  sudo systemctl start mastodon-sidekiq-1-default@35.service
  sudo systemctl start mastodon-sidekiq-2-default@35.service
  sudo systemctl start mastodon-sidekiq-1-ingress@25.service
  sudo systemctl start mastodon-sidekiq-2-ingress@25.service
  sudo systemctl start mastodon-sidekiq-pull@40.service
  sudo systemctl start mastodon-sidekiq-push@35.service
  sudo systemctl start mastodon-sidekiq-mailers@20.service
  sudo systemctl start mastodon-sidekiq-scheduler@5.service
  sudo systemctl start mastodon-fasp.service
  sudo systemctl start mastodon-streaming.service
  sudo systemctl start mastodon-web.service
  
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