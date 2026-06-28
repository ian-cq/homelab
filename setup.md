# Homelab Setup — quanianitis-01

Step-by-step record of every command executed to bring up the k3s cluster on `quanianitis-01` (Debian 13 Trixie, AMD Ryzen 7 5800X, NVIDIA GTX 1650, 16 GB RAM).

---

## 1. NVIDIA Driver Fix

The NVIDIA driver packages (550.163.01) were already installed via `apt`, but the kernel module had never been built because `dkms` was present and kernel headers were missing. The `nouveau` open-source driver was claiming the GPU.

### 1.1 Install kernel headers (triggers DKMS module build)

```bash
sudo apt-get update -qq
sudo apt-get install -y dkms linux-headers-$(uname -r)
```

DKMS automatically built and installed the NVIDIA kernel modules:

```
Autoinstall of module nvidia-current/550.163.01 for kernel 6.12.86+deb13-amd64 (x86_64)
Building module(s)........... done.
Installing /lib/modules/6.12.86+deb13-amd64/updates/dkms/nvidia-current.ko.xz
...
```

### 1.2 Blacklist nouveau

The `nouveau` driver was loaded at boot and had already claimed the GPU (`NVRM: No NVIDIA devices probed.` in dmesg). Blacklist it:

```bash
sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

sudo update-initramfs -u
sudo reboot
```

### 1.3 Verify after reboot

```bash
nvidia-smi
```

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.163.01             Driver Version: 550.163.01     CUDA Version: 12.4     |
|-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
|   0  NVIDIA GeForce GTX 1650        Off |   00000000:2B:00.0 Off |                  N/A |
| 35%   34C    P8              7W /   75W |       1MiB /   4096MiB |      0%      Default |
+-----------------------------------------+------------------------+----------------------+
```

---

## 2. NVIDIA Container Toolkit

### 2.1 Add NVIDIA apt repository

Debian 13 uses `sqv` for signature verification instead of `gpg`, so the key must be stored as ASCII-armored (`.asc`), not binary (`.gpg`):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo tee /usr/share/keyrings/nvidia-container-toolkit-keyring.asc > /dev/null

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.asc] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
```

### 2.2 Install

```bash
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
```

Installed version: `1.19.0-1`.

### 2.3 Generate CDI spec

The NVIDIA device plugin uses CDI (Container Device Interface) to discover GPUs:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

### 2.4 Set runtime mode to CDI

By default the nvidia-container-runtime uses `mode = "auto"` which causes detection failures inside the device plugin pod. Set it to `cdi` explicitly:

```bash
sudo nvidia-ctk config --set nvidia-container-runtime.mode=cdi --in-place
```

Verify in `/etc/nvidia-container-runtime/config.toml`:

```toml
mode = "cdi"
```

---

## 3. k3s v1.36.0 Installation

### 3.1 Install k3s

Install with flannel, kube-proxy, traefik, and servicelb disabled — Cilium will replace all of these:

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.36.0+k3s1" sh -s - server \
  --cluster-init \
  --flannel-backend=none \
  --disable-kube-proxy \
  --disable-network-policy \
  --disable=traefik \
  --disable=servicelb
```

Output:

```
[INFO]  Using v1.36.0+k3s1 as release
[INFO]  Installing k3s to /usr/local/bin/k3s
[INFO]  systemd: Enabling k3s unit
[INFO]  systemd: Starting k3s
```

### 3.2 Verify

```bash
sudo kubectl get nodes -o wide
```

```
NAME             STATUS     ROLES                AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                CONTAINER-RUNTIME
quanianitis-01   NotReady   control-plane,etcd   18s   v1.36.0+k3s1   192.168.1.50   <none>        Debian GNU/Linux 13 (trixie)   6.12.86+deb13-amd64 (amd64)   containerd://2.2.3-k3s1
```

Node is `NotReady` because there is no CNI yet — this is expected.

### 3.3 NVIDIA runtime auto-detection

k3s v1.36 automatically detects `/usr/bin/nvidia-container-runtime` and registers it as a containerd runtime. No manual `config.toml.tmpl` is needed. The k3s journal confirms:

```
Found nvidia container runtime at /usr/bin/nvidia-container-runtime
```

It also creates a `RuntimeClass` named `nvidia`:

```bash
sudo kubectl get runtimeclass nvidia
```

```
NAME     HANDLER   AGE
nvidia   nvidia    10m
```

> **Important**: Do NOT create a custom `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` that adds an `nvidia` runtime block. k3s auto-generates it, and duplicating the `[nvidia]` TOML table causes containerd to crash with `toml: table nvidia already exists`.

### 3.4 Fetch kubeconfig to laptop

```bash
# On the laptop
ssh -i ~/Library/Keychains/quanianitis.pem quanianitis@quanianitis-01 \
  'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's/127\.0\.0\.1/quanianitis-01/g' > ~/.kube/k3s-quanianitis.yaml

export KUBECONFIG=~/.kube/k3s-quanianitis.yaml
kubectl get nodes
```

### 3.5 Passwordless sudo (optional, for automation)

```bash
# On quanianitis-01
echo 'quanianitis ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/quanianitis
sudo chmod 440 /etc/sudoers.d/quanianitis
```

---

## 4. Cilium CNI

### 4.1 Install via Helm (from laptop)

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update cilium

helm install cilium cilium/cilium \
  --version 1.17.3 \
  --namespace kube-system \
  --set operator.replicas=1 \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=quanianitis-01 \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set hubble.relay.enabled=false \
  --set hubble.ui.enabled=false
```

### 4.2 Wait for rollout

```bash
kubectl -n kube-system rollout status daemonset/cilium --timeout=180s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=120s
kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=120s
```

### 4.3 Verify node is Ready

```bash
kubectl get nodes
```

```
NAME             STATUS   ROLES                AGE     VERSION
quanianitis-01   Ready    control-plane,etcd   2m33s   v1.36.0+k3s1
```

All system pods come up after Cilium provides networking:

```
kube-system   cilium-envoy-phcl9                        1/1   Running
kube-system   cilium-gqtsl                              1/1   Running
kube-system   cilium-operator-68564bd884-89c4d          1/1   Running
kube-system   coredns-85c87b586d-bcjjc                  1/1   Running
kube-system   local-path-provisioner-5467cc9b7c-ct5pk   1/1   Running
kube-system   metrics-server-7c86f97b8d-5vc72           1/1   Running
```

---

## 5. ArgoCD (Minimal)

### 5.1 Install via Helm

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo

kubectl create namespace argocd

helm install argocd argo/argo-cd \
  --version 7.7.16 \
  --namespace argocd \
  --set fullnameOverride=argocd \
  --set "crds.install=true" \
  --set "crds.keep=true" \
  --set "dex.enabled=false" \
  --set "notifications.enabled=false" \
  --set "applicationSet.enabled=false" \
  --set "server.service.type=NodePort" \
  --set "server.service.nodePortHttp=30080" \
  --set "server.service.nodePortHttps=30443" \
  --set "configs.params.server\.insecure=true"
```

### 5.2 Wait and get password

```bash
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

### 5.3 Access

```
URL:      http://quanianitis-01:30080
Username: admin
Password: (from command above)
```

---

## 6. NVIDIA Device Plugin (Helm)

### 6.1 Install via Helm

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update nvdp

helm install nvidia-device-plugin nvdp/nvidia-device-plugin \
  --version 0.17.0 \
  --namespace kube-system \
  --set runtimeClassName=nvidia \
  --set deviceListStrategy=volume-mounts
```

### 6.2 Verify GPU is advertised

```bash
kubectl describe node quanianitis-01 | grep nvidia.com/gpu
```

```
  nvidia.com/gpu:     1
  nvidia.com/gpu:     1
```

### 6.3 Restart k3s after CDI config change

If you changed the nvidia-container-runtime mode to `cdi` (section 2.4) after k3s was already running, restart k3s and then the device plugin pod:

```bash
# On quanianitis-01
sudo systemctl restart k3s

# From laptop
kubectl -n kube-system delete pod -l app.kubernetes.io/instance=nvidia-device-plugin
```

---

## 7. Prometheus

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

kubectl create namespace monitoring

helm install prometheus prometheus-community/prometheus \
  --version 25.27.0 \
  --namespace monitoring \
  --set alertmanager.enabled=false \
  --set prometheus-pushgateway.enabled=false \
  --set prometheus-node-exporter.enabled=false \
  --set kube-state-metrics.enabled=true \
  --set server.persistentVolume.enabled=true \
  --set server.persistentVolume.size=10Gi \
  --set server.retention=15d \
  --set server.service.type=ClusterIP \
  --set server.resources.requests.cpu=200m \
  --set server.resources.requests.memory=512Mi \
  --set server.resources.limits.memory=1Gi
```

```bash
kubectl -n monitoring rollout status deployment/prometheus-server --timeout=180s
```

Access via port-forward:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
```

---

## 8. Node Exporter

```bash
helm install node-exporter prometheus-community/prometheus-node-exporter \
  --version 4.39.0 \
  --namespace monitoring \
  --set service.port=9100 \
  --set service.targetPort=9100 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.memory=128Mi
```

```bash
kubectl -n monitoring rollout status daemonset/node-exporter-prometheus-node-exporter --timeout=120s
```

---

## 9. Grafana

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update grafana

helm install grafana grafana/grafana \
  --version 8.8.2 \
  --namespace monitoring \
  --set persistence.enabled=false \
  --set testFramework.enabled=false \
  --set service.type=NodePort \
  --set service.nodePort=31000 \
  --set adminUser=admin \
  --set adminPassword=admin \
  --set "datasources.datasources\.yaml.apiVersion=1" \
  --set "datasources.datasources\.yaml.datasources[0].name=Prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].type=prometheus" \
  --set "datasources.datasources\.yaml.datasources[0].url=http://prometheus-server.monitoring.svc.cluster.local" \
  --set "datasources.datasources\.yaml.datasources[0].access=proxy" \
  --set "datasources.datasources\.yaml.datasources[0].isDefault=true"
```

```bash
kubectl -n monitoring rollout status deployment/grafana --timeout=180s
```

Access:

```
URL:      http://quanianitis-01:31000
Username: admin
Password: admin
```

---

## 10. CUDA Smoke Test

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-smi
  namespace: default
spec:
  runtimeClassName: nvidia
  restartPolicy: Never
  containers:
    - name: cuda-smi
      image: nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: "1"
EOF
```

Wait and check:

```bash
kubectl wait --for=condition=Ready pod/cuda-smi --timeout=120s 2>/dev/null || true
kubectl logs cuda-smi
```

```
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 550.163.01             Driver Version: 550.163.01     CUDA Version: 12.4     |
|   0  NVIDIA GeForce GTX 1650        On  |   00000000:2B:00.0 Off |                  N/A |
| 35%   32C    P8              7W /   75W |       1MiB /   4096MiB |      0%      Default |
+-----------------------------------------------------------------------------------------+
```

Clean up:

```bash
kubectl delete pod cuda-smi
```

---

## 11. ArgoCD Applications

After all components are running, ArgoCD Applications were created to manage them declaratively from the Git repo. The repo must be accessible to ArgoCD:

```bash
# Register the repo (public, no credentials needed)
kubectl -n argocd apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: homelab-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/ian-cq/homelab.git
EOF
```

Then apply the Application manifests:

```bash
kubectl -n argocd apply -f deployments/applications/system/cilium.yaml
kubectl -n argocd apply -f deployments/applications/system/nvidia-device-plugin.yaml
kubectl -n argocd apply -f deployments/applications/system/prometheus.yaml
kubectl -n argocd apply -f deployments/applications/system/node-exporter.yaml
kubectl -n argocd apply -f deployments/applications/system/grafana.yaml
```

### ArgoCD + Kubernetes v1.36 compatibility note

Kubernetes v1.36 added `.status.terminatingReplicas` to DaemonSet and Deployment status. ArgoCD 7.x does not have this field in its schema, causing:

```
Failed to compare desired state to live state: failed to calculate diff:
error calculating structured merge diff: error building typed value from
live resource: .status.terminatingReplicas: field not declared in schema
```

The fix is to add `ignoreDifferences` for `/status` on affected resource kinds and enable `ServerSideApply`:

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: DaemonSet
      jsonPointers:
        - /status
    - group: apps
      kind: Deployment
      jsonPointers:
        - /status
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

---

## 12. Final State

```
$ kubectl get nodes -o wide
NAME             STATUS   ROLES                AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                       KERNEL-VERSION                CONTAINER-RUNTIME
quanianitis-01   Ready    control-plane,etcd   21m   v1.36.0+k3s1   192.168.1.50   <none>        Debian GNU/Linux 13 (trixie)   6.12.86+deb13-amd64 (amd64)   containerd://2.2.3-k3s1

$ kubectl -n argocd get applications
NAME                   SYNC STATUS   HEALTH STATUS
cilium                 Synced        Healthy
grafana                Synced        Healthy
node-exporter          Synced        Healthy
nvidia-device-plugin   Synced        Healthy
prometheus             Synced        Healthy
```

| Service              | Access                                     | Credentials                                                |
| -------------------- | ------------------------------------------ | ---------------------------------------------------------- |
| ArgoCD               | `http://quanianitis-01:30080`              | admin / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Grafana              | `http://quanianitis-01:31000`              | admin / admin                                              |
| Prometheus           | `kubectl -n monitoring port-forward svc/prometheus-server 9090:80` | n/a                                         |
| CUDA test            | `kubectl logs cuda-smi`                    | n/a                                                        |

---

## Troubleshooting

### nouveau blocking NVIDIA driver

**Symptom**: `nvidia-smi` fails with `NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver`, dmesg shows `NVRM: No NVIDIA devices probed`.

**Cause**: `nouveau` kernel module loaded first and claimed the GPU.

**Fix**: Blacklist nouveau (section 1.2), rebuild initramfs, reboot.

### k3s containerd crashes with `toml: table nvidia already exists`

**Symptom**: k3s fails to start after creating `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` with an nvidia runtime block.

**Cause**: k3s v1.36 auto-detects nvidia-container-runtime and adds the `[nvidia]` table to the generated containerd config. A custom template duplicates it.

**Fix**: Delete the custom template. k3s handles NVIDIA runtime registration automatically:

```bash
sudo rm /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl
sudo systemctl restart k3s
```

### NVIDIA device plugin: `Incompatible strategy detected auto`

**Symptom**: Device plugin logs show `Incompatible strategy detected auto` and `No devices found`.

**Cause**: The nvidia-container-runtime `mode` is set to `auto`, which fails to detect GPUs from inside a container.

**Fix**: Set mode to `cdi` and generate CDI specs (sections 2.3 and 2.4), then restart k3s and the device plugin pod.

### CUDA pod: `nvidia-smi: executable file not found in $PATH`

**Symptom**: CUDA pod is scheduled and starts but fails with `nvidia-smi` not found.

**Cause**: Pod is running with the default `runc` runtime, not the `nvidia` runtime. The NVIDIA libraries are not injected into the container.

**Fix**: Add `runtimeClassName: nvidia` to the pod spec.

### Debian 13 GPG key format for NVIDIA repo

**Symptom**: `apt-get update` fails with `OpenPGP signature verification failed` and `Failed to parse keyring`.

**Cause**: Debian 13 (Trixie) uses `sqv` for signature verification, which cannot read binary `.gpg` keyring files.

**Fix**: Store the key as ASCII-armored `.asc` instead of binary `.gpg` (section 2.1).

### ArgoCD `.status.terminatingReplicas` schema error

**Symptom**: ArgoCD Application shows `ComparisonError` with `field not declared in schema`.

**Cause**: Kubernetes v1.36 added new status fields that ArgoCD 7.x does not recognize.

**Fix**: Add `ignoreDifferences` for `/status` on DaemonSet/Deployment kinds and enable `ServerSideApply=true` (section 11).

---

## 13. North-south traffic architecture

The cluster has two distinct networking layers; mixing them up is the single most common cause of "why doesn't my hostname work" bugs in this repo. They are not interchangeable:

- **Cilium** (CNI + kube-proxy replacement only).
  Pod networking, NetworkPolicy, socket-LB for ClusterIP from the host
  netns, Hubble observability. Cilium's own Gateway-API controller is
  **disabled** (`gatewayAPI.enabled: false` in
  `infra/kustomize/cilium/values.yaml`); the `l2announcements` feature
  is also off. Cilium does not terminate TLS and does not own any
  Gateway/HTTPRoute on this cluster.

- **Envoy Gateway** (north-south, gateway.networking.k8s.io v1).
  GatewayClass `eg`, Gateway `gateway/public` with wildcard HTTPS
  listener for `*.62a.quanianitis.com`, cert-manager-issued Let's
  Encrypt cert. SecurityPolicy on the Gateway enforces Google OIDC +
  JWT email allowlist (`infra/kustomize/gateway/securitypolicy.yaml`).
  All HTTPRoutes (`argocd`, `hubble-ui`, `grafana`,
  `kubernetes-dashboard`, `plane`, …) bind to this Gateway.

- **FRP** (external edge → cluster ingress).
  `frpc.service` on the host dials a remote `frps` on the VPS at
  `103.40.207.125:7000` and forwards `:443` to the Envoy Gateway
  Service ClusterIP `10.43.201.212:443` (svc
  `gateway/envoy-gateway-public-1e7f3513`). The Service is
  type=LoadBalancer but k3s is started with `--disable=servicelb`, so
  the external IP stays `<pending>` and FRP punches the ClusterIP
  directly from host netns via Cilium socket-LB. The Gateway's
  `Programmed=False / AddressNotAssigned` status is therefore expected
  and not a problem — FRP doesn't care about the Gateway address.

**Traffic path (one hostname end-to-end):**

```
client → DNS *.62a.quanianitis.com → VPS 103.40.207.125:443
       → frps → tcp passthrough → frpc on quanianitis-01
       → 10.43.201.212:443 (envoy-gateway-public-1e7f3513 ClusterIP)
       → Envoy Gateway listener (terminates TLS, applies SecurityPolicy)
       → HTTPRoute match by Host header
       → backend Service (e.g. argocd-server.argocd.svc:80)
```

**Historical scar tissue.** Earlier iterations of this repo used Cilium's
Gateway-API controller (`cilium-gateway-public` Service in the
`gateway` namespace) for the same role. That path was removed; the
relevant lessons live in `~/claude-agent/AGENTS.md` under "Lessons
from prior sessions". Do not re-enable `gatewayAPI` in Cilium without
reading them.
