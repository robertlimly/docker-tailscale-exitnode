#!/usr/bin/env sh
set -eu

echo 'Starting Tailscale exit-node container...'

TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-docker-$(hostname)}"
TAILSCALE_PORT="${TAILSCALE_PORT:-41641}"
TAILSCALE_STATE="${TAILSCALE_STATE:-mem:}"
TAILSCALE_HEALTH_PORT="${TAILSCALE_HEALTH_PORT:-9002}"
TAILSCALE_OAUTH_TAGS="${TAILSCALE_OAUTH_TAGS:-${TAILSCALE_ADVERTISE_TAGS:-tag:docker-exit}}"
TAILSCALE_UP_TAGS="${TAILSCALE_ADVERTISE_TAGS:-}"
NETDEV="${TAILSCALE_EXIT_NODE_DEV:-$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)}"
NETDEV="${NETDEV:-eth0}"

modprobe xt_mark 2>/dev/null || echo 'Could not load xt_mark kernel module (continuing)'

sysctl -w net.ipv4.ip_forward=1 >/dev/null || echo 'Could not enable IPv4 forwarding (continuing)'
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || echo 'Could not enable IPv6 forwarding (continuing)'

iptables -t nat -C POSTROUTING -o "$NETDEV" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$NETDEV" -j MASQUERADE || \
    echo "Could not configure IPv4 masquerade on ${NETDEV} (continuing)"
ip6tables -t nat -C POSTROUTING -o "$NETDEV" -j MASQUERADE 2>/dev/null || \
    ip6tables -t nat -A POSTROUTING -o "$NETDEV" -j MASQUERADE || \
    echo "Could not configure IPv6 masquerade on ${NETDEV} (continuing)"

# Enable UDP GRO forwarding on the internet-facing NIC for better exit-node
# throughput (Tailscale perf best practice; needs tailscale >=1.54 + kernel >=6.2).
# Not persistent across restarts, but start.sh runs on every container start.
ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || \
    echo "Could not enable UDP GRO forwarding on ${NETDEV} (continuing)"

/app/tailscaled \
    --verbose=1 \
    --port="${TAILSCALE_PORT}" \
    --state="${TAILSCALE_STATE}" &
TAILSCALED_PID=$!

# Serve /cgi-bin/healthz for Docker health checks or external probes.
httpd -f -p "${TAILSCALE_HEALTH_PORT}" -h /var/www &

AUTH_KEY=""
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    echo 'Using TAILSCALE_AUTH_KEY authentication'
    AUTH_KEY="$TAILSCALE_AUTH_KEY"
elif [ -n "${TAILSCALE_OAUTH_CLIENT_ID:-}" ] || [ -n "${TAILSCALE_OAUTH_SECRET:-}" ]; then
    if [ -z "${TAILSCALE_OAUTH_CLIENT_ID:-}" ] || [ -z "${TAILSCALE_OAUTH_SECRET:-}" ]; then
        echo 'TAILSCALE_OAUTH_CLIENT_ID and TAILSCALE_OAUTH_SECRET must both be set'
        exit 1
    fi

    echo 'Using OAuth client to generate an auth key'
    if ! OAUTH_TOKEN_RESPONSE=$(wget --quiet --output-document=- --header="Content-Type: application/x-www-form-urlencoded" \
        --post-data="client_id=${TAILSCALE_OAUTH_CLIENT_ID}&client_secret=${TAILSCALE_OAUTH_SECRET}" \
        https://api.tailscale.com/api/v2/oauth/token); then
        echo 'Failed to get access token from Tailscale API'
        exit 1
    fi

    ACCESS_TOKEN=$(printf '%s' "$OAUTH_TOKEN_RESPONSE" | grep -o '"access_token":"[^"]*' | cut -d'"' -f4)

    if [ -z "$ACCESS_TOKEN" ]; then
        echo "Failed to get access token from Tailscale API"
        exit 1
    fi

    OAUTH_TAGS_CSV=$(printf '%s' "$TAILSCALE_OAUTH_TAGS" | tr -d ' ')
    OAUTH_TAGS_JSON=$(printf '%s' "$OAUTH_TAGS_CSV" | sed 's/,/","/g; s/^/"/; s/$/"/')
    AUTH_KEY_REQUEST=$(printf '{"capabilities":{"devices":{"create":{"reusable":true,"ephemeral":true,"preauthorized":true,"tags":[%s]}}}}' "$OAUTH_TAGS_JSON")

    if ! AUTH_KEY_RESPONSE=$(wget --quiet --output-document=- --header="Content-Type: application/json" \
        --header="Authorization: Bearer ${ACCESS_TOKEN}" \
        --post-data="$AUTH_KEY_REQUEST" \
        https://api.tailscale.com/api/v2/tailnet/-/keys); then
        echo 'Failed to generate auth key from Tailscale API'
        exit 1
    fi

    AUTH_KEY=$(printf '%s' "$AUTH_KEY_RESPONSE" | grep -o '"key":"[^"]*' | cut -d'"' -f4)

    if [ -z "$AUTH_KEY" ]; then
        echo "Failed to generate auth key from Tailscale API"
        exit 1
    fi

    if [ -z "$TAILSCALE_UP_TAGS" ]; then
        TAILSCALE_UP_TAGS="$OAUTH_TAGS_CSV"
    fi

    echo 'Successfully generated auth key using OAuth'
else
    echo 'No Tailscale auth environment variables set; starting unauthenticated'
fi

set -- /app/tailscale up \
    --hostname="${TAILSCALE_HOSTNAME}" \
    --advertise-exit-node

if [ -n "$AUTH_KEY" ]; then
    set -- "$@" --auth-key="${AUTH_KEY}"
fi

if [ -n "$TAILSCALE_UP_TAGS" ]; then
    set -- "$@" --advertise-tags="${TAILSCALE_UP_TAGS}"
fi

if [ -n "$AUTH_KEY" ]; then
    "$@"
else
    "$@" || echo 'tailscale up is waiting for interactive login; healthz will stay unhealthy'
fi

echo "Tailscale started as ${TAILSCALE_HOSTNAME}."

# Block on tailscaled. If it exits, the container exits so Docker can restart it.
wait "$TAILSCALED_PID"
