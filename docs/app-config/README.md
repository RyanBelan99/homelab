# App config snapshots

Reference copies of the config files that hold settings the chart doesn't manage, taken
2026-11-18 from the running apps. Nothing applies these automatically: after a rebuild or a
wiped config, compare with the live file and copy the settings you need by hand. The intent
of each setting is in [`host-config.md`](../host-config.md#app-settings-outside-the-chart).

Redacted before committing: API keys, passwords and hashes, tokens, notification keys,
emails, and Jellyfin's server ID (`REDACTED`); the tailnet and public names (`<tailnet>`,
`<publicDomain>`). Restore those from `secrets/secrets.yaml` or from the app itself.

| App | File | Lives at (on the node) |
|---|---|---|
| Jellyfin | `jellyfin/network.xml`, `system.xml`, `encoding.xml` | `/mnt/config/jellyfin/config/config/` |
| Radarr, Sonarr, Prowlarr | `<app>/config.xml` | `/mnt/config/<app>/` |
| Seerr | `seerr/settings.json` | `/mnt/config/seerr/` |
| SABnzbd | `sabnzbd/sabnzbd.ini` | `/mnt/config/sabnzbd/` |
| Pi-hole | `pihole/pihole.toml` | Pi-hole's `pihole-etc` volume on the server; most of it is set by `FTLCONF_*` env in the chart |

Not here: Keycloak users and Dispatcharr's settings (in their Postgres databases), and app
data (watch history, libraries, queues). Stop an app before editing its file; most rewrite it
on exit.
