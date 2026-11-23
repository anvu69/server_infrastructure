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

5. When all three primaries are up, run these on the Docker host as a user
   with Docker access:

   ```sh
   for group in coord worker1 worker2; do
     pgbackrest-citus apply-archive-config "$group" || break
     pgbackrest-citus stanza-create "$group" || break
     pgbackrest-citus check "$group" || break
     pgbackrest-citus backup "$group" full || break
   done
   pgbackrest-citus info
   ```

   On an existing cluster, apply the archive config to each group before its
   first backup. If `archive_mode` was previously off, roll-restart that group
   after applying the config and before running `check`. Apply the image and
   mount changes before enabling archiving. Initialize the stanzas promptly:
   PostgreSQL retains unarchived WAL if the repository is unavailable.

By default, the runtime files are under `/docker/patroni/runtime` and
PgBouncer is published on `127.0.0.1:26432`. Keep the PostgreSQL and etcd data
directories on fast local storage.

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
- Roll upgrades one group and one node at a time. Recreate replicas first
  and check replication after each, switch over to an upgraded replica, then
  recreate the former leader. Use `docker compose up -d --no-deps <node>`
  with the deployment's Compose environment to apply image or mount changes;
  `restart` alone does not. Do not use the full deployment playbook for a
  rolling upgrade: it stops the stack by default.