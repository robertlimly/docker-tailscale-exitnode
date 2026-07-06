tailscale-exit-docker
---------------------

Docker image for running a Tailscale exit node. Runtime configuration is passed
with container environment variables, so no Fly.io app config or secrets are
required.

The image downloads `tailscale` and `tailscaled` binaries from
https://github.com/LiuTangLei/tailscale/releases at build time.

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
