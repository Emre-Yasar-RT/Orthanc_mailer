#!/bin/bash

# ============================
# USER KONFIGURATION
# ============================
export HOME_DIR="path/to/location"
export REPO="git@github.com:Emre-Yasar-RT/Orthanc_mailer.git"
export SERVER_HOSTNAME="#SERVERNAME"

export HTTP_PORT="8042"
export DICOM_PORT="11112"
export DICOM_AET="ORTHANC"
export LOG_LEVEL="Debug"
export ARCHIVE_AGE_DAYS="30"

export DICOM_MODALITY_1_NAME="modality1"
export DICOM_MODALITY_1_AET="MODALITY_1"
export DICOM_MODALITY_1_HOST="#domain_or_IP"
export DICOM_MODALITY_1_PORT="11112"

export DICOM_MODALITY_2_NAME="3d-slicer"
export DICOM_MODALITY_2_AET="3D_SLICER"
export DICOM_MODALITY_2_HOST="#domain_or_IP"
export DICOM_MODALITY_2_PORT="11112"

export FILESENDER_USERNAME="your_Switch_Email"
export FILESENDER_API_KEY="secret_API"

# ============================
# TRIGGER DEPLOYMENT
# ============================

REQUIRED_VARS=(HOME_DIR REPO HTTP_PORT DICOM_PORT DICOM_AET LOG_LEVEL ARCHIVE_AGE_DAYS FILESENDER_USERNAME FILESENDER_API_KEY)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "[ERROR] Environment variable $var is missing – verify deploy.env.sh configuration"
        exit 1
    fi
done

# Execute only when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_PATH="$(dirname "$(realpath "$0")")/deploy.sh"
    echo "[INFO] Starting Deployment over $SCRIPT_PATH"
    bash "$SCRIPT_PATH"
fi
