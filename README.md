# BillionMail Railway Deployment Guide

Deploy [BillionMail](https://github.com/aaPanel/BillionMail) email marketing platform on Railway using a unified container optimized for Railway's single-volume limitation.

## About BillionMail

BillionMail is a comprehensive, self-hosted email marketing platform that includes:
- **Complete Mail Server**: SMTP, IMAP, POP3 with Postfix and Dovecot
- **Email Marketing**: Campaign management, newsletters, analytics
- **Webmail Interface**: Full-featured webmail client
- **Spam Protection**: Advanced filtering with Rspamd
- **Privacy-First**: Completely self-hosted solution
- **Unlimited Sending**: No monthly limits or restrictions

## Prerequisites

- Railway account (Pro plan required for SMTP functionality)
- Custom domain for mail services
- GitHub account (for repository-based deployments)

> **⚠️ Important Railway Limitations**:
> - **SMTP ports (25, 465, 587) only work on Pro plans** - Free/Hobby plans must use HTTP API services
> - **Single volume per service** - This deployment uses a unified container with `/data` volume
> - **No static IPs** - May affect email deliverability reputation

## Deployment Instructions

This deployment uses a unified container approach that combines all BillionMail services into a single deployable unit, optimized for Railway's infrastructure constraints.

### Step 1: Create a New Railway Project

1. Log into [Railway](https://railway.app)
2. Click "New Project"
3. Name your project "BillionMail"

### Step 2: Deploy PostgreSQL Database

1. Click "New" → "Database" → "Add PostgreSQL"
2. Note the connection details from the Variables tab:
   - `DATABASE_URL`
   - `PGHOST`
   - `PGPORT`
   - `PGUSER`
   - `PGPASSWORD`
   - `PGDATABASE`

### Step 3: Deploy Redis Cache

1. Click "New" → "Database" → "Add Redis"
2. Note the `REDIS_URL` from the Variables tab

### Step 4: Deploy BillionMail Unified Container

1. Click "New" → "GitHub Repo" → Connect this repository
2. Or use "Docker Image" with your custom build
3. Add environment variables:
   ```
   HOSTNAME=mail.yourdomain.com
   DOMAIN=yourdomain.com
   ADMIN_EMAIL=admin@yourdomain.com
   ADMIN_PASSWORD=YourSecurePassword
   SECRET_KEY=YourSecretKey  # Generate with: openssl rand -hex 32
   TZ=UTC
   DATABASE_URL=${{Postgres.DATABASE_URL}}
   REDIS_URL=${{Redis.REDIS_URL}}
   DB_INIT=true
   
   # For non-Pro plans (use HTTP API for email):
   SMTP_MODE=api
   EMAIL_API_PROVIDER=resend
   RESEND_API_KEY=your-resend-api-key
   
   # For Pro plans (direct SMTP):
   SMTP_MODE=direct
   ```
4. Add volume in Settings → Volumes:
   - Mount path: `/data`
5. Configure networking (see Network Configuration section below)
6. Generate domain and note the URL

## Network Configuration on Railway

### Important: Railway Port Limitations

Railway has specific networking constraints for mail servers:

1. **HTTP/HTTPS Traffic**: Works normally through Railway domains
2. **SMTP Ports (25, 465, 587)**: **Only available on Pro plan** - Free/Hobby plans blocked
3. **IMAP/POP3 Ports**: Available on all plans via TCP Proxy

### Setting Up TCP Proxies

After deployment, configure TCP proxies in the Railway dashboard:

1. Go to your BillionMail service → Settings → Networking
2. Under "TCP Proxy", add configurations for each mail port:

| Service | Internal Port | Purpose |
|---------|--------------|---------|
| SMTP | 25 | Standard mail transfer |
| SMTP Submission | 587 | Client mail submission |
| SMTPS | 465 | Secure SMTP |
| IMAP | 143 | Mail retrieval |
| IMAPS | 993 | Secure IMAP |
| POP3 | 110 | Mail download |
| POP3S | 995 | Secure POP3 |

3. Railway will generate unique endpoints for each TCP proxy:
   - Example: `tcp-proxy-abc123.up.railway.app:12345`
   - Note these endpoints for mail client configuration

### Mail Client Configuration with Railway

Due to Railway's TCP proxy system, mail clients must use Railway-generated endpoints:

**IMAP Settings:**
- Server: `[railway-generated-domain]`
- Port: `[railway-generated-port]`
- Security: SSL/TLS

**SMTP Settings:**
- Server: `[railway-generated-domain]`
- Port: `[railway-generated-port]`
- Security: STARTTLS or SSL/TLS

**Note**: Standard mail ports (25, 587, 993, etc.) are NOT directly accessible. Use the Railway-generated endpoints instead.

### Alternative: External Proxy Solution

For standard port access, consider:
1. **Cloudflare Spectrum** (paid): Proxy standard ports to Railway endpoints
2. **VPS Proxy**: Set up nginx/HAProxy on a VPS to forward traffic
3. **Hybrid Setup**: Use Railway for web interface, external server for mail

## Volume Structure

The unified container organizes all data under `/data`:
```
/data/
├── config/          # Service configurations
├── vmail/           # Email storage (Dovecot)
├── postfix-spool/   # Mail queue (Postfix)
├── rspamd/          # Spam filter data
├── www/             # Web interface files
├── ssl/             # SSL certificates
├── log/             # Unified logs
├── backup/          # Backup storage
└── tmp/             # Temporary files
```

## DNS Configuration

Configure these DNS records for your domain:

```
Type    Name    Value                   TTL     Priority
A       mail    YOUR_RAILWAY_IP         3600    -
MX      @       mail.yourdomain.com     3600    10
TXT     @       v=spf1 a mx ~all        3600    -
```

### DKIM Setup

1. Check the BillionMail Core service logs for DKIM key
2. Add TXT record: `mail._domainkey` with the DKIM public key

## Post-Deployment Checklist

- [ ] All services are running (check Railway dashboard)
- [ ] DNS records are configured
- [ ] SPF record is set
- [ ] DKIM is configured
- [ ] Test email sending via SMTP (port 587)
- [ ] Test email receiving
- [ ] Access webmail interface
- [ ] Configure firewall rules if needed
- [ ] Set up email accounts
- [ ] Configure backup strategy

## Access Points

### Web Interface
- **Admin Panel**: `https://[your-billionmail-core-domain].railway.app`
- **Webmail**: `https://[your-billionmail-core-domain].railway.app/webmail`

### Email Client Settings

**Important**: Use the Railway-generated TCP proxy endpoints from your dashboard, NOT standard ports.

Example configuration after setting up TCP proxies:
- **IMAP Server**: `tcp-imap-[id].up.railway.app`
  - Port: `[railway-generated-port]` (e.g., 10234)
  - Security: SSL/TLS
- **SMTP Server**: `tcp-smtp-[id].up.railway.app`
  - Port: `[railway-generated-port]` (e.g., 10567)
  - Security: STARTTLS

Check your Railway dashboard → Networking → TCP Proxy for actual endpoints.

## Troubleshooting

### Services Won't Start
- Check environment variables are correctly set
- Verify database connections
- Check Railway service logs

### Email Not Sending
1. Verify SMTP ports are accessible
2. Check Postfix logs in Railway
3. Ensure DNS MX records are correct
4. Verify authentication settings

### Email Not Receiving
1. Check MX records point to correct server
2. Verify Dovecot is running
3. Check firewall isn't blocking ports
4. Review Dovecot logs

### Connection Issues Between Services
- Ensure private networking is enabled
- Use `.railway.internal` hostnames
- Check service discovery is working

## Local Development

For local testing:
```bash
# Build the unified container
docker build -t billionmail-railway .

# Run with local volume
docker run -d \
  -v billionmail-data:/data \
  -p 80:80 -p 443:443 \
  -p 25:25 -p 587:587 -p 465:465 \
  -p 143:143 -p 993:993 \
  -p 110:110 -p 995:995 \
  --env-file .env \
  billionmail-railway
```

For multi-container testing, use the provided `docker-compose.yml`.

## Security Recommendations

1. **Use Strong Passwords**: Generate secure passwords for all services
2. **Enable 2FA**: On your Railway account
3. **Regular Updates**: Keep Docker images updated
4. **Monitor Logs**: Check for suspicious activity
5. **Backup Data**: Regular backups of volumes
6. **SSL/TLS**: Always use encrypted connections
7. **Firewall Rules**: Restrict access to necessary ports only

## Railway-Specific Architecture

### Unified Container Approach
This deployment uses a custom unified container that:
- Combines all BillionMail services (Postfix, Dovecot, Rspamd, web interface)
- Uses supervisord to manage multiple processes
- Stores all persistent data under a single `/data` volume
- Redirects standard service paths to `/data` subdirectories via symlinks

### Benefits
- **Single Volume Compliance**: Works within Railway's one-volume-per-service limit
- **Simplified Deployment**: One container instead of multiple services
- **Unified Logging**: All logs in `/data/log` for easy debugging
- **Persistent Data**: All mail, configuration, and state data persists across restarts

## Limitations on Railway

### Plan-Based Restrictions
- **Free/Trial/Hobby Plans**: 
  - ❌ No SMTP ports (25, 465, 587) - must use HTTP API services
  - ✅ Web interface and management features work
  - ✅ Can receive email via IMAP/POP3
  - ⚠️ Outbound email only via API (Resend, SendGrid, etc.)

- **Pro Plan**:
  - ✅ Full SMTP functionality available
  - ✅ All mail protocols supported
  - ⚠️ Still uses TCP proxy endpoints (non-standard ports)

### General Railway Limitations
- **Non-Standard Mail Ports**: Railway uses TCP proxies with generated endpoints
- **No Static IPs**: May affect email deliverability reputation
- **Single Volume**: All data must be stored under `/data`
- **Egress Limits**: Check plan limits for bulk email sending

## Recommended Alternatives

For production email servers, consider:
- **VPS Providers**: DigitalOcean, Linode, Vultr
- **Dedicated Mail Hosting**: MXRoute, Migadu
- **Managed Solutions**: AWS SES, SendGrid, Mailgun

## Support

- [BillionMail Documentation](https://github.com/aaPanel/BillionMail)
- [Railway Documentation](https://docs.railway.app)
- [Railway Discord](https://discord.gg/railway)

## License

This deployment guide is provided as-is. BillionMail is licensed under AGPLv3.