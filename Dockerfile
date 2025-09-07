# Unified BillionMail container for Railway with single /data volume
FROM alpine:3.20

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    supervisor \
    postgresql16-client \
    redis \
    curl \
    jq \
    netcat-openbsd \
    tzdata \
    ca-certificates \
    openssl \
    # Mail server essentials
    postfix \
    postfix-pgsql \
    postfix-pcre \
    dovecot \
    dovecot-pgsql \
    dovecot-lmtpd \
    rspamd \
    rspamd-client \
    # SMTP authentication and delivery
    cyrus-sasl \
    cyrus-sasl-login \
    opendkim \
    # Python for API transport
    python3 \
    py3-pip \
    py3-requests \
    # Additional tools
    fail2ban \
    rsyslog \
    nginx \
    php82 \
    php82-fpm \
    php82-pgsql \
    php82-imap \
    php82-intl \
    php82-ldap \
    php82-gd \
    php82-curl \
    php82-xml \
    php82-mbstring \
    php82-zip \
    php82-opcache \
    php82-redis

# Create unified directory structure under /data
RUN mkdir -p \
    /data/config \
    /data/vmail \
    /data/postfix-spool \
    /data/rspamd \
    /data/www \
    /data/ssl \
    /data/log \
    /data/backup \
    /data/tmp \
    /data/dkim \
    /var/run/opendkim

# Create mail user (skip if already exists from dovecot package)
RUN addgroup -g 5000 vmail 2>/dev/null || true && \
    adduser -u 5000 -G vmail -s /sbin/nologin -D vmail 2>/dev/null || true

# Copy wrapper scripts
COPY scripts/unified-start.sh /usr/local/bin/
COPY scripts/setup-volumes.sh /usr/local/bin/
COPY scripts/health-check.sh /usr/local/bin/
COPY scripts/configure-smtp.sh /usr/local/bin/
COPY supervisord-unified.conf /etc/supervisor/supervisord.conf

# Make scripts executable
RUN chmod +x /usr/local/bin/*.sh

# Set up symbolic links to redirect standard paths to /data
RUN ln -sf /data/vmail /var/vmail && \
    ln -sf /data/postfix-spool /var/spool/postfix && \
    ln -sf /data/rspamd /var/lib/rspamd && \
    ln -sf /data/www /var/www/html && \
    ln -sf /data/ssl /etc/ssl/mail && \
    ln -sf /data/config /etc/billionmail

# Configure services to use /data paths
RUN echo "mail_location = maildir:/data/vmail/%d/%n/Maildir" > /etc/dovecot/conf.d/10-mail.conf && \
    echo "queue_directory = /data/postfix-spool" >> /etc/postfix/main.cf && \
    echo "dbdir = /data/rspamd" >> /etc/rspamd/local.d/redis.conf

# Railway manages volumes externally - no VOLUME instruction needed
# All persistent data will be stored under /data when mounted via Railway

# Environment variables
ENV TZ=UTC \
    HOSTNAME=mail.example.com \
    ADMIN_EMAIL=admin@example.com

# Expose ports
EXPOSE 25 587 465 143 993 110 995 80 443

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD /usr/local/bin/health-check.sh || exit 1

# Start with unified script
ENTRYPOINT ["/usr/local/bin/unified-start.sh"]