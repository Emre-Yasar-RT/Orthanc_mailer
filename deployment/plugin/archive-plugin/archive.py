#!/usr/bin/env python3
"""
Orthanc Archive Plugin - Upload-based archiving
Archives studis X days after upload in Orthanc (not StudyDate)
"""

import orthanc
import json
import zipfile
import tempfile
from datetime import datetime, timedelta
from pathlib import Path

# read configuration from orthanc.json
try:
    config = json.loads(orthanc.GetConfiguration())
    ARCHIVE_AGE_DAYS = config.get('ArchiveAfterDays', 30)
    ARCHIVE_PATH = config.get('ArchiveDirectory', '/var/lib/orthanc/archive')
except:
    # Fallback-values
    ARCHIVE_AGE_DAYS = 30
    ARCHIVE_PATH = "/var/lib/orthanc/archive"

def LogInfo(msg):
    orthanc.LogInfo(f"[ARCHIVE] {msg}")

def LogError(msg):
    orthanc.LogError(f"[ARCHIVE] {msg}")

def should_archive_study(study_id):
    """Checks if study is older than X days in Orthanc (based on upload date)"""
    try:
        # Read upload time from Orthanc metadata
        # ReceptionDate = when the study was received/uploaded in Orthanc
        reception_date_str = orthanc.RestApiGet(f'/studies/{study_id}/metadata/ReceptionDate')
        
        # Orthanc stores the format as "20241115T143022.123456" (with quotes)
        reception_date_clean = reception_date_str.strip('"')
        
        # Format: YYYYMMDDTHHMMSS.ffffff
        if '.' in reception_date_clean:
            upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S.%f')
        else:
            # Fallback if no microseconds
            upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S')
        
        cutoff_time = datetime.now() - timedelta(days=ARCHIVE_AGE_DAYS)
        
        days_in_orthanc = (datetime.now() - upload_time).days
        should_archive = upload_time < cutoff_time
        
        if should_archive:
            LogInfo(f"Study {study_id} ready for archiving: {days_in_orthanc} days in Orthanc (uploaded: {upload_time.strftime('%Y-%m-%d %H:%M')})")
        
        return should_archive
        
    except Exception as e:
        LogError(f"Error checking upload time for study {study_id}: {str(e)}")
        # Fallback: try old method using StudyDate
        try:
            LogInfo(f"Fallback to StudyDate for study {study_id}")
            study_info = json.loads(orthanc.RestApiGet(f'/studies/{study_id}'))
            study_date_str = study_info.get('MainDicomTags', {}).get('StudyDate', '')
            
            if not study_date_str:
                return False
                
            study_date = datetime.strptime(study_date_str, '%Y%m%d')
            cutoff_date = datetime.now() - timedelta(days=ARCHIVE_AGE_DAYS)
            
            return study_date < cutoff_date
            
        except Exception as e2:
            LogError(f"StudyDate fallback also failed for study {study_id}: {str(e2)}")
            return False

def archive_study(study_id):
    """Archives study as DICOMDIR+ZIP and DELETES it from Orthanc"""
    try:
        # Get study info
        study_info = json.loads(orthanc.RestApiGet(f'/studies/{study_id}'))
        patient_id = study_info.get('MainDicomTags', {}).get('PatientID', 'UNKNOWN')
        study_date = study_info.get('MainDicomTags', {}).get('StudyDate', 'UNKNOWN')
        
        # Upload time for better archive naming
        try:
            reception_date_str = orthanc.RestApiGet(f'/studies/{study_id}/metadata/ReceptionDate')
            reception_date_clean = reception_date_str.strip('"')
            if '.' in reception_date_clean:
                upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S.%f')
            else:
                upload_time = datetime.strptime(reception_date_clean, '%Y%m%dT%H%M%S')
            upload_date_str = upload_time.strftime('%Y%m%d')
        except:
            upload_date_str = "UNKNOWN"
        
        # Create archive path
        archive_dir = Path(ARCHIVE_PATH)
        archive_dir.mkdir(parents=True, exist_ok=True)
        
        # Filename with upload date for better sorting
        archive_file = archive_dir / f"{patient_id}_study{study_date}_uploaded{upload_date_str}_{study_id}.zip"
        
        # Check if already archived
        if archive_file.exists():
            LogInfo(f"Study {study_id} already archived - deleting from Orthanc")
            orthanc.RestApiDelete(f'/studies/{study_id}')
            LogInfo(f"Study {study_id} removed from Orthanc (was already archived)")
            return
        
        LogInfo(f"Archiving study {study_id} (PatientID: {patient_id}, StudyDate: {study_date}, Uploaded: {upload_date_str})")
        
        # Temporary directory
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            dicom_dir = temp_path / "DICOM"
            dicom_dir.mkdir()
            
            # Download all instances
            instances = json.loads(orthanc.RestApiGet(f'/studies/{study_id}/instances'))
            
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
            
            # CRITICAL: delete study from Orthanc to free up space
            orthanc.RestApiDelete(f'/studies/{study_id}')
            LogInfo(f"Study {study_id} archived and deleted from Orthanc - space freed")
            
    except Exception as e:
        LogError(f"Error archiving {study_id}: {str(e)}")
        # On error: delete archive if created
        if 'archive_file' in locals() and archive_file.exists():
            archive_file.unlink()
            LogError(f"Corrupt archive deleted: {archive_file.name}")

def OnChange(changeType, level, resource):
    """Callback for Orthanc changes"""
    if level == orthanc.ResourceType.STUDY and changeType == orthanc.ChangeType.STABLE_STUDY:
        if should_archive_study(resource):
            archive_study(resource)

# Register plugin
orthanc.RegisterOnChangeCallback(OnChange)
LogInfo(f"Archive plugin loaded - archives + deletes studies {ARCHIVE_AGE_DAYS} days after upload in Orthanc")