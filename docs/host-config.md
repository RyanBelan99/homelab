# Host-level configuration (outside Kubernetes)

These settings live on the CentralPI host itself, not in any manifest. They are
required for the cluster to work and must be reproduced on a rebuild. Captured
here so this repo tells the complete story.

## 1. cgroup memory controller — `/boot/firmware/cmdline.txt`

k3s needs the kernel memory cgroup enabled to enforce pod memory limits. Debian
on the Pi ships it off. The following flags are appended to the single line in
`cmdline.txt` (requires a reboot to take effect):

```
cgroup_memory=1 cgroup_enable=memory
```

## 2. Firewall — ufw

k3s traffic must be allowed through ufw (default deny-incoming). Rules added:

```bash
sudo ufw allow from 192.168.0.0/24 to any port 6443 proto tcp   # kubectl / API from LAN
sudo ufw allow from 10.42.0.0/16                                 # pod network
sudo ufw allow from 10.43.0.0/16                                 # service network
sudo ufw allow in on cni0                                        # pod bridge
```

The home LAN (`192.168.0.0/24`) and the router's WireGuard VPN (`10.5.5.0/24`)
may only reach SSH (22), Samba (445), the k3s API (6443), and, as a safety net,
DNS (53), Traefik (80) and Jellyfin (8096). Those last three are Kubernetes
services whose traffic is forwarded to pods rather than delivered to the host.
Kubelet (10250), flannel VXLAN (8472/udp) and the rest stay closed to the LAN.
Set by `scripts/06-harden-host.sh` (section 7).

## 3. Host DNS pin — NetworkManager

The host's own DNS is pinned to public resolvers instead of the Pi-hole pod, so
the cluster can always resolve/pull images even if the Pi-hole pod is down
(avoids a circular dependency). On the `eth0` connection:

```bash
nmcli con mod "<eth0-connection>" ipv4.ignore-auto-dns yes ipv4.dns "1.1.1.1 9.9.9.9"
nmcli con mod "<eth0-connection>" ipv6.ignore-auto-dns yes ipv6.dns ""
nmcli con up   "<eth0-connection>"
```

Every *other* device on the LAN still uses Pi-hole (192.168.0.34) via the
router's DHCP — only the Pi itself bypasses it.

## 4. kubectl access

k3s writes its admin kubeconfig to `/etc/rancher/k3s/k3s.yaml`, root-only
(`--write-kubeconfig-mode 600`): it is cluster-admin. Your user gets its own copy:

```bash
install -d -m 700 ~/.kube
sudo install -m 600 -o "$USER" -g "$USER" /etc/rancher/k3s/k3s.yaml ~/.kube/config
export KUBECONFIG=$HOME/.kube/config   # in ~/.bashrc
```

Re-copy it if k3s ever rotates its certificates (kubectl then reports an
expired or unknown certificate).

## 5. k3s install flags

Installed with the bundled Traefik disabled. Traefik is instead installed from
`apps/traefik/` (a pinned `HelmChart` that k3s's helm-controller deploys), so its
version and settings live in git:

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 600
```

## 6. Tailscale - remote access (`scripts/05-tailscale.sh`)

Tailscale runs on the host, not in k3s. Every service is already a ServiceLB
port on the node, so the host's tailnet IP reaches all of them with no
per-service config. Nothing is port-forwarded on the router.

- **Subnet router** for `192.168.0.0/24`: remote devices use the same LAN URLs
  as at home (`http://192.168.0.34:8096`).
- **Exit node**: optional full-tunnel through home (and Pi-hole) on public wifi.
- **`--accept-dns=false`**: keeps the host DNS pin from section 3.
- **No Tailscale SNAT** (`--snat-subnet-routes=false`): Pi-hole and Traefik see
  each tailnet device's real 100.x IP. Instead, a ufw NAT rule at the top of
  `/etc/ufw/before.rules` masquerades only tailnet traffic leaving eth0 (other
  LAN devices, the exit node), since the router has no route back to 100.64.0.0/10.
- **ufw**: `allow in on tailscale0`, `route allow in on tailscale0 out on eth0`,
  `allow 41641/udp`.
- **sysctl**: `/etc/sysctl.d/99-tailscale.conf` turns on IPv4/IPv6 forwarding.
- **UDP GRO**: `/etc/NetworkManager/dispatcher.d/50-tailscale-gro` re-applies
  `ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off` whenever eth0 comes up.

Access rules live in `docs/tailscale-policy.hujson` (pasted into the admin
console). Settings that only exist in the admin console:

- **DNS**: nameserver = `192.168.0.34` with **Override DNS servers** and **Use
  with exit node** on, so every tailnet device uses Pi-hole. Use the LAN IP, not
  the node's 100.x IP: the 100.x path goes through the svclb proxy pod, which
  hides the client, while 192.168.0.34 hits kube-proxy directly.

## 7. Host hardening (`scripts/06-harden-host.sh`)

From the 2026-10-28 security audit. The script runs as a background systemd job
(`harden-host`) so a dropped SSH session cannot interrupt the upgrades.

- **Docker removed**: it was unused, and its group was root-equivalent. k3s runs
  its own containerd under `/var/lib/rancher/k3s`.
- **No desktop**: boots to `multi-user.target` with no console autologin (the
  `getty@tty1` autologin drop-in is removed); lightdm, Bluetooth, avahi (mDNS)
  and CUPS are disabled, CUPS masked. Raspberry Pi Connect and wayvnc (remote
  shell and screen sharing through Raspberry Pi's cloud) are purged. `centralpi.local` no longer resolves; use
  `192.168.0.34` or `centralpi` over Tailscale.
- **SSH**: `/etc/ssh/sshd_config.d/20-hardening.conf` sets `X11Forwarding no` and
  `PermitRootLogin no` (password login was already off in `10-disable-password-auth.conf`).
- **ufw**: LAN and router VPN limited to the ports in section 2.
- **kubeconfig**: root-only, per-user copy (section 4).
- **Updates**: `apt full-upgrade`. Unattended upgrades only install Debian security
  updates, so run a full upgrade (and reboot) every month or so.
