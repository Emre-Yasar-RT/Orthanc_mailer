#!/usr/bin/env python3
"""
- Uses the WORKING API endpoint for forwarding
- Archives old studies for storage management
"""

import orthanc
import json
import zipfile
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

def LogInfo(msg):
    print(f"[ARCHIVE] {msg}")
    orthanc.LogInfo(f"[ARCHIVE] {msg}")

def LogError(msg):
    print(f"[ARCHIVE ERROR] {msg}")
    orthanc.LogError(f"[ARCHIVE] {msg}")

def LogForward(msg):
    print(f"[FORWARD] {msg}")
    orthanc.LogInfo(f"[FORWARD] {msg}")

# Global configuration
ARCHIVE_AGE_DAYS = 30
ARCHIVE_PATH = "/var/lib/orthanc/archive"

def load_configuration():
    """Load configuration after initialization"""
    global ARCHIVE_AGE_DAYS, ARCHIVE_PATH
    try:
        config = json.loads(orthanc.GetConfiguration())
        ARCHIVE_AGE_DAYS = config.get('ArchiveAfterDays', 30)
        ARCHIVE_PATH = config.get('ArchiveDirectory', '/var/lib/orthanc/archive')
        LogInfo(f"Configuration loaded: Archive after {ARCHIVE_AGE_DAYS} days, Path: {ARCHIVE_PATH}")
        return True
    except Exception as e:
        LogError(f"Could not load configuration: {e}")
        return False

def study_exists(study_id):
    """Check if study exists"""
    try:
        orthanc.RestApiGet(f'/studies/{study_id}')
        return True
    except Exception:
        return False

def forward_study_to_processing(study_id):
    """Forward study using the WORKING API endpoint"""
    try:
        LogForward(f"Forwarding study: {study_id}")
        
        # Verify study exists
        if not study_exists(study_id):
            LogError(f"Study {study_id} does not exist - cannot forward")
            return False
        
        # Use the WORKING endpoint: /modalities/processing/store
        payload = json.dumps({"Resources": [study_id]})
        result = orthanc.RestApiPost('/modalities/processing/store', payload)
        
        # Parse result to check success
        if result:
            result_data = json.loads(result)
            instances_count = result_data.get('InstancesCount', 0)
            failed_count = result_data.get('FailedInstancesCount', 0)
            
            if failed_count == 0 and instances_count > 0:
                LogForward(f"SUCCESS: Study {study_id} forwarded successfully ({instances_count} instances)")
                return True
            else:
                LogError(f"Forwarding failed: {failed_count} failed instances out of {instances_count}")
                return False
        else:
            LogError(f"Empty result from forwarding")
            return False
        
    except Exception as e:
        LogError(f"Failed to forward study {study_id}: {str(e)}")
        return False

def should_archive_study(study_id):
    """Check if study should be archived"""
    try:
        if not study_exists(study_id):
            return False
            
        reception_date_str = orthanc.RestApiGet(f'/studies/{study_id}/metadata/ReceptionDate')
        reception_date_clean = reception_date_str.strip('"')
        
        if '.' in reception_date_clean:
            upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S.%f')
        else:
            upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S')
        
        cutoff_time = datetime.now() - timedelta(days=ARCHIVE_AGE_DAYS)
        should_archive = upload_time < cutoff_time
        
        if should_archive:
            days_old = (datetime.now() - upload_time).days
            LogInfo(f"Study {study_id} ready for archiving: {days_old} days old")
        
        return should_archive
        
    except Exception as e:
        LogError(f"Error checking study age for {study_id}: {str(e)}")
        return False

def archive_study(study_id):
    """Archive study as ZIP file"""
    try:
        study_info = json.loads(orthanc.RestApiGet(f'/studies/{study_id}'))
        patient_id = study_info.get('MainDicomTags', {}).get('PatientID', 'UNKNOWN')
        study_date = study_info.get('MainDicomTags', {}).get('StudyDate', 'UNKNOWN')
        
        LogInfo(f"Archiving study {study_id} (Patient: {patient_id})")
        
        # Create archive directory
        archive_dir = Path(ARCHIVE_PATH)
        archive_dir.mkdir(parents=True, exist_ok=True)
        archive_file = archive_dir / f"{patient_id}_study{study_date}_{study_id}.zip"
        
        if archive_file.exists():
            LogInfo(f"Study {study_id} already archived - deleting from Orthanc")
            orthanc.RestApiDelete(f'/studies/{study_id}')
            return
        
        # Create ZIP with all instances
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            dicom_dir = temp_path / "DICOM"
            dicom_dir.mkdir()
            
            instances = json.loads(orthanc.RestApiGet(f'/studies/{study_id}/instances'))
            LogInfo(f"Archiving {len(instances)} instances for study {study_id}")
            
            for i, instance in enumerate(instances):
                dicom_data = orthanc.RestApiGet(f'/instances/{instance["ID"]}/file')
                dicom_file = dicom_dir / f"IMG_{i:04d}.dcm"
                with open(dicom_file, 'wb') as f:
                    f.write(dicom_data)
            
            # Create ZIP
            with zipfile.ZipFile(archive_file, 'w', zipfile.ZIP_DEFLATED) as zipf:
                for file_path in temp_path.rglob('*'):
                    if file_path.is_file():
                        arcname = file_path.relative_to(temp_path)
                        zipf.write(file_path, arcname)
        
        LogInfo(f"Archive created: {archive_file.name}")
        
        # Delete study from Orthanc
        orthanc.RestApiDelete(f'/studies/{study_id}')
        LogInfo(f"Study {study_id} archived and deleted from Orthanc")
        
    except Exception as e:
        LogError(f"Error archiving {study_id}: {str(e)}")

def OnStableStudy(studyId, tags, metadata):
    """Called when study becomes stable"""
    try:
        LogInfo(f"=== STABLE STUDY DETECTED: {studyId} ===")
        
        # Load configuration
        load_configuration()
        
        # 1. Forward to processing
        forward_success = forward_study_to_processing(studyId)
        
        if forward_success:
            LogInfo(f"Study {studyId} forwarded successfully to orthanc-processing")
        else:
            LogError(f"Failed to forward study {studyId}")
        
        # 2. Check for archiving (independent of forwarding)
        try:
            if study_exists(studyId):
                if should_archive_study(studyId):
                    LogInfo(f"Study {studyId} is old enough for archiving")
                    archive_study(studyId)
                else:
                    LogInfo(f"Study {studyId} not ready for archiving yet (< {ARCHIVE_AGE_DAYS} days old)")
            else:
                LogInfo(f"Study {studyId} no longer exists (processed)")
                
        except Exception as e:
            LogError(f"Error during archiving check for study {studyId}: {e}")
                
    except Exception as e:
        LogError(f"Error in OnStableStudy for {studyId}: {str(e)}")

def OnChange(changeType, level, resource):
    """Callback for Orthanc changes"""
    try:
        if level == orthanc.ResourceType.STUDY and changeType == orthanc.ChangeType.STABLE_STUDY:
            LogInfo(f"OnChange triggered: STABLE_STUDY {resource}")
            OnStableStudy(resource, {}, {})
    except Exception as e:
        LogError(f"Error in OnChange: {str(e)}")

def Initialize():
    """Initialize the plugin"""
    LogInfo("=== INITIALIZING ARCHIVE PLUGIN (CORRECTED VERSION) ===")
    LogInfo("Using WORKING API endpoint: /modalities/processing/store")
    
    try:
        orthanc.RegisterOnChangeCallback(OnChange)
        LogInfo("SUCCESS: OnChange callback registered")
        LogForward("SUCCESS: DICOM Forwarding enabled using working API endpoint")
        LogInfo("=== ARCHIVE PLUGIN INITIALIZATION COMPLETE ===")
    except Exception as e:
        LogError(f"Failed to register OnChange callback: {e}")

# Initialize
LogInfo("=== LOADING CORRECTED ARCHIVE PLUGIN ===")
try:
    Initialize()
except Exception as e:
    LogError(f"Initialization failed: {e}")
    print(f"CRITICAL: Plugin initialization failed: {e}")