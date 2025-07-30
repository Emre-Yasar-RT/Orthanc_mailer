#!/bin/bash
# log_monitor.sh - Einheitliches Log-Monitoring
# Automatically installed by deploy.env.sh

# ENV-Datei laden (genau wie cronjob.sh)
ENV_FILE="$(dirname "$0")/deploy.env.sh"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[FATAL] deploy.env.sh not found" >&2
    exit 1
fi

# QUICK STATUS CHECK
echo "Quick Status:"
if [ -d "$HOME_DIR/logs" ]; then
    total_logs=$(find "$HOME_DIR/logs" -name "*.log" -type f 2>/dev/null | wc -l)
    total_size=$(du -sh "$HOME_DIR/logs/" 2>/dev/null | cut -f1)
    echo "Total log files: $total_logs"
    echo "Total size: $total_size"
else
    echo "Log directory not found: $HOME_DIR/logs"
fi

# CHECK ORTHANC STATUS
if curl -s --max-time 3 "http://localhost/statistics" >/dev/null 2>&1; then
    echo "Orthanc: Running"
else
    echo "Orthanc: Not responding"
fi
echo ""

# MENU for Log Monitoring
echo "Which logs would you like to monitor?"
echo "1) FileSender plugin logs (live)"
echo "2) Docker container logs (live)"
echo "3) Deployment logs (latest)"
echo "4) Show all log files"
echo "5) Log folder size"
echo "6) Log cleanup (delete >30 days old)"
echo "7) Orthanc container status"
echo "8) Clean up log structure"
echo ""

read -p "Selection [1-8]: " choice

case $choice in
    1)
        echo "Monitoring FileSender logs (Ctrl+C to stop)..."
        FILESENDER_LOG="$HOME_DIR/logs/filesender/filesender.log"
        if [ -f "$FILESENDER_LOG" ]; then
            echo "Last 10 lines:"
            tail -10 "$FILESENDER_LOG"
            echo ""
            echo "Live monitoring (Ctrl+C to stop):"
            tail -f "$FILESENDER_LOG"
        else
            echo "FileSender log not found: $FILESENDER_LOG"
        fi
        ;;
    2)
        echo "Monitoring Docker container logs (Ctrl+C to stop)..."
        cd "$HOME_DIR/deployment"
        docker compose logs -f
        ;;
    3)
        echo "Latest deployment logs:"
        
        # Check both locations for backward compatibility
        echo "In ~/logs/deployment/:"
        ls -la "$HOME_DIR/logs/deployment/" 2>/dev/null | tail -10
        
        # Check for misplaced logs in the root log directory
        misplaced_in_root=$(ls "$HOME_DIR/logs"/deploy*.log 2>/dev/null)
        if [ -n "$misplaced_in_root" ]; then
            echo ""
            echo "Misplaced logs found in ~/logs/ (should be in deployment/):"
            ls -la "$HOME_DIR/logs"/deploy*.log 2>/dev/null
        fi
        
        echo ""
        
        # Try to find the most recent deployment log
        latest_deploy_log=""
        
        # First check deployment subdirectory
        if [ -f "$HOME_DIR/logs/deployment/latest.log" ]; then
            latest_deploy_log="$HOME_DIR/logs/deployment/latest.log"
        else
            # Fallback: find the newest deploy log in deployment/
            latest_deploy_log=$(ls -t "$HOME_DIR/logs/deployment"/deploy-*.log 2>/dev/null | head -1)
            
            # Last resort: check root log directory
            if [ -z "$latest_deploy_log" ]; then
                latest_deploy_log=$(ls -t "$HOME_DIR/logs"/deploy-*.log 2>/dev/null | head -1)
            fi
        fi
        
        if [ -n "$latest_deploy_log" ] && [ -f "$latest_deploy_log" ]; then
            echo "Content of the latest deployment log:"
            echo "$(basename "$latest_deploy_log")"
            echo "────────────────────────────────────────"
            cat "$latest_deploy_log"
        else
            echo "No deployment logs found."
            echo "Hint: Run a deployment to generate log files."
        fi
        ;;
    4)
        echo "All available log files:"
        echo ""
        echo "Deployment logs:"
        ls -la "$HOME_DIR/logs/deployment/" 2>/dev/null || echo "   (none found)"
        echo ""
        echo "FileSender logs:"
        ls -la "$HOME_DIR/logs/filesender/" 2>/dev/null || echo "   (none found)"
        echo ""
        echo "Orthanc logs:"
        ls -la "$HOME_DIR/logs/orthanc/" 2>/dev/null || echo "   (none found)"
        echo ""
        echo "Temp upload logs:"
        ls -la /tmp/upload_*.log 2>/dev/null || echo "   (none found)"
        ;;
    5)
        echo "Log folder size:"
        du -h "$HOME_DIR/logs/"* 2>/dev/null | sort -hr
        echo ""
        echo "Total log size:"
        du -sh "$HOME_DIR/logs/" 2>/dev/null
        echo ""
        echo "System disk usage:"
        df -h "$HOME_DIR"
        ;;
    6)
        echo "Log cleanup (files older than 30 days)..."
        echo "Searching for old log files..."
        old_files=$(find "$HOME_DIR/logs/" -name "*.log" -mtime +30 -type f 2>/dev/null)
        if [ -z "$old_files" ]; then
            echo "No old log files found"
        else
            echo "Found old log files:"
            echo "$old_files"
            read -p "Really delete them? [y/N]: " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                find "$HOME_DIR/logs/" -name "*.log" -mtime +30 -type f -print -delete
                echo "Cleanup completed"
            else
                echo "Cleanup aborted"
            fi
        fi
        ;;
    7)
        echo "Orthanc Container Status:"
        cd "$HOME_DIR/deployment"
        echo ""
        echo "Container Status:"
        docker compose ps
        echo ""
        echo "Container Resources:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"
        echo ""
        echo "Recent Container Logs (last 20 lines):"
        docker compose logs --tail=20
        ;;
    8)
        echo "CLEANING UP LOG STRUCTURE..."
        echo ""
        echo "Current structure issues:"
        
        # Check for misplaced logs
        misplaced_logs=()
        for logfile in "$HOME_DIR/logs"/*.log; do
            if [ -f "$logfile" ]; then
                misplaced_logs+=("$(basename "$logfile")")
            fi
        done
        
        if [ ${#misplaced_logs[@]} -gt 0 ]; then
            echo "Misplaced logs found in ~/logs/ (they should be inside subfolders):"
            for log in "${misplaced_logs[@]}"; do
                echo "   - $log"
            done
            echo ""
            read -p "Automatically clean up log structure? [Y/n]: " cleanup_confirm
            if [[ ! $cleanup_confirm =~ ^[Nn]$ ]]; then
                # Move deployment logs
                for logfile in "$HOME_DIR/logs"/deploy*.log; do
                    if [ -f "$logfile" ]; then
                        filename=$(basename "$logfile")
                        echo "Moving: $filename → deployment/"
                        mv "$logfile" "$HOME_DIR/logs/deployment/"
                    fi
                done
                
                # Other common deployment logs
                for logfile in "$HOME_DIR/logs"/{deploy,deployment,build,install,setup}.log; do
                    if [ -f "$logfile" ]; then
                        filename=$(basename "$logfile")
                        echo "Moving: $filename → deployment/"
                        mv "$logfile" "$HOME_DIR/logs/deployment/" 2>/dev/null
                    fi
                done
                
                # Create latest.log symlink
                latest_deploy=$(ls -t "$HOME_DIR/logs/deployment"/deploy-*.log 2>/dev/null | head -1)
                if [ -n "$latest_deploy" ]; then
                    ln -sf "$(basename "$latest_deploy")" "$HOME_DIR/logs/deployment/latest.log"
                    echo "Symlink created: deployment/latest.log"
                fi
                
                echo "Log-structure cleaned!"
            fi
        else
            echo "Log-Structure is already correct!"
        fi
        
        echo ""
        echo "CORRECT LOG-STRUCTURE:"
        echo "~/logs/"
        echo "├── deployment/  (deployment logs)"
        echo "├── filesender/  (plugin logs)"  
        echo "└── orthanc/     (additional logs)"
        ;;
    *)
        echo "Invalid Auswahl"
        exit 1
        ;;
esac