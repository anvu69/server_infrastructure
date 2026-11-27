# Beszel agent

Collects host and Docker metrics and sends them to a [Beszel](https://beszel.dev)
hub over an outbound WebSocket. The agent uses host networking for interface
stats, but its SSH listener is disabled, so it needs no inbound port.

1. In the hub, click **Add system**. Copy the generated token and public key
   into the encrypted inventory as `vault_beszel_agent_token` and
   `vault_beszel_agent_key` for the target host.
2. If the hub is behind Cloudflare Access, ensure the agent can reach the
   hub's `/api/beszel/agent-connect` WebSocket endpoint without an interactive
   login. Beszel authenticates the connection with the token and key.
3. Add `beszel-agent` to the host's `vault_services` and run
   `ansible-playbook -i <inventory> install-beszel-agent.yml -l <host>`.
   The playbook uses Docker Compose v2 on Linux and stores the credentials
   in a root-owned `0600` `.env` in the deployment directory.

| Ansible variable | Value |
| --- | --- |
| `beszel_agent_hub_url` | Required; hub HTTPS URL, e.g. `https://<domain>`. |
| `beszel_agent_token` | Required; reference `vault_beszel_agent_token`. |
| `beszel_agent_key` | Required; reference `vault_beszel_agent_key`. |
| `beszel_agent_tag` | Required; pinned image tag, e.g. `0.21.2`. |
| `beszel_agent_compose_dir` | Defaults to `/docker/beszel-agent`. |

The Docker socket is mounted read-only for container metrics; this does not
restrict which Docker API calls the container can issue.
