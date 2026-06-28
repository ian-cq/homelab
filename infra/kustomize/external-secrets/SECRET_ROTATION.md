# Secret rotation workflow

How leaked-or-rotation-due secrets in this repo are handled today, and
the planned migration to ExternalSecret + 1Password Connect.

The reference case throughout is **`gateway/gateway-api-key`** — the
shared X-API-Key Secret consumed by the `inbox-apikey` SecurityPolicy
on the `inbox` listener of Gateway `public`. The same pattern applies
to every other Secret whose body has historically lived inline in a
manifest (firefly.`APP_KEY`, plane.`SECRET_KEY`, duitku.`FIREFLY_PAT`,
etc.).

---

## State today (interim)

- ESO + 1Password Connect are installed and the `1password`
  ClusterSecretStore is `Ready=True` against vault `quanianitis.com`
  (see `cluster-secretstore.yaml`).
- Most application Secrets are still declared inline in git as `kind:
  Secret` with `stringData`. **Any value committed to this repo must
  be considered public** — `github.com/ian-cq/homelab` is a public
  repo, history is forever, `git rm` does not unleak anything.
- For Secrets whose inline value has leaked and been rotated, the
  in-cluster Secret is created **out-of-band via `kubectl create`** and
  the git manifest is removed. The live Secret carries
  `argocd.argoproj.io/sync-options: Prune=false` so Argo does not
  delete it when the manifest disappears from source.

This file documents that interim workflow and the path to the
end-state (ExternalSecret-managed everything).

---

## Rotation procedure (manual / interim)

Run from any shell that has both `op` (1Password CLI, signed in to the
account that holds vault `quanianitis.com`) and `kubectl` pointed at
this cluster.

### 1. Mint a new key

```sh
NEW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32), end="")')
```

`token_urlsafe(32)` → 256 bits of entropy, ~43 chars,
URL/header-safe. Adjust if the consumer needs a different shape.

### 2. Store the new value in 1Password

Create the item the first time:

```sh
op item create \
  --category=password \
  --vault=quanianitis.com \
  --title='gateway-api-key-inbox' \
  --tags='homelab,k8s,gateway,api-key' \
  "cf-worker[password]=$NEW" \
  notesPlain='Shared X-API-Key for the inbox listener of Gateway public.
Consumed by SecurityPolicy gateway/inbox-apikey via Secret
gateway/gateway-api-key (key: cf-worker). Mirror the value into the
Cloudflare Email Worker with `wrangler secret put GATEWAY_API_KEY`.
Rotation: see infra/kustomize/external-secrets/SECRET_ROTATION.md.'
```

For subsequent rotations, edit the existing item instead of creating a
new one (keeps the item UUID stable for the future ExternalSecret):

```sh
op item edit gateway-api-key-inbox \
  --vault quanianitis.com \
  "cf-worker[password]=$NEW"
```

If you want to keep the previous value as a second client during a
graceful rotation, add a second field instead of overwriting:

```sh
op item edit gateway-api-key-inbox \
  --vault quanianitis.com \
  "cf-worker-next[password]=$NEW"
```

…and tear it down once the consumer has switched over.

### 3. Apply the new value to the cluster

Pipe directly from 1Password to `kubectl` so the value never lands in
a shell variable, history file, or terminal scrollback:

```sh
op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker' \
  | kubectl create secret generic gateway-api-key \
      -n gateway \
      --from-file=cf-worker=/dev/stdin \
      --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl annotate secret -n gateway gateway-api-key \
  argocd.argoproj.io/sync-options=Prune=false --overwrite

kubectl label secret -n gateway gateway-api-key \
  app.kubernetes.io/name=gateway \
  app.kubernetes.io/component=api-key-auth \
  --overwrite
```

The `Prune=false` annotation is what makes it safe for the matching
inline manifest to be absent from git: Argo CD will not delete a live
resource that carries it, even when the source-of-truth no longer
declares it. Always re-apply this annotation after any rotation; a
plain `kubectl apply` of a fresh manifest will drop annotations not in
the manifest body.

### 4. Update downstream consumers

For `gateway-api-key-inbox` the only consumer today is the
**Cloudflare Email Worker** in the duitku repo's `worker/`
subdirectory. Push the new value to Cloudflare:

```sh
op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker' \
  | wrangler secret put GATEWAY_API_KEY
wrangler deploy
```

Verify by tailing Envoy Gateway access logs (`kubectl logs -n gateway
deploy/envoy-...`) — the `x-client-id` header on accepted requests
should report `cf-worker` and 401s on the old key should stop within
seconds of the wrangler deploy completing.

### 5. (Optional) Hard-rotate by removing the old key

If the old value is known-leaked (i.e. it ever appeared in git, in a
log, or in a chat), do **not** keep it around as a graceful-rotation
fallback. Skip step 2's "keep old + add new" variant, overwrite the
single field in 1Password, and re-apply in step 3 with the new value
only. Any client still presenting the old key gets a clean 401 from
Envoy at L7 — that is the desired outcome.

---

## What goes into git (interim)

For every Secret that is rotated out-of-band, the git tree should
contain **none of the secret bytes** and **none of the secret
manifest**. Concretely, for `gateway/gateway-api-key`:

- `infra/kustomize/gateway/api-key-secret.yaml` — **deleted**.
- `infra/kustomize/gateway/kustomization.yaml` — `resources:` no longer
  references the file; an inline comment points readers to this doc.
- `infra/kustomize/gateway/securitypolicy-inbox.yaml` — unchanged, its
  `credentialRefs` still names `gateway-api-key`. The SecurityPolicy
  doesn't care whether the Secret it references was applied from git
  or `kubectl create`; it just needs to resolve at admission time.

That's the entire git surface. The Secret exists in-cluster only.

---

## End-state: ExternalSecret + 1Password Connect

When you are ready to drop the manual `kubectl create` step, replace
it with the ExternalSecret below and commit. ESO will pull from
1Password Connect every `refreshInterval` and reconcile the target
Secret with `creationPolicy: Owner`.

**Prerequisite:** the 1Password item must already exist (step 2
above). ESO does not create items; it only reads them.

Drop this file in alongside the SecurityPolicy:

```yaml
# infra/kustomize/gateway/api-key-externalsecret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gateway-api-key
  namespace: gateway
  labels:
    app.kubernetes.io/name: gateway
    app.kubernetes.io/component: api-key-auth
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: 1password
  target:
    name: gateway-api-key      # name of the Secret ESO will manage
    creationPolicy: Owner
  data:
    - secretKey: cf-worker
      remoteRef:
        key: gateway-api-key-inbox   # 1Password item title
        property: cf-worker          # field label inside the item
```

And add it to `infra/kustomize/gateway/kustomization.yaml`:

```yaml
resources:
  - certificate.yaml
  - gateway.yaml
  - gatewayclass.yaml
  - securitypolicy.yaml
  - securitypolicy-inbox.yaml
  - api-key-externalsecret.yaml   # replaces the inline Secret + manual kubectl create
```

### Cut-over checklist

ESO with `creationPolicy: Owner` will **not** adopt a Secret that
already exists and is not owned by an ExternalSecret. Before pushing
the ExternalSecret manifest:

1. Confirm the 1Password item holds the **same value** currently in
   the cluster Secret. If they differ, the cut-over will rotate the
   key as a side effect.
   ```sh
   diff <(op read 'op://quanianitis.com/gateway-api-key-inbox/cf-worker') \
        <(kubectl get secret -n gateway gateway-api-key \
            -o jsonpath='{.data.cf-worker}' | base64 -d)
   ```
2. Delete the live Secret so ESO can re-create it with itself as
   owner. This causes a brief auth gap on the inbox listener (~seconds
   while ESO reconciles); schedule accordingly.
   ```sh
   kubectl delete secret -n gateway gateway-api-key
   ```
3. Push the commit that adds `api-key-externalsecret.yaml` and lets
   Argo sync. Verify:
   ```sh
   kubectl get externalsecret -n gateway gateway-api-key
   kubectl get secret         -n gateway gateway-api-key \
     -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
   # expect: ExternalSecret
   ```
4. The `Prune=false` annotation is no longer needed once ESO owns the
   Secret (ESO will recreate on delete). Leave it; it's harmless and
   helpful as a belt-and-braces measure.

### Why we don't migrate straight to step 4 today

- Most of the leaked-then-rotated Secrets here (`gateway-api-key`,
  duitku.`FIREFLY_PAT`, firefly.`APP_KEY`, plane.`SECRET_KEY`) do
  **not** yet have 1Password items. Step 2 has to happen for each one
  before the ExternalSecret is meaningful.
- The Argo CD `.status.terminatingReplicas` ComparisonError (see
  `~/claude-agent/AGENTS.md` § "Lessons from prior sessions") currently
  pins several Applications at `Sync=Unknown`. Until that's cleared,
  hand-applied changes via `kubectl apply` are the only reliable way
  to mutate cluster state, and there's no point introducing an
  ExternalSecret whose `target` Secret Argo can't see anyway.

Migrate Secret-by-Secret as each one is rotated. Tracking list:

| Namespace / Secret              | Field(s)       | 1Password item                 | Status |
| ------------------------------- | -------------- | ------------------------------ | ------ |
| `gateway/gateway-api-key`       | `cf-worker`    | `gateway-api-key-inbox`        | rotated; kubectl-managed; ESO pending |
| `duitku/gateway-api-key`        | `cf-worker`    | `gateway-api-key-inbox` (same) | rotated; kubectl-managed; remove once `gateway` ns Secret is the only one referenced |
| `duitku/duitku` → `FIREFLY_PAT` | `FIREFLY_PAT`  | TODO                           | leaked inline (empty default), needs rotation when populated |
| `firefly/...` → `APP_KEY`       | `APP_KEY`      | TODO                           | leaked inline             |
| `plane/...` → `SECRET_KEY`      | `SECRET_KEY`   | TODO                           | leaked inline             |

Update this table as items are migrated.

---

## Hard rules

- **Never** commit a rotated value to git, even temporarily, even in a
  commit you plan to amend or force-push. Public repo history is
  immutable in the threat model that matters.
- **Never** echo a secret value to stdout or write it to a file outside
  the in-cluster Secret. Pipe `op read` → `kubectl` → done.
- **Always** re-apply the `Prune=false` annotation after a
  `kubectl apply` rotation. A vanilla apply drops annotations not in
  the manifest body, which would let Argo prune the Secret on the next
  sync of the parent application.
- If you `kubectl delete` a Secret that is referenced by an Envoy
  Gateway SecurityPolicy `credentialRef`, the listener will reject
  every request until the Secret reappears. Recreate within the same
  shell, do not leave a gap.
