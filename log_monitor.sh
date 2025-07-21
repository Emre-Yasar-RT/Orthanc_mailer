#!/bin/bash
# log_monitor.sh - unified log-monitoring
# Automatically installed by deploy-config.sh

# ENV-Datei laden (genau wie cronjob.sh)
ENV_FILE="$(dirname "$0")/deploy-config.sh"
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
else
    echo "[FATAL] deploy-config.sh not found" >&2
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

# MENU für Log-Überwachung
echo "Welche Logs möchten Sie überwachen?"
echo "1) FileSender Plugin Logs (live)"
echo "2) Docker Container Logs (live)"
echo "3) Deployment Logs (latest)"
echo "4) Alle Log-Dateien anzeigen"
echo "5) Log-Ordner-Größe"
echo "6) Log-Cleanup (>30 Tage löschen)"
echo "7) Orthanc Container Status"
echo "8) Log-Struktur bereinigen"
echo ""

read -p "Auswahl [1-8]: " choice

case $choice in
    1)
        echo "Überwache FileSender Logs (Ctrl+C zum Beenden)..."
        FILESENDER_LOG="$HOME_DIR/logs/filesender/filesender.log"
        if [ -f "$FILESENDER_LOG" ]; then
            echo "Letzten 10 Zeilen:"
            tail -10 "$FILESENDER_LOG"
            echo ""
            echo "Live-Monitoring (Ctrl+C zum Beenden):"
            tail -f "$FILESENDER_LOG"
        else
            echo "FileSender Log noch nicht vorhanden: $FILESENDER_LOG"
        fi
        ;;
    2)
        echo "Überwache Docker Container Logs (Ctrl+C zum Beenden)..."
        cd "$HOME_DIR/deployment"
        docker compose logs -f
        ;;
    3)
        echo "Neueste Deployment Logs:"
        
        # Check both locations for backward compatibility
        echo "In ~/logs/deployment/:"
        ls -la "$HOME_DIR/logs/deployment/" 2>/dev/null | tail -10
        
        # Check for misplaced logs in root
        misplaced_in_root=$(ls "$HOME_DIR/logs"/deploy*.log 2>/dev/null)
        if [ -n "$misplaced_in_root" ]; then
            echo ""
            echo "Falsch platzierte Logs in ~/logs/ (sollten in deployment/ sein):"
            ls -la "$HOME_DIR/logs"/deploy*.log 2>/dev/null
        fi
        
        echo ""
        
        # Try to find latest deployment log
        latest_deploy_log=""
        
        # First check deployment subdirectory
        if [ -f "$HOME_DIR/logs/deployment/latest.log" ]; then
            latest_deploy_log="$HOME_DIR/logs/deployment/latest.log"
        else
            # Fallback: find newest deploy log in deployment/
            latest_deploy_log=$(ls -t "$HOME_DIR/logs/deployment"/deploy-*.log 2>/dev/null | head -1)
            
            # Last resort: check root directory
            if [ -z "$latest_deploy_log" ]; then
                latest_deploy_log=$(ls -t "$HOME_DIR/logs"/deploy-*.log 2>/dev/null | head -1)
            fi
        fi
        
        if [ -n "$latest_deploy_log" ] && [ -f "$latest_deploy_log" ]; then
            echo "Inhalt des neuesten Deployment Logs:"
            echo "$(basename "$latest_deploy_log")"
            echo "────────────────────────────────────────"
            cat "$latest_deploy_log"
        else
            echo "Keine Deployment Logs gefunden"
            echo "Tipp: Führen Sie ein Deployment aus um Logs zu generieren"
        fi
        ;;
    4)
        echo "Alle verfügbaren Log-Dateien:"
        echo ""
        echo "Deployment Logs:"
        ls -la "$HOME_DIR/logs/deployment/" 2>/dev/null || echo "   (keine gefunden)"
        echo ""
        echo "FileSender Logs:"
        ls -la "$HOME_DIR/logs/filesender/" 2>/dev/null || echo "   (keine gefunden)"
        echo ""
        echo "Orthanc Logs:"
        ls -la "$HOME_DIR/logs/orthanc/" 2>/dev/null || echo "   (keine gefunden)"
        echo ""
        echo "Temp Upload Logs:"
        ls -la /tmp/upload_*.log 2>/dev/null || echo "   (keine gefunden)"
        ;;
    5)
        echo "Log-Ordner-Größe:"
        du -h "$HOME_DIR/logs/"* 2>/dev/null | sort -hr
        echo ""
        echo "Gesamt-Log-Größe:"
        du -sh "$HOME_DIR/logs/" 2>/dev/null
        echo ""
        echo "System-Disk-Usage:"
        df -h "$HOME_DIR"
        ;;
    6)
        echo "Log-Cleanup (Dateien älter als 30 Tage)..."
        echo "Suche nach alten Log-Dateien..."
        old_files=$(find "$HOME_DIR/logs/" -name "*.log" -mtime +30 -type f 2>/dev/null)
        if [ -z "$old_files" ]; then
            echo "Keine alten Log-Dateien gefunden"
        else
            echo "Gefundene alte Log-Dateien:"
            echo "$old_files"
            read -p "Wirklich löschen? [y/N]: " confirm
            if [[ $confirm =~ ^[Yy]$ ]]; then
                find "$HOME_DIR/logs/" -name "*.log" -mtime +30 -type f -print -delete
                echo "Cleanup abgeschlossen"
            else
                echo "Cleanup abgebrochen"
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
        echo "LOG-STRUKTUR BEREINIGEN..."
        echo ""
        echo "Aktuelle Struktur-Probleme:"
        
        # Check for misplaced logs
        misplaced_logs=()
        for logfile in "$HOME_DIR/logs"/*.log; do
            if [ -f "$logfile" ]; then
                misplaced_logs+=("$(basename "$logfile")")
            fi
        done
        
        if [ ${#misplaced_logs[@]} -gt 0 ]; then
            echo "Falsch platzierte Logs in ~/logs/ (sollten in Unterordnern sein):"
            for log in "${misplaced_logs[@]}"; do
                echo "   - $log"
            done
            echo ""
            read -p "Log-Struktur automatisch bereinigen? [Y/n]: " cleanup_confirm
            if [[ ! $cleanup_confirm =~ ^[Nn]$ ]]; then
                # Deployment logs verschieben
                for logfile in "$HOME_DIR/logs"/deploy*.log; do
                    if [ -f "$logfile" ]; then
                        filename=$(basename "$logfile")
                        echo "Verschiebe: $filename → deployment/"
                        mv "$logfile" "$HOME_DIR/logs/deployment/"
                    fi
                done
                
                # Other common deployment logs
                for logfile in "$HOME_DIR/logs"/{deploy,deployment,build,install,setup}.log; do
                    if [ -f "$logfile" ]; then
                        filename=$(basename "$logfile")
                        echo "Verschiebe: $filename → deployment/"
                        mv "$logfile" "$HOME_DIR/logs/deployment/" 2>/dev/null
                    fi
                done
                
                # Create latest.log symlink
                latest_deploy=$(ls -t "$HOME_DIR/logs/deployment"/deploy-*.log 2>/dev/null | head -1)
                if [ -n "$latest_deploy" ]; then
                    ln -sf "$(basename "$latest_deploy")" "$HOME_DIR/logs/deployment/latest.log"
                    echo "Symlink erstellt: deployment/latest.log"
                fi
                
                echo "Log-Struktur bereinigt!"
            fi
        else
            echo "Log-Struktur ist bereits korrekt!"
        fi
        
        echo ""
        echo "KORREKTE LOG-STRUKTUR:"
        echo "~/logs/"
        echo "├── deployment/  (deployment logs)"
        echo "├── filesender/  (plugin logs)"  
        echo "└── orthanc/     (additional logs)"
        ;;
    *)
        echo "Ungültige Auswahl"
        exit 1
        ;;
esac