#!/bin/bash
set -e

# ENV-Datei laden
ENV_FILE="$(dirname "$0")/deploy-config.sh"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[FATAL] deploy-config.sh not found" >&2
    exit 1
fi

# Timestamp für diesen Deployment-Lauf
TIMESTAMP=$(date '+%Y%m%d-%H%M%S')
DEPLOYMENT_LOGFILE="$HOME_DIR/logs/deploy-$TIMESTAMP.log"
STATUS_LOGFILE="$HOME_DIR/logs/deploy.log"
LOCKFILE="$HOME_DIR/.deploy.lock"
LAST_COMMIT_FILE="$HOME_DIR/.last-deployed-commit"

# Logs-Verzeichnis sicherstellen
mkdir -p "$HOME_DIR/logs"

# Funktionen für verschiedene Log-Arten
status_log() { 
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CRONJOB] $1" >> "$STATUS_LOGFILE"
}

deployment_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$DEPLOYMENT_LOGFILE"
}

# Lock setzen
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    status_log "ERROR: Another deployment running (lockfile: $LOCKFILE)"
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

# Git remote prüfen (nur main branch)
cd /tmp
rm -rf git-check
git clone --depth=1 --branch=main "$REPO" git-check 2>/dev/null || {
    status_log "ERROR: Git clone failed"
    exit 1
}

# Aktueller remote commit
CURRENT_COMMIT=$(cd git-check && git rev-parse HEAD)
CURRENT_COMMIT_SHORT=${CURRENT_COMMIT:0:8}
rm -rf git-check

# Letzter deployed commit
LAST_COMMIT=""
if [ -f "$LAST_COMMIT_FILE" ]; then
    LAST_COMMIT=$(cat "$LAST_COMMIT_FILE")
fi

# Prüfen ob Update nötig
if [ "$CURRENT_COMMIT" = "$LAST_COMMIT" ]; then
    current_minute=$(date '+%M')
    if [ "$current_minute" = "00" ]; then
        status_log "INFO: No updates on GitLab main branch (checked at $(date))"
    fi
    exit 0
fi

# Neuer Commit gefunden -> Deployment starten
echo "$CURRENT_COMMIT" > "$LAST_COMMIT_FILE"

# Status + Deployment Log initialisieren
status_log "INFO: New commit detected ($CURRENT_COMMIT_SHORT) - starting deployment"
deployment_log "=== DEPLOYMENT STARTED ==="
deployment_log "Commit: $CURRENT_COMMIT"
deployment_log "Time: $(date)"
deployment_log "Log: $DEPLOYMENT_LOGFILE"
deployment_log "=========================="

# Deployment starten
if [ ! -f "$HOME_DIR/deploy-config.sh" ]; then
    status_log "ERROR: Deploy script not found: $HOME_DIR/deploy-config.sh"
    deployment_log "ERROR: Deploy script not found: $HOME_DIR/deploy-config.sh"
    exit 1
fi

# Deployment ausführen mit detailliertem Logging
deployment_log "Starting deployment script..."
if "$HOME_DIR/deploy-config.sh" >> "$DEPLOYMENT_LOGFILE" 2>&1; then
    status_log "SUCCESS: Deployment completed for commit $CURRENT_COMMIT_SHORT (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT SUCCESSFUL ==="
else
    exit_code=$?
    status_log "ERROR: Deployment failed for commit $CURRENT_COMMIT_SHORT with exit code $exit_code (log: deploy-$TIMESTAMP.log)"
    deployment_log "=== DEPLOYMENT FAILED (exit code: $exit_code) ==="
    # Bei Fehler: Last commit nicht als deployed markieren
    echo "$LAST_COMMIT" > "$LAST_COMMIT_FILE"
    exit $exit_code
fi