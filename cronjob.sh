#!/bin/bash
set -e

#load environment variables from deploy-config.sh
ENV_FILE="$(dirname "$0")/deploy-config.sh"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[FATAL] deploy-config.sh not found" >&2
    exit 1
fi
# Timestamp for this Deployment-phase
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
DEPLOYMENT_LOGFILE="$HOME_DIR/logs/deploy-$TIMESTAMP.log"
STATUS_LOGFILE="$HOME_DIR/logs/deploy.log"
LOCKFILE="$HOME_DIR/.deploy.lock"
LAST_COMMIT_FILE="$HOME_DIR/.last-deployed-commit"

# ensure Logs-folder
mkdir -p "$HOME_DIR/logs"

# functions for different log-types
status_log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRONJOB] $1" >> "$STATUS_LOGFILE"
}

deployment_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEPLOYMENT_LOGFILE"
}

# set Lock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    status_log "ERROR: Another deployment running (lockfile: $LOCKFILE)"
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

# check Git remote (only main branch)
cd /tmp
rm -rf git-check
git clone --depth=1 --branch=main "$REPO" git-check 2>/dev/null || {
    status_log "ERROR: Git clone failed"
    exit 1
}

# recent remote commit
CURRENT_COMMIT=$(cd git-check && git rev-parse HEAD)
CURRENT_COMMIT_SHORT=${CURRENT_COMMIT:0:8}
rm -rf git-check

# last deployed commit
LAST_COMMIT=""
if [ -f "$LAST_COMMIT_FILE" ]; then
    LAST_COMMIT=$(cat "$LAST_COMMIT_FILE")
fi

# check if update is necessary
if [ "$CURRENT_COMMIT" = "$LAST_COMMIT" ]; then
    current_minute=$(date '+%M')
    if [ "$current_minute" = "00" ]; then
        status_log "INFO: No updates on GitLab main branch (checked at $(date))"
    fi
    exit 0
fi

# New commit found -> start deployment
echo "$CURRENT_COMMIT" > "$LAST_COMMIT_FILE"

# initialize status + deployment log
status_log "INFO: New commit detected ($CURRENT_COMMIT_SHORT) - starting deployment"
deployment_log "=== DEPLOYMENT STARTED ==="
deployment_log "Commit: $CURRENT_COMMIT"
deployment_log "Time: $(date)"
deployment_log "Log: $DEPLOYMENT_LOGFILE"
deployment_log "=========================="

# start deployment
if [ ! -f "$HOME_DIR/deploy.sh" ]; then
    status_log "ERROR: Deploy script not found: $HOME_DIR/deploy.sh"
    deployment_log "ERROR: Deploy script not found: $HOME_DIR/deploy.sh"
    exit 1
fi

# execute deployment with detailed logging
deployment_log "Starting deployment script..."
if "$HOME_DIR/deploy.sh" >> "$DEPLOYMENT_LOGFILE" 2>&1; then
    status_log "SUCCESS: Deployment completed for commit $CURRENT_COMMIT_SHORT (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT SUCCESSFUL ==="
else
    exit_code=$?
    status_log "ERROR: Deployment failed for commit $CURRENT_COMMIT_SHORT with exit code $exit_code (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT FAILED (exit code: $exit_code) ==="
    # in case of errors: don't mark last commit as deployed
    echo "$LAST_COMMIT" > "$LAST_COMMIT_FILE"
    exit $exit_code
fi