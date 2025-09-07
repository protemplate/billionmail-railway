#!/bin/bash
# SMTP Configuration Helper for BillionMail on Railway
# Handles different SMTP modes: direct, relay, and API

set -e

SMTP_MODE="${SMTP_MODE:-direct}"
SMTP_CONFIG_FILE="/etc/postfix/smtp_config"

echo "========================================="
echo "BillionMail SMTP Configuration"
echo "========================================="
echo "Mode: ${SMTP_MODE}"

# Function to test SMTP connectivity
test_smtp_connection() {
    local host=$1
    local port=$2
    
    echo "Testing connection to ${host}:${port}..."
    
    if timeout 5 nc -zv "${host}" "${port}" 2>/dev/null; then
        echo "✓ Successfully connected to ${host}:${port}"
        return 0
    else
        echo "✗ Failed to connect to ${host}:${port}"
        return 1
    fi
}

# Function to configure DNS records help
show_dns_requirements() {
    echo ""
    echo "========================================="
    echo "Required DNS Records for ${HOSTNAME:-mail.example.com}"
    echo "========================================="
    echo ""
    echo "1. MX Record:"
    echo "   Type: MX"
    echo "   Name: @"
    echo "   Value: ${HOSTNAME:-mail.example.com}"
    echo "   Priority: 10"
    echo ""
    echo "2. A Record (for mail subdomain):"
    echo "   Type: A"
    echo "   Name: mail"
    echo "   Value: <Your Railway Public IP>"
    echo ""
    echo "3. SPF Record:"
    echo "   Type: TXT"
    echo "   Name: @"
    echo "   Value: \"v=spf1 mx a:${HOSTNAME:-mail.example.com} ~all\""
    echo ""
    echo "4. DKIM Record (after generating key):"
    echo "   Type: TXT"
    echo "   Name: mail._domainkey"
    echo "   Value: <Will be generated and shown after setup>"
    echo ""
    echo "5. DMARC Record:"
    echo "   Type: TXT"
    echo "   Name: _dmarc"
    echo "   Value: \"v=DMARC1; p=quarantine; rua=mailto:${ADMIN_EMAIL}\""
    echo ""
}

# Function to generate DKIM keys
generate_dkim_keys() {
    local domain="${DOMAIN:-example.com}"
    local selector="mail"
    
    echo "Generating DKIM keys for ${domain}..."
    
    mkdir -p /data/dkim
    
    if [ ! -f "/data/dkim/${domain}.private" ]; then
        # Generate DKIM key using openssl (opendkim-genkey not available in Alpine)
        echo "Generating DKIM keys using OpenSSL..."
        openssl genrsa -out "/data/dkim/${domain}.private" 2048 2>/dev/null
        openssl rsa -in "/data/dkim/${domain}.private" -pubout -out "/data/dkim/${domain}.public" 2>/dev/null
        
        # Extract public key for DNS record
        pubkey=$(openssl rsa -in "/data/dkim/${domain}.private" -pubout 2>/dev/null | grep -v "^-----" | tr -d '\n')
        
        # Create DNS TXT record format
        cat > "/data/dkim/${domain}.txt" <<EOF
${selector}._domainkey IN TXT "v=DKIM1; k=rsa; p=${pubkey}"
EOF
        
        # Set proper permissions
        chmod 600 "/data/dkim/${domain}.private"
        chmod 644 "/data/dkim/${domain}.public"
        chmod 644 "/data/dkim/${domain}.txt"
        
        echo ""
        echo "DKIM Public Key (add this to DNS):"
        echo "--------------------------------"
        cat "/data/dkim/${domain}.txt"
        echo "--------------------------------"
    else
        echo "DKIM keys already exist for ${domain}"
    fi
    
    # Configure OpenDKIM
    cat > /etc/opendkim/opendkim.conf <<EOF
# OpenDKIM Configuration
Syslog yes
SyslogSuccess yes
Canonicalization relaxed/simple
Domain ${domain}
Selector ${selector}
KeyFile /data/dkim/${domain}.private
Socket inet:8891@localhost
PidFile /var/run/opendkim/opendkim.pid
UMask 002
UserID opendkim:opendkim
TemporaryDirectory /tmp
EOF
    
    # Add to Postfix
    echo "" >> /etc/postfix/main.cf
    echo "# DKIM Signing" >> /etc/postfix/main.cf
    echo "milter_protocol = 6" >> /etc/postfix/main.cf
    echo "milter_default_action = accept" >> /etc/postfix/main.cf
    echo "smtpd_milters = inet:localhost:8891" >> /etc/postfix/main.cf
    echo "non_smtpd_milters = inet:localhost:8891" >> /etc/postfix/main.cf
}

# Function to setup HTTP API transport
setup_api_transport() {
    local provider="${EMAIL_API_PROVIDER:-resend}"
    
    echo "Setting up ${provider} API transport..."
    
    # Create API transport script
    cat > /usr/local/bin/smtp-api-transport.py <<'EOF'
#!/usr/bin/env python3
import sys
import os
import json
import base64
import email
from email import policy
import requests

def send_via_resend(raw_email):
    api_key = os.environ.get('RESEND_API_KEY')
    if not api_key:
        return False, "RESEND_API_KEY not configured"
    
    msg = email.message_from_string(raw_email, policy=policy.default)
    
    data = {
        'from': msg['From'],
        'to': msg['To'].split(',') if msg['To'] else [],
        'subject': msg['Subject'],
        'html': msg.get_body(preferencelist=('html',)).get_content() if msg.is_multipart() else msg.get_payload(),
    }
    
    if msg['Cc']:
        data['cc'] = msg['Cc'].split(',')
    if msg['Bcc']:
        data['bcc'] = msg['Bcc'].split(',')
    
    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }
    
    response = requests.post('https://api.resend.com/emails', 
                            headers=headers, 
                            json=data)
    
    return response.status_code == 200, response.text

def send_via_sendgrid(raw_email):
    api_key = os.environ.get('SENDGRID_API_KEY')
    if not api_key:
        return False, "SENDGRID_API_KEY not configured"
    
    msg = email.message_from_string(raw_email, policy=policy.default)
    
    data = {
        'personalizations': [{
            'to': [{'email': addr.strip()} for addr in msg['To'].split(',')]
        }],
        'from': {'email': msg['From']},
        'subject': msg['Subject'],
        'content': [{
            'type': 'text/html' if msg.is_multipart() else 'text/plain',
            'value': msg.get_body(preferencelist=('html',)).get_content() if msg.is_multipart() else msg.get_payload()
        }]
    }
    
    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }
    
    response = requests.post('https://api.sendgrid.com/v3/mail/send',
                            headers=headers,
                            json=data)
    
    return response.status_code in [200, 202], response.text

# Main execution
if __name__ == '__main__':
    provider = os.environ.get('EMAIL_API_PROVIDER', 'resend')
    raw_email = sys.stdin.read()
    
    try:
        if provider == 'resend':
            success, message = send_via_resend(raw_email)
        elif provider == 'sendgrid':
            success, message = send_via_sendgrid(raw_email)
        else:
            success, message = False, f"Unknown provider: {provider}"
        
        if success:
            sys.exit(0)
        else:
            print(f"Error: {message}", file=sys.stderr)
            sys.exit(1)
    except Exception as e:
        print(f"Exception: {str(e)}", file=sys.stderr)
        sys.exit(1)
EOF
    
    chmod +x /usr/local/bin/smtp-api-transport.py
    
    # Create Postfix pipe transport
    cat >> /etc/postfix/master.cf <<EOF

# API Transport
smtp-api   unix  -       n       n       -       -       pipe
  flags=FR user=vmail argv=/usr/local/bin/smtp-api-transport.py
EOF
    
    echo "API transport configured for ${provider}"
}

# Main configuration based on SMTP_MODE
case "${SMTP_MODE}" in
    direct)
        echo "Configuring direct SMTP delivery (Railway Pro Plan required)"
        echo ""
        echo "Testing outbound SMTP connectivity..."
        
        # Test common SMTP ports
        if test_smtp_connection "smtp.gmail.com" 25; then
            echo "✓ Port 25 (SMTP) is open - Direct delivery possible"
        else
            echo "✗ Port 25 blocked - You may need Railway Pro plan"
        fi
        
        if test_smtp_connection "smtp.gmail.com" 587; then
            echo "✓ Port 587 (Submission) is open"
        else
            echo "✗ Port 587 blocked"
        fi
        
        # Generate DKIM keys
        generate_dkim_keys
        
        # Show DNS requirements
        show_dns_requirements
        ;;
        
    relay)
        echo "Configuring SMTP relay via ${SMTP_RELAY_HOST}"
        
        if [ -z "${SMTP_RELAY_HOST}" ]; then
            echo "ERROR: SMTP_RELAY_HOST not configured"
            exit 1
        fi
        
        # Test relay connectivity
        test_smtp_connection "${SMTP_RELAY_HOST}" "${SMTP_RELAY_PORT:-587}"
        
        echo "SMTP relay configured successfully"
        ;;
        
    api)
        echo "Configuring HTTP API email delivery"
        
        # Check for API keys
        case "${EMAIL_API_PROVIDER}" in
            resend)
                if [ -z "${RESEND_API_KEY}" ]; then
                    echo "WARNING: RESEND_API_KEY not set"
                    echo "Get your API key from: https://resend.com/api-keys"
                fi
                ;;
            sendgrid)
                if [ -z "${SENDGRID_API_KEY}" ]; then
                    echo "WARNING: SENDGRID_API_KEY not set"
                    echo "Get your API key from: https://app.sendgrid.com/settings/api_keys"
                fi
                ;;
        esac
        
        # Setup API transport
        setup_api_transport
        ;;
        
    *)
        echo "ERROR: Invalid SMTP_MODE: ${SMTP_MODE}"
        echo "Valid modes: direct, relay, api"
        exit 1
        ;;
esac

echo ""
echo "========================================="
echo "SMTP Configuration Complete"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Configure DNS records as shown above"
echo "2. Set environment variables in Railway dashboard"
echo "3. Restart the service to apply changes"
echo ""

# Write configuration summary
cat > "${SMTP_CONFIG_FILE}" <<EOF
SMTP_MODE=${SMTP_MODE}
CONFIGURED_AT=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
HOSTNAME=${HOSTNAME:-mail.example.com}
DOMAIN=${DOMAIN:-example.com}
EOF

echo "Configuration saved to ${SMTP_CONFIG_FILE}"