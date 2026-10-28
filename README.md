# Remnawave node installer

Installs Remnanode 2.8.0, Caddy with Gcore DNS-01, Psiphon, native WARP and BBR on Debian 12/13 or Ubuntu 22.04/24.04.

## New server

Download `vpn-install.sh`, inspect it, then run `sudo bash vpn-install.sh` in a terminal. Enter the Gcore DNS token, the full node authentication bundle from Remnawave, and the SNI domain. Secret inputs are hidden. DNS must already point to the intended server(s).

An existing Remnanode Compose file or Caddyfile stops a normal installation. The script does not change the provider firewall or publish a Remnawave profile.

## Existing server

```sh
sudo bash vpn-install.sh --check
sudo bash vpn-install.sh --repair
```

`--repair` applies the Caddy fix verified on the US node: no `--environ` credential logging, restart on failure after 5 seconds, and a 300-second startup timeout. It backs up the preceding service and drop-ins, enables startup, restarts Caddy, and checks trusted HTTPS against the existing local SNI endpoint. It does not reinstall or remove Remnanode, tunnels, keys, certificates, or users. Other components are audited with `--check`; repair success alone is not a VPN traffic test.

`--reinstall` explicitly opts into the original full replacement procedure. It stops/removes the named VPN components after backups; use only during an approved maintenance window. Backups are under `/var/backups/unified-vpn-installer/` and installation logs are root-only.

## Remnawave profile and client checks

All Xray profiles and routing changes belong in Remnawave. The installer never calls Xray's runtime routing API.

- Disable the affected location's hosts before maintenance; handle locations sequentially.
- Preserve each profile's existing inbound tags, REALITY keys and short IDs.
- Match the Host SNI override, REALITY `serverNames` and Caddy certificate domain. Use target `127.0.0.1:8443`, `xver: 0`.
- The Host fingerprint override `firefox` fixed Happ connections over the tested mobile network on the US node; validate the exported client profile on each location.
- Psiphon is a TCP-only SOCKS outbound. Keep `network: "tcp"` on its routing rule.
- Gemini worked on the US node through `DIRECT` with IPv4. Do not copy a US location/region assumption to another exit without a traffic check.
- Validate the saved profile, the panel-to-node update, trusted local TLS, a real VLESS request, DNS, and required sites before re-enabling the hosts.

Caddy and API readiness do not establish that a client connection works. Do not change the operator computer's active VPN during maintenance.

## Caddy repair rollback

Remove the added `/etc/systemd/system/caddy.service.d/zz-unified-vpn-reliability.conf` drop-in, run `systemctl daemon-reload`, and restart Caddy to return to the preceding unit settings. Retain the backup before other changes. The normal install and `--repair` do not alter DNS records.

Node access logs rotate at 50 MiB, with compressed history and an hourly check to prevent disk exhaustion on small VPSs. Existing large logs should be archived before truncation; the installer does not delete them during repair.
