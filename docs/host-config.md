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

Installed with Traefik disabled (Pi-hole owns ports 80/443):

```bash
curl -sfL https://get.k3s.io | sh -s - --disable traefik --write-kubeconfig-mode 644
```
