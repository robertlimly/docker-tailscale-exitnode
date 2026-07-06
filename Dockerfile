ARG TSVERSION=1.98.5

FROM alpine:3.24 AS tailscale
ARG TSVERSION
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /app

RUN wget -O tailscale "https://github.com/LiuTangLei/tailscale/releases/download/v${TSVERSION}/tailscale-${TARGETOS}-${TARGETARCH}" && \
  wget -O tailscaled "https://github.com/LiuTangLei/tailscale/releases/download/v${TSVERSION}/tailscaled-${TARGETOS}-${TARGETARCH}" && \
  chmod +x tailscale tailscaled

FROM alpine:3.24
# busybox-extras provides httpd, used to serve the health check endpoint (see start.sh)
RUN apk add --no-cache ca-certificates iptables ip6tables busybox-extras ethtool

# tailscale state dirs + the directory httpd serves the health check from
RUN mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale /var/www/cgi-bin

# tailscale binaries from the build stage; our scripts straight from the build context
COPY --from=tailscale /app/tailscaled /app/tailscale /app/
COPY start.sh /app/start.sh
COPY healthz /var/www/cgi-bin/healthz
RUN chmod +x /app/start.sh /var/www/cgi-bin/healthz

EXPOSE 9002 41641/udp

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -q -O - "http://127.0.0.1:${TAILSCALE_HEALTH_PORT:-9002}/cgi-bin/healthz" >/dev/null || exit 1

# Run on container startup.
CMD ["/app/start.sh"]
