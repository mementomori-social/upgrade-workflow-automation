### 1.1.0: 2025-10-21

* Add automatic stash prompt for unstaged changes before git checkout operations
* Add multi-package-manager support for GitHub CLI installation (Arch/pacman, Debian/Ubuntu/apt, Fedora/dnf, CentOS/yum, macOS/brew)
* Add automatic GitHub CLI authentication check and login prompt within script
* Add automatic bundler version detection and installation from Gemfile.lock
* Make GitHub CLI required for fork synchronization (exits if not installed)
* Change y/n prompts to require Enter key press instead of immediate response
* Prevent script crashes when unstaged changes exist in working directory

### 1.0.3: 2025-09-20

* Add maintenance message templates to production script for easy copy-paste
* Fix local script remote detection to use correct variable name
* Improve Ruby version handling to auto-update ruby-build and continue on failure
* Remove unnecessary 'skip' option from action prompts
* Make maintenance announcement formatting consistent between local and production scripts
* Improve message formatting for easy copy-paste without leading spaces
* Add quick upgrade workflow section to README with idempotent git commands
* Move database backup prompt to very beginning of local script for time efficiency
* Improve upgrade summary formatting and hide zero commit counts
* Add root/sudo execution prevention with colored error messages
* Fix Bird UI script permission issues by using temp files for downloads
* Clarify production deployment workflow in README with explicit SSH steps

### 1.0.2: 2025-08-30

* Rename environment variables for clarity: GITHUB_REPO → YOUR_FORK_REPO, UPSTREAM_REPO → OFFICIAL_MASTODON_REPO
* Add backward compatibility for old environment variable names
* Fix mastodon-bird-ui-update.sh to use --no-verify flag for git commits
* Remove unnecessary nightly version warning from Bird UI script
* Improve environment variable documentation with clearer descriptions
* Add automatic remote detection based on repository URLs instead of remote names
* Fix production script to detect git remotes before attempting branch detection
* Add automatic update of MASTODON_VERSION_METADATA and GITHUB_REPOSITORY in both scripts
* Remove search index prompts from production script, add as optional recommendations instead
* Fix production script to use restart instead of stop/start to minimize downtime

### 1.0.1: 2025-08-30

* Split environment configuration into development and production files following Mastodon conventions
* Add version headers to scripts
* Add mastodon-bird-ui-update.sh script

### 1.0.0: 2025-08-30

* Release 1.0.0
