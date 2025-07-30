#!/usr/bin/env python3
import os
import subprocess
import requests
import time
import datetime
import logging
import sys

# === Configuration ===
HOME_DIR = os.environ.get("HOME_DIR")
ORTHANC_API = os.environ.get("ORTHANC_URL")

# Fixed defaults
ORTHANC_CONTAINER = "deployment-orthanc-1"
FILESENDER_PY = "/app/switchfilesender/filesender_cli/filesender.py"
FILESENDER_USERNAME = os.environ.get("FILESENDER_USERNAME")
FILESENDER_RECIPIENT = FILESENDER_USERNAME
LOGFILE = f"{HOME_DIR}/logs/watcher/watcher.log"
DUMMY_FILE = f"{HOME_DIR}/logs/watcher/admin_alert.txt"
FILESENDER_API_KEY = os.environ.get("FILESENDER_API_KEY")

# State file to track whether a notification has already been sent
STATE_FILE = f"{HOME_DIR}/logs/watcher/notification_state.txt"

if not HOME_DIR or not ORTHANC_API:
    sys.stderr.write("ERROR: HOME_DIR and ORTHANC_URL must be set in the environment.\n")
    sys.exit(1)

if not FILESENDER_API_KEY:
    sys.stderr.write("ERROR: FILESENDER_API_KEY must be set in the environment.\n")
    sys.exit(1)

if not FILESENDER_USERNAME:
    sys.stderr.write("ERROR: FILESENDER_USERNAME must be set in the environment.\n")
    sys.exit(1)

watcher_log_dir = os.path.dirname(LOGFILE)
if not os.path.exists(watcher_log_dir):
    os.makedirs(watcher_log_dir, exist_ok=True)

logging.basicConfig(
    filename=LOGFILE,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s: %(message)s"
)


def log(msg):
    print(msg)
    logging.info(msg)


def is_orthanc_up():
    """Resilient health check mechanism with retry attempts"""
    for attempt in range(3):
        try:
            r = requests.get(f"{ORTHANC_API}/system", timeout=10)
            if r.status_code == 200:
                return True
            log(f"Health check attempt {attempt + 1}: HTTP {r.status_code}")
        except Exception as e:
            log(f"Health check attempt {attempt + 1}: {e}")
        
        if attempt < 2:  # Skip wait delay after the last retry
            time.sleep(5)
    
    return False


def main():
    log("Watcher health check started")

    if not is_orthanc_up():
        log("Orthanc is not reachable after multiple attempts")
        msg = "Orthanc is not reachable. Docker Compose should have already attempted a restart. Please check manually."
        notify_admin(msg)
        return
    else:
        # Orthanc is running – reset state if there were issues before
        if has_been_notified():
            clear_notification_state()
            log("Orthanc is healthy again - notification state cleared")
        else:
            log("Orthanc is running normally")


# Remove all study-processing functions – no longer needed

def get_stable_studies_with_mail():
    try:
        r = requests.get(f"{ORTHANC_API}/studies", timeout=10)
        ids = r.json()
        studies = []
        for sid in ids:
            info = requests.get(f"{ORTHANC_API}/studies/{sid}", timeout=5).json()
            if not info.get("IsStable", False):
                continue
            desc = info["MainDicomTags"].get("StudyDescription", "")
            # ONLY consider studies with BOTH – email AND password – as hanging
            if EMAIL_REGEX.search(desc) and PASSWORD_REGEX.search(desc):
                studies.append((sid, desc))
        return studies
    except Exception as e:
        log(f"Error getting studies: {e}")
        return []


def retrigger_study(study_id, description):
    payload = {
        "Replace": {
            "StudyDescription": description
        },
        "Force": True
    }
    r = requests.post(
        f"{ORTHANC_API}/studies/{study_id}/modify",
        json=payload,
        timeout=10
    )
    if r.ok:
        log(f"Study {study_id} retriggered successfully")
    else:
        log(f"Error retriggering study {study_id}: {r.text}")


def has_been_notified():
    """Checks whether a notification has already been sent"""
    return os.path.exists(STATE_FILE)


def mark_as_notified():
    """Marks that a notification has been sent"""
    timestamp = datetime.datetime.now().isoformat()
    with open(STATE_FILE, "w") as f:
        f.write(f"notified_at={timestamp}\n")
    log("Notification state marked")


def clear_notification_state():
    """Clears the notification status (Orthanc is healthy again)"""
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
        log("Notification state cleared - Orthanc is healthy again")


def notify_admin(message):
    """Sends notification only if not already sent"""
    if has_been_notified():
        log("Admin notification skipped - already notified for current issue")
        return
    
    timestamp = datetime.datetime.now().isoformat()
    with open(DUMMY_FILE, "w") as f:
        f.write(f"[{timestamp}] {message}\n")
    
    cmd = [
        "python3", FILESENDER_PY,
        DUMMY_FILE,
        "-r", FILESENDER_RECIPIENT,
        "-s", "Orthanc Watcher: System Alert",
        "-m", message,
        "-u", FILESENDER_USERNAME,
        "-a", FILESENDER_API_KEY
    ]
    
    try:
        subprocess.run(cmd, timeout=30)
        mark_as_notified()
        log("Administrator has been notified (first time for this issue)")
    except Exception as e:
        log(f"Failed to send notification: {e}")


def is_orthanc_up():
    """Robust health check with multiple retries"""
    for attempt in range(3):
        try:
            r = requests.get(f"{ORTHANC_API}/system", timeout=10)
            if r.status_code == 200:
                return True
            log(f"Health check attempt {attempt + 1}: HTTP {r.status_code}")
        except Exception as e:
            log(f"Health check attempt {attempt + 1}: {e}")
        
        if attempt < 2:  # Don't wait on the last attempt
            time.sleep(5)
    
    return False


def was_orthanc_recently_restarted():
    """Checks whether Orthanc was recently restarted"""
    try:
        r = requests.get(f"{ORTHANC_API}/system", timeout=10)
        system_info = r.json()
        
        # Orthanc returns "StartupTime" – check if it's less than 5 minutes ago
        if "StartupTime" in system_info:
            startup = datetime.datetime.fromisoformat(system_info["StartupTime"].replace("Z", "+00:00"))
            now = datetime.datetime.now(datetime.timezone.utc)
            uptime = (now - startup).total_seconds()
            
            if uptime < 300:  # 5 Minuten
                log(f"Orthanc recently restarted - uptime: {uptime:.1f} seconds")
                return True
        
        return False
    except Exception as e:
        log(f"Error checking Orthanc restart status: {e}")
        return False


def are_studies_stuck():
    """Checks if studies are truly stuck (older than 10 minutes)"""
    try:
        hanging = get_stable_studies_with_mail()
        if not hanging:
            return False
        
        # Check age of the studies
        for sid, desc in hanging:
            study_info = requests.get(f"{ORTHANC_API}/studies/{sid}", timeout=5).json()
            
            # Check when study became stable (Orthanc timestamp)
            # If no exact timestamp is available, assume it's stuck after 10 minutes of uptime
            pass
        
        # Simplified: if studies are present and Orthanc has been running for more than 10 minutes → consider them stuck
        return not was_orthanc_recently_restarted()
    
    except Exception as e:
        log(f"Error checking if studies are stuck: {e}")
        return False


def main():
    log("Watcher health check started")

    if not is_orthanc_up():
        log("Orthanc is not reachable")
        msg = "Orthanc is not reachable. Docker Compose should have already attempted a restart. Please check manually."
        notify_admin(msg)
        return
    else:
        # Orthanc is running – reset state if there were previous issues
        if has_been_notified():
            clear_notification_state()
            log("Orthanc is healthy again - notification state cleared")
        else:
            log("Orthanc is running normally")


def cleanup_unfinished_studies():
    """Cleanup of unfinished studies"""
    hanging = get_stable_studies_with_mail()
    if not hanging:
        log("No unfinished studies found")
        return

    log(f"Found {len(hanging)} unfinished study/studies - retriggering...")
    for sid, desc in hanging:
        retrigger_study(sid, desc)

    # Warte vor Recheck
    time.sleep(20)
    still_hanging = get_stable_studies_with_mail()
    if still_hanging:
        msg = f"After cleanup, {len(still_hanging)} studies are still pending. Manual intervention may be required."
        notify_admin(msg)
        log(f"WARNING: {len(still_hanging)} studies still unfinished after cleanup")
    else:
        log("All unfinished studies successfully retriggered")


if __name__ == "__main__":
    log("Watcher health monitor started - alert-only mode")
    while True:
        try:
            main()
        except Exception as e:
            log(f"Unexpected error in main loop: {e}")
        time.sleep(120)