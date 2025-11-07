# Mastodon upgrade workflow automation

![Version](https://img.shields.io/badge/version-1.1.1-blue?style=for-the-badge)
![Mastodon](https://img.shields.io/badge/-MASTODON-%236364FF?style=for-the-badge&logo=mastodon&logoColor=white)
![bash](https://img.shields.io/badge/bash-%23121011.svg?style=for-the-badge&color=%23222222&logo=gnu-bash&logoColor=white)
![linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)

Automated bash scripts for managing Mastodon instance upgrades, designed for the mementomori.social workflow but adaptable to other instances.

<img width="829" height="516" alt="image" src="https://github.com/user-attachments/assets/ca087d38-99eb-4857-b548-8d2b5b2a6d8b" />

## When it's upgrade day - Test and upgrade workflow with [the scripts](https://github.com/mementomori-social/upgrade-workflow-automation)

You don't even have to create announcement and status page update manually, the script will prompt about it.

```bash
sudo su mastodon
```

```bash
# Long oneliner in local environment
cd ~ && (test -d upgrade-workflow-automation && cd upgrade-workflow-automation && git pull || git clone https://github.com/mementomori-social/upgrade-workflow-automation.git) && cd ~/upgrade-workflow-automation &&  bash mastodon-upgrade-local.sh
```

After testing and verification, SSH to your production server and deploy:

```bash
ssh your-production-server
```

```bash
sudo su mastodon
```

```bash
# Long oneliner in production
cd ~ && (test -d upgrade-workflow-automation && cd upgrade-workflow-automation && git pull || git clone https://github.com/mementomori-social/upgrade-workflow-automation.git) && cd ~/upgrade-workflow-automation && bash mastodon-upgrade-production.sh
```

Optional: Update Mastodon Bird UI if there are new changes:

```bash
bash mastodon-bird-ui-update.sh
```

## Features

- **Automatic git remote detection** - Detects your fork and upstream remotes automatically
- **Commit behind tracking** - Shows how many commits behind upstream before sync
- **Colored output** - Modern, visually appealing progress indicators
- **Service management** - Automatic service startup/restart handling
- **Migration management** - Handles database migrations with confirmations
- **Search index rebuilding** - Manages Elasticsearch index updates
- **Upgrade logging** - Tracks upgrade history for documentation
- **Safety confirmations** - Production-safe with multiple confirmation prompts

## Scripts

### Local development script

`mastodon-upgrade-local.sh` handles the development environment upgrade process:

- Checks and starts required services automatically
- Fetches current production version from API
- Manages GitHub fork sync workflow
- Builds and tests changes
- Creates new versioned branches
- Merges modifications from previous branches

### Production deployment script

`mastodon-upgrade-production.sh` manages production deployments:

- Requires database backup before proceeding
- Service status validation
- Careful migration handling with live database warnings
- Optional search index rebuilding
- Service restart management
- Post-deployment monitoring

## Prerequisites

### Environment setup

This automation expects specific Mastodon installation setups:

**Local development environment:**
- Mastodon installed at `/opt/mastodon`
- Running as `mastodon` user
- Services: `mastodon-web`, `mastodon-sidekiq`, `mastodon-streaming`
- PostgreSQL service available

**Production environment:**
- Mastodon installed at `/home/mastodon/live`
- Running as `mastodon` user
- Database server accessible (can be remote)
- Backup directory configured and writable

### Required tools

- **Git** - For repository management
- **Ruby** (via rbenv) - Version management
- **Node.js** (via nvm) - For asset compilation (v22.18.0 recommended for production parity)
- **Yarn** - Package manager (managed by corepack)
- **PostgreSQL client** - For database operations
- **GitHub CLI** (optional) - For automated fork syncing: `sudo apt install gh`

### Permissions

- `mastodon` user must have sudo privileges for service management
- Write access to backup directory (production)
- SSH access to database server (if remote)

## Installation

1. Copy scripts to your Mastodon user's home directory:

```bash
sudo cp mastodon-upgrade-*.sh /home/mastodon/
sudo chown mastodon:mastodon /home/mastodon/mastodon-upgrade-*.sh
sudo chmod +x /home/mastodon/mastodon-upgrade-*.sh
```

2. Switch to mastodon user and run:

```bash
sudo su - mastodon
./mastodon-upgrade-local.sh
```

## Configuration

### Using .env file

The scripts support configuration via a `.env` file. Copy the example and customize:

```bash
cp .env.example .env
nano .env
```

### Manual configuration

If not using a `.env` file, you can edit the scripts directly to customize:

#### Local environment settings
- `MASTODON_DIR="/opt/mastodon"` - Your Mastodon installation directory
- `API_URL="https://your-instance.com/api/v1/instance"` - Your instance API URL
- `YOUR_FORK_REPO="your-org/mastodon"` - Your fork repository

#### Production environment settings
- `PRODUCTION_MASTODON_DIR="/home/mastodon/live"` - Production Mastodon directory
- `DB_HOST`, `DB_PORT`, `DB_USER` - Database server settings for backups
- `BACKUP_DIR="/tmp/mastodon-backups"` - Where to store database backups

## Workflow

### Development upgrade

1. **Service check** - Ensures all services are running
2. **Version detection** - Gets current production version
3. **Commit analysis** - Checks how many commits behind upstream
4. **GitHub sync** - Prompts for manual fork sync
5. **Build and test** - Installs dependencies and builds
6. **Migration** - Handles database migrations
7. **Branch management** - Creates new branch and merges mods
8. **Verification** - Manual testing checklist

### Production deployment

1. **Backup reminder** - Database backup instructions
2. **Service validation** - Checks current service status
3. **Code deployment** - Fetches and applies changes
4. **Migration** - Runs database migrations with confirmation
5. **Service restart** - Restarts all Mastodon services
6. **Monitoring** - Shows log output for verification

## Upgrade logging

All upgrades are logged to `~/mastodon-upgrades.log` with format:
```
2025-08-30 14:30:00 - Upgrade completed: mementomods-2025-08-29 -> mementomods-2025-08-30 (was 42 commits behind)
```

## Customization

To adapt for your instance:

1. Update the organization/fork references:
```bash
YOUR_FORK_REPO="your-org/mastodon"
```

2. Modify the git remote detection pattern:
```bash
if [[ "$url" =~ your-org/mastodon ]]; then
```

3. Adjust paths for your environment:
```bash
MASTODON_DIR="/your/mastodon/path"
```

## About

Created for [mementomori.social](https://mementomori.social) - A Mastodon instance focused on memory, mortality, and mindful living.

---

*These scripts automate our manual upgrade workflow documented at [help.mementomori.social](https://help.mementomori.social/mementomori.social/mastodon-upgrade-workflow)*
