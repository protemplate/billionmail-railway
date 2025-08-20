#!/bin/bash
# BillionMail Backup Script for Railway
# Creates backups of critical data within the single volume

set -euo pipefail

# Configuration
DATA_DIR=${DATA_PATH:-/data}
BACKUP_DIR=${BACKUP_PATH:-$DATA_DIR/backups}
RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-7}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="billionmail_backup_$TIMESTAMP"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to check if we're running as the correct user
check_user() {
    if [[ $EUID -eq 0 ]]; then
        warn "Running as root. Consider running as billionmail user."
    fi
}

# Function to create backup directory
create_backup_dir() {
    log "Creating backup directory: $BACKUP_PATH"
    mkdir -p "$BACKUP_PATH"
    
    if [[ ! -w "$BACKUP_PATH" ]]; then
        error "Cannot write to backup directory: $BACKUP_PATH"
        exit 1
    fi
}

# Function to check available disk space
check_disk_space() {
    local data_size=$(du -sb "$DATA_DIR" 2>/dev/null | cut -f1 || echo "0")
    local available_space=$(df "$DATA_DIR" | awk 'NR==2 {print $4*1024}')
    local required_space=$((data_size / 2))  # Estimate 50% of data size needed
    
    info "Data size: $(numfmt --to=iec $data_size)"
    info "Available space: $(numfmt --to=iec $available_space)"
    info "Estimated backup size: $(numfmt --to=iec $required_space)"
    
    if [[ $available_space -lt $required_space ]]; then
        error "Not enough disk space for backup"
        error "Required: $(numfmt --to=iec $required_space), Available: $(numfmt --to=iec $available_space)"
        exit 1
    fi
}

# Function to backup mail data
backup_mail() {
    local mail_dir="$DATA_DIR/mail"
    local backup_file="$BACKUP_PATH/mail.tar.gz"
    
    if [[ -d "$mail_dir" ]]; then
        log "Backing up mail data..."
        tar -czf "$backup_file" -C "$DATA_DIR" mail/ 2>/dev/null || {
            error "Failed to backup mail data"
            return 1
        }
        log "✅ Mail data backup completed: $(du -h "$backup_file" | cut -f1)"
    else
        warn "Mail directory not found: $mail_dir"
    fi
}

# Function to backup configuration
backup_config() {
    local config_dir="$DATA_DIR/config"
    local backup_file="$BACKUP_PATH/config.tar.gz"
    
    if [[ -d "$config_dir" ]]; then
        log "Backing up configuration..."
        tar -czf "$backup_file" -C "$DATA_DIR" config/ 2>/dev/null || {
            error "Failed to backup configuration"
            return 1
        }
        log "✅ Configuration backup completed: $(du -h "$backup_file" | cut -f1)"
    else
        warn "Config directory not found: $config_dir"
    fi
}

# Function to backup application data
backup_app_data() {
    local app_dir="$DATA_DIR/app"
    local backup_file="$BACKUP_PATH/app.tar.gz"
    
    if [[ -d "$app_dir" ]]; then
        log "Backing up application data..."
        # Exclude cache and temporary files
        tar -czf "$backup_file" -C "$DATA_DIR" \
            --exclude="app/cache/*" \
            --exclude="app/tmp/*" \
            --exclude="app/temp/*" \
            app/ 2>/dev/null || {
            error "Failed to backup application data"
            return 1
        }
        log "✅ Application data backup completed: $(du -h "$backup_file" | cut -f1)"
    else
        warn "App directory not found: $app_dir"
    fi
}

# Function to backup database (if accessible)
backup_database() {
    if [[ -n "${DATABASE_HOST:-}" ]] && [[ -n "${DATABASE_NAME:-}" ]] && [[ -n "${DATABASE_USER:-}" ]] && [[ -n "${DATABASE_PASSWORD:-}" ]]; then
        log "Backing up database..."
        local backup_file="$BACKUP_PATH/database.sql"
        
        # Try to create database backup
        if command -v pg_dump >/dev/null 2>&1; then
            PGPASSWORD="$DATABASE_PASSWORD" pg_dump \
                -h "$DATABASE_HOST" \
                -p "${DATABASE_PORT:-5432}" \
                -U "$DATABASE_USER" \
                -d "$DATABASE_NAME" \
                --no-password \
                --clean \
                --if-exists > "$backup_file" 2>/dev/null || {
                warn "Database backup failed (pg_dump error)"
                return 1
            }
            
            # Compress the SQL file
            gzip "$backup_file" 2>/dev/null || true
            log "✅ Database backup completed: $(du -h "$backup_file.gz" | cut -f1)"
        else
            warn "pg_dump not available, skipping database backup"
        fi
    else
        warn "Database connection not configured, skipping database backup"
    fi
}

# Function to create backup manifest
create_manifest() {
    local manifest_file="$BACKUP_PATH/manifest.txt"
    
    log "Creating backup manifest..."
    
    cat > "$manifest_file" << EOF
BillionMail Backup Manifest
===========================
Backup Name: $BACKUP_NAME
Timestamp: $(date)
Hostname: ${BILLIONMAIL_HOSTNAME:-unknown}
Data Directory: $DATA_DIR

Files Included:
EOF

    # List all files in backup
    find "$BACKUP_PATH" -type f -name "*.tar.gz" -o -name "*.sql.gz" | while read -r file; do
        local filename=$(basename "$file")
        local size=$(du -h "$file" | cut -f1)
        echo "  - $filename ($size)" >> "$manifest_file"
    done
    
    # Add checksums
    echo "" >> "$manifest_file"
    echo "Checksums (SHA256):" >> "$manifest_file"
    find "$BACKUP_PATH" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) -exec sha256sum {} \; | sed 's|'$BACKUP_PATH'/||g' >> "$manifest_file"
    
    log "✅ Backup manifest created"
}

# Function to cleanup old backups
cleanup_old_backups() {
    log "Cleaning up backups older than $RETENTION_DAYS days..."
    
    local deleted=0
    find "$BACKUP_DIR" -type d -name "billionmail_backup_*" -mtime +$RETENTION_DAYS | while read -r old_backup; do
        if [[ -d "$old_backup" ]]; then
            rm -rf "$old_backup"
            log "Deleted old backup: $(basename "$old_backup")"
            ((deleted++))
        fi
    done
    
    if [[ $deleted -gt 0 ]]; then
        log "✅ Cleaned up $deleted old backups"
    else
        log "No old backups to clean up"
    fi
}

# Function to check backup integrity
verify_backup() {
    log "Checking backup integrity..."
    
    local verified=0
    local failed=0
    
    # Test each tar.gz file
    find "$BACKUP_PATH" -name "*.tar.gz" | while read -r archive; do
        if tar -tzf "$archive" >/dev/null 2>&1; then
            log "✅ $(basename "$archive") - OK"
            ((verified++))
        else
            error "❌ $(basename "$archive") - CORRUPTED"
            ((failed++))
        fi
    done
    
    # Test compressed SQL files
    find "$BACKUP_PATH" -name "*.sql.gz" | while read -r archive; do
        if gunzip -t "$archive" >/dev/null 2>&1; then
            log "✅ $(basename "$archive") - OK"
            ((verified++))
        else
            error "❌ $(basename "$archive") - CORRUPTED"
            ((failed++))
        fi
    done
    
    if [[ $failed -gt 0 ]]; then
        error "Backup check failed: $failed corrupted files"
        return 1
    else
        log "✅ All backup files checked successfully"
        return 0
    fi
}

# Function to display backup summary
backup_summary() {
    local total_size=$(du -sh "$BACKUP_PATH" | cut -f1)
    local file_count=$(find "$BACKUP_PATH" -type f | wc -l)
    
    info "📊 Backup Summary"
    info "=================="
    info "Backup Location: $BACKUP_PATH"
    info "Total Size: $total_size"
    info "Files Created: $file_count"
    info "Retention: $RETENTION_DAYS days"
    
    # List backup contents
    info ""
    info "Backup Contents:"
    find "$BACKUP_PATH" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" -o -name "manifest.txt" \) | while read -r file; do
        local filename=$(basename "$file")
        local size=$(du -h "$file" | cut -f1)
        info "  📁 $filename ($size)"
    done
}

# Main backup function
main() {
    log "🔄 Starting BillionMail backup process..."
    log "Backup name: $BACKUP_NAME"
    
    # Pre-flight checks
    check_user
    check_disk_space
    
    # Create backup directory
    create_backup_dir
    
    # Perform backups
    backup_mail
    backup_config
    backup_app_data
    backup_database
    
    # Create manifest and check
    create_manifest
    verify_backup
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Show summary
    backup_summary
    
    log "🎉 Backup completed successfully!"
    log "Backup location: $BACKUP_PATH"
}

# Handle command line arguments
case "${1:-}" in
    --help|-h)
        echo "BillionMail Backup Script"
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h           Show this help message"
        echo "  --verify-only        Only check existing backups"
        echo "  --cleanup-only       Only cleanup old backups"
        echo ""
        echo "Environment Variables:"
        echo "  DATA_PATH            Data directory path (default: /data)"
        echo "  BACKUP_PATH          Backup directory path (default: /data/backups)"
        echo "  BACKUP_RETENTION_DAYS Backup retention in days (default: 7)"
        exit 0
        ;;
    --verify-only)
        log "Checking existing backups..."
        find "$BACKUP_DIR" -type d -name "billionmail_backup_*" | while read -r backup; do
            if verify_backup "$backup"; then
                log "✅ $backup checked"
            else
                error "❌ $backup check failed"
            fi
        done
        exit 0
        ;;
    --cleanup-only)
        cleanup_old_backups
        exit 0
        ;;
    *)
        main
        ;;
esac