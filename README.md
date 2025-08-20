# BillionMail Railway Template

Deploy [BillionMail](https://github.com/aaPanel/BillionMail), a fully self-hosted email marketing platform and mail server, on Railway with one click.

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/billionmail)

## Features

- **Complete Email Server**: SMTP, IMAP, POP3 support with Postfix and Dovecot
- **Webmail Interface**: Roundcube webmail for easy email access
- **Marketing Platform**: Send newsletters and transactional emails
- **Anti-Spam**: Rspamd for spam filtering
- **Security**: DKIM, SPF, and DMARC support
- **Web Admin**: Management interface for email accounts and campaigns
- **Railway Optimized**: Configured for Railway's infrastructure with PostgreSQL and Redis

## Prerequisites

### Railway Services

Before deploying BillionMail, you need to set up these services in your Railway project:

1. **PostgreSQL Database** - Add from Railway template
2. **Redis Cache** - Add from Railway template

These services will be automatically connected to BillionMail using Railway's reference variables.

### Domain Requirements

You'll need a domain name with the ability to configure DNS records:

- **A Record**: Point your mail subdomain (e.g., `mail.yourdomain.com`) to Railway's IP
- **MX Record**: Point to your mail subdomain
- **SPF Record**: `v=spf1 a mx ip4:YOUR_RAILWAY_IP ~all`
- **DKIM Record**: Will be provided after deployment
- **DMARC Record**: `v=DMARC1; p=quarantine; rua=mailto:admin@yourdomain.com`

## Deployment

### Method 1: Deploy from Template (Recommended)

1. Click the "Deploy on Railway" button above
2. Connect your GitHub account
3. Railway will create:
   - PostgreSQL service
   - Redis service
   - BillionMail service (from this repository)
4. Configure environment variables in Railway dashboard

### Method 2: Manual Deployment

1. Fork this repository
2. Create a new Railway project
3. Add PostgreSQL and Redis services
4. Add a new service from your forked GitHub repository
5. Railway will automatically detect the `railway.toml` configuration

## Configuration

### Important Note on railway.toml

The `railway.toml` file contains only Railway-specific build and deploy configuration. Environment variables are NOT set in railway.toml - they must be configured in the Railway dashboard or through the template system.

### Required Environment Variables

Set these in your Railway dashboard's Variables tab:

| Variable | Description | Example |
|----------|-------------|---------|
| `BILLIONMAIL_HOSTNAME` | Your mail server domain | `mail.example.com` |
| `ADMIN_EMAIL` | Administrator email | `admin@example.com` |
| `ADMIN_PASSWORD` | Admin password (auto-generated if using `${{secret()}}`) | - |

### Automatic Variables

When you connect PostgreSQL and Redis services in Railway, these variables are automatically provided through service references:

- `DATABASE_URL` - PostgreSQL connection string (from `${{Postgres.DATABASE_URL}}`)
- `REDIS_URL` - Redis connection string (from `${{Redis.REDIS_URL}}`)
- `RAILWAY_PUBLIC_DOMAIN` - Your Railway public domain
- `PORT` - Application port

### Template Variables

If deploying via Railway template, all environment variables are pre-configured in `railway.json` with proper references to PostgreSQL and Redis services.

### Optional Configuration

See `.env.example` for all available configuration options. These can be added in the Railway dashboard's Variables tab.

## Post-Deployment Setup

### 1. Configure DNS Records

After deployment, configure your domain's DNS:

```
Type    Name    Value                   TTL
A       mail    YOUR_RAILWAY_IP         3600
MX      @       mail.yourdomain.com     3600 (Priority: 10)
TXT     @       v=spf1 a mx ~all        3600
```

### 2. Get DKIM Key

SSH into your Railway service or check logs for the DKIM public key:

```bash
railway logs | grep "DKIM"
```

Add the DKIM record to your DNS:

```
Type    Name              Value
TXT     mail._domainkey   v=DKIM1; k=rsa; p=YOUR_DKIM_PUBLIC_KEY
```

### 3. Configure Railway TCP Proxy

For mail protocols, configure Railway TCP Proxy:

1. Go to your BillionMail service settings
2. Add TCP Proxy for ports:
   - 25 (SMTP)
   - 587 (Submission)
   - 993 (IMAPS)
   - 995 (POP3S)

### 4. Access Services

- **Webmail**: `https://YOUR_RAILWAY_DOMAIN`
- **Admin Panel**: `https://YOUR_RAILWAY_DOMAIN:8080`
- **API**: `https://YOUR_RAILWAY_DOMAIN/api`

Default credentials:
- Username: `admin`
- Password: The one you set in environment variables

## Email Client Configuration

Configure email clients with these settings:

### Incoming Mail
- **IMAP Server**: `mail.yourdomain.com`
- **Port**: 993 (SSL/TLS)
- **Username**: Your full email address
- **Password**: Your email password

### Outgoing Mail
- **SMTP Server**: `mail.yourdomain.com`
- **Port**: 587 (STARTTLS)
- **Username**: Your full email address
- **Password**: Your email password

## Monitoring

### Health Check

The service includes a comprehensive health check at `/health` that monitors:
- Database connectivity
- Redis connectivity
- Mail services (Postfix, Dovecot, Rspamd)
- Web services (Nginx, PHP-FPM)
- API services

### Logs

View logs in Railway dashboard or via CLI:

```bash
railway logs -s billionmail
```

## Troubleshooting

### Service Won't Start

1. Check environment variables are set correctly
2. Verify PostgreSQL and Redis services are running
3. Check logs for specific errors:
   ```bash
   railway logs | grep ERROR
   ```

### Can't Send/Receive Email

1. Verify DNS records are configured correctly
2. Check if ports are accessible:
   ```bash
   telnet mail.yourdomain.com 25
   ```
3. Review mail logs in Railway dashboard

### Database Connection Failed

1. Ensure PostgreSQL service is running
2. Check DATABASE_URL is properly set
3. Verify network connectivity between services

### Performance Issues

1. Scale your Railway services:
   - Increase PostgreSQL resources
   - Add more Redis memory
2. Enable caching in environment variables
3. Monitor resource usage in Railway dashboard

## Security Considerations

1. **Change default passwords** immediately after deployment
2. **Enable 2FA** for admin accounts
3. **Configure firewall rules** if needed
4. **Regular updates**: Keep the image updated
5. **Monitor logs** for suspicious activity
6. **Backup data** regularly using Railway volumes

## Backup and Recovery

### Automated Backups

The template includes a backup script that runs daily. Backups are stored in `/app/storage/backups`.

### Manual Backup

```bash
railway run scripts/backup.sh
```

### Restore

1. Stop the service
2. Restore database from backup
3. Copy mail files from backup
4. Restart service

## Development

### Local Development

1. Clone the repository
2. Copy `.env.example` to `.env`
3. Configure local PostgreSQL and Redis
4. Build and run with Docker:

```bash
docker build -t billionmail-railway .
docker run -p 80:80 --env-file .env billionmail-railway
```

### Testing

Run health checks:

```bash
./scripts/health-check.sh
```

## Support

- [BillionMail Documentation](https://github.com/aaPanel/BillionMail)
- [Railway Documentation](https://docs.railway.app)
- [Issues](https://github.com/yourusername/billionmail-railway/issues)

## License

This Railway template is open source. BillionMail is licensed under AGPLv3.

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

## Credits

- [BillionMail](https://github.com/aaPanel/BillionMail) - The email platform
- [Railway](https://railway.app) - Hosting platform
- [Postfix](http://www.postfix.org/) - Mail transfer agent
- [Dovecot](https://www.dovecot.org/) - IMAP/POP3 server
- [Roundcube](https://roundcube.net/) - Webmail client
- [Rspamd](https://rspamd.com/) - Spam filtering