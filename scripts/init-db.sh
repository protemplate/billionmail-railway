#!/bin/bash
set -e

echo "[init-db] Starting database initialization..."

# Parse DATABASE_URL if provided (Railway format)
if [ -n "$DATABASE_URL" ]; then
    # Extract components from DATABASE_URL
    # Format: postgresql://user:password@host:port/database
    DB_REGEX="postgresql://([^:]+):([^@]+)@([^:]+):([0-9]+)/(.+)"
    if [[ $DATABASE_URL =~ $DB_REGEX ]]; then
        export POSTGRES_USER="${BASH_REMATCH[1]}"
        export POSTGRES_PASSWORD="${BASH_REMATCH[2]}"
        export POSTGRES_HOST="${BASH_REMATCH[3]}"
        export POSTGRES_PORT="${BASH_REMATCH[4]}"
        export POSTGRES_DB="${BASH_REMATCH[5]}"
    fi
fi

# Ensure required variables are set
if [ -z "$POSTGRES_HOST" ] || [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$POSTGRES_DB" ]; then
    echo "[init-db] ERROR: Database configuration missing!"
    echo "[init-db] Required: POSTGRES_HOST, POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB"
    exit 1
fi

# Default port if not set
POSTGRES_PORT=${POSTGRES_PORT:-5432}

# Wait for PostgreSQL to be ready
echo "[init-db] Waiting for PostgreSQL at $POSTGRES_HOST:$POSTGRES_PORT..."
for i in {1..30}; do
    if PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; then
        echo "[init-db] PostgreSQL is ready!"
        break
    fi
    echo "[init-db] Waiting for PostgreSQL... ($i/30)"
    sleep 2
done

# Check if database is already initialized
if PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1 FROM information_schema.tables WHERE table_name = 'users'" > /dev/null 2>&1; then
    echo "[init-db] Database already initialized, skipping..."
    exit 0
fi

echo "[init-db] Initializing database schema..."

# Create database schema
PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
-- Create mail users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    maildir VARCHAR(255) NOT NULL,
    quota BIGINT DEFAULT 1073741824, -- 1GB default
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create virtual domains table
CREATE TABLE IF NOT EXISTS domains (
    id SERIAL PRIMARY KEY,
    domain VARCHAR(255) UNIQUE NOT NULL,
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create virtual aliases table
CREATE TABLE IF NOT EXISTS aliases (
    id SERIAL PRIMARY KEY,
    source VARCHAR(255) NOT NULL,
    destination VARCHAR(255) NOT NULL,
    domain_id INTEGER REFERENCES domains(id) ON DELETE CASCADE,
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(source, destination)
);

-- Create admin users table
CREATE TABLE IF NOT EXISTS admins (
    id SERIAL PRIMARY KEY,
    username VARCHAR(255) UNIQUE NOT NULL,
    password VARCHAR(255) NOT NULL,
    email VARCHAR(255) NOT NULL,
    role VARCHAR(50) DEFAULT 'admin',
    enabled BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create mailbox table for Dovecot
CREATE TABLE IF NOT EXISTS mailbox (
    username VARCHAR(255) PRIMARY KEY,
    password VARCHAR(255) NOT NULL,
    name VARCHAR(255),
    maildir VARCHAR(255) NOT NULL,
    quota BIGINT DEFAULT 0,
    local_part VARCHAR(255) NOT NULL,
    domain VARCHAR(255) NOT NULL,
    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    active CHAR(1) DEFAULT 'Y'
);

-- Create alias table for Postfix
CREATE TABLE IF NOT EXISTS alias (
    address VARCHAR(255) PRIMARY KEY,
    goto TEXT NOT NULL,
    domain VARCHAR(255),
    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    active CHAR(1) DEFAULT 'Y'
);

-- Create domain table for Postfix
CREATE TABLE IF NOT EXISTS domain (
    domain VARCHAR(255) PRIMARY KEY,
    description VARCHAR(255),
    aliases INTEGER DEFAULT 0,
    mailboxes INTEGER DEFAULT 0,
    maxquota BIGINT DEFAULT 0,
    quota BIGINT DEFAULT 0,
    transport VARCHAR(255) DEFAULT 'virtual',
    backupmx CHAR(1) DEFAULT 'N',
    created TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    modified TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    active CHAR(1) DEFAULT 'Y'
);

-- Create sender access control table
CREATE TABLE IF NOT EXISTS sender_access (
    id SERIAL PRIMARY KEY,
    source VARCHAR(255) NOT NULL,
    access VARCHAR(50) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create recipient access control table
CREATE TABLE IF NOT EXISTS recipient_access (
    id SERIAL PRIMARY KEY,
    recipient VARCHAR(255) NOT NULL,
    access VARCHAR(50) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create transport maps table
CREATE TABLE IF NOT EXISTS transport_maps (
    id SERIAL PRIMARY KEY,
    domain VARCHAR(255) NOT NULL,
    transport VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(domain)
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
CREATE INDEX IF NOT EXISTS idx_domains_domain ON domains(domain);
CREATE INDEX IF NOT EXISTS idx_aliases_source ON aliases(source);
CREATE INDEX IF NOT EXISTS idx_aliases_destination ON aliases(destination);
CREATE INDEX IF NOT EXISTS idx_mailbox_username ON mailbox(username);
CREATE INDEX IF NOT EXISTS idx_mailbox_domain ON mailbox(domain);
CREATE INDEX IF NOT EXISTS idx_alias_address ON alias(address);
CREATE INDEX IF NOT EXISTS idx_alias_domain ON alias(domain);

-- Insert default domain if BILLIONMAIL_HOSTNAME is set
INSERT INTO domains (domain, enabled) 
VALUES ('${BILLIONMAIL_HOSTNAME}', true) 
ON CONFLICT (domain) DO NOTHING;

INSERT INTO domain (domain, description, active) 
VALUES ('${BILLIONMAIL_HOSTNAME}', 'Primary mail domain', 'Y') 
ON CONFLICT (domain) DO NOTHING;

-- Create default admin user if variables are set
EOF

# Create admin user if credentials are provided
if [ -n "$ADMIN_EMAIL" ] && [ -n "$ADMIN_PASSWORD" ]; then
    echo "[init-db] Creating admin user..."
    
    # Hash the password using Python (available in the container)
    HASHED_PASSWORD=$(python3 -c "
import hashlib
import os
password = '$ADMIN_PASSWORD'
salt = os.urandom(16).hex()
hashed = hashlib.pbkdf2_hmac('sha256', password.encode(), salt.encode(), 100000).hex()
print(f'{salt}${hashed}')
")
    
    PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
-- Insert admin user
INSERT INTO admins (username, password, email, role, enabled)
VALUES ('admin', '$HASHED_PASSWORD', '$ADMIN_EMAIL', 'superadmin', true)
ON CONFLICT (username) DO UPDATE 
SET password = '$HASHED_PASSWORD', email = '$ADMIN_EMAIL';

-- Create mailbox for admin
INSERT INTO users (email, password, maildir, quota, enabled)
VALUES ('$ADMIN_EMAIL', '$HASHED_PASSWORD', '${ADMIN_EMAIL}/', 10737418240, true)
ON CONFLICT (email) DO NOTHING;

INSERT INTO mailbox (username, password, name, maildir, quota, local_part, domain, active)
VALUES ('$ADMIN_EMAIL', '$HASHED_PASSWORD', 'Administrator', '${ADMIN_EMAIL}/', 10737418240, 
        SPLIT_PART('$ADMIN_EMAIL', '@', 1), SPLIT_PART('$ADMIN_EMAIL', '@', 2), 'Y')
ON CONFLICT (username) DO NOTHING;

-- Add postmaster and abuse aliases
INSERT INTO alias (address, goto, domain, active)
VALUES ('postmaster@${BILLIONMAIL_HOSTNAME}', '$ADMIN_EMAIL', '${BILLIONMAIL_HOSTNAME}', 'Y')
ON CONFLICT (address) DO NOTHING;

INSERT INTO alias (address, goto, domain, active)
VALUES ('abuse@${BILLIONMAIL_HOSTNAME}', '$ADMIN_EMAIL', '${BILLIONMAIL_HOSTNAME}', 'Y')
ON CONFLICT (address) DO NOTHING;
EOF
fi

echo "[init-db] Creating BillionMail application tables..."

# Initialize BillionMail-specific tables
PGPASSWORD=$POSTGRES_PASSWORD psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
-- Create campaigns table
CREATE TABLE IF NOT EXISTS campaigns (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    subject VARCHAR(255) NOT NULL,
    from_email VARCHAR(255) NOT NULL,
    from_name VARCHAR(255),
    reply_to VARCHAR(255),
    html_content TEXT,
    text_content TEXT,
    status VARCHAR(50) DEFAULT 'draft',
    scheduled_at TIMESTAMP,
    sent_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create subscribers table
CREATE TABLE IF NOT EXISTS subscribers (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255),
    status VARCHAR(50) DEFAULT 'active',
    subscribed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    unsubscribed_at TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create lists table
CREATE TABLE IF NOT EXISTS lists (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create list_subscribers junction table
CREATE TABLE IF NOT EXISTS list_subscribers (
    list_id INTEGER REFERENCES lists(id) ON DELETE CASCADE,
    subscriber_id INTEGER REFERENCES subscribers(id) ON DELETE CASCADE,
    subscribed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (list_id, subscriber_id)
);

-- Create email_logs table
CREATE TABLE IF NOT EXISTS email_logs (
    id SERIAL PRIMARY KEY,
    campaign_id INTEGER REFERENCES campaigns(id) ON DELETE SET NULL,
    subscriber_id INTEGER REFERENCES subscribers(id) ON DELETE SET NULL,
    status VARCHAR(50),
    opened BOOLEAN DEFAULT false,
    clicked BOOLEAN DEFAULT false,
    bounced BOOLEAN DEFAULT false,
    sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    opened_at TIMESTAMP,
    clicked_at TIMESTAMP
);

-- Create templates table
CREATE TABLE IF NOT EXISTS templates (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    subject VARCHAR(255),
    html_content TEXT,
    text_content TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create settings table
CREATE TABLE IF NOT EXISTS settings (
    key VARCHAR(255) PRIMARY KEY,
    value TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert default settings
INSERT INTO settings (key, value) VALUES
    ('smtp_host', 'localhost'),
    ('smtp_port', '587'),
    ('smtp_encryption', 'tls'),
    ('smtp_username', ''),
    ('smtp_password', ''),
    ('default_from_email', 'noreply@${BILLIONMAIL_HOSTNAME}'),
    ('default_from_name', 'BillionMail'),
    ('tracking_enabled', 'true'),
    ('bounce_handling_enabled', 'true')
ON CONFLICT (key) DO NOTHING;

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_campaigns_status ON campaigns(status);
CREATE INDEX IF NOT EXISTS idx_subscribers_email ON subscribers(email);
CREATE INDEX IF NOT EXISTS idx_subscribers_status ON subscribers(status);
CREATE INDEX IF NOT EXISTS idx_email_logs_campaign ON email_logs(campaign_id);
CREATE INDEX IF NOT EXISTS idx_email_logs_subscriber ON email_logs(subscriber_id);

-- Grant permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${POSTGRES_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${POSTGRES_USER};
EOF

echo "[init-db] Database initialization completed successfully!"