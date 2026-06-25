# nginx-redirect

HTTP→HTTPS edge redirect for the VPS frontend.

## Role

Plain `:80` on the VPS (`103.40.207.125`) used to be claimed by frps as
`vhostHTTPPort = 80`, but no frpc proxies use the HTTP vhost mechanism —
it sat idle. Browsers hitting `http://<host>.62a.quanianitis.com` got a
connection-reset or a 404 from frps.

This compose stack replaces that bind with a tiny nginx returning
`301 https://$host$request_uri` for every path, preserving host + query.

TLS termination still happens inside the cluster (cilium gateway on the
homelab node, reached via the frp **TCP** proxy on `:443`). nginx here
never touches TLS.

## Layout

```
nginx-redirect/
├── docker-compose.yml      # nginx:1.27-alpine, host :80
├── nginx.conf              # single server block, 301 + /healthz
├── nginx-redirect.service  # systemd unit wrapping `docker compose`
└── README.md               # this file
```

On the VPS the files live in `/opt/nginx-redirect/` and the unit is
installed at `/etc/systemd/system/nginx-redirect.service`.

## Deploy

Prereq: docker engine + compose plugin installed on the VPS, and frps
config no longer claims port 80 (`vhostHTTPPort` removed, frps
restarted).

```sh
# from the repo, push files to the VPS
sudo install -d -m 0755 -o root -g root /opt/nginx-redirect
sudo install -m 0644 docker-compose.yml nginx.conf README.md /opt/nginx-redirect/
sudo install -m 0644 nginx-redirect.service /etc/systemd/system/

sudo systemctl daemon-reload
sudo systemctl enable --now nginx-redirect.service
sudo systemctl status nginx-redirect.service
```

## Lifecycle

- `sudo systemctl start nginx-redirect`   → `docker compose up -d`
- `sudo systemctl stop nginx-redirect`    → `docker compose down`
- `sudo systemctl reload nginx-redirect`  → recreate containers
  (use after changing `nginx.conf` or `docker-compose.yml`)
- `sudo systemctl restart nginx-redirect` → down + up

Container crash recovery is independent of systemd: `restart:
unless-stopped` in `docker-compose.yml` brings nginx back in <1s if it
segfaults, without waiting for systemd to notice.

## Verify

```sh
curl -sI http://hubble.62a.quanianitis.com
# expect: HTTP/1.1 301 Moved Permanently
#         Location: https://hubble.62a.quanianitis.com/

curl -sI http://hubble.62a.quanianitis.com/some/deep/path?x=1
# expect: Location: https://hubble.62a.quanianitis.com/some/deep/path?x=1
```

The healthcheck endpoint stays plaintext (no redirect):

```sh
curl -s http://127.0.0.1/healthz   # on the VPS only
# -> ok
```

## Rollback

```sh
sudo systemctl disable --now nginx-redirect.service
# then put `vhostHTTPPort = 80` back in /etc/frp/frps.toml and restart frps
sudo systemctl restart frps
```

## Hard rules

- This stack must not terminate TLS. If you ever add a `listen 443` block
  here, you have stepped on the cluster's gateway and broken OIDC.
- Do not add proxy_pass to any cluster backend from here. The whole
  point of frp's TCP proxy on :443 is that the VPS is dumb pipe for
  HTTPS.
