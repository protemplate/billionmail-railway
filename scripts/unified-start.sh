#!/bin/bash
# Unified startup script for BillionMail on Railway with single /data volume

set -e

echo "Starting BillionMail with unified /data volume..."

# Setup volume structure
/usr/local/bin/setup-volumes.sh

# Configure SMTP based on environment
/usr/local/bin/configure-smtp.sh

# Wait for database using PG* variables
echo "Waiting for PostgreSQL..."
until pg_isready -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}"; do
    echo "PostgreSQL is unavailable - sleeping"
    sleep 2
done
echo "PostgreSQL is ready"

# Wait for Redis using REDIS* variables
echo "Waiting for Redis..."
if [ -n "${REDISPASSWORD}" ]; then
    until redis-cli -h "${REDISHOST:-localhost}" -p "${REDISPORT:-6379}" -a "${REDISPASSWORD}" ping 2>/dev/null | grep -q PONG; do
        echo "Redis is unavailable - sleeping"
        sleep 2
    done
else
    until redis-cli -h "${REDISHOST:-localhost}" -p "${REDISPORT:-6379}" ping 2>/dev/null | grep -q PONG; do
        echo "Redis is unavailable - sleeping"
        sleep 2
    done
fi
echo "Redis is ready"

# Initialize database if needed
if [ "${DB_INIT:-false}" = "true" ]; then
    echo "Initializing database..."
    psql "${DATABASE_URL}" < /usr/local/share/billionmail/schema.sql || true
fi

# Generate configurations from environment
echo "Generating configurations..."

# Configure SMTP based on mode
echo "Configuring SMTP mode: ${SMTP_MODE:-direct}"

# Postfix configuration
cat > /etc/postfix/main.cf <<EOF
# Basic settings
myhostname = ${HOSTNAME:-mail.example.com}
mydomain = ${DOMAIN:-example.com}
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
mynetworks = 127.0.0.0/8 [::1]/128
inet_interfaces = all
inet_protocols = all

# Mail storage
home_mailbox = Maildir/
mailbox_size_limit = 0
recipient_delimiter = +

# Queue in /data
queue_directory = /data/postfix-spool

# Virtual domains from database
virtual_mailbox_domains = pgsql:/etc/postfix/pgsql/virtual_domains.cf
virtual_mailbox_maps = pgsql:/etc/postfix/pgsql/virtual_mailboxes.cf
virtual_alias_maps = pgsql:/etc/postfix/pgsql/virtual_aliases.cf
virtual_mailbox_base = /data/vmail
virtual_uid_maps = static:5000
virtual_gid_maps = static:5000

# TLS
smtp_tls_security_level = may
smtpd_tls_security_level = may
smtpd_tls_cert_file = /data/ssl/cert.pem
smtpd_tls_key_file = /data/ssl/key.pem

# SASL
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes

# Milters (Rspamd)
milter_default_action = accept
milter_protocol = 6
smtpd_milters = inet:localhost:11332
non_smtpd_milters = inet:localhost:11332

# SMTP Delivery Configuration
smtp_helo_name = ${SMTP_HELO_NAME:-${HOSTNAME:-mail.example.com}}
bounce_queue_lifetime = 4h
maximal_queue_lifetime = 5d
maximal_backoff_time = 4000s
minimal_backoff_time = 300s
queue_run_delay = 300s

# Connection limits
smtp_destination_concurrency_limit = ${SMTP_MAX_CONNECTIONS:-10}
smtp_destination_rate_delay = 1s
smtp_connect_timeout = ${SMTP_CONNECTION_TIMEOUT:-30}s
EOF

# Configure SMTP relay if needed
if [ "${SMTP_MODE}" = "relay" ] && [ -n "${SMTP_RELAY_HOST}" ]; then
    echo "Configuring SMTP relay via ${SMTP_RELAY_HOST}:${SMTP_RELAY_PORT:-587}"
    cat >> /etc/postfix/main.cf <<EOF

# SMTP Relay Configuration
relayhost = [${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT:-587}
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_use_tls = yes
smtp_tls_security_level = encrypt
smtp_tls_note_starttls_offer = yes
EOF

    # Create SASL password file
    if [ -n "${SMTP_RELAY_USER}" ] && [ -n "${SMTP_RELAY_PASSWORD}" ]; then
        echo "[${SMTP_RELAY_HOST}]:${SMTP_RELAY_PORT:-587} ${SMTP_RELAY_USER}:${SMTP_RELAY_PASSWORD}" > /etc/postfix/sasl_passwd
        postmap /etc/postfix/sasl_passwd
        chmod 600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
    fi
fi

# Generate self-signed certificate if not exists (needed before Dovecot config)
if [ ! -f /data/ssl/cert.pem ] || [ ! -f /data/ssl/key.pem ]; then
    echo "Generating self-signed certificate..."
    mkdir -p /data/ssl
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /data/ssl/key.pem \
        -out /data/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${HOSTNAME:-mail.example.com}" 2>/dev/null
    chmod 600 /data/ssl/key.pem
    chmod 644 /data/ssl/cert.pem
fi

# Dovecot configuration
cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap pop3 lmtp
listen = *, ::
mail_location = maildir:/data/vmail/%d/%n/Maildir
mail_uid = vmail
mail_gid = vmail
first_valid_uid = 5000
last_valid_uid = 5000
auth_mechanisms = plain login

passdb {
    driver = static
    args = password=temppass
}

userdb {
    driver = static
    args = uid=vmail gid=vmail home=/data/vmail/%d/%n
}

service auth {
    unix_listener /var/spool/postfix/private/auth {
        mode = 0666
        user = postfix
        group = postfix
    }
}

service lmtp {
    unix_listener /var/spool/postfix/private/dovecot-lmtp {
        mode = 0600
        user = postfix
        group = postfix
    }
}

ssl = yes
ssl_cert = </data/ssl/cert.pem
ssl_key = </data/ssl/key.pem

log_path = /data/log/dovecot.log
info_log_path = /data/log/dovecot-info.log
EOF

# Rspamd configuration
mkdir -p /etc/rspamd/local.d
cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "${REDISHOST:-localhost}:${REDISPORT:-6379}";
password = "${REDISPASSWORD:-}";
db = "0";
dbdir = "/data/rspamd";
EOF

cat > /etc/rspamd/local.d/logging.inc <<EOF
type = "file";
filename = "/data/log/rspamd.log";
level = "info";
EOF

# SSL certificates already generated above

# Configure email API transport if needed
if [ "${SMTP_MODE}" = "api" ]; then
    echo "Configuring HTTP API email delivery"
    # Create transport map for API delivery
    cat > /etc/postfix/transport <<EOF
# Route all mail through API transport
*    smtp-api:
EOF
    postmap /etc/postfix/transport
    
    # Add transport configuration to main.cf
    cat >> /etc/postfix/main.cf <<EOF

# API Transport Configuration
transport_maps = hash:/etc/postfix/transport
EOF
fi

# Fix permissions
chown -R vmail:vmail /data/vmail 2>/dev/null || true
chown -R postfix:postfix /data/postfix-spool 2>/dev/null || true
chown -R rspamd:rspamd /data/rspamd 2>/dev/null || true
chmod 700 /data/vmail

echo "Starting services with supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf