#!/bin/bash

# Health check script for BillionMail on Railway
# Returns 0 if all critical services are healthy, 1 otherwise

HEALTH_STATUS=0
CRITICAL_FAILURE=0

# Color codes for output (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Function to check if a process is running
check_process() {
    local process_name=$1
    local critical=${2:-1}  # Default to critical
    
    if pgrep -f "$process_name" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} $process_name is running"
        return 0
    else
        echo -e "${RED}✗${NC} $process_name is not running"
        if [ "$critical" -eq 1 ]; then
            CRITICAL_FAILURE=1
        fi
        HEALTH_STATUS=1
        return 1
    fi
}

# Function to check if a port is listening
check_port() {
    local port=$1
    local service=$2
    local critical=${3:-1}  # Default to critical
    
    if netstat -tuln | grep -q ":$port "; then
        echo -e "${GREEN}✓${NC} $service (port $port) is listening"
        return 0
    else
        echo -e "${RED}✗${NC} $service (port $port) is not listening"
        if [ "$critical" -eq 1 ]; then
            CRITICAL_FAILURE=1
        fi
        HEALTH_STATUS=1
        return 1
    fi
}

# Function to check database connectivity
check_database() {
    # Parse DATABASE_URL if provided
    if [ -n "$DATABASE_URL" ]; then
        DB_REGEX="postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)"
        if [[ $DATABASE_URL =~ $DB_REGEX ]]; then
            POSTGRES_USER="${BASH_REMATCH[1]}"
            POSTGRES_PASSWORD="${BASH_REMATCH[2]}"
            POSTGRES_HOST="${BASH_REMATCH[3]}"
            POSTGRES_PORT="${BASH_REMATCH[4]}"
            POSTGRES_DB="${BASH_REMATCH[5]}"
        fi
    fi
    
    if [ -n "$POSTGRES_HOST" ]; then
        if PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; then
            echo -e "${GREEN}✓${NC} PostgreSQL connection is healthy"
            return 0
        else
            echo -e "${RED}✗${NC} PostgreSQL connection failed"
            CRITICAL_FAILURE=1
            HEALTH_STATUS=1
            return 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} PostgreSQL not configured"
        return 0
    fi
}

# Function to check Redis connectivity
check_redis() {
    # Parse REDIS_URL if provided
    if [ -n "$REDIS_URL" ]; then
        REDIS_REGEX="redis://(:([^@]+)@)?([^:]+):([0-9]+)"
        if [[ $REDIS_URL =~ $REDIS_REGEX ]]; then
            REDIS_PASSWORD="${BASH_REMATCH[2]}"
            REDIS_HOST="${BASH_REMATCH[3]}"
            REDIS_PORT="${BASH_REMATCH[4]}"
        fi
    fi
    
    if [ -n "$REDIS_HOST" ]; then
        if [ -n "$REDIS_PASSWORD" ]; then
            REDIS_RESPONSE=$(redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" -a "$REDIS_PASSWORD" ping 2>/dev/null)
        else
            REDIS_RESPONSE=$(redis-cli -h "$REDIS_HOST" -p "${REDIS_PORT:-6379}" ping 2>/dev/null)
        fi
        
        if [ "$REDIS_RESPONSE" = "PONG" ]; then
            echo -e "${GREEN}✓${NC} Redis connection is healthy"
            return 0
        else
            echo -e "${RED}✗${NC} Redis connection failed"
            CRITICAL_FAILURE=1
            HEALTH_STATUS=1
            return 1
        fi
    else
        echo -e "${YELLOW}⚠${NC} Redis not configured"
        return 0
    fi
}

# Function to check HTTP endpoint
check_http() {
    local endpoint=$1
    local service=$2
    local critical=${3:-0}  # Default to non-critical
    
    if curl -f -s -o /dev/null "http://localhost$endpoint"; then
        echo -e "${GREEN}✓${NC} $service HTTP endpoint is responding"
        return 0
    else
        echo -e "${RED}✗${NC} $service HTTP endpoint is not responding"
        if [ "$critical" -eq 1 ]; then
            CRITICAL_FAILURE=1
        fi
        HEALTH_STATUS=1
        return 1
    fi
}

# Function to check supervisord status
check_supervisor() {
    if supervisorctl status > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Supervisord is running"
        
        # Check individual services managed by supervisor
        local supervisor_status=$(supervisorctl status 2>/dev/null)
        
        # Check critical services
        for service in nginx php-fpm postfix dovecot rspamd; do
            if echo "$supervisor_status" | grep -q "$service.*RUNNING"; then
                echo -e "  ${GREEN}✓${NC} $service is RUNNING"
            elif echo "$supervisor_status" | grep -q "$service"; then
                echo -e "  ${RED}✗${NC} $service is not RUNNING"
                CRITICAL_FAILURE=1
                HEALTH_STATUS=1
            fi
        done
        
        # Check optional services
        for service in opendkim billionmail-api billionmail-celery billionmail-beat; do
            if echo "$supervisor_status" | grep -q "$service.*RUNNING"; then
                echo -e "  ${GREEN}✓${NC} $service is RUNNING"
            elif echo "$supervisor_status" | grep -q "$service"; then
                echo -e "  ${YELLOW}⚠${NC} $service is not RUNNING (optional)"
            fi
        done
        
        return 0
    else
        echo -e "${RED}✗${NC} Supervisord is not running"
        CRITICAL_FAILURE=1
        HEALTH_STATUS=1
        return 1
    fi
}

# Main health check
echo "========================================"
echo "BillionMail Health Check"
echo "========================================"

# Check supervisord and managed services
check_supervisor

# Check database connectivity
check_database

# Check Redis connectivity
check_redis

# Check critical ports
check_port 80 "Web interface" 1
check_port 25 "SMTP" 1
check_port 587 "Submission" 1
check_port 143 "IMAP" 1

# Check optional ports
check_port 443 "HTTPS" 0
check_port 465 "SMTPS" 0
check_port 993 "IMAPS" 0
check_port 110 "POP3" 0
check_port 995 "POP3S" 0
check_port 8080 "Admin API" 0

# Check HTTP endpoints
check_http "/health" "Health endpoint" 0
check_http "/" "Webmail interface" 0
check_http ":8080/health" "API health" 0

echo "========================================"

if [ $CRITICAL_FAILURE -eq 1 ]; then
    echo -e "${RED}CRITICAL: One or more critical services are down${NC}"
    exit 1
elif [ $HEALTH_STATUS -eq 1 ]; then
    echo -e "${YELLOW}WARNING: Some non-critical services are down${NC}"
    exit 0  # Return success for non-critical failures
else
    echo -e "${GREEN}All services are healthy${NC}"
    exit 0
fi