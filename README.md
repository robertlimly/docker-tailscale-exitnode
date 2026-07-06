tailscale-exit-docker
---------------------

Docker image for running a Tailscale exit node. Runtime configuration is passed
with container environment variables, so no Fly.io app config or secrets are
required.

The image downloads `tailscale` and `tailscaled` binaries from
https://github.com/LiuTangLei/tailscale/releases at build time.

Kernel mode is required for a normal high-throughput Linux exit node. It needs
root, `NET_ADMIN`, `/dev/net/tun`, writable forwarding sysctls, and iptables
access. By default `TAILSCALE_USERSPACE=auto` falls back to userspace mode when
`/dev/net/tun` is missing, but userspace exit-node mode has different behavior
and lower performance.

## Build

```bash
docker build -t tailscale-exit .
```

To pin another LiuTangLei release:

```bash
docker build --build-arg TSVERSION=1.98.5 -t tailscale-exit .
```

## Run With An Auth Key

```bash
docker run -d --name tailscale-exit \
  --restart unless-stopped \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  -p 9002:9002 \
  -p 41641:41641/udp \
  -e TAILSCALE_HOSTNAME=docker-exit \
  -e TAILSCALE_AUTH_KEY=<your-auth-key> \
  tailscale-exit
```

## Run With OAuth

The OAuth client must have the `auth_keys` scope and permission for the tag you
use in `TAILSCALE_OAUTH_TAGS`.

```bash
docker run -d --name tailscale-exit \
  --restart unless-stopped \
  --cap-add=NET_ADMIN \
  --device=/dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv6.conf.all.forwarding=1 \
  -p 9002:9002 \
  -p 41641:41641/udp \
  -e TAILSCALE_HOSTNAME=docker-exit \
  -e TAILSCALE_OAUTH_CLIENT_ID=<your-oauth-client-id> \
  -e TAILSCALE_OAUTH_SECRET=<your-oauth-client-secret> \
  -e TAILSCALE_OAUTH_TAGS=tag:docker-exit \
  tailscale-exit
```

If `TAILSCALE_AUTH_KEY` is set, it takes precedence over OAuth credentials.

## Docker Compose

```bash
cp env.example.sh .env
# edit .env
docker compose up -d --build
```

For userspace mode on restricted platforms:

```bash
docker compose --profile userspace up -d --build tailscale-exit-userspace
```

## Environment Variables

| Variable | Default | Description |
| --- | --- | --- |
| `TAILSCALE_AUTH_KEY` | unset | Direct Tailscale auth key. |
| `TAILSCALE_OAUTH_CLIENT_ID` | unset | OAuth client ID used to mint an auth key at startup. |
| `TAILSCALE_OAUTH_SECRET` | unset | OAuth client secret used to mint an auth key at startup. |
| `TAILSCALE_OAUTH_TAGS` | `TAILSCALE_ADVERTISE_TAGS` or `tag:docker-exit` | Tags on the auth key generated through OAuth. |
| `TAILSCALE_ADVERTISE_TAGS` | unset | Tags passed to `tailscale up --advertise-tags`. |
| `TAILSCALE_HOSTNAME` | `docker-<container-hostname>` | Node name shown in Tailscale. |
| `TAILSCALE_PORT` | `41641` | UDP port used by `tailscaled`. |
| `TAILSCALE_HEALTH_PORT` | `9002` | Busybox HTTP health endpoint port. |
| `TAILSCALE_STATE` | `mem:` | Tailscale state location. `mem:` makes the node ephemeral. |
| `TAILSCALE_EXIT_NODE_DEV` | default route interface | Egress interface for NAT masquerade. |
| `TAILSCALE_USERSPACE` | `auto` | Uses kernel mode when `/dev/net/tun` exists, otherwise userspace mode. Set `false` to require kernel mode. |
| `TS_USERSPACE` | unset | Compatibility alias for `TAILSCALE_USERSPACE`. |
| `TAILSCALE_UP_TIMEOUT` | `60` | Seconds to wait for authenticated nodes to reach `Running`. |
| `TAILSCALE_SOCKS5_SERVER` | unset | Optional SOCKS5 listen address in userspace mode, for example `0.0.0.0:1055`. |
| `TAILSCALE_HTTP_PROXY` | unset | Optional HTTP proxy listen address in userspace mode, for example `0.0.0.0:1055`. |

## Health Check

The container serves:

```bash
curl http://localhost:9002/cgi-bin/healthz
```

It returns `200` when Tailscale is connected and `503` while unauthenticated or
unhealthy.

## Notes

Run this on a Linux Docker host with `/dev/net/tun` available. After the node
appears in the Tailscale admin console, approve it as an exit node unless your
tailnet policy auto-approves the advertised tag.

If logs show `Read-only file system`, `Permission denied (you must be root)`, or
`/dev/net/tun does not exist`, the container was started without the required
kernel-mode permissions. Start it with `--cap-add=NET_ADMIN --device=/dev/net/tun`
and the forwarding `--sysctl` flags. To fail instead of automatically falling
back to userspace mode, set `TAILSCALE_USERSPACE=false`.

If logs show `policy requires hardware attestation`, your tailnet policy or auth
key requires a TPM-backed device. Containers using `TAILSCALE_STATE=mem:` or
userspace mode cannot satisfy that on hosts without `/dev/tpmrm0`. Use an auth
key or ACL policy that does not require hardware attestation for this container,
or run on a host/container runtime that exposes a compatible TPM device.

Warnings about UDP buffer size in userspace mode are not fatal. They mean the
platform will use smaller socket buffers, which can reduce throughput.
