#!/usr/bin/env sh
# Copy this to .env or env.sh, fill in your values, then pass it to Docker with
# --env-file or source it in your shell.

TAILSCALE_HOSTNAME=docker-exit

# Use one authentication method. If both are set, TAILSCALE_AUTH_KEY wins.
# TAILSCALE_AUTH_KEY=<your-auth-key>

# OAuth clients need the auth_keys scope and at least one permitted tag.
# TAILSCALE_OAUTH_CLIENT_ID=<your-oauth-client-id>
# TAILSCALE_OAUTH_SECRET=<your-oauth-client-secret>
# TAILSCALE_OAUTH_TAGS=tag:docker-exit

# Optional: tags passed to tailscale up --advertise-tags.
# TAILSCALE_ADVERTISE_TAGS=tag:docker-exit

# Optional: set to true only when the platform cannot provide /dev/net/tun or
# NET_ADMIN. Kernel mode is preferred for a high-throughput exit node.
# TAILSCALE_USERSPACE=true
# TAILSCALE_UP_TIMEOUT=60
# TAILSCALE_SOCKS5_SERVER=0.0.0.0:1055
# TAILSCALE_HTTP_PROXY=0.0.0.0:1055
