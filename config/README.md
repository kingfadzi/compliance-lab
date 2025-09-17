# Configuration Template

This directory contains a template configuration file for any environment.

## Quick Start

1. **Copy the template** for your environment:
   ```bash
   # For any environment (local, dev, staging, prod, etc.)
   cp config/compliance-lab.local.template config/compliance-lab.{ENV}

   # Examples:
   cp config/compliance-lab.local.template config/compliance-lab.local
   cp config/compliance-lab.local.template config/compliance-lab.prod
   cp config/compliance-lab.local.template config/compliance-lab.staging
   ```

2. **Edit your config file** with your actual values:
   - Replace `yourdomain.com` with your actual domain
   - Add your Cloudflare email, API token, and zone ID
   - Optionally configure Rancher integration

3. **Run the deployment**:
   ```bash
   ./compliance-lab.sh
   ```

## Configuration Files

### Main Configuration
- `compliance-lab.local.template` - Main cluster configuration template (for any environment)
- `compliance-lab.{env}` - Your actual configuration files (gitignored)

### Optional Rancher Integration
- Rancher settings are configured in the main `compliance-lab.{env}` files
- Uncomment `RANCHER_URL` and `RANCHER_BEARER_TOKEN` to enable
- Use `./compliance-lab.sh register` and `./compliance-lab.sh deregister` commands

## Environment Detection

The script automatically detects your environment based on config files:

1. **Looks for environment-specific files** in this order:
   - `config/compliance-lab.local` → local environment
   - `config/compliance-lab.dev` → dev environment
   - `config/compliance-lab.staging` → staging environment
   - `config/compliance-lab.prod` → production environment

2. **Falls back to hostname detection** if no config files found

## SSL Certificates

- **Local/Dev/Staging**: Uses Let's Encrypt staging certificates (untrusted but no rate limits)
- **Production**: Automatically uses Let's Encrypt production certificates (trusted but rate limited)

## Required Values

All environments require:
- `K3S_INGRESS_DOMAIN` - Your domain name
- `CLOUDFLARE_EMAIL` - Your Cloudflare account email
- `CLOUDFLARE_API_TOKEN` - API token with DNS edit permissions
- `CLOUDFLARE_ZONE_ID` - Zone ID for your domain

## Security Notes

- **Never commit actual config files** - they contain secrets
- **Use separate API tokens** for different environments
- **Use strong passwords** in production
- **Review .gitignore** to ensure secrets aren't committed