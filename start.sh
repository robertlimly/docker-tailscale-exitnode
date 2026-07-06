#!/usr/bin/env sh
set -eu

echo 'Starting Tailscale exit-node container...'

die() {
    printf '%s\n' "$@" >&2
    exit 1
}

is_true() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

is_false() {
    case "${1:-}" in
        0|false|FALSE|no|NO|off|OFF) return 0 ;;
        *) return 1 ;;
    esac
}

require_sysctl() {
    key="$1"
    value="$2"

    if sysctl -w "${key}=${value}" >/dev/null 2>&1; then
        return 0
    fi

    current=$(sysctl -n "$key" 2>/dev/null || true)
    if [ "$current" = "$value" ]; then
        return 0
    fi

    die "Required sysctl ${key}=${value} is not set." \
        "Start the container with --sysctl ${key}=${value} or set TAILSCALE_USERSPACE=true for restricted platforms."
}

try_sysctl() {
    key="$1"
    value="$2"

    sysctl -w "${key}=${value}" >/dev/null 2>&1 || [ "$(sysctl -n "$key" 2>/dev/null || true)" = "$value" ]
}

wait_for_running() {
    timeout="$1"
    elapsed=0

    while [ "$elapsed" -lt "$timeout" ]; do
        if /app/tailscale status --json 2>/dev/null | grep -Eq '"BackendState":[[:space:]]*"Running"'; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo 'Tailscale did not reach Running state before timeout.' >&2
    /app/tailscale status 2>&1 || true
    return 1
}

TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-docker-$(hostname)}"
TAILSCALE_PORT="${TAILSCALE_PORT:-41641}"
TAILSCALE_STATE="${TAILSCALE_STATE:-mem:}"
TAILSCALE_HEALTH_PORT="${TAILSCALE_HEALTH_PORT:-9002}"
TAILSCALE_USERSPACE="${TAILSCALE_USERSPACE:-${TS_USERSPACE:-auto}}"
TAILSCALE_UP_TIMEOUT="${TAILSCALE_UP_TIMEOUT:-60}"
TAILSCALE_SOCKS5_SERVER="${TAILSCALE_SOCKS5_SERVER:-}"
TAILSCALE_HTTP_PROXY="${TAILSCALE_HTTP_PROXY:-}"
TAILSCALE_OAUTH_TAGS="${TAILSCALE_OAUTH_TAGS:-${TAILSCALE_ADVERTISE_TAGS:-tag:docker-exit}}"
TAILSCALE_UP_TAGS="${TAILSCALE_ADVERTISE_TAGS:-}"
NETDEV="${TAILSCALE_EXIT_NODE_DEV:-$(awk '$2 == "00000000" { print $1; exit }' /proc/net/route)}"
NETDEV="${NETDEV:-eth0}"

if is_false "$TAILSCALE_USERSPACE"; then
    TAILSCALE_USERSPACE=false
elif is_true "$TAILSCALE_USERSPACE"; then
    TAILSCALE_USERSPACE=true
elif [ -c /dev/net/tun ]; then
    TAILSCALE_USERSPACE=false
else
    echo 'No /dev/net/tun found; automatically using Tailscale userspace networking mode.'
    TAILSCALE_USERSPACE=true
fi

if is_true "$TAILSCALE_USERSPACE"; then
    echo 'Using Tailscale userspace networking mode; kernel forwarding, TUN, and iptables are not required.'
else
    [ "$(id -u)" = "0" ] || die \
        'Kernel-mode exit node requires root inside the container.' \
        'Run the container as root or set TAILSCALE_USERSPACE=true for restricted platforms.'

    [ -c /dev/net/tun ] || die \
        'Kernel-mode exit node requires /dev/net/tun, but it is missing.' \
        'Start with --device=/dev/net/tun --cap-add=NET_ADMIN, or set TAILSCALE_USERSPACE=true for restricted platforms.'

    modprobe xt_mark 2>/dev/null || echo 'Could not load xt_mark kernel module (continuing)'
    require_sysctl net.ipv4.ip_forward 1
    try_sysctl net.ipv6.conf.all.forwarding 1 || echo 'Could not enable IPv6 forwarding (continuing)'

    iptables -t nat -C POSTROUTING -o "$NETDEV" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "$NETDEV" -j MASQUERADE || \
        die "Could not configure IPv4 masquerade on ${NETDEV}." \
            'Start with --cap-add=NET_ADMIN or --privileged, or set TAILSCALE_USERSPACE=true for restricted platforms.'
    ip6tables -t nat -C POSTROUTING -o "$NETDEV" -j MASQUERADE 2>/dev/null || \
        ip6tables -t nat -A POSTROUTING -o "$NETDEV" -j MASQUERADE || \
        echo "Could not configure IPv6 masquerade on ${NETDEV} (continuing)"

    # Enable UDP GRO forwarding on the internet-facing NIC for better exit-node
    # throughput (Tailscale perf best practice; needs tailscale >=1.54 + kernel >=6.2).
    # Not persistent across restarts, but start.sh runs on every container start.
    ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || \
        echo "Could not enable UDP GRO forwarding on ${NETDEV} (continuing)"
fi

set -- /app/tailscaled \
    --verbose=1 \
    --port="${TAILSCALE_PORT}" \
    --state="${TAILSCALE_STATE}"

if is_true "$TAILSCALE_USERSPACE"; then
    set -- "$@" --tun=userspace-networking
fi

if [ -n "$TAILSCALE_SOCKS5_SERVER" ]; then
    set -- "$@" --socks5-server="${TAILSCALE_SOCKS5_SERVER}"
fi

if [ -n "$TAILSCALE_HTTP_PROXY" ]; then
    set -- "$@" --outbound-http-proxy-listen="${TAILSCALE_HTTP_PROXY}"
fi

"$@" &
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
    wait_for_running "$TAILSCALE_UP_TIMEOUT" || exit 1
else
    "$@" || echo 'tailscale up is waiting for interactive login; healthz will stay unhealthy'
fi

echo "Tailscale started as ${TAILSCALE_HOSTNAME}."

# Block on tailscaled. If it exits, the container exits so Docker can restart it.
wait "$TAILSCALED_PID"
