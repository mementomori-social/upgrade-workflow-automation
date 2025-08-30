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
