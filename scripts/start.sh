#!/bin/bash
set -e

echo "========================================"
echo "BillionMail Railway Startup Script"
echo "========================================"
echo "Environment: ${APP_ENV:-production}"
echo "Hostname: ${BILLIONMAIL_HOSTNAME:-not set}"
echo "========================================"

# Function to handle shutdown gracefully
shutdown_handler() {
    echo "[start] Received shutdown signal, stopping services..."
    supervisorctl stop all
    exit 0
}

# Register shutdown handler
trap shutdown_handler SIGTERM SIGINT

# Check required environment variables
check_required_vars() {
    local missing_vars=()
    
    if [ -z "$DATABASE_URL" ] && [ -z "$POSTGRES_HOST" ]; then
        missing_vars+=("DATABASE_URL or POSTGRES_HOST")
    fi
    
    if [ -z "$REDIS_URL" ] && [ -z "$REDIS_HOST" ]; then
        missing_vars+=("REDIS_URL or REDIS_HOST")
    fi
    
    if [ -z "$BILLIONMAIL_HOSTNAME" ]; then
        missing_vars+=("BILLIONMAIL_HOSTNAME")
    fi
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "[start] ERROR: Missing required environment variables:"
        printf '%s\n' "${missing_vars[@]}"
        echo "[start] Please configure these in Railway dashboard"
        exit 1
    fi
}

# Wait for a service to be ready
wait_for_service() {
    local host=$1
    local port=$2
    local service=$3
    local max_attempts=30
    local attempt=1
    
    echo "[start] Waiting for $service at $host:$port..."
    
    while [ $attempt -le $max_attempts ]; do
        if nc -z "$host" "$port" 2>/dev/null; then
            echo "[start] $service is ready!"
            return 0
        fi
        echo "[start] Waiting for $service... ($attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "[start] ERROR: $service failed to start after $max_attempts attempts"
    return 1
}

# Parse database URL
parse_database_url() {
    if [ -n "$DATABASE_URL" ]; then
        DB_REGEX="postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)"
        if [[ $DATABASE_URL =~ $DB_REGEX ]]; then
            export POSTGRES_USER="${BASH_REMATCH[1]}"
            export POSTGRES_PASSWORD="${BASH_REMATCH[2]}"
            export POSTGRES_HOST="${BASH_REMATCH[3]}"
            export POSTGRES_PORT="${BASH_REMATCH[4]}"
            export POSTGRES_DB="${BASH_REMATCH[5]}"
        fi
    fi
}

# Parse Redis URL
parse_redis_url() {
    if [ -n "$REDIS_URL" ]; then
        REDIS_REGEX="redis://(:([^@]+)@)?([^:]+):([0-9]+)"
        if [[ $REDIS_URL =~ $REDIS_REGEX ]]; then
            export REDIS_PASSWORD="${BASH_REMATCH[2]}"
            export REDIS_HOST="${BASH_REMATCH[3]}"
            export REDIS_PORT="${BASH_REMATCH[4]}"
        fi
    fi
}

# Main startup sequence
main() {
    echo "[start] Starting BillionMail..."
    
    # Check required variables
    check_required_vars
    
    # Parse connection URLs
    parse_database_url
    parse_redis_url
    
    # Set defaults
    export POSTGRES_PORT=${POSTGRES_PORT:-5432}
    export REDIS_PORT=${REDIS_PORT:-6379}
    export PORT=${PORT:-80}
    
    # Display configuration
    echo "[start] Configuration:"
    echo "[start]   Database: ${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
    echo "[start]   Redis: ${REDIS_HOST}:${REDIS_PORT}"
    echo "[start]   Domain: ${BILLIONMAIL_HOSTNAME}"
    echo "[start]   Web Port: ${PORT}"
    
    # Create required directories
    echo "[start] Creating directories..."
    mkdir -p /app/storage/{mail,config,logs,data,temp}
    mkdir -p /var/vmail
    mkdir -p /var/spool/postfix
    mkdir -p /var/run/supervisor
    mkdir -p /var/run/opendkim
    mkdir -p /var/run/php
    
    # Set proper permissions
    chown -R vmail:vmail /var/vmail /app/storage/mail
    chown -R www-data:www-data /app/storage/data /app/storage/temp
    chown -R opendkim:opendkim /var/run/opendkim
    chmod 755 /app/storage/logs
    
    # Wait for database
    wait_for_service "${POSTGRES_HOST}" "${POSTGRES_PORT}" "PostgreSQL" || exit 1
    
    # Wait for Redis
    wait_for_service "${REDIS_HOST}" "${REDIS_PORT}" "Redis" || exit 1
    
    # Initialize database
    echo "[start] Initializing database..."
    /usr/local/bin/billionmail/init-db.sh
    
    # Configure services
    echo "[start] Configuring services..."
    /usr/local/bin/billionmail/configure-services.sh
    
    # Initialize Postfix
    echo "[start] Initializing Postfix..."
    newaliases
    postmap /etc/postfix/main.cf 2>/dev/null || true
    
    # Update ClamAV database if enabled
    if [ "${ANTIVIRUS_ENABLED}" = "true" ]; then
        echo "[start] Updating ClamAV database (this may take a while)..."
        freshclam --quiet || true
    fi
    
    # Fix PHP-FPM configuration
    echo "[start] Configuring PHP-FPM..."
    sed -i 's/^listen = .*/listen = \/var\/run\/php\/php8.2-fpm.sock/' /etc/php/8.2/fpm/pool.d/www.conf
    sed -i 's/^;listen.owner = .*/listen.owner = www-data/' /etc/php/8.2/fpm/pool.d/www.conf
    sed -i 's/^;listen.group = .*/listen.group = www-data/' /etc/php/8.2/fpm/pool.d/www.conf
    
    # Initialize Roundcube database
    echo "[start] Initializing Roundcube..."
    cd /var/www/roundcube
    if [ -f "SQL/postgres.initial.sql" ]; then
        PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" < SQL/postgres.initial.sql 2>/dev/null || true
    fi
    
    # Start supervisord
    echo "[start] Starting supervisord..."
    exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
}

# Run main function
main "$@"