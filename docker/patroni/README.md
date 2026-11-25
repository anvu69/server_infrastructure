# Patroni / Citus

Deploys a single Docker host with three etcd members, a three-node Citus
coordinator group and two two-node worker groups. Applications connect
through PgBouncer and HAProxy to the current coordinator primary.

## Host mới

1. Add `patroni` to the target host's `vault_services`. Use the
   [example group variables](../../inventories/example/group_vars/all/main.yml)
   and [Vault keys](../../inventories/example/group_vars/all/vault.example.yml)
   as a starting point for your private inventory. Set the actual secrets in
   Vault. Keep `patroni_pgbackrest_timers: false` until the initial backups are
   complete. Set any [small-host overrides](#small-shared-hosts) before bootstrap.
2. Set a **unique `patroni_pgbackrest_repo_path` for each cluster**. Never
   point two clusters at the same repository path and stanzas, even if they
   share an S3 bucket. Set `patroni_pgbackrest_repo_s3_bucket`,
   `patroni_pgbackrest_repo_s3_endpoint` (without `https://`), and
   `patroni_pgbackrest_repo_s3_region`. For Backblaze B2, use a private bucket,
   a bucket-scoped application key, `path` URI style, and the **Keep only the
   last version** lifecycle policy so expired backups free space.
3. Use the default image, `anvu69/patroni-citus:4.1.3-pgbr`, which includes
   PostgreSQL 17, Citus and pgBackRest. To build it yourself, run this from a
   checkout of the [anvu69/patroni `citus-prod` branch](https://github.com/anvu69/patroni/tree/citus-prod):

   ```sh
   docker build -f Dockerfile.citus -t anvu69/patroni-citus:4.1.3-pgbr .
   ```

   For an image built directly on the target Docker host, set
   `patroni_compose_pull: false` and ensure the PgBouncer image is also present.
   Deploy from the repository root, limiting the run to the new host:

   ```sh
   ansible-playbook -i inventories/prod install-patroni.yml -l <host>
   ```

4. On the Docker host, run `patronictl list` and wait for a leader in each
   Citus group (`0`, `1`, `2`):

   ```sh
   docker exec -u postgres citus-coord1 patronictl -c /etc/patroni list
   ```

5. Render the backup config and host command without restarting Compose:

   ```sh
   ansible-playbook -i inventories/prod install-patroni-pgbackrest.yml -l <host>
   ```

6. On the Docker host, create the stanzas, check WAL archiving, and complete
   the first full backup for all three groups. Initialize the stanzas promptly:
   PostgreSQL retains unarchived WAL when the repository is unavailable.

   ```sh
   (
     for group in coord worker1 worker2; do
       pgbackrest-citus stanza-create "$group" || exit 1
     done
     for group in coord worker1 worker2; do
       pgbackrest-citus check "$group" || exit 1
     done
     for group in worker1 worker2 coord; do
       pgbackrest-citus backup "$group" full || exit 1
     done
   )
   ```

7. After all three full backups succeed, set `patroni_pgbackrest_timers: true`
   **only for the new host**, then rerun
   `install-patroni-pgbackrest.yml -l <host>` with the same inventory. Check
   `systemctl list-timers pgbackrest-full.timer pgbackrest-diff.timer` on that
   host. The defaults are full on Sundays and differential Monday–Saturday,
   both at 03:00 `Asia/Ho_Chi_Minh`.

By default, the runtime files are under `/docker/patroni/runtime` and
PgBouncer is published on `127.0.0.1:26432`. Keep the PostgreSQL and etcd data
directories on fast local storage.

### Small shared hosts

Set `patroni_oom_score_adj: 0` to remove the stack's OOM preference. The table
is a starting point for a lightly loaded shared host, not a capacity guarantee.
Size for seven PostgreSQL instances plus etcd, proxies, backups, and the other
services on the host. `work_mem` is per query operation; keep enough connections
for Citus workers and PgBouncer server pools.

| Bootstrap variable | Small-host starting point |
| --- | --- |
| `patroni_pg_shared_buffers` | `128MB` |
| `patroni_pg_effective_cache_size` | `512MB` |
| `patroni_pg_work_mem` | `4MB` |
| `patroni_pg_maintenance_work_mem` | `64MB` |
| `patroni_pg_max_connections` | `120` |
| `patroni_pg_max_prepared_transactions` | `240` |
| `patroni_pg_max_wal_size` | `1GB` |
| `patroni_pg_min_wal_size` | `256MB` |
| `patroni_pg_max_worker_processes` | `12` |
| `patroni_pg_max_parallel_workers` | `2` |
| `patroni_pg_max_parallel_workers_per_gather` | `1` |
| `patroni_pg_max_parallel_maintenance_workers` | `1` |

These values apply when each group's DCS configuration is first bootstrapped.

## Production host đang chạy

**Before running either playbook**, match the inventory to the live stack:
keep its data and config mount paths, Compose network, scope/namespace, etcd
token, database, image tags, ports, and credentials. If the PostgreSQL
containers still use the legacy pgBackRest config, set
`patroni_pgbackrest_container_config: /var/log/pgbackrest/conf/pgbackrest.conf`
before deploying. Ansible also renders the config under the existing log mount,
so the current DCS archive command and nightly backup keep using the same path.
Leave `patroni_pgbackrest_timers` unset or `false` to leave existing systemd
units and timers unmanaged.

On the first `install-patroni.yml` run, leave `patroni_compose_recreate`,
`patroni_compose_pull`, `patroni_compose_stop_before_start`, and
`patroni_compose_down_before_start` unset or `false`. The playbook syncs files
and prints the Compose dry-run before `up -d --no-recreate`: running containers
are not restarted or recreated. Compose starts stopped containers and creates
missing ones. Do not run Compose concurrently with the file sync. Afterward,
run manual Compose commands from the deployment directory (default
`/docker/patroni`) as root so Compose can read the managed `.env`. Do not
source it or override its values with exported variables.

Docker log rotation (`patroni_log_max_size`, default `50m`; `patroni_log_max_file`, default `5`) takes effect when each container is recreated.

Apply new image or mount settings only when needed, one service at a time:

```sh
docker compose up -d --no-deps --force-recreate <service>
```

1. Handle one Citus group at a time (`0` coordinator, `1` worker1, `2`
   worker2). Recreate replicas first. After each node, run `patronictl list`
   and wait for the replica to be streaming with zero lag. Run
   `patronictl switchover --group N` from a healthy Patroni node, targeting an
   updated replica. Verify the new primary before recreating the former
   primary, then verify it is streaming with zero lag.
2. Recreate etcd members one at a time. After each, wait for `etcdctl endpoint
   health` to report all three endpoints healthy before moving on.
3. Recreate `haproxy` and `pgbouncer` last. Expect brief client disconnects;
   schedule the change and make sure clients reconnect.

Keep the legacy pgBackRest path through the rollout. **Do not run
`apply-archive-config` until every node in that group mounts the config
directory at `/etc/pgbackrest`.** Once all PostgreSQL nodes have the directory
mount, remove the override and rerun `install-patroni-pgbackrest.yml`. Then
run the commands below on the Docker host. If a group's `archive_mode` was
previously off, run the commands for that group separately: roll-restart it
after applying the archive config and before running `check`.

```sh
for group in coord worker1 worker2; do
  pgbackrest-citus apply-archive-config "$group" || break
  pgbackrest-citus check "$group" || break
done
```

Remove `<log dir>/conf` only after all three checks succeed.

## Hyperdrive qua Workers VPC

1. In Cloudflare, create a remotely managed Cloudflare Tunnel. Store its token
   as `vault_cloudflared_tunnel_token` in the target host's encrypted inventory.
   Allow outbound UDP port 7844 for QUIC. No public hostname or published
   database port is needed.
2. On the target host, set `patroni_pgbouncer_client_tls_sslmode: allow` and run
   `ansible-playbook install-patroni.yml -l <host>` with the deployment inventory.
   Client TLS remains off when the variable is absent or empty. `allow` still
   accepts plaintext from internal clients.
3. From the deployed Patroni Compose directory (default `/docker/patroni`), run
   `docker compose up -d --no-deps pgbouncer`. The playbook uses `--no-recreate`
   by default; this targeted command applies the new mount and network to
   PgBouncer without recreating its dependencies. Expect a brief disconnect.
4. Add `cloudflared-tunnel` to the target host's `vault_services` and run
   `ansible-playbook install-cloudflared-tunnel.yml -l <host>`. If you override
   `patroni_tunnel_network`, set `cloudflared_tunnel_network` to the same name.
   PgBouncer is the only Patroni service on this bridge; the connector does not
   join the existing `citus` bridge.

Upload `ca.crt` from the Patroni SSL directory, not the server certificate or
private key. The server certificate must include `DNS:pgbouncer` so Workers VPC
can verify the hostname. Use the returned CA ID in the VPC service command,
then the returned VPC service ID in the Hyperdrive command:

```sh
npx wrangler cert upload certificate-authority --ca-cert ca.crt --name "$CA_NAME"
npx wrangler vpc service create "$VPC_SERVICE_NAME" --type tcp --tcp-port 5432 \
  --app-protocol postgresql --tunnel-id "$TUNNEL_ID" --hostname pgbouncer \
  --certificate-authority "$CA_ID" --cert-verification-mode verify_full
npx wrangler hyperdrive create "$HYPERDRIVE_NAME" --service-id "$SERVICE_ID" \
  --database "$DB_NAME" --user "$DB_USER" --password "$DB_PASSWORD" --scheme postgresql
```

Add the new Hyperdrive ID to your Worker's Hyperdrive binding. See the
[connector README](../cloudflared-tunnel/README.md) for deployment variables.

## PgBouncer

To add an application user, create the role on the coordinator, append its
SCRAM verifier entry to the host's `userlist.txt` in place (preserving the inode
of this single-file bind mount), then run `docker kill -s HUP citus-pgbouncer`.
When `pgbouncer.ini` changes, including via `patroni_pgbouncer_users`, Ansible
replaces the inode of that single-file bind mount, so HUP still sees the old
file. Run `docker restart citus-pgbouncer` to pick up the new file; expect client
connections to drop for a few seconds.

## Operational notes

- Set `patroni_coord_shm_size` (default `1g`) or `patroni_worker_shm_size` (default `256m`) to tune PostgreSQL `/dev/shm`; apply changes by recreating one node at a time: replicas first, then switch over and recreate the former primary.
- Mount the entire pgBackRest config directory read-only at `/etc/pgbackrest`,
  not the individual files. Ansible replaces files atomically; a file bind
  mount can stay pinned to the old inode. PostgreSQL runs
  `/etc/pgbackrest/pgbackrest-archive-push.sh %p`. Shared config and log
  mounts use the SELinux `:z` label.
- `edoburu/pgbouncer` needs its host `userlist.txt` readable and writable by
  UID/GID 70. Ansible sets the ownership without overwriting existing entries.
  Keep the plaintext client port off public interfaces; use an SSH tunnel
  for remote administration.
- `io-timeout=300` allows for slow S3 reads. `repo1-bundle=y` reduces
  small-object requests; `repo1-block=y` enables block-level incremental
  backups.
- `patronictl edit-config` needs `--group`: `0` for the coordinator, `1` for
  worker1, and `2` for worker2. Bootstrap YAML does not overwrite an existing
  group's dynamic configuration.