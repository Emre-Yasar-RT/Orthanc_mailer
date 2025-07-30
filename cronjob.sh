#!/bin/bash
set -e

# Load ENV file
ENV_FILE="$(dirname "$0")/deploy.env.sh"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[FATAL] deploy.env.sh not found" >&2
    exit 1
fi

# Timestamp for this deployment run
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
DEPLOYMENT_LOGFILE="$HOME_DIR/logs/deployment/deploy-$TIMESTAMP.log"
STATUS_LOGFILE="$HOME_DIR/logs/deployment/cronjob/deploy.log"
LATEST_LOG="$HOME_DIR/logs/deployment/cronjob/latest.log"
LOCKFILE="$HOME_DIR/.deploy.lock"
LAST_COMMIT_FILE="$HOME_DIR/.last-deployed-commit"

# Ensure log directories exist
mkdir -p "$HOME_DIR/logs/deployment"
mkdir -p "$HOME_DIR/logs/deployment/cronjob"

# Functions for different log types
status_log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRONJOB] $1" >> "$STATUS_LOGFILE"
}

deployment_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEPLOYMENT_LOGFILE"
}

# Set lock
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    status_log "ERROR: Another deployment running (lockfile: $LOCKFILE)"
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

# Check Git remote (main branch only)
cd /tmp
rm -rf git-check
git clone --depth=1 --branch=main "$REPO" git-check 2>/dev/null || {
    status_log "ERROR: Git clone failed"
    exit 1
}

# Current remote commit
CURRENT_COMMIT=$(cd git-check && git rev-parse HEAD)
CURRENT_COMMIT_SHORT=${CURRENT_COMMIT:0:8}
rm -rf git-check

# Last deployed commit
LAST_COMMIT=""
if [ -f "$LAST_COMMIT_FILE" ]; then
    LAST_COMMIT=$(cat "$LAST_COMMIT_FILE")
fi

# Check if update needed
if [ "$CURRENT_COMMIT" = "$LAST_COMMIT" ]; then
    # No changes found - silent exit without logging
    exit 0
fi

# New commit found -> start deployment
echo "$CURRENT_COMMIT" > "$LAST_COMMIT_FILE"

# Initialize status + deployment log
status_log "INFO: New commit detected ($CURRENT_COMMIT_SHORT) - starting deployment"
deployment_log "=== DEPLOYMENT STARTED ==="
deployment_log "Commit: $CURRENT_COMMIT"
deployment_log "Time: $(date)"
deployment_log "Log: $DEPLOYMENT_LOGFILE"
deployment_log "=========================="

# Start deployment
if [ ! -f "$HOME_DIR/deploy.sh" ]; then
    status_log "ERROR: Deploy script not found: $HOME_DIR/deploy.sh"
    deployment_log "ERROR: Deploy script not found: $HOME_DIR/deploy.sh"
    exit 1
fi

# Ensure deploy.sh is executable
if [ ! -x "$HOME_DIR/deploy.sh" ]; then
    chmod +x "$HOME_DIR/deploy.sh"
    status_log "INFO: Made deploy.sh executable"
fi

# IMPROVED DEPLOYMENT LOGGING
deployment_log "Starting deployment script..."
status_log "Executing deployment: $HOME_DIR/deploy.sh"

# Execute deployment with complete logging (capture stdout AND stderr)
if "$HOME_DIR/deploy.sh" >>"$DEPLOYMENT_LOGFILE" 2>&1; then
    # SUCCESS
    status_log "SUCCESS: Deployment completed for commit $CURRENT_COMMIT_SHORT (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT SUCCESSFUL ==="
    
    # Create latest.log symlink for easy access
    ln -sf "$DEPLOYMENT_LOGFILE" "$LATEST_LOG"
    status_log "Latest log available at: $LATEST_LOG"
    
    # Log summary to status log
    echo "LAST_SUCCESS=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATUS_LOGFILE"
    echo "LAST_COMMIT=$CURRENT_COMMIT_SHORT" >> "$STATUS_LOGFILE"
    echo "LAST_LOG=deploy-$TIMESTAMP.log" >> "$STATUS_LOGFILE"
    
    # ADDITIONAL: Create log summary
    status_log "Deployment summary:"
    if grep -q "DEPLOYMENT.*COMPLETED" "$DEPLOYMENT_LOGFILE"; then
        status_log "  - Deployment setup completed"
    fi
    if grep -q "Container Status:" "$DEPLOYMENT_LOGFILE"; then
        status_log "  - Containers started successfully"
    fi
    
else
    # FAILURE
    exit_code=$?
    status_log "ERROR: Deployment failed for commit $CURRENT_COMMIT_SHORT with exit code $exit_code (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT FAILED (exit code: $exit_code) ==="
    
    # Create latest.log symlink even for failures
    ln -sf "$DEPLOYMENT_LOGFILE" "$LATEST_LOG"
    status_log "Failure log available at: $LATEST_LOG"
    
    # ADDITIONAL: Extract error details
    if grep -q "ERROR" "$DEPLOYMENT_LOGFILE"; then
        last_error=$(grep "ERROR" "$DEPLOYMENT_LOGFILE" | tail -1)
        status_log "Last error: $last_error"
    fi
    
    # Log failure to status log
    echo "LAST_FAILURE=$(date '+%Y-%m-%d %H:%M:%S')" >> "$STATUS_LOGFILE"
    echo "LAST_ERROR_CODE=$exit_code" >> "$STATUS_LOGFILE"
    echo "LAST_LOG=deploy-$TIMESTAMP.log" >> "$STATUS_LOGFILE"
    
    # On error: don't mark last commit as deployed
    echo "$LAST_COMMIT" > "$LAST_COMMIT_FILE"
    exit $exit_code
fi