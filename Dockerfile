# Build BillionMail for Railway deployment
FROM debian:12-slim

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Install system dependencies and mail server components
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    curl \
    wget \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    supervisor \
    netcat-openbsd \
    jq \
    gettext-base \
    # Build tools
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    # Mail server components
    postfix \
    postfix-pgsql \
    dovecot-core \
    dovecot-imapd \
    dovecot-pop3d \
    dovecot-lmtpd \
    dovecot-pgsql \
    dovecot-sieve \
    dovecot-managesieved \
    # Rspamd (spam filter)
    rspamd \
    redis-tools \
    # Web server and PHP for Roundcube
    nginx \
    php8.2-fpm \
    php8.2-pgsql \
    php8.2-intl \
    php8.2-ldap \
    php8.2-gd \
    php8.2-curl \
    php8.2-xml \
    php8.2-mbstring \
    php8.2-zip \
    php8.2-imap \
    php8.2-opcache \
    php8.2-redis \
    # Additional tools
    opendkim \
    opendkim-tools \
    spamassassin \
    clamav \
    clamav-daemon \
    fail2ban \
    && rm -rf /var/lib/apt/lists/*

# Install Roundcube webmail
RUN cd /tmp && \
    wget https://github.com/roundcube/roundcubemail/releases/download/1.6.6/roundcubemail-1.6.6-complete.tar.gz && \
    tar xzf roundcubemail-1.6.6-complete.tar.gz && \
    mv roundcubemail-1.6.6 /var/www/roundcube && \
    chown -R www-data:www-data /var/www/roundcube && \
    rm -rf /tmp/roundcubemail-*

# Clone BillionMail repository for management interface
RUN git clone https://github.com/aaPanel/BillionMail.git /opt/billionmail && \
    cd /opt/billionmail && \
    git checkout main

# Create directory structure
RUN mkdir -p \
    /app/scripts \
    /app/config \
    /app/storage/mail \
    /app/storage/config \
    /app/storage/logs \
    /app/storage/data \
    /app/storage/temp \
    /var/log/supervisor \
    /var/run/supervisor \
    /etc/postfix/sql \
    /etc/dovecot/sql \
    /var/vmail \
    /var/lib/rspamd

# Create mail user
RUN groupadd -g 5000 vmail && \
    useradd -u 5000 -g vmail -s /usr/sbin/nologin -d /var/vmail -m vmail

# Copy configuration files
COPY supervisord.conf /etc/supervisor/supervisord.conf
COPY scripts/ /app/scripts/
COPY config/ /app/config/

# Make scripts executable
RUN chmod +x /app/scripts/*.sh

# Set up Python virtual environment for BillionMail
RUN python3 -m venv /opt/billionmail/venv && \
    /opt/billionmail/venv/bin/pip install --upgrade pip && \
    /opt/billionmail/venv/bin/pip install \
        flask \
        flask-cors \
        flask-jwt-extended \
        flask-migrate \
        flask-sqlalchemy \
        psycopg2-binary \
        redis \
        celery \
        gunicorn \
        python-dotenv \
        requests \
        cryptography \
        email-validator

# Configure nginx for Railway
RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Set proper permissions
RUN chown -R vmail:vmail /var/vmail /app/storage/mail && \
    chown -R www-data:www-data /var/www/roundcube /app/storage/data && \
    chmod -R 755 /app

# Configure for Railway's IPv6 networking
ENV BIND_ADDRESS=:: \
    HOSTNAME=::

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD /app/scripts/health-check.sh || exit 1

# Expose ports
# Web interface
EXPOSE 80 443
# Mail ports
EXPOSE 25 587 465 143 993 110 995
# Admin interface
EXPOSE 8080

# Start with supervisord
CMD ["/app/scripts/start.sh"]