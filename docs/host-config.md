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

Pre-existing rules (from before k3s) still allow the LAN and VPN subnets and DNS
on port 53.

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

k3s writes its admin kubeconfig to `/etc/rancher/k3s/k3s.yaml` (installed with
`--write-kubeconfig-mode 644` so your user can read it). To use `kubectl`:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml   # add to ~/.bashrc to make permanent
```

## 5. k3s install flags

Installed with the bundled Traefik disabled. Traefik is instead installed from
`apps/traefik/` (a pinned `HelmChart` that k3s's helm-controller deploys), so its
version and settings live in git:

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
```

## 6. Tailscale - remote access (`scripts/05-tailscale.sh`)

Tailscale runs on the host, not in k3s. Every service is already a ServiceLB
port on the node, so the host's tailnet IP reaches all of them with no
per-service config. Nothing is port-forwarded on the router.

- **Subnet router** for `192.168.0.0/24`: remote devices use the same LAN URLs
  as at home (`http://192.168.0.34:8096`).
- **Exit node**: optional full-tunnel through home (and Pi-hole) on public wifi.
- **`--accept-dns=false`**: keeps the host DNS pin from section 3.
- **ufw**: `allow in on tailscale0`, `route allow in on tailscale0 out on eth0`,
  `allow 41641/udp`.
- **sysctl**: `/etc/sysctl.d/99-tailscale.conf` turns on IPv4/IPv6 forwarding.
- **UDP GRO**: `/etc/NetworkManager/dispatcher.d/50-tailscale-gro` re-applies
  `ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off` whenever eth0 comes up.

Access rules live in `docs/tailscale-policy.hujson` (pasted into the admin
console). Settings that only exist in the admin console:

- **DNS**: nameserver = this node's Tailscale IP (`tailscale ip -4`), with
  **Override DNS servers** on, so every tailnet device uses Pi-hole. Use the
  100.x IP, not 192.168.0.34: through the subnet route Pi-hole would see every
  remote device as the Pi itself.
