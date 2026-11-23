# Cloudflare Workers VPC tunnel

This connector runs a remotely managed Cloudflare Tunnel for Hyperdrive to
reach the Patroni stack's PgBouncer. The `cloudflared-vpc` Compose project and
container are separate from any existing `cloudflared` deployment.

| Ansible variable | Value |
| --- | --- |
| `cloudflared_tunnel_token` | Required; reference `vault_cloudflared_tunnel_token` from the encrypted inventory. |
| `cloudflared_tunnel_image` | Defaults to `cloudflare/cloudflared:2026.11.2`; overrides must be at least `2025.7.0`. |
| `cloudflared_tunnel_network` | Defaults to `patroni_tunnel`; must match `patroni_tunnel_network`. |

Follow [Hyperdrive qua Workers VPC](../patroni/README.md#hyperdrive-qua-workers-vpc)
to configure TLS and attach PgBouncer to the dedicated bridge first. Add
`cloudflared-tunnel` to the host's `vault_services`, then run
`ansible-playbook install-cloudflared-tunnel.yml -l <host>` with your inventory.
The playbook runs Compose from `~/docker/cloudflared-tunnel` for the deployment
user and stores the token in its `0600` `.env`, not on the command line.

The bridge must already exist. Keep other workloads off it and do not join the
Patroni application bridge. The connector needs outbound UDP port 7844 for
QUIC; it publishes no ports and checks readiness over container loopback.
