# Homelab Execution Plan

Convert a Windows PC (AMD Ryzen 7 5800X + NVIDIA GTX 1650) into a dual-boot Debian 12 homelab node running k3s, accessible via SSH (public port 22) and Tailscale, managed by Ansible from a laptop.

---

## Hardware Summary
- **CPU**: AMD Ryzen 7 5800X (8c/16t)
- **RAM**: 16GB DDR4-3200
- **GPU**: NVIDIA GTX 1650 (CUDA compute 7.5)
- **Disks**: 500GB NVMe SSD (OSes), 500GB HDD, 2TB HDD
- **Network**: Wi-Fi
- **Headless**: yes (post-setup), dual-boot retained
- **Hostname**: `quanianitis-01`
- **Linux user**: `quanianitis`
- **Domain**: quanianitis.com (Cloudflare DDNS)
- **Ansible repo**: github.com/ian-cq/homelab (private)

---

## Disk Layout

| Disk | Purpose | Partitions / Mounts |
|---|---|---|
| **NVMe 500GB** | Windows + Debian | Windows (~300GB) · shared EFI System Partition · Debian `/` ext4 (~180GB) · swap (16GB) |
| **HDD 2TB** | Linux data | ext4 → `/data` |
| **HDD 500GB** | Linux backup | ext4 → `/backup` |

**Boot model**: GRUB on shared ESP. BIOS boots NVMe → GRUB → Debian default, Windows as secondary entry via `os-prober`.

**Risk**: Windows updates may repair the ESP and break GRUB. Keep a Debian live USB for `grub-install` recovery.

---

## Phase 1 — Pre-Install (in Windows)
1. Back up critical Windows data.
2. Disk Management → shrink C: to ~300GB (leaves ~200GB unallocated for Debian).
3. Disable Fast Startup (Power Options).
4. Disable BitLocker if enabled.
5. BIOS:
   - Confirm UEFI mode (no legacy/CSM).
   - **Disable Secure Boot** (simplifies NVIDIA driver install).
   - Note current boot order.
6. Download Debian 12 netinst ISO; flash to USB via Rufus (GPT/UEFI).

---

## Phase 2 — Debian Install
1. Boot USB → Graphical Install.
2. **Hostname**: `quanianitis-01`. **User**: `quanianitis`. (Spell-check both — typos here propagate to Tailscale MagicDNS, SSH config, certs, and Ansible inventory.)
3. **Root password**: leave **blank**. This tells the installer to auto-install `sudo` and add the new user to the `sudo` group. Setting a root password skips this and leaves you without sudo on first boot (recoverable via `su -`, but annoying).
4. Manual partitioning on **NVMe** unallocated space:
   - Reuse existing EFI System Partition (mount `/boot/efi`, **do NOT format** — Windows shares it).
   - 16GB swap.
   - Remainder (~180GB) ext4 → `/`.
5. Tasksel: select **SSH server** + **standard system utilities**. Skip desktop.
6. **Bootloader install**: let installer install GRUB to the NVMe ESP. The installer drops two binaries under `/boot/efi/EFI/debian/`:
   - `shimx64.efi` — Microsoft-signed first-stage loader (works in both Secure Boot states).
   - `grubx64.efi` — actual GRUB, loaded by shim.
   Both are normal. The installer registers `shimx64.efi` as the primary UEFI entry — **keep it that way** even with Secure Boot disabled (zero performance cost, future-proofs SB re-enable).
7. **First reboot**: unplug the Debian USB **before** reboot to avoid BIOS hang loops on post-install firmware.

---

## Phase 2.5 — First-Boot UEFI + GRUB Verification

After first boot into Debian, before doing anything else, lock in the boot order at the firmware level. Windows-installed UEFI entries often outrank Debian's by default.

1. Log in as `quanianitis` (password set during install). If `sudo` is missing (you set a root password in step 3 above), recover:
   ```
   su -                                  # enter root password
   apt update && apt install -y sudo
   usermod -aG sudo quanianitis
   exit
   exit                                  # log out fully
   ```
   Log back in so the new sudo group membership takes effect.

2. Inspect UEFI boot entries:
   ```
   sudo efibootmgr -v
   ```
   Find the entry for `\EFI\DEBIAN\SHIMX64.EFI` (typically `Boot0000`).

3. Make Debian's shim the persistent first boot:
   ```
   sudo efibootmgr -o 0000,<windows-id>,<other-ids>
   ```
   Verify:
   ```
   efibootmgr | head -3
   ```
   `BootOrder` should list Debian's shim first.

4. Register Windows in GRUB so dual-boot works without BIOS detours:
   ```
   sudo apt install -y os-prober
   sudo vim /etc/default/grub
   ```
   Set:
   ```
   GRUB_DEFAULT=0
   GRUB_TIMEOUT=5
   GRUB_DISABLE_OS_PROBER=false
   ```
   Apply:
   ```
   sudo update-grub
   ```
   Output must include `Found Windows Boot Manager on /dev/nvme0n1p1` (or similar).

5. Confirm Secure Boot state matches plan (should be **disabled** per Phase 1):
   ```
   sudo apt install -y mokutil
   mokutil --sb-state
   ```
   Expected: `SecureBoot disabled`.

6. Reboot once to confirm GRUB menu shows both Debian (default) and Windows.

7. Format and mount HDDs via `/etc/fstab`:
   - 2TB HDD → `/data` (ext4)
   - 500GB HDD → `/backup` (ext4)
   Both are NTFS from prior Windows use — back up any data first, then `mkfs.ext4`.

---

## Phase 3 — Base System (via dotfiles repo)

The user-space environment (Homebrew, zsh + Oh My Zsh, CLI tooling, configs) is fully managed by the dotfiles repo at **github.com/ian-cq/dotfiles** (local: `/Users/quanianitis/dotfiles`). Bootstrap with the official one-liner — **do not install Homebrew or shell packages manually**.

1. `sudo apt update && sudo apt upgrade -y`.
2. Enable `non-free` and `contrib` repos in `/etc/apt/sources.list` (required for NVIDIA drivers in Phase 8).
3. Install bootstrap prerequisites for Homebrew + dotfiles installer:
   ```
   sudo apt install -y build-essential procps curl file git vim sudo zsh stow
   ```
4. Set zsh as the default shell for `quanianitis`: `chsh -s "$(which zsh)"`.
5. Run the dotfiles bootstrap (installs Homebrew/Linuxbrew, runs `brew bundle` against `homebrew/Brewfile`, installs Oh My Zsh + plugins, stows all top-level packages into `$HOME`, applies hostname):
   ```
   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/ian-cq/dotfiles/refs/heads/main/install)"
   ```
   - The installer will clone the repo to `~/dotfiles`, install the prebuilt `setup_quanianitis` binary to `/usr/local/bin` (Linux path — no `/opt/homebrew` on Linux), then run it.
   - macOS-specific aliases (`flush`, `lscleanup`, `defaults`) become no-ops on Linux per the dotfiles README.
6. Verify symlinks: `ls -la ~/.zshrc ~/.gitconfig ~/.config/helix` should all point into `~/dotfiles/`.
7. Confirm Brewfile-installed CLIs are on `PATH`: `kubectl`, `helm`, `k9s`, `kubectx`, `kubens`, `argocd`, `fzf`, `rg`, `fd`, `bat`, `delta`, `zoxide`, `zellij`, `helix`.
8. Configure `unattended-upgrades` (apt-level; outside dotfiles scope):
   ```
   sudo apt install -y unattended-upgrades && sudo dpkg-reconfigure -plow unattended-upgrades
   ```

**Tradeoff note**: System services (sshd, k3s, NVIDIA drivers, kernel modules, fail2ban, ddclient) stay on **apt**. The dotfiles repo + **Homebrew (Linuxbrew)** owns user-space CLI tooling and shell config only. This split is intentional — kernel/driver-adjacent packages must come from the distro's package manager.

**Submodules note**: If cloning manually instead of using the bootstrap installer, use `git clone --recurse-submodules` to pull `config/nvim` (kickstart.nvim fork) and `config/alacritty/catppuccin`.

---

## Phase 4 — Wi-Fi (Headless Reliability)
1. Configure Wi-Fi via NetworkManager (`nmcli`).
2. Set DHCP reservation on router for stable LAN IP.

**Caveat**: Wi-Fi for a 24/7 server is suboptimal. Move to Ethernet later if feasible.

---

## Phase 5 — SSH Hardening
1. Confirm `openssh-server` running.
2. From laptop: `ssh-copy-id quanianitis@192.168.1.50`.
3. `/etc/ssh/sshd_config`:
   - `PasswordAuthentication no`
   - `PermitRootLogin no`
   - `PubkeyAuthentication yes`
4. Restart sshd.
5. Install `fail2ban` (enabled — public port 22).

---

## Phase 6 — Public SSH Exposure + Cloudflare DDNS

**Pre-allocated homelab LAN IP**: `192.168.1.50` (outside router DHCP pool; bound via DHCP reservation in Phase 4 once the homelab boots and its MAC is known).

**External port mapping**: WAN `2222` → LAN `192.168.1.50:22`. Using a non-22 external port dramatically cuts botnet scan noise (and `fail2ban` log volume) without weakening security — internal sshd still listens on 22.

### Step 1 — CGNAT Pre-Check (do this from macOS first)
```
curl -4 ifconfig.me
```
If the result starts with `10.`, `100.64–127.x`, or `192.168.`, you're behind carrier-grade NAT — port forwarding will not work from the public internet. Fall back to Tailscale-only access, or ask ISP for a public IPv4. Otherwise proceed.

### Step 2 — Router Port Forward
Add a rule in the router admin UI (router at `http://192.168.1.1`):

| Field | Value |
|---|---|
| Enable | ✅ |
| Protocol | TCP |
| Remote (WAN) Port Range | `2222` - `2222` |
| Local IP Address | `192.168.1.50` |
| Local Port Range | `22` - `22` |
| Remote IP Address | empty / `0.0.0.0` (any source) |

The rule may be added before the homelab exists; it will sit dormant until something answers at `192.168.1.50:22`.

### Step 3 — DHCP Reservation (after homelab is built)
Once Debian is installed, find its MAC: `ip link show`. In router UI → **DHCP → Address Reservation**, bind that MAC to `192.168.1.50`. Reboot the homelab to confirm.

### Step 4 — Cloudflare DDNS
1. In Cloudflare DNS for `quanianitis.com`: create A record `homelab` → (current WAN IP placeholder).
2. Generate a scoped API token: **My Profile → API Tokens → Create Token** with permissions `Zone:DNS:Edit` scoped to `quanianitis.com`.
3. On the homelab: install and configure `ddclient`:
   ```
   sudo apt install -y ddclient
   ```
   `/etc/ddclient.conf`:
   ```
   protocol=cloudflare
   use=web
   zone=quanianitis.com
   ttl=120
   login=token
   password=<API_TOKEN>
   homelab.quanianitis.com
   ```
   Enable: `sudo systemctl enable --now ddclient`.

### Step 5 — Verify From macOS

You **cannot** test reliably from inside your home network (NAT hairpin issues). Use one of:

- **iPhone hotspot**: disable Wi-Fi on the Mac, tether to phone:
  ```
  ssh -p 2222 quanianitis@homelab.quanianitis.com
  ```
- **TCP probe** from hotspot:
  ```
  nc -vz homelab.quanianitis.com 2222
  ```
- **External port checker**: https://www.yougetsignal.com/tools/open-ports/ (enter WAN IP + `2222`).

### Step 6 — macOS SSH Convenience
Add to `~/.ssh/config` on the laptop:
```
Host homelab
    HostName homelab.quanianitis.com
    User quanianitis
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
```
Then: `ssh homelab`.

### Troubleshooting
| Symptom | Likely cause | Fix |
|---|---|---|
| Connection refused from outside | sshd off OR forward wrong | First confirm `ssh quanianitis@192.168.1.50` works on LAN |
| Connection timed out from outside | port not forwarded / double-NAT / ISP blocks 22 | Check port-checker; confirm ISP modem is in bridge mode (not double-NAT) |
| Works on LAN but not WAN | NAT hairpin (normal) | Test via mobile hotspot, not home Wi-Fi |
| WAN IP `100.64.x.x` | CGNAT | Drop port-forward, rely on Tailscale only |

**Risk reminder**: Public SSH (even on port 2222) + fail2ban + key-only auth is acceptable but a larger attack surface than Tailscale-only. Reconsider later if Tailscale meets all access needs.

---

## Phase 7 — Tailscale
1. Install via official script.
2. `sudo tailscale up` → authenticate.
3. Enable MagicDNS in admin console.
4. Keep traditional SSH keys (Tailscale SSH not enabled).
5. Optional later: advertise as exit node / subnet router.

---

## Phase 8 — NVIDIA GPU for k3s Workloads

**Secure Boot is disabled** (per Phase 1 + Phase 2.5 verification), so the unsigned NVIDIA kernel module loads without the MOK signing/enrollment dance. If SB were enabled, you'd need `mokutil --import` + a reboot into MokManager — this plan deliberately avoids that.

1. Verify GPU: `lspci | grep -i nvidia`.
2. Install drivers (with non-free + contrib enabled):
   - `sudo apt install nvidia-driver firmware-misc-nonfree`.
3. Reboot. Verify: `nvidia-smi` shows GTX 1650.
4. Install **NVIDIA Container Toolkit**:
   - Add NVIDIA apt repo.
   - `sudo apt install nvidia-container-toolkit`.
5. After k3s install, configure containerd to use `nvidia` runtime:
   - Add `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` with nvidia runtime block.
   - Restart k3s.
6. Apply **NVIDIA k8s-device-plugin** DaemonSet (manifest lives in `infra/kustomize/` of the homelab repo).
7. Workloads request `nvidia.com/gpu: 1`.
8. Smoke test: run `nvidia/cuda:12-base` pod with `nvidia-smi`.

---

## Phase 9 — k3s via Ansible (from laptop)

**Repo**: github.com/ian-cq/homelab (private)
**Local clone**: `/Users/quanianitis/Documents/personal-infrastructure/homelab`

### Existing Repo Layout (already in place)

The repo is already structured and contains a vendored copy of the upstream `k3s-io/k3s-ansible` Ansible collection. No restructuring required — extend in place.

```
homelab/
├── deployments/                  # Application-layer manifests
│   ├── applications/             # Per-app manifests (kustomize/helm values)
│   ├── gitops/                   # ArgoCD / Flux config (future)
│   └── placeholder/
├── infra/                        # Cluster infrastructure layer
│   ├── charts/                   # Helm charts / values for cluster services
│   └── kustomize/                # Kustomize bases/overlays (e.g. NVIDIA device plugin)
├── k3s/                          # k3s-io/k3s-ansible vendored collection
│   ├── ansible.cfg
│   ├── galaxy.yml
│   ├── k3s.yaml
│   ├── Vagrantfile               # Local 5-node cluster test rig (libvirt/virtualbox)
│   ├── collections/
│   ├── meta/
│   ├── playbooks/                # site.yml, upgrade.yml, reset.yml, etc.
│   ├── roles/                    # k3s_server, k3s_agent, prereq, ...
│   ├── .ansible-lint
│   └── .yamllint
├── .gitignore
└── README.md
```

### What To Add (per-host configuration)

Create the following inside `k3s/`:

1. **`k3s/inventory.yml`** — single-server inventory targeting the homelab over Tailscale MagicDNS:
   ```yaml
   k3s_cluster:
     children:
       server:
         hosts:
           quanianitis-01:
             ansible_host: quanianitis-01   # Tailscale MagicDNS hostname
             ansible_user: quanianitis
       agent:
         hosts: {}                          # add future nodes here
     vars:
       k3s_version: v1.30.x+k3s1
       token: "{{ lookup('env', 'K3S_TOKEN') }}"   # or vault file
       api_endpoint: "{{ hostvars[groups['server'][0]]['ansible_host'] }}"
       extra_server_args: ""                # leave defaults: Traefik, servicelb, local-path on
   ```

2. **`k3s/.gitignore` additions** — ensure `inventory.yml`, fetched kubeconfig, and any vault files are not committed if they contain secrets.

3. **Bootstrap commands** (run from laptop, inside `k3s/`):
   ```bash
   ansible-galaxy collection install -r collections/requirements.yml   # if applicable
   ansible-playbook playbooks/site.yml -i inventory.yml
   ```

   Or, since the collection is already vendored, the upstream-sanctioned form:
   ```bash
   ansible-playbook k3s.orchestration.site -i inventory.yml
   ```

4. **Upgrade workflow**: bump `k3s_version` in `inventory.yml`, then:
   ```bash
   ansible-playbook playbooks/upgrade.yml -i inventory.yml
   ```

### Configuration Choices
- **Traefik**: default (enabled)
- **servicelb / klipper-lb**: default (enabled)
- **Storage**: default `local-path`
- Single server, **no embedded etcd / HA** initially (single host in `server` group → SQLite backend per upstream behavior).
- Inventory ready for additional `agent:` hosts without restructuring.
- Ansible reaches host via **Tailscale MagicDNS** (`quanianitis-01`), so the playbook works from any network.

### Post-Install Steps
1. Upstream playbook copies kubeconfig to laptop and merges into `~/.kube/config` under context `k3s-ansible`. Verify:
   ```bash
   kubectl config use-context k3s-ansible
   kubectl get nodes -o wide
   ```
2. Apply NVIDIA device plugin via `infra/kustomize/nvidia-device-plugin/`:
   ```bash
   kubectl apply -k infra/kustomize/nvidia-device-plugin/
   ```
3. Verify GPU resource: `kubectl describe node quanianitis-01 | grep nvidia.com/gpu` should report `1`.
4. Smoke test:
   ```bash
   kubectl run cuda-smi --rm -it --restart=Never \
     --image=nvidia/cuda:12.4.1-base-ubuntu22.04 \
     --overrides='{"spec":{"containers":[{"name":"cuda-smi","image":"nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}'
   ```

### Local Testing (optional)
The repo ships a `k3s/Vagrantfile` that can spin up a 5-node cluster locally (libvirt/virtualbox) for playbook iteration before touching the homelab.

---

## Execution Order
1. Backup Windows + shrink C: to ~300GB + BIOS prep (disable Secure Boot)
2. Debian install on NVMe (reuse ESP, ~180GB root + 16GB swap)
3. Base packages + non-free repos + run **dotfiles bootstrap** (Homebrew + Brewfile + zsh + stowed configs) + HDD mounts (`/data`, `/backup`)
4. Wi-Fi + DHCP reservation
5. SSH hardening + fail2ban
6. Tailscale install + enroll host as `quanianitis-01`
7. Router port-forward + Cloudflare DDNS
8. NVIDIA driver + container toolkit + verify
9. From laptop: add `k3s/inventory.yml` to homelab repo, run `playbooks/site.yml`
10. Apply NVIDIA device plugin manifest from `infra/kustomize/`
11. Smoke test: CUDA pod requesting `nvidia.com/gpu: 1`
12. Begin populating `deployments/applications/` with first workloads

---

## Decisions Locked
- Windows: ~300GB · Debian: ~200GB · shared NVMe ESP
- HDDs separate: 2TB → `/data`, 500GB → `/backup`
- Secure Boot: disabled
- Swap: 16GB
- DDNS: Cloudflare via `ddclient` (`homelab.quanianitis.com`)
- LAN IP: `192.168.1.50` (DHCP reservation)
- Public SSH: WAN `2222` → LAN `22`
- `unattended-upgrades`: enabled
- `fail2ban`: enabled
- **Dotfiles**: github.com/ian-cq/dotfiles (local: `/Users/quanianitis/dotfiles`) — bootstraps Homebrew, zsh + Oh My Zsh, all CLI tooling via `homebrew/Brewfile`, and stowed configs (`config/`, `git/`, `ssh/`, `zsh/`, `aliases/`).
- Ansible repo: github.com/ian-cq/homelab (private) — already cloned, vendored `k3s-io/k3s-ansible` under `k3s/`
- k3s: defaults (Traefik, servicelb, local-path)
- GPU plugin manifest lives under `infra/kustomize/`
- App workloads live under `deployments/applications/` (GitOps stub under `deployments/gitops/`)

---

## Appendix — Troubleshooting Notes (lessons from the actual install)

### BIOS hangs on first reboot after Debian install
- **Cause**: Debian USB still plugged in, or BIOS Fast Boot stalling on changed EFI vars.
- **Fix order**:
  1. Hard power off (10s power button), unplug Debian USB, power on.
  2. If still hanging, boot Windows and use `bcdedit` to set boot order from Windows (skips BIOS entirely):
     ```
     bcdedit /enum firmware
     bcdedit /set "{fwbootmgr}" displayorder "{DEBIAN-SHIM-GUID}" /addfirst
     ```
  3. Last resort: CMOS reset (jumper or pull CR2032 for 5 min). Re-disable Secure Boot afterward.

### `bcdedit bootsequence` vs `displayorder`
- `bootsequence` = **one-shot** override, consumed on next boot.
- `displayorder /addfirst` = **persistent** boot order change.
- Use `displayorder` for permanent fix; `bootsequence` only for testing.

### `efibootmgr` shows two `debian` entries
- Normal — `shimx64.efi` and `grubx64.efi` are both registered as fallbacks. Keep `shimx64` first; ignore the other.

### `sudo: command not found` on first login
- Cause: root password was set during install (skips auto-sudo install).
- Fix: `su -` → `apt install -y sudo` → `usermod -aG sudo <user>` → log out and back in.

### `<user> is not in the sudoers file` after `usermod`
- Cause: Group membership only applies to **new** login sessions.
- Fix: log out fully and log back in, or `newgrp sudo` for current shell only.

### GRUB menu doesn't list Windows
- Fix: install `os-prober`, set `GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub`, run `sudo update-grub`.

### Router admin page (`http://192.168.1.1`) won't load in Firefox but works in curl/Safari
- Cause: Firefox DoH (DNS-over-HTTPS) or proxy intercepting LAN addresses; or iCloud Private Relay / VPN routing LAN traffic externally.
- Fix: Firefox → disable DoH (`about:preferences#privacy` → DNS over HTTPS → Off), set proxy to "Use system proxy settings". Or just use Safari for router admin.

### Hostname typo discovered post-install
- If caught early (before Tailscale/k3s): `sudo hostnamectl set-hostname <correct>` + edit `/etc/hosts` line `127.0.1.1` + reboot.
- If caught late: easier to reinstall than to chase the name through every config.
