# frpc — homelab edge tunnel

Host-level systemd unit that publishes the homelab Gateway and SSH to a
public VPS (`103.40.207.125`). Single point of ingress for the
`*.62a.quanianitis.com` namespace.

## Why frpc lives on the host (not in k8s)

frpc dials a **ClusterIP** as its `localIP`. If frpc were a Pod, it would
depend on the cluster networking it is meant to publish — a circular
dependency that bricks the edge whenever the cluster is half-up
(node reboot, CNI restart, Gateway redeploy). Keeping frpc as a host
systemd unit means: as long as the kernel is up and the Service
ClusterIP is reachable on the cni bridge, external traffic flows.

Don't migrate this into the cluster without solving the bootstrap loop
first.

## Topology

```
Internet ─▶ VPS (103.40.207.125:443)
                 │  frps
                 │  TCP passthrough
                 ▼
            frpc (this host, systemd)
                 │  dials ClusterIP :443
                 ▼
        Envoy Gateway data-plane Pod
        Service gateway/envoy-gateway-public-<hash>
        ClusterIP: 10.43.201.212  (pinned, see below)
                 │  Gateway listener terminates TLS (cert-manager)
                 ▼
            HTTPRoutes → backend Services
```

A second proxy (`ssh`) exposes VPS:2222 → 127.0.0.1:22.

## Files

| File | Purpose |
|------|---------|
| `frpc.toml` | Canonical config. **Source of truth.** Edit here and `make configure`. |
| `frpc.service` | systemd unit; runs as `frp` user with `ProtectSystem=strict`. |
| `setup.sh` | One-shot installer: downloads frpc binary, creates `frp` user, prepares `/etc/frp`. |
| `Makefile` | `setup`, `install`, `configure`, `secret`, `secret-rotate`, `restart`, `logs`, `status`, `uninstall`. |

Live deploy state on the host:

- Binary: `/usr/local/bin/frpc`
- Config: `/etc/frp/frpc.toml` (owned `frp:frp`, mode `640`)
- Token: `/etc/frp/frpc.env` (sourced via `EnvironmentFile`, mode `600`)
- Unit:  `/etc/systemd/system/frpc.service`

## The ClusterIP contract (read this before touching the Gateway)

`frpc.toml` hard-codes `localIP = 10.43.201.212`. This is the ClusterIP
of `Service gateway/envoy-gateway-public-<hash>`, which is **owned and
allocated by the envoy-gateway controller**, not declared in git. The
Gateway-API spec has no `clusterIP` field on Gateway/EnvoyProxy, so we
pinned it manually.

### How the pin was set

1. Scale `cilium-operator` and the gateway-api controller out of the
   reconcile race:
   ```sh
   kubectl -n envoy-gateway-system scale deploy envoy-gateway --replicas=0
   ```
2. Snapshot the live Service:
   ```sh
   kubectl -n gateway get svc envoy-gateway-public-1e7f3513 \
     -o yaml > /tmp/eg-public-svc-before.yaml
   ```
3. Delete it (the owning Gateway stays; only the Service is recreated).
4. Reapply a manifest with **`spec.clusterIP: 10.43.201.212`** explicit,
   plus the same `ownerReferences`, labels, ports
   (`30269` nodePort, `30631` healthCheckNodePort).
5. Scale the controller back to `replicas=1`. It adopts the existing
   Service rather than recreating it.

The pinned manifest is preserved at `/tmp/eg-public-svc-pinned.yaml`
on the homelab host (not in git — operator-owned object).

### When the pin breaks

The pin is preserved across pod restarts, controller restarts, helm
upgrades that don't recreate the Service, and node reboots. It is
**lost** if:

- The `public` Gateway is deleted and recreated (Service gets a new
  ownerRef and the controller allocates a fresh ClusterIP).
- The `gateway` namespace is recreated.
- envoy-gateway is uninstalled and reinstalled.

If you see external traffic time out after any of those, re-pin:

```sh
# 1. Read whatever ClusterIP the controller allocated
NEW_IP=$(kubectl -n gateway get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=public \
  -o jsonpath='{.items[0].spec.clusterIP}')

# 2. Update frpc.toml in this repo
sed -i "s/localIP = \"10\.43\.[0-9.]*\"/localIP = \"${NEW_IP}\"/" frpc.toml

# 3. Push the config to the host
make configure
```

Or, if you want the previous IP back, redo the scale-delete-apply-scale
dance above.

## Day-to-day operations

```sh
make configure       # edited frpc.toml? push it and restart
make secret-rotate   # pull new FRP_AUTH_TOKEN from 1Password, restart
make status          # systemctl status frpc
make logs            # journalctl -u frpc -f
```

## Diagnostic checklist

External traffic to `*.62a.quanianitis.com` failing? Walk the chain:

```sh
# 1. Is frpc running on the host?
systemctl is-active frpc

# 2. Does its local target answer?
curl -sk --resolve argocd.62a.quanianitis.com:443:10.43.201.212 \
  https://argocd.62a.quanianitis.com/ -o /dev/null -w '%{http_code}\n'

# 3. Does the VPS-side frps see the tunnel?
ssh debian@103.40.207.125 'systemctl status frps; ss -tlnp | grep :443'

# 4. End-to-end via the VPS
curl -sI https://argocd.62a.quanianitis.com/ | head -5
```

Step 2 failing while pods are healthy = ClusterIP drifted; re-pin.
Step 2 working and step 4 failing = frps/frpc tunnel, check the token
and `journalctl -u frpc`.

## What this README does not cover

- VPS-side frps config — lives on `debian@103.40.207.125`, see
  `/etc/frp/frps.toml` on that host.
- TLS termination — handled inside the cluster by cert-manager +
  Envoy Gateway listener. frps/frpc are TCP passthrough only.
- DNS — `*.62a.quanianitis.com` A records point to `103.40.207.125`,
  managed in the registrar, not in this repo.
