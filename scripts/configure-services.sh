#!/bin/bash
set -e

echo "[configure] Starting service configuration..."

# Parse DATABASE_URL if provided
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

# Parse REDIS_URL if provided
if [ -n "$REDIS_URL" ]; then
    # Format: redis://:password@host:port or redis://host:port
    REDIS_REGEX="redis://(:([^@]+)@)?([^:]+):([0-9]+)"
    if [[ $REDIS_URL =~ $REDIS_REGEX ]]; then
        export REDIS_PASSWORD="${BASH_REMATCH[2]}"
        export REDIS_HOST="${BASH_REMATCH[3]}"
        export REDIS_PORT="${BASH_REMATCH[4]}"
    fi
fi

# Set defaults
POSTGRES_PORT=${POSTGRES_PORT:-5432}
REDIS_PORT=${REDIS_PORT:-6379}
BILLIONMAIL_HOSTNAME=${BILLIONMAIL_HOSTNAME:-localhost}

# Create configuration directories
mkdir -p /etc/postfix/sql
mkdir -p /etc/dovecot/sql
mkdir -p /etc/rspamd/local.d
mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/opendkim
mkdir -p /app/storage/config/ssl

echo "[configure] Configuring Postfix..."

# Configure Postfix main.cf
cat > /etc/postfix/main.cf <<EOF
# Basic configuration
myhostname = ${BILLIONMAIL_HOSTNAME}
myorigin = \$myhostname
mydestination = localhost
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
inet_interfaces = all
inet_protocols = all

# Virtual mailbox configuration
virtual_mailbox_domains = pgsql:/etc/postfix/sql/virtual_domains.cf
virtual_mailbox_maps = pgsql:/etc/postfix/sql/virtual_mailbox.cf
virtual_alias_maps = pgsql:/etc/postfix/sql/virtual_alias.cf
virtual_transport = lmtp:unix:private/dovecot-lmtp

# Authentication
smtpd_sasl_type = dovecot
smtpd_sasl_path = private/auth
smtpd_sasl_auth_enable = yes
smtpd_sasl_security_options = noanonymous
smtpd_sasl_local_domain = \$myhostname

# TLS configuration
smtpd_tls_cert_file = /app/storage/config/ssl/cert.pem
smtpd_tls_key_file = /app/storage/config/ssl/key.pem
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtp_tls_security_level = may

# Restrictions
smtpd_recipient_restrictions = 
    permit_sasl_authenticated,
    permit_mynetworks,
    reject_unauth_destination,
    reject_invalid_hostname,
    reject_non_fqdn_sender,
    reject_non_fqdn_recipient,
    reject_unknown_sender_domain,
    reject_unknown_recipient_domain,
    check_policy_service unix:private/policyd-spf

# Message size limit
message_size_limit = ${MAX_MESSAGE_SIZE:-26214400}

# Milter configuration for DKIM and spam filtering
milter_protocol = 6
milter_default_action = accept
smtpd_milters = inet:localhost:11332
non_smtpd_milters = inet:localhost:11332

# Queue settings
maximal_queue_lifetime = 3d
bounce_queue_lifetime = 3d
EOF

# Configure Postfix master.cf
cat > /etc/postfix/master.cf <<EOF
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
# ==========================================================================
smtp      inet  n       -       y       -       -       smtpd
submission inet n       -       y       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
smtps     inet  n       -       y       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_client_restrictions=permit_sasl_authenticated,reject
pickup    unix  n       -       y       60      1       pickup
cleanup   unix  n       -       y       -       0       cleanup
qmgr      unix  n       -       n       300     1       qmgr
tlsmgr    unix  -       -       y       1000?   1       tlsmgr
rewrite   unix  -       -       y       -       -       trivial-rewrite
bounce    unix  -       -       y       -       0       bounce
defer     unix  -       -       y       -       0       bounce
trace     unix  -       -       y       -       0       bounce
verify    unix  -       -       y       -       1       verify
flush     unix  n       -       y       1000?   0       flush
proxymap  unix  -       -       n       -       -       proxymap
proxywrite unix -       -       n       -       1       proxymap
smtp      unix  -       -       y       -       -       smtp
relay     unix  -       -       y       -       -       smtp
showq     unix  n       -       y       -       -       showq
error     unix  -       -       y       -       -       error
retry     unix  -       -       y       -       -       error
discard   unix  -       -       y       -       -       discard
local     unix  -       n       n       -       -       local
virtual   unix  -       n       n       -       -       virtual
lmtp      unix  -       -       y       -       -       lmtp
anvil     unix  -       -       y       -       1       anvil
scache    unix  -       -       y       -       1       scache
policyd-spf unix -      n       n       -       0       spawn
  user=policyd-spf argv=/usr/bin/policyd-spf
EOF

# Create Postfix SQL configuration files
cat > /etc/postfix/sql/virtual_domains.cf <<EOF
user = ${POSTGRES_USER}
password = ${POSTGRES_PASSWORD}
hosts = ${POSTGRES_HOST}
port = ${POSTGRES_PORT}
dbname = ${POSTGRES_DB}
query = SELECT domain FROM domain WHERE domain='%s' AND active='Y'
EOF

cat > /etc/postfix/sql/virtual_mailbox.cf <<EOF
user = ${POSTGRES_USER}
password = ${POSTGRES_PASSWORD}
hosts = ${POSTGRES_HOST}
port = ${POSTGRES_PORT}
dbname = ${POSTGRES_DB}
query = SELECT maildir FROM mailbox WHERE username='%s' AND active='Y'
EOF

cat > /etc/postfix/sql/virtual_alias.cf <<EOF
user = ${POSTGRES_USER}
password = ${POSTGRES_PASSWORD}
hosts = ${POSTGRES_HOST}
port = ${POSTGRES_PORT}
dbname = ${POSTGRES_DB}
query = SELECT goto FROM alias WHERE address='%s' AND active='Y'
EOF

echo "[configure] Configuring Dovecot..."

# Configure Dovecot
cat > /etc/dovecot/dovecot.conf <<EOF
protocols = imap pop3 lmtp
listen = *, ::
auth_mechanisms = plain login

# Mail location
mail_location = maildir:/var/vmail/%d/%n
mail_uid = vmail
mail_gid = vmail
first_valid_uid = 5000
last_valid_uid = 5000

# SSL configuration
ssl = yes
ssl_cert = </app/storage/config/ssl/cert.pem
ssl_key = </app/storage/config/ssl/key.pem

# Authentication
passdb {
  driver = sql
  args = /etc/dovecot/sql/dovecot-sql.conf
}

userdb {
  driver = sql
  args = /etc/dovecot/sql/dovecot-sql.conf
}

# Services
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 993
    ssl = yes
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
  inet_listener pop3s {
    port = 995
    ssl = yes
  }
}

# Protocol settings
protocol imap {
  mail_plugins = \$mail_plugins quota imap_quota
}

protocol pop3 {
  mail_plugins = \$mail_plugins quota
}

protocol lmtp {
  postmaster_address = postmaster@${BILLIONMAIL_HOSTNAME}
  mail_plugins = \$mail_plugins sieve
}

# Plugin settings
plugin {
  quota = maildir:User quota
  quota_rule = *:storage=1G
  sieve = ~/.dovecot.sieve
  sieve_dir = ~/sieve
}

# Logging
log_path = /app/storage/logs/dovecot.log
info_log_path = /app/storage/logs/dovecot-info.log
debug_log_path = /app/storage/logs/dovecot-debug.log
EOF

# Create Dovecot SQL configuration
cat > /etc/dovecot/sql/dovecot-sql.conf <<EOF
driver = pgsql
connect = host=${POSTGRES_HOST} port=${POSTGRES_PORT} dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}
default_pass_scheme = SHA512-CRYPT
password_query = SELECT username AS user, password FROM mailbox WHERE username = '%u' AND active = 'Y'
user_query = SELECT '/var/vmail/%d/%n' AS home, 5000 AS uid, 5000 AS gid, '*:storage=' || quota || 'M' AS quota_rule FROM mailbox WHERE username = '%u' AND active = 'Y'
iterate_query = SELECT username AS user FROM mailbox WHERE active = 'Y'
EOF

echo "[configure] Configuring Rspamd..."

# Configure Rspamd for Redis
cat > /etc/rspamd/local.d/redis.conf <<EOF
servers = "${REDIS_HOST}:${REDIS_PORT}";
EOF

if [ -n "$REDIS_PASSWORD" ]; then
    echo "password = \"${REDIS_PASSWORD}\";" >> /etc/rspamd/local.d/redis.conf
fi

# Configure Rspamd worker
cat > /etc/rspamd/local.d/worker-normal.inc <<EOF
bind_socket = "localhost:11333";
EOF

# Configure Rspamd controller
cat > /etc/rspamd/local.d/worker-controller.inc <<EOF
bind_socket = "localhost:11334";
password = "\$2\$g95yw5aun3kqn8eodp4uuqxnmpo8jmty\$1zq8qnx7qwgxrwf6a8rbhmrm1kc7p1bdh8465hzjjogqiotdwij7";
enable_password = "\$2\$g95yw5aun3kqn8eodp4uuqxnmpo8jmty\$1zq8qnx7qwgxrwf6a8rbhmrm1kc7p1bdh8465hzjjogqiotdwij7";
EOF

# Configure Rspamd milter
cat > /etc/rspamd/local.d/worker-proxy.inc <<EOF
bind_socket = "localhost:11332";
milter = yes;
timeout = 120s;
upstream "local" {
  default = yes;
  self_scan = yes;
}
EOF

echo "[configure] Configuring Nginx..."

# Configure Nginx for web interfaces
cat > /etc/nginx/sites-enabled/billionmail <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${BILLIONMAIL_HOSTNAME};
    
    root /var/www/roundcube;
    index index.php index.html;
    
    # Roundcube webmail
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }
    
    location ~ /\.(ht|git) {
        deny all;
    }
    
    # BillionMail API proxy
    location /api/ {
        proxy_pass http://[::1]:8080/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # Health check endpoint
    location /health {
        access_log off;
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}

# Admin interface
server {
    listen 8080;
    listen [::]:8080;
    server_name _;
    
    location / {
        proxy_pass http://[::1]:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

echo "[configure] Configuring Roundcube..."

# Configure Roundcube
cat > /var/www/roundcube/config/config.inc.php <<EOF
<?php
\$config = [];
\$config['db_dsnw'] = 'pgsql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}';
\$config['default_host'] = 'localhost';
\$config['default_port'] = 143;
\$config['smtp_server'] = 'localhost';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
\$config['support_url'] = '';
\$config['product_name'] = 'BillionMail Webmail';
\$config['des_key'] = '${ROUNDCUBE_DES_KEY:-$(openssl rand -hex 12)}';
\$config['plugins'] = ['archive', 'zipdownload', 'newmail_notifier', 'managesieve'];
\$config['skin'] = 'elastic';
\$config['log_driver'] = 'file';
\$config['log_dir'] = '/app/storage/logs/';
\$config['temp_dir'] = '/app/storage/temp/';
?>
EOF

echo "[configure] Creating SSL certificates..."

# Generate self-signed certificates if not using Let's Encrypt
if [ "$SSL_TYPE" != "letsencrypt" ] || [ ! -f "/app/storage/config/ssl/cert.pem" ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /app/storage/config/ssl/key.pem \
        -out /app/storage/config/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=${BILLIONMAIL_HOSTNAME}"
fi

# Set proper permissions
chmod 600 /app/storage/config/ssl/key.pem
chmod 644 /app/storage/config/ssl/cert.pem

echo "[configure] Configuring OpenDKIM..."

# Configure OpenDKIM
cat > /etc/opendkim.conf <<EOF
Syslog yes
SyslogSuccess yes
LogWhy yes
Canonicalization relaxed/simple
Domain ${BILLIONMAIL_HOSTNAME}
KeyFile /app/storage/config/dkim.key
Selector mail
Socket inet:8891@localhost
PidFile /var/run/opendkim/opendkim.pid
UMask 022
UserID opendkim:opendkim
TemporaryDirectory /tmp
EOF

# Generate DKIM key if not exists
if [ ! -f "/app/storage/config/dkim.key" ]; then
    opendkim-genkey -s mail -d ${BILLIONMAIL_HOSTNAME} -D /app/storage/config/
    mv /app/storage/config/mail.private /app/storage/config/dkim.key
    mv /app/storage/config/mail.txt /app/storage/config/dkim.txt
    chown opendkim:opendkim /app/storage/config/dkim.key
    chmod 600 /app/storage/config/dkim.key
fi

echo "[configure] Configuring BillionMail application..."

# Create BillionMail configuration
cat > /opt/billionmail/.env <<EOF
# Database
DATABASE_URL=${DATABASE_URL}
DB_HOST=${POSTGRES_HOST}
DB_PORT=${POSTGRES_PORT}
DB_NAME=${POSTGRES_DB}
DB_USER=${POSTGRES_USER}
DB_PASSWORD=${POSTGRES_PASSWORD}

# Redis
REDIS_URL=${REDIS_URL}
REDIS_HOST=${REDIS_HOST}
REDIS_PORT=${REDIS_PORT}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Application
APP_ENV=${APP_ENV}
SECRET_KEY=${SECRET_KEY}
DEBUG=false
HOST=0.0.0.0
PORT=8080

# Mail
MAIL_SERVER=localhost
MAIL_PORT=587
MAIL_USE_TLS=true
MAIL_USERNAME=
MAIL_PASSWORD=
DEFAULT_FROM_EMAIL=noreply@${BILLIONMAIL_HOSTNAME}

# Domain
SERVER_NAME=${BILLIONMAIL_HOSTNAME}
ALLOWED_HOSTS=${BILLIONMAIL_HOSTNAME},localhost,127.0.0.1,[::1]

# Storage
UPLOAD_FOLDER=/app/storage/data/uploads
STATIC_FOLDER=/opt/billionmail/static
TEMPLATE_FOLDER=/opt/billionmail/templates
EOF

echo "[configure] Configuration completed successfully!"