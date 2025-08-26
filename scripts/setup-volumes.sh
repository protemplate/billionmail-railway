#!/bin/bash
# Setup unified /data volume structure for BillionMail

echo "Setting up /data volume structure..."

# Create all required subdirectories
mkdir -p /data/config \
         /data/vmail \
         /data/postfix-spool \
         /data/rspamd \
         /data/www \
         /data/ssl \
         /data/log \
         /data/backup \
         /data/tmp

# Initialize Postfix spool structure if needed
if [ ! -d /data/postfix-spool/pid ]; then
    echo "Initializing Postfix spool directories..."
    # Create Postfix queue directories
    for dir in active bounce corrupt defer deferred flush hold incoming maildrop pid private public saved trace; do
        mkdir -p /data/postfix-spool/$dir
    done
    
    # Set proper permissions for Postfix
    chown -R postfix:postfix /data/postfix-spool
    chmod 755 /data/postfix-spool
    chmod 700 /data/postfix-spool/private
    chmod 730 /data/postfix-spool/maildrop
    chmod 710 /data/postfix-spool/public
fi

# Create vmail structure
if [ ! -d /data/vmail/domains ]; then
    echo "Initializing vmail directory structure..."
    mkdir -p /data/vmail/domains
    chown -R 5000:5000 /data/vmail
    chmod 700 /data/vmail
fi

# Create Rspamd directories
if [ ! -d /data/rspamd/dkim ]; then
    echo "Initializing Rspamd directories..."
    mkdir -p /data/rspamd/dkim
    mkdir -p /data/rspamd/stats
    chown -R _rspamd:_rspamd /data/rspamd 2>/dev/null || chown -R rspamd:rspamd /data/rspamd
fi

# Create log files if they don't exist
touch /data/log/postfix.log
touch /data/log/dovecot.log
touch /data/log/rspamd.log
touch /data/log/nginx-access.log
touch /data/log/nginx-error.log

# Set log permissions
chmod 644 /data/log/*.log

# Create www directories for web interface
mkdir -p /data/www/roundcube
mkdir -p /data/www/billionmail

# Ensure config directory has proper structure
mkdir -p /data/config/postfix
mkdir -p /data/config/dovecot
mkdir -p /data/config/rspamd
mkdir -p /data/config/nginx

echo "Volume structure setup complete"

# Create symlinks if they don't exist (for compatibility)
[ ! -L /var/vmail ] && ln -sf /data/vmail /var/vmail
[ ! -L /var/spool/postfix ] && ln -sf /data/postfix-spool /var/spool/postfix
[ ! -L /var/lib/rspamd ] && ln -sf /data/rspamd /var/lib/rspamd
[ ! -L /var/www/html ] && ln -sf /data/www /var/www/html
[ ! -L /etc/ssl/mail ] && ln -sf /data/ssl /etc/ssl/mail

echo "Symbolic links created"