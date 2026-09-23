# pg

Builds and starts a PostgreSQL container from a templated Dockerfile and
compose file.

## Variables

| Name | Source | Description |
|---|---|---|
| `pg_pg_user` | `inventories/prod/host_vars/srv1/main.yml` | Superuser name |
| `pg_pg_password` | `inventories/prod/host_vars/srv1/main.yml`, as `{{ vault_pg_pg_password }}` from `host_vars/srv1/vault.yml` | Superuser password |
| `pg_pg_port`, `pg_db`, `pg_schema`, `pg_tag`, `pg_lang`, `pg_initdb_args`, `deploy_path`, `service_name` | role defaults, overridable per host in `host_vars` | |
| `network` | `inventories/prod/group_vars/all/main.yml` | Docker network to join |
| `tz` | `inventories/prod/group_vars/all/main.yml` | Container timezone |

`pg_pg_password` must never appear as a literal in `main.yml` — only as a
reference to the vaulted `vault_pg_pg_password`.
