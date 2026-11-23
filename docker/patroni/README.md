# Patroni / Citus

Deploys a single Docker host with three etcd members, a three-node Citus
coordinator group and two two-node worker groups. Applications connect
through PgBouncer and HAProxy to the current coordinator primary.

## Deploy

1. Add `patroni` to the target host's `vault_services`. Use the
   [example group variables](../../inventories/example/group_vars/all/main.yml)
   and [Vault keys](../../inventories/example/group_vars/all/vault.example.yml)
   as a starting point for your private inventory. Set the actual secrets in
   Vault. For an existing cluster, keep the current PostgreSQL and etcd bind
   paths, Patroni scope/namespace, and credentials; rename the inventory keys
   before redeploying.
2. Set `patroni_pgbackrest_repo_s3_bucket`, `patroni_pgbackrest_repo_s3_endpoint`
   (without `https://`), and `patroni_pgbackrest_repo_s3_region`. For Backblaze B2,
   use a private bucket and a bucket-scoped application key. Use `path` URI
   style and set the bucket lifecycle to **Keep only the last version** so
   expired backups free space. Use a separate bucket or repository prefix for
   a fresh cluster; do not point it at a live cluster's stanzas.
3. Use the default image, `anvu69/patroni-citus:4.1.3-pgbr`, which includes
   PostgreSQL 17, Citus and pgBackRest. To build it yourself, run this from a
   checkout of the [anvu69/patroni `citus-prod` branch](https://github.com/anvu69/patroni/tree/citus-prod):

   ```sh
   docker build -f Dockerfile.citus -t anvu69/patroni-citus:4.1.3-pgbr .
   ```

   For an image built directly on the target Docker host, set
   `patroni_compose_pull: false` and ensure the PgBouncer image is also present.
4. Run from the root of this repository:

   ```sh
   ansible-playbook -i inventories/prod install-patroni.yml
   ```

   The full playbook already renders pgBackRest before starting Compose. To
   render only the backup config and host command, without stopping the stack:

   ```sh
   ansible-playbook -i inventories/prod install-patroni-pgbackrest.yml
   ```

5. For a fresh cluster, once all three primaries are up and every node mounts
   the config directory at `/etc/pgbackrest`, run these on the Docker host:

   ```sh
   for group in coord worker1 worker2; do
     pgbackrest-citus apply-archive-config "$group" || break
     pgbackrest-citus stanza-create "$group" || break
     pgbackrest-citus check "$group" || break
     pgbackrest-citus backup "$group" full || break
   done
   pgbackrest-citus info
   ```

   Initialize the stanzas promptly: PostgreSQL retains unarchived WAL if the
   repository is unavailable. For an existing production stack, follow the
   rollout below instead.

By default, the runtime files are under `/docker/patroni/runtime` and
PgBouncer is published on `127.0.0.1:26432`. Keep the PostgreSQL and etcd data
directories on fast local storage.

## Production host đang chạy

**Before running either playbook**, match the inventory to the live stack:
keep its data and config mount paths, Compose network, scope/namespace, etcd
token, database, image tags, ports, and credentials. If the PostgreSQL
containers still use the legacy pgBackRest config, set
`patroni_pgbackrest_container_config: /var/log/pgbackrest/conf/pgbackrest.conf`
before deploying. Ansible also renders the config under the existing log mount,
so the current DCS archive command and nightly backup keep using the same path.

On the first `install-patroni.yml` run, leave `patroni_compose_recreate`,
`patroni_compose_pull`, `patroni_compose_stop_before_start`, and
`patroni_compose_down_before_start` unset or `false`. The playbook syncs files
and prints the Compose dry-run before `up -d --no-recreate`: running containers
are not restarted or recreated. Compose starts stopped containers and creates
missing ones. Do not run Compose concurrently with the file sync. Afterward,
run manual Compose commands from the deployment directory (default
`/docker/patroni`) as root so Compose can read the managed `.env`. Do not
source it or override its values with exported variables.

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

## Operational notes

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