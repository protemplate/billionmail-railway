# Railway TCP Proxy Configuration Guide for BillionMail

This guide explains how to configure TCP proxies in Railway for BillionMail's mail services, since Railway doesn't support direct exposure of standard mail ports.

## Understanding Railway's Networking Model

Railway provides two types of networking for services:

1. **HTTP/HTTPS Traffic**: Automatically routed through port 443 with domain-based routing
2. **TCP Traffic**: Requires TCP Proxy configuration with generated endpoints

For mail services (SMTP, IMAP, POP3), we must use TCP Proxies.

## Step-by-Step TCP Proxy Configuration

### 1. Access Network Settings

1. Log into Railway Dashboard
2. Navigate to your BillionMail service
3. Click on "Settings" tab
4. Scroll to "Networking" section

### 2. Enable TCP Proxy for Each Mail Service

You'll need to create a TCP proxy for each mail protocol port:

#### SMTP Services

**Standard SMTP (Port 25)**
- Click "Add TCP Proxy"
- Internal Port: `25`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`
- Save the endpoint for mail server configuration

**SMTP Submission (Port 587)**
- Click "Add TCP Proxy"
- Internal Port: `587`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`
- This is for authenticated client submissions

**Secure SMTP (Port 465)**
- Click "Add TCP Proxy"
- Internal Port: `465`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`
- For SSL/TLS encrypted SMTP

#### IMAP Services

**Standard IMAP (Port 143)**
- Click "Add TCP Proxy"
- Internal Port: `143`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`

**Secure IMAP (Port 993)**
- Click "Add TCP Proxy"
- Internal Port: `993`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`
- Most mail clients will use this

#### POP3 Services

**Standard POP3 (Port 110)**
- Click "Add TCP Proxy"
- Internal Port: `110`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`

**Secure POP3 (Port 995)**
- Click "Add TCP Proxy"
- Internal Port: `995`
- Railway generates: `tcp-[unique-id].up.railway.app:[port]`

### 3. Document Your Endpoints

After creating all TCP proxies, you'll have a mapping like this:

| Service | Standard Port | Railway Endpoint | Railway Port |
|---------|--------------|------------------|--------------|
| SMTP | 25 | tcp-abc123.up.railway.app | 10025 |
| SMTP Submission | 587 | tcp-def456.up.railway.app | 10587 |
| SMTPS | 465 | tcp-ghi789.up.railway.app | 10465 |
| IMAP | 143 | tcp-jkl012.up.railway.app | 10143 |
| IMAPS | 993 | tcp-mno345.up.railway.app | 10993 |
| POP3 | 110 | tcp-pqr678.up.railway.app | 10110 |
| POP3S | 995 | tcp-stu901.up.railway.app | 10995 |

**Important**: Save these endpoints! You'll need them for:
- Mail client configuration
- DNS documentation
- User setup guides

## Configuring Mail Clients

### Desktop Mail Clients (Outlook, Thunderbird, Apple Mail)

**Incoming Mail (IMAP)**
```
Server: tcp-mno345.up.railway.app
Port: 10993
Security: SSL/TLS
Username: user@yourdomain.com
Password: [user password]
```

**Outgoing Mail (SMTP)**
```
Server: tcp-def456.up.railway.app
Port: 10587
Security: STARTTLS
Authentication: Required
Username: user@yourdomain.com
Password: [user password]
```

### Mobile Mail Clients

The configuration is similar, but note that some mobile clients may not accept non-standard ports. In such cases, you may need to use a mail app that supports custom port configuration.

## Environment Variables for Port Binding

Add these environment variables to your Railway service to ensure proper internal port binding:

```bash
# Port binding configuration
PORT=80
HTTP_PORT=80
HTTPS_PORT=443
SMTP_PORT=25
SUBMISSION_PORT=587
SMTPS_PORT=465
IMAP_PORT=143
IMAPS_PORT=993
POP3_PORT=110
POP3S_PORT=995

# Tell services to bind to all interfaces
BIND_ADDRESS=0.0.0.0
```

## Testing Your Configuration

### Test SMTP Connection
```bash
# Using telnet (replace with your actual endpoint)
telnet tcp-def456.up.railway.app 10587

# Using openssl for secure connection
openssl s_client -connect tcp-def456.up.railway.app:10587 -starttls smtp
```

### Test IMAP Connection
```bash
# Test secure IMAP
openssl s_client -connect tcp-mno345.up.railway.app:10993
```

### Test with Mail Client
1. Configure a test email client with the Railway endpoints
2. Try sending a test email
3. Try receiving email
4. Check Railway logs if connection fails

## Troubleshooting Common Issues

### Connection Refused
- Verify the service is running (check Railway logs)
- Ensure the internal port matches the service configuration
- Check that the service binds to `0.0.0.0` not `127.0.0.1`

### Authentication Failed
- Verify username includes full email address
- Check password is correct
- Ensure user exists in the mail system

### SSL/TLS Errors
- Verify SSL certificates are properly configured
- Try different security settings (SSL vs STARTTLS)
- Check that ports match security type

### Timeout Issues
- Railway TCP proxies have a default timeout
- Ensure your mail client sends keepalive packets
- Check Railway service logs for disconnection reasons

## Production Considerations

### DNS and MX Records

While you can receive mail through Railway's TCP proxies, there are challenges:

1. **MX Records**: Must point to a hostname and standard port 25
2. **Railway Limitation**: TCP proxies use non-standard ports
3. **Solution Options**:
   - Use external SMTP relay for receiving mail
   - Set up port forwarding through a VPS
   - Use Railway for sending only, external service for receiving

### Email Reputation

- Railway IPs are shared and dynamic
- Consider using an SMTP relay service (SendGrid, AWS SES) for better deliverability
- Configure SPF, DKIM, and DMARC records properly

### Workarounds for Standard Ports

If you absolutely need standard mail ports:

1. **Cloudflare Spectrum** (Enterprise)
   - Can proxy TCP traffic on standard ports
   - Requires enterprise plan
   - Maps standard ports to Railway endpoints

2. **VPS Bridge**
   ```nginx
   # Example nginx stream configuration on external VPS
   stream {
       upstream railway_smtp {
           server tcp-def456.up.railway.app:10587;
       }
       
       server {
           listen 587;
           proxy_pass railway_smtp;
       }
   }
   ```

3. **Hybrid Architecture**
   - Web interface on Railway
   - Mail services on traditional VPS
   - Shared database between services

## Alternative Deployment Strategies

### For Development/Testing
Railway's TCP proxy setup works well for:
- Development environments
- Internal mail systems
- Testing deployments

### For Production
Consider these alternatives:
- **Traditional VPS**: Full control over ports
- **Kubernetes**: With LoadBalancer services
- **Dedicated Mail Hosting**: Services like MXRoute
- **Hybrid Setup**: Railway for web, external for mail

## Summary

Railway's TCP proxy system allows you to run mail services, but with non-standard ports. This works for:
- Internal mail systems
- Development environments
- Controlled user bases who can configure custom ports

For public-facing mail servers expecting standard ports, consider alternative deployment strategies or proxy solutions.