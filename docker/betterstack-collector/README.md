# Better Stack collector

Collects host and Docker telemetry and sends it to Better Stack. Add
`betterstack-collector` to the target host's `vault_services` and run
`ansible-playbook -i <inventory> install-betterstack-collector.yml -l <host>`.
The playbook uses Docker Compose v2 on Linux and writes the collector secret to
a root-owned `0600` `.env` in the deployment directory.

| Ansible variable | Value |
| --- | --- |
| `betterstack_collector_secret` | Required; reference `vault_betterstack_collector_secret` from the encrypted inventory. |
| `betterstack_collector_tag` | Required; GHCR tag shared by both images, e.g. `1.2.5` for release `v1.2.5`. |
| `betterstack_collector_compose_dir` | Defaults to `/docker/betterstack-collector`. |
| `betterstack_collector_base_url` | Defaults to `https://telemetry.betterstack.com`. |
| `betterstack_collector_cluster_collector` | Defaults to `false`. |
| `betterstack_collector_enable_dockerprobe` | Defaults to `true`. |
| `betterstack_collector_hostname` | Defaults to `inventory_hostname`. |
| `betterstack_collector_cpus` | Defaults to `1.2`; set to `1.0` on single-CPU hosts. |
| `betterstack_collector_host_cpus` | Defaults to `1.0`. |

`collector-host` is privileged, uses the host PID/network namespaces, and
reserves about 1.5 GiB RAM (2 GiB limit). Both containers can read the host root
filesystem (`/:/host:ro`). `collector-host` mounts the Docker socket; the
read-only mount does not restrict which Docker API calls it can issue. Both
containers rotate Docker logs at 20 MB with up to three files each.

To upgrade, verify the new tag exists for both images, review the corresponding
upstream Compose file, change `betterstack_collector_tag`, and rerun the
playbook. Unlike upstream `install.sh`, the playbook does not clamp CPU quotas,
publish optional OpenTelemetry receiver ports, or perform legacy Docker,
Swarm, or IPv6 network migration. Review those requirements before deployment.

To uninstall, remove `betterstack-collector` from the host's `vault_services`.
As root, run `docker compose -p better-stack-collector down` from the deployment
directory, then delete `/var/lib/better-stack` if its data is no longer needed.
Remove the deployment directory to remove the stored secret as well.
