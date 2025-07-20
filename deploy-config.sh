#!/bin/bash

# ============================
# USER CONFIGURATION
# ============================
export HOME_DIR="/home/pacs"
export REPO="git@github.com:Emre-Yasar-RT/Orthanc_mailer.git"

export SERVER_HOSTNAME="test_server.ch"

export HTTP_PORT="80"
export DICOM_PORT="11112"
export DICOM_AET="ORTHANC"
export LOG_LEVEL="Debug"
export ARCHIVE_AGE_DAYS="30"

export DICOM_MODALITY_1_NAME="Test-modality"
export DICOM_MODALITY_1_AET="TEST"
export DICOM_MODALITY_1_HOST="123.123.123.123"
export DICOM_MODALITY_1_PORT="11112"

export DICOM_MODALITY_2_NAME="Test-modality"
export DICOM_MODALITY_2_AET="TEST-MODALITY-2"
export DICOM_MODALITY_2_HOST="123.123.123.123"
export DICOM_MODALITY_2_PORT="11112"

export FILESENDER_USERNAME="example@hotmail.com"
export FILESENDER_API_KEY="123abcdefgh123"

# ============================
# TRIGGER DEPLOYMENT
# ============================

REQUIRED_VARS=(HOME_DIR REPO HTTP_PORT DICOM_PORT DICOM_AET LOG_LEVEL ARCHIVE_AGE_DAYS FILESENDER_USERNAME FILESENDER_API_KEY)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "[ERROR] Environment variable $var is not set – please check deploy-config.sh"
        exit 1
    fi
done

# Start deployment if directly called, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_PATH="$(dirname "$(realpath "$0")")/deploy.yml"
    echo "[INFO] Starting Ansible deployment via $SCRIPT_PATH"
    
    # Pass all environment variables to Ansible
    ansible-playbook "$SCRIPT_PATH" \
        --inventory localhost, \
        --connection local \
        --become
fi