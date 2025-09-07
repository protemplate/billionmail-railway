#!/bin/bash
# Health check script for BillionMail on Railway
# Verifies critical services and dependencies are available

set -e

# Colors for output (currently unused, kept for future debugging)
# RED='\033[0;31m'
# GREEN='\033[0;32m'
# NC='\033[0m' # No Color

# Exit codes
EXIT_SUCCESS=0
EXIT_FAILURE=1

# Track overall health status
HEALTH_STATUS=$EXIT_SUCCESS

# Function to check service
check_service() {
    local service_name=$1
    local check_command=$2
    
    if eval "$check_command" > /dev/null 2>&1; then
        echo "[OK] $service_name is healthy"
        return 0
    else
        echo "[FAIL] $service_name is not responding"
        HEALTH_STATUS=$EXIT_FAILURE
        return 1
    fi
}

echo "Starting health check..."

# 1. Check PostgreSQL connectivity (external service) using PG* variables
if [ -n "$PGHOST" ] && [ -n "$PGUSER" ] && [ -n "$PGDATABASE" ]; then
    check_service "PostgreSQL" "pg_isready -h '$PGHOST' -p '${PGPORT:-5432}' -U '$PGUSER' -d '$PGDATABASE'"
elif [ -n "$DATABASE_URL" ]; then
    check_service "PostgreSQL" "pg_isready -d '$DATABASE_URL'"
fi

# 2. Check Redis connectivity (external service) using REDIS* variables
if [ -n "$REDISHOST" ]; then
    if [ -n "$REDISPASSWORD" ]; then
        check_service "Redis" "redis-cli -h '$REDISHOST' -p '${REDISPORT:-6379}' -a '$REDISPASSWORD' ping 2>/dev/null | grep -q PONG"
    else
        check_service "Redis" "redis-cli -h '$REDISHOST' -p '${REDISPORT:-6379}' ping 2>/dev/null | grep -q PONG"
    fi
elif [ -n "$REDIS_URL" ]; then
    # Fallback to parsing REDIS_URL if REDIS* variables not set
    check_service "Redis" "redis-cli -u '$REDIS_URL' ping 2>/dev/null | grep -q PONG"
fi

# 3. Check web interface (nginx)
check_service "Web Interface" "curl -f -s -o /dev/null http://localhost:80/health || curl -f -s -o /dev/null http://localhost:80/"

# 4. Check critical directories exist
if [ -d "/data" ]; then
    echo "[OK] Data volume is mounted"
else
    echo "[FAIL] Data volume is not mounted at /data"
    HEALTH_STATUS=$EXIT_FAILURE
fi

# 5. Check mail services (only if SMTP_MODE is 'direct' for Pro plan)
if [ "${SMTP_MODE:-api}" = "direct" ]; then
    echo "Checking mail services (Pro plan mode)..."
    
    # Check Postfix
    if pgrep -x "postfix" > /dev/null 2>&1 || pgrep -x "master" > /dev/null 2>&1; then
        echo "[OK] Postfix is running"
    else
        echo "[WARN] Postfix is not running (may still be starting)"
    fi
    
    # Check Dovecot
    if pgrep -x "dovecot" > /dev/null 2>&1; then
        echo "[OK] Dovecot is running"
    else
        echo "[WARN] Dovecot is not running (may still be starting)"
    fi
    
    # Check SMTP port
    if nc -z localhost 25 2>/dev/null; then
        echo "[OK] SMTP port 25 is listening"
    else
        echo "[WARN] SMTP port 25 is not available"
    fi
else
    echo "[INFO] Running in API mode (non-Pro plan) - mail services disabled"
fi

# 6. Check supervisor is running
if pgrep -x "supervisord" > /dev/null 2>&1; then
    echo "[OK] Supervisord is running"
else
    echo "[FAIL] Supervisord is not running"
    HEALTH_STATUS=$EXIT_FAILURE
fi

# 7. Check disk space
DISK_USAGE=$(df /data 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
if [ -n "$DISK_USAGE" ]; then
    if [ "$DISK_USAGE" -lt 90 ]; then
        echo "[OK] Disk usage is ${DISK_USAGE}%"
    else
        echo "[WARN] Disk usage is high: ${DISK_USAGE}%"
    fi
fi

# Final status
echo "----------------------------------------"
if [ $HEALTH_STATUS -eq $EXIT_SUCCESS ]; then
    echo "Health check PASSED"
else
    echo "Health check FAILED"
fi

exit $HEALTH_STATUS