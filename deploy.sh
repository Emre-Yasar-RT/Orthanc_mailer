#!/bin/bash
set -e

# =============================================================================
# LOAD USER CONFIGURATION
# =============================================================================

ENV_FILE="$(dirname "$0")/deploy.env.sh"

if [ -f "$ENV_FILE" ]; then
    echo "[INFO] Loading configuration from $ENV_FILE"
    set -a
    source "$ENV_FILE"
    set +a
    echo "[INFO] Configuration loaded from $ENV_FILE"
    
    # Debug: Verify key variables are loaded
    echo "[DEBUG] After loading deploy.env.sh:"
    echo "[DEBUG] HTTP_PORT=$HTTP_PORT"
    echo "[DEBUG] DICOM_PORT=$DICOM_PORT"
    echo "[DEBUG] HOME_DIR=$HOME_DIR"
else
    echo "[ERROR] $ENV_FILE not found - deployment aborted"
    exit 1
fi

# =============================================================================
# AUTOMATIC USER/GROUP DETECTION
# =============================================================================

echo "[INFO] Auto-detecting deployment user and group..."

# Automatically detect current user and group
DEPLOY_USER=$(whoami)
DEPLOY_GROUP=$(id -gn)

echo "[INFO] Deployment will run as: $DEPLOY_USER:$DEPLOY_GROUP"

# Export for other scripts and Docker
export DEPLOY_USER
export DEPLOY_GROUP

# Helper functions for safe ownership
safe_chown() {
    local target="$1"
    if [ -e "$target" ]; then
        chown "$DEPLOY_USER:$DEPLOY_GROUP" "$target"
    fi
}

set_directory_ownership() {
    local dir="$1"
    if [ -d "$dir" ]; then
        chown -R "$DEPLOY_USER:$DEPLOY_GROUP" "$dir"
    fi
}

# =============================================================================
# DERIVED PATHS AND EXPORTS
# =============================================================================
export BASE_PATH="$HOME_DIR"
export DEPLOYMENT_PATH="$HOME_DIR/deployment"
export HOST_EXPORTS_PATH="$DEPLOYMENT_PATH/exports"
export HOST_MAILQUEUE_PATH="$HOME_DIR/mailqueue"
export HOST_HTTP_PORT="$HTTP_PORT"
export HOST_DICOM_PORT="$DICOM_PORT"
export BUILD_PLUGIN="true"
export ORTHANC_URL="http://$SERVER_HOSTNAME:$HTTP_PORT"

# Ensure all variables are properly exported for docker-compose
export HTTP_PORT
export DICOM_PORT
export DICOM_AET
export LOG_LEVEL
export ARCHIVE_AGE_DAYS
export SERVER_HOSTNAME
export HOME_DIR
export FILESENDER_USERNAME
export FILESENDER_API_KEY
export DICOM_MODALITY_1_NAME
export DICOM_MODALITY_1_AET
export DICOM_MODALITY_1_HOST
export DICOM_MODALITY_1_PORT
export DICOM_MODALITY_2_NAME
export DICOM_MODALITY_2_AET
export DICOM_MODALITY_2_HOST
export DICOM_MODALITY_2_PORT

TMP_CLONE="$HOME_DIR/tmp-clone"
DEPLOY_DIR="$HOME_DIR/deployment"

echo "[INFO] Starting DUAL-ORTHANC deployment..."

# =============================================================================
# STOP DOCKER CONTAINERS FIRST (BEFORE DELETING FILES)
# =============================================================================
echo "[INFO] Stopping existing Orthanc containers before file operations..."

if [ -d "$DEPLOY_DIR" ] && [ -f "$DEPLOY_DIR/docker-compose.yml" ]; then
    cd "$DEPLOY_DIR"
    
    # Source existing .env if available
    if [ -f ".env" ]; then
        set -a
        source .env
        set +a
        echo "[INFO] Existing environment variables loaded for container shutdown"
    fi
    
    # Stop containers to release file locks
    docker compose down --remove-orphans || echo "[WARNING] No containers to stop"
    
    # Wait for complete shutdown
    echo "[INFO] Waiting for containers to fully shut down..."
    sleep 3
    
    cd "$HOME_DIR"
else
    echo "[INFO] No existing deployment found"
fi

# =============================================================================
# NOW SAFE TO DELETE AND RECREATE DEPLOYMENT
# =============================================================================

# Clone repository
rm -rf "$TMP_CLONE"
git clone "$REPO" "$TMP_CLONE" || { echo "[ERROR] Git clone failed"; exit 1; }

# Copy deployment/ - now that containers are stopped
echo "[INFO] Removing old deployment directory..."
chmod -R u+w "$DEPLOY_DIR/" 2>/dev/null || true
rm -rf "$DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"

echo "[INFO] Copying new deployment files..."
rsync -av "$TMP_CLONE/deployment/" "$DEPLOY_DIR/"
bash "$DEPLOY_DIR/plugin/build-plugin.sh"

# Copy log_monitor.sh
LOG_MONITOR_SCRIPT="$HOME_DIR/log_monitor.sh"
if [ -f "$TMP_CLONE/log_monitor.sh" ]; then
    cp "$TMP_CLONE/log_monitor.sh" "$LOG_MONITOR_SCRIPT"
    chmod +x "$LOG_MONITOR_SCRIPT"
    safe_chown "$LOG_MONITOR_SCRIPT"
    echo "[INFO] Log monitoring script installed: $LOG_MONITOR_SCRIPT"
fi

# =============================================================================
# CRONJOB HANDLING (KORRIGIERT)
# =============================================================================
echo "[INFO] Setting up cronjob functionality..."

# Copy cronjob script if it exists
CRON_SCRIPT="$HOME_DIR/cronjob.sh"
if [ -f "$TMP_CLONE/cronjob.sh" ]; then
    cp "$TMP_CLONE/cronjob.sh" "$CRON_SCRIPT"
    chmod +x "$CRON_SCRIPT"
    safe_chown "$CRON_SCRIPT"
    echo "[INFO] Cronjob script installed: $CRON_SCRIPT"
else
    echo "[WARNING] cronjob.sh not found in repository"
fi

# Create cronjob log directory
mkdir -p "$HOME_DIR/logs/deployment/cronjob"
chmod 755 "$HOME_DIR/logs/deployment/cronjob"
echo "[INFO] Cronjob log directory created: $HOME_DIR/logs/deployment/cronjob"

# Install cronjob if script exists
if [ -f "$CRON_SCRIPT" ]; then
    # Remove existing cronjob entries for this script
    crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" | crontab - || true
    
    # Add new cronjob entry: every 10 minutes (for immediate deployment detection)
    (crontab -l 2>/dev/null; echo "*/10 * * * * $CRON_SCRIPT >> $HOME_DIR/logs/deployment/cronjob/cronjob.log 2>&1") | crontab -
    echo "[INFO] Cronjob installed: every 10 minutes for automatic deployment"
    echo "[INFO] Cronjob logs: $HOME_DIR/logs/deployment/cronjob/cronjob.log"
else
    echo "[WARNING] Cronjob script not found - skipping cronjob installation"
fi

# =============================================================================
# DUAL ORTHANC LOG STRUCTURE
# =============================================================================
echo "[INFO] Creating DUAL-ORTHANC log directory structure..."
mkdir -p "$HOME_DIR/archive" 
mkdir -p "$HOME_DIR/logs/deployment"
mkdir -p "$HOME_DIR/logs/deployment/cronjob"  # RESTORED
mkdir -p "$HOME_DIR/logs/filesender" 
mkdir -p "$HOME_DIR/logs/orthanc"
mkdir -p "$HOME_DIR/var/lib/orthanc-ingest/storage"
mkdir -p "$HOME_DIR/var/lib/orthanc-ingest/index"
mkdir -p "$HOME_DIR/var/lib/orthanc-ingest/archive"
mkdir -p "$HOME_DIR/var/log/orthanc-ingest"
mkdir -p "$HOME_DIR/var/log/orthanc-processing"

chmod 755 "$HOME_DIR/archive" "$HOME_DIR/logs" "$HOME_DIR/logs/deployment" "$HOME_DIR/logs/deployment/cronjob" "$HOME_DIR/logs/filesender" "$HOME_DIR/logs/orthanc"
chmod 755 "$HOME_DIR/var/lib/orthanc-ingest/storage" "$HOME_DIR/var/lib/orthanc-ingest/index" "$HOME_DIR/var/lib/orthanc-ingest/archive"
chmod 755 "$HOME_DIR/var/log/orthanc-ingest" "$HOME_DIR/var/log/orthanc-processing"

echo "[INFO] DUAL-ORTHANC directories created:"
echo "  - $HOME_DIR/var/lib/orthanc-ingest/  (persistent PACS storage)"
echo "  - $HOME_DIR/var/log/orthanc-ingest/  (ingest logs)"
echo "  - $HOME_DIR/var/log/orthanc-processing/  (processing logs)"
echo "  - $HOME_DIR/logs/deployment/cronjob/  (cronjob logs)"

# =============================================================================
# GENERATE DUAL ORTHANC CONFIGURATION FILES
# =============================================================================

echo "[INFO] Generating DUAL-ORTHANC configuration files..."

# Generate orthanc-ingest.json from template
ORTHANC_INGEST_TEMPLATE="$TMP_CLONE/deployment/orthanc-ingest.json.template"
ORTHANC_INGEST_TARGET="$DEPLOY_DIR/orthanc-ingest.json"

if [ -f "$ORTHANC_INGEST_TEMPLATE" ]; then
    sed -e "s|{{HTTP_PORT}}|$HTTP_PORT|g" \
        -e "s|{{DICOM_PORT}}|$DICOM_PORT|g" \
        -e "s|{{DICOM_AET}}|$DICOM_AET|g" \
        -e "s|{{LOG_LEVEL}}|$LOG_LEVEL|g" \
        -e "s|{{ARCHIVE_AGE_DAYS}}|$ARCHIVE_AGE_DAYS|g" \
        -e "s|{{DICOM_MODALITY_1_NAME}}|$DICOM_MODALITY_1_NAME|g" \
        -e "s|{{DICOM_MODALITY_1_AET}}|$DICOM_MODALITY_1_AET|g" \
        -e "s|{{DICOM_MODALITY_1_HOST}}|$DICOM_MODALITY_1_HOST|g" \
        -e "s|{{DICOM_MODALITY_1_PORT}}|$DICOM_MODALITY_1_PORT|g" \
        -e "s|{{DICOM_MODALITY_2_NAME}}|$DICOM_MODALITY_2_NAME|g" \
        -e "s|{{DICOM_MODALITY_2_AET}}|$DICOM_MODALITY_2_AET|g" \
        -e "s|{{DICOM_MODALITY_2_HOST}}|$DICOM_MODALITY_2_HOST|g" \
        -e "s|{{DICOM_MODALITY_2_PORT}}|$DICOM_MODALITY_2_PORT|g" \
        "$ORTHANC_INGEST_TEMPLATE" > "$ORTHANC_INGEST_TARGET"
    echo "[INFO] orthanc-ingest.json successfully created"
else
    echo "[ERROR] orthanc-ingest.json.template not found: $ORTHANC_INGEST_TEMPLATE"
    exit 1
fi

# Generate orthanc-processing.json from template
ORTHANC_PROCESSING_TEMPLATE="$TMP_CLONE/deployment/orthanc-processing.json.template"
ORTHANC_PROCESSING_TARGET="$DEPLOY_DIR/orthanc-processing.json"

if [ -f "$ORTHANC_PROCESSING_TEMPLATE" ]; then
    sed -e "s|{{HTTP_PORT}}|$HTTP_PORT|g" \
        -e "s|{{DICOM_PORT}}|$DICOM_PORT|g" \
        -e "s|{{DICOM_AET}}|$DICOM_AET|g" \
        -e "s|{{LOG_LEVEL}}|$LOG_LEVEL|g" \
        -e "s|{{DICOM_MODALITY_1_NAME}}|$DICOM_MODALITY_1_NAME|g" \
        -e "s|{{DICOM_MODALITY_1_AET}}|$DICOM_MODALITY_1_AET|g" \
        -e "s|{{DICOM_MODALITY_1_HOST}}|$DICOM_MODALITY_1_HOST|g" \
        -e "s|{{DICOM_MODALITY_1_PORT}}|$DICOM_MODALITY_1_PORT|g" \
        -e "s|{{DICOM_MODALITY_2_NAME}}|$DICOM_MODALITY_2_NAME|g" \
        -e "s|{{DICOM_MODALITY_2_AET}}|$DICOM_MODALITY_2_AET|g" \
        -e "s|{{DICOM_MODALITY_2_HOST}}|$DICOM_MODALITY_2_HOST|g" \
        -e "s|{{DICOM_MODALITY_2_PORT}}|$DICOM_MODALITY_2_PORT|g" \
        "$ORTHANC_PROCESSING_TEMPLATE" > "$ORTHANC_PROCESSING_TARGET"
    echo "[INFO] orthanc-processing.json successfully created"
else
    echo "[ERROR] orthanc-processing.json.template not found: $ORTHANC_PROCESSING_TEMPLATE"
    exit 1
fi

# Generate .env (adapted for Dual-Orthanc)
ENV_TEMPLATE="$DEPLOY_DIR/.env.template"
ENV_TARGET="$DEPLOY_DIR/.env"

# Always create a .env file with current variables for docker-compose
echo "[INFO] Creating .env file for docker-compose..."
cat > "$ENV_TARGET" << EOF
# Generated .env file for docker-compose
HOME_DIR=$HOME_DIR
REPO=$REPO
SERVER_HOSTNAME=$SERVER_HOSTNAME
HTTP_PORT=$HTTP_PORT
DICOM_PORT=$DICOM_PORT
DICOM_AET=$DICOM_AET
LOG_LEVEL=$LOG_LEVEL
ARCHIVE_AGE_DAYS=$ARCHIVE_AGE_DAYS
ORTHANC_URL=$ORTHANC_URL
DICOM_MODALITY_1_NAME=$DICOM_MODALITY_1_NAME
DICOM_MODALITY_1_AET=$DICOM_MODALITY_1_AET
DICOM_MODALITY_1_HOST=$DICOM_MODALITY_1_HOST
DICOM_MODALITY_1_PORT=$DICOM_MODALITY_1_PORT
DICOM_MODALITY_2_NAME=$DICOM_MODALITY_2_NAME
DICOM_MODALITY_2_AET=$DICOM_MODALITY_2_AET
DICOM_MODALITY_2_HOST=$DICOM_MODALITY_2_HOST
DICOM_MODALITY_2_PORT=$DICOM_MODALITY_2_PORT
FILESENDER_USERNAME=$FILESENDER_USERNAME
FILESENDER_API_KEY=$FILESENDER_API_KEY

# Derived variables
HOST_EXPORTS_PATH=$HOST_EXPORTS_PATH
HOST_MAILQUEUE_PATH=$HOST_MAILQUEUE_PATH
HOST_HTTP_PORT=$HOST_HTTP_PORT
HOST_DICOM_PORT=$HOST_DICOM_PORT
EOF

echo "[INFO] .env file created with current variables"

# If template exists, also process it for additional variables
if [ -f "$ENV_TEMPLATE" ]; then
    echo "[INFO] Processing additional .env template..."
    sed -e "s|{{HOME_DIR}}|$HOME_DIR|g" \
        -e "s|{{REPO}}|$REPO|g" \
        -e "s|{{SERVER_HOSTNAME}}|$SERVER_HOSTNAME|g" \
        -e "s|{{HTTP_PORT}}|$HTTP_PORT|g" \
        -e "s|{{DICOM_PORT}}|$DICOM_PORT|g" \
        -e "s|{{DICOM_AET}}|$DICOM_AET|g" \
        -e "s|{{LOG_LEVEL}}|$LOG_LEVEL|g" \
        -e "s|{{ARCHIVE_AGE_DAYS}}|$ARCHIVE_AGE_DAYS|g" \
        -e "s|{{ORTHANC_URL}}|$ORTHANC_URL|g" \
        -e "s|{{DICOM_MODALITY_1_NAME}}|$DICOM_MODALITY_1_NAME|g" \
        -e "s|{{DICOM_MODALITY_1_AET}}|$DICOM_MODALITY_1_AET|g" \
        -e "s|{{DICOM_MODALITY_1_HOST}}|$DICOM_MODALITY_1_HOST|g" \
        -e "s|{{DICOM_MODALITY_1_PORT}}|$DICOM_MODALITY_1_PORT|g" \
        -e "s|{{DICOM_MODALITY_2_NAME}}|$DICOM_MODALITY_2_NAME|g" \
        -e "s|{{DICOM_MODALITY_2_AET}}|$DICOM_MODALITY_2_AET|g" \
        -e "s|{{DICOM_MODALITY_2_HOST}}|$DICOM_MODALITY_2_HOST|g" \
        -e "s|{{DICOM_MODALITY_2_PORT}}|$DICOM_MODALITY_2_PORT|g" \
        -e "s|{{FILESENDER_USERNAME}}|$FILESENDER_USERNAME|g" \
        -e "s|{{FILESENDER_API_KEY}}|$FILESENDER_API_KEY|g" \
        "$ENV_TEMPLATE" >> "$ENV_TARGET"
    echo "[INFO] .env template processed and appended"
elif [ -f "$TMP_CLONE/.env" ]; then
    cat "$TMP_CLONE/.env" >> "$ENV_TARGET"
    echo "[INFO] Repository .env appended"
fi

rm -rf "$TMP_CLONE"

if grep -q "{{" "$ENV_TARGET" 2>/dev/null; then
    echo "[WARNING] Some placeholders in .env were not replaced:"
    grep "{{" "$ENV_TARGET"
else
    echo "[INFO] All variables in .env successfully replaced"
fi

# ===============================================================================
# START DUAL ORTHANC CONTAINERS
# ===============================================================================

echo "[INFO] Starting DUAL-ORTHANC deployment..."
cd "$DEPLOY_DIR"

# Ensure all environment variables are available for docker-compose
echo "[INFO] Exporting environment variables for docker-compose..."
export HTTP_PORT DICOM_PORT DICOM_AET LOG_LEVEL ARCHIVE_AGE_DAYS
export SERVER_HOSTNAME HOME_DIR FILESENDER_USERNAME FILESENDER_API_KEY
export DICOM_MODALITY_1_NAME DICOM_MODALITY_1_AET DICOM_MODALITY_1_HOST DICOM_MODALITY_1_PORT
export DICOM_MODALITY_2_NAME DICOM_MODALITY_2_AET DICOM_MODALITY_2_HOST DICOM_MODALITY_2_PORT

# Debug: Show key variables
echo "[DEBUG] HTTP_PORT=$HTTP_PORT"
echo "[DEBUG] DICOM_PORT=$DICOM_PORT" 
echo "[DEBUG] HOME_DIR=$HOME_DIR"

# Source .env file for docker-compose (if exists)
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
    echo "[INFO] Environment variables loaded for docker-compose"
fi

echo "[INFO] Starting DUAL-ORTHANC with new plugins..."
# Start with build to ensure latest images
docker compose up -d --build

# =============================================================================
# enhanced logging
# =============================================================================

echo "[INFO] Waiting for DUAL-ORTHANC to initialize..."

# HEALTH CHECK
HEALTH_CHECK_ATTEMPTS=10
HEALTH_CHECK_DELAY=5
ORTHANC_READY=false

for i in $(seq 1 $HEALTH_CHECK_ATTEMPTS); do
    echo "[INFO] Health check attempt $i/$HEALTH_CHECK_ATTEMPTS..."
    
    if curl -s --max-time 5 "http://localhost:$HTTP_PORT/app/explorer.html" > /dev/null && \
       curl -s --max-time 5 "http://localhost:$HTTP_PORT/statistics" > /dev/null; then
        echo "[INFO] Orthanc is responding on HTTP port $HTTP_PORT"
        ORTHANC_READY=true
        break
    else
        echo "[INFO] Orthanc not ready yet, waiting ${HEALTH_CHECK_DELAY}s..."
        sleep $HEALTH_CHECK_DELAY
    fi
done

if [ "$ORTHANC_READY" = false ]; then
    echo "[ERROR] Orthanc health check failed after $((HEALTH_CHECK_ATTEMPTS * HEALTH_CHECK_DELAY)) seconds"
    echo "[INFO] Container status:"
    docker compose ps
    echo "[INFO] Recent logs:"
    docker compose logs --tail=20
    exit 1
fi

echo "[INFO] Orthanc deployment completed successfully"
echo "[INFO] Container Status:"
docker compose ps
echo "[INFO] ============================================="
echo "[INFO] DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "[INFO] ============================================="
echo "[INFO] Orthanc Web Interface: http://localhost:$HTTP_PORT"
echo "[INFO] DICOM Port: $DICOM_PORT"
echo "[INFO] Container Logs: docker compose logs -f"
echo "[INFO] FileSender Logs: $HOME_DIR/logs/filesender/filesender.log"
echo "[INFO] Deployment Logs: $HOME_DIR/logs/deployment/"
echo "[INFO] ============================================="

DEPLOYMENT_LOG="$HOME_DIR/logs/deployment/deploy-$(date +%Y%m%d-%H%M%S).log"
echo "$(date): Deployment completed successfully" >> "$DEPLOYMENT_LOG"
echo "  - Orthanc URL: http://localhost:$HTTP_PORT" >> "$DEPLOYMENT_LOG"
echo "  - Containers: $(docker compose ps --format 'table {{.Service}}' | tail -n +2 | tr '\n' ' ')" >> "$DEPLOYMENT_LOG"

# Symlink for easy access
ln -sf "$DEPLOYMENT_LOG" "$HOME_DIR/logs/deployment/latest.log"