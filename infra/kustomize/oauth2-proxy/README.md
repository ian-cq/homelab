# oauth2-proxy — Google OAuth SSO in front of all 4 public services

## Topology

One Helm chart (`oauth2-proxy` v10.7.0, appVersion 7.15.3), four releases in
this namespace:

| Release                       | Upstream                                       | Hostname                          |
|-------------------------------|------------------------------------------------|-----------------------------------|
| `oauth2-proxy-argocd`         | `argocd-server.argocd.svc:80`                  | argocd.62a.quanianitis.com        |
| `oauth2-proxy-grafana`        | `grafana.monitoring.svc:80`                    | grafana.62a.quanianitis.com       |
| `oauth2-proxy-prometheus`     | `prometheus-server.monitoring.svc:80`          | prometheus.62a.quanianitis.com    |
| `oauth2-proxy-kubernetes`     | `kubernetes-dashboard.monitoring.svc:80`       | kubernetes.62a.quanianitis.com    |

oauth2-proxy is **multi-instance per-app** rather than a single shared
instance because the chart's `upstreams=` is path-based, not Host-based.
Four small pods (~50Mi each) is cheaper than running an ext_authz sidecar
on Cilium Gateway and easier to reason about than path-based routing.

## Shared cookie SSO

All four instances share the same Google OAuth client (the same
`oauth2-proxy-google` Secret) and the same cookie domain
(`.62a.quanianitis.com`) so a login at one host satisfies all four.

The `oauth2-proxy-google` Secret is **provided out of band by the operator**
and is not present in this repo. It must contain:

- `client-id`     — Google OAuth client ID
- `client-secret` — Google OAuth client secret
- `cookie-secret` — 32 random bytes, base64-encoded (`openssl rand -base64 32 | head -c 32 | base64`)

Until the Secret exists in the `oauth` namespace, oauth2-proxy pods will
CrashLoopBackOff. That is expected and harmless: the existing HTTPRoutes
still point at the app Services directly, not at oauth2-proxy.

## Two-phase rollout

This kustomize is **phase 1**: deploy the chart, the namespace, and the
ReferenceGrant. HTTPRoutes are *not* rewired yet, so traffic still flows
unauthenticated to the apps.

**Phase 2** (after the Secret is in place and the four pods are Running):
update each app's `httproute.yaml` so `backendRefs[0]` points at
`oauth2-proxy-<app>.oauth.svc:80` instead of the app Service. That single
change cuts traffic through Google OAuth.

The phase-2 commit is intentionally separate so the Secret can be staged
and pods verified before any user-facing traffic is affected.

## Google OAuth client setup

In Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client:

- Authorized redirect URIs (add all four):
  - https://argocd.62a.quanianitis.com/oauth2/callback
  - https://grafana.62a.quanianitis.com/oauth2/callback
  - https://prometheus.62a.quanianitis.com/oauth2/callback
  - https://kubernetes.62a.quanianitis.com/oauth2/callback

Email allowlist is set per-release in the `extraArgs.email-domains` value
(currently `*` — restrict in values once verified working).
