#!/bin/bash
# Unified startup script for BillionMail on Railway with single /data volume

set -e

echo "Starting BillionMail with unified /data volume..."

# Setup volume structure
/usr/local/bin/setup-volumes.sh

# Wait for database
echo "Waiting for PostgreSQL..."
until pg_isready -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U "${PGUSER:-postgres}"; do
    echo "PostgreSQL is unavailable - sleeping"
    sleep 2
done
echo "PostgreSQL is ready"

# Wait for Redis
echo "Waiting for Redis..."
until redis-cli -h "${REDIS_HOST:-localhost}" -p "${REDIS_PORT:-6379}" ping; do
    echo "Redis is unavailable - sleeping"
    sleep 2
done
echo "Redis is ready"

# Initialize database if needed
if [ "${DB_INIT:-false}" = "true" ]; then
    echo "Initializing database..."
    psql "${DATABASE_URL}" < /usr/local/share/billionmail/schema.sql || true
fi

# Generate configurations from environment
echo "Generating configurations..."

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
EOF

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
    driver = sql
    args = /etc/dovecot/dovecot-sql.conf
}

userdb {
    driver = sql
    args = /etc/dovecot/dovecot-sql.conf
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
servers = "${REDIS_HOST:-localhost}:${REDIS_PORT:-6379}";
password = "${REDIS_PASSWORD:-}";
db = "0";
dbdir = "/data/rspamd";
EOF

cat > /etc/rspamd/local.d/logging.inc <<EOF
type = "file";
filename = "/data/log/rspamd.log";
level = "info";
EOF

# Generate self-signed certificate if not exists
if [ ! -f /data/ssl/cert.pem ]; then
    echo "Generating self-signed certificate..."
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /data/ssl/key.pem \
        -out /data/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${HOSTNAME:-mail.example.com}"
fi

# Fix permissions
chown -R vmail:vmail /data/vmail
chown -R postfix:postfix /data/postfix-spool
chown -R _rspamd:_rspamd /data/rspamd
chmod 700 /data/vmail

echo "Starting services with supervisord..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf