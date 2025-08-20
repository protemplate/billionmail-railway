#!/bin/bash

# Wrapper script for running Postfix under supervisord
# Postfix doesn't run as a single process, so we need this wrapper

set -e

# Ensure Postfix directories exist with correct permissions
mkdir -p /var/spool/postfix/etc
mkdir -p /var/spool/postfix/lib
mkdir -p /var/spool/postfix/usr/lib
mkdir -p /var/spool/postfix/pid

# Copy required files to chroot jail
cp /etc/services /var/spool/postfix/etc/
cp /etc/resolv.conf /var/spool/postfix/etc/
cp /etc/nsswitch.conf /var/spool/postfix/etc/
cp -a /lib/x86_64-linux-gnu/libnss_* /var/spool/postfix/lib/ 2>/dev/null || true
cp -a /lib/x86_64-linux-gnu/libresolv* /var/spool/postfix/lib/ 2>/dev/null || true

# Fix permissions
postfix set-permissions 2>/dev/null || true

# Start Postfix
postfix start

# Check if Postfix started successfully
sleep 2
if ! postfix status 2>/dev/null; then
    echo "Failed to start Postfix"
    exit 1
fi

echo "Postfix started successfully"

# Keep the script running and monitor Postfix
while true; do
    # Check if Postfix is still running
    if ! postfix status 2>/dev/null; then
        echo "Postfix has stopped, attempting to restart..."
        postfix start
        sleep 2
        
        if ! postfix status 2>/dev/null; then
            echo "Failed to restart Postfix, exiting..."
            exit 1
        fi
    fi
    
    # Sleep for a while before checking again
    sleep 30
done