# Plane (self-hosted, community edition)

Adapted from the official Docker Compose deployment:
https://developers.plane.so/self-hosting/methods/docker-compose
(upstream files: https://github.com/makeplane/plane/releases — `docker-compose.yml`, `variables.env`)

Plane's own Caddy container (`makeplane/plane-proxy`) keeps doing the path routing
inside the stack; the nginx-proxy already running on the target only forwards the
vhost to it and terminates TLS.

## Differences from upstream

- All internal services run on a private `plane-internal` network. Only the Caddy
  `proxy` container joins the shared `nginx_proxy` network.
- The `proxy` container does **not** publish 80/443 on the host and does not request
  certificates (`SITE_ADDRESS=:80`, `CERT_EMAIL` blank). TLS is terminated by
  nginx-proxy + acme-companion via `VIRTUAL_HOST` / `LETSENCRYPT_HOST`, like every
  other service in this repo. To publish directly on the host instead, uncomment the
  `ports:` block on `proxy`.
- `logging: local` with `LOG_MAX_SIZE` / `LOG_MAX_FILE` from `vars/common.yml`.
- Environment values come from `vars/plane.yml` and are exported by
  `tasks/plane/start.yml` instead of a `variables.env` file.

`CERT_ACME_CA` must stay non-empty even though certificates are disabled: the Caddyfile
renders `acme_ca {$CERT_ACME_CA:<default>}` and Caddy only falls back when the variable
is *unset*, not when it is blank. A blank value makes the container exit with
`wrong argument count or unexpected line ending after 'acme_ca'`.

The routing Caddy performs (useful when debugging a 404):

| path | backend |
|---|---|
| `/` | `web:3000` |
| `/spaces` | `space:3000` |
| `/god-mode` | `admin:3000` |
| `/live` | `live:3000` |
| `/api`, `/auth`, `/static` | `api:8000` |
| `/<aws_s3_bucket_name>` | `plane-minio:9000` |

```shell
docker run --rm --entrypoint cat makeplane/plane-proxy:<tag> /etc/caddy/Caddyfile
```

## Deploy

```shell
ansible-playbook install-plane.yml
```

First boot takes a few minutes: `migrator` seeds the database before `api` becomes
healthy. Follow it with:

```shell
docker compose -f ~/docker/plane/docker-compose.yml logs -f migrator api
```

Then open `https://<virtual_host>/god-mode/` to create the instance admin.

## Using external Postgres / Redis / S3

- **Postgres** — set `pg_host` (e.g. `patroni-citus-haproxy`), `pg_port` (`5000`),
  `pg_user`, `pg_password`, `pg_database` in `vars/plane.yml`, create the database
  beforehand, then comment out the `plane-db` service.
- **Redis** — set `redis_host` / `redis_port` (or `redis_url`) and comment out `plane-redis`.
- **RabbitMQ** — set `rabbitmq_*` (or `amqp_url`) and comment out `plane-mq`.
- **S3** — set `use_minio: 0`, fill `aws_region`, `aws_access_key_id`,
  `aws_secret_access_key`, `aws_s3_endpoint_url`, `aws_s3_bucket_name`, set
  `minio_endpoint_ssl: 1` for an HTTPS endpoint, then comment out `plane-minio`.

When a bundled service is commented out, also drop it from the `depends_on:` list of
the services that reference it.

## Data on disk

Everything is bind-mounted into the deploy folder (`~/docker/plane`) instead of named
volumes, matching the rest of this repo (`docker/mysql8`, `templates/pg`):

| path | container |
|---|---|
| `pgdata/` | `plane-db:/var/lib/postgresql/data` |
| `redisdata/` | `plane-redis:/data` |
| `rabbitmq_data/` | `plane-mq:/var/lib/rabbitmq` |
| `uploads/` | `plane-minio:/export` |
| `logs/{api,worker,beat-worker,migrator}/` | `/code/plane/logs` |
| `caddy/{config,data}/` | `proxy:/config`, `proxy:/data` |

`tasks/plane/start.yml` creates them before `docker compose up`; every image here runs
its entrypoint as root and chowns its own data directory, so plain root-owned `0755`
directories are enough. Backup is a plain `tar` of `pgdata/` and `uploads/`, and
`docker system prune` in `tasks/common/prune.yml` can never reclaim them.

Gotcha: run Erlang tooling on `plane-mq` as the `rabbitmq` user, not root —
`docker compose exec -u rabbitmq plane-mq rabbitmq-diagnostics ping`. A root `docker exec`
against an *empty* data directory creates a root-owned `0400 .erlang.cookie` that the
server then cannot read (`Error when reading /var/lib/rabbitmq/.erlang.cookie: eacces`).

## Notes

- Uploads are capped twice: `file_size_limit` here (bytes, default 5 MB) and
  `client_max_body_size` in `docker/nginx/nginx.conf` (currently 200M).
- The `live` service uses websockets. `proxy_read_timeout` in
  `docker/nginx/conf.d/proxy.conf` is 60s — raise it if collaborative editing
  sessions drop while idle.
- Upgrading: bump `app_release` in `vars/plane.yml` and re-run the playbook.
  Back up `~/docker/plane/pgdata` and `~/docker/plane/uploads` first.

## Importing from Plane Cloud / Linear

The Community Edition has no importer: the web app ships `settings/(workspace)/exports`
but no `imports` route, and the public API has no import endpoint. Data has to be pushed
in over `/api/v1/`. `scripts/plane-import-csv.py` does that for a Plane Cloud export.

```shell
export PLANE_API_TOKEN=...   # Workspace Settings -> API tokens
scripts/plane-import-csv.py --zip export.zip --base-url https://<virtual_host> \
    --workspace <slug> --dry-run
```

Drop `--dry-run` to write. The run is resumable — created work items, comments, links
and parent wiring are recorded in `plane-import-state.json` and skipped next time, so an
interrupted import continues instead of duplicating.

If the instance sits behind Cloudflare, note that urllib's default
`Python-urllib/x.y` User-Agent is on Cloudflare's banned-signature list: the request
never reaches Plane and comes back as `403 error code: 1010`. The script sends
`plane-import-csv/1.0` instead, which passes; `--user-agent` overrides it.

Raise the rate limit first, or the import crawls: `api_key_rate_limit` in
`vars/plane.yml` defaults to `60/minute`, and the script throttles to `--rps 0.9` to
match. Bump both for a large workspace, then put it back afterwards.

The export dialect is detected per cell: Plane Cloud packs repeated values as
`a|b|c` with `;` between the fields of one entry (`url;title`,
`created_at;created_by;body`), while the Community serializer `json.dumps()` them.
Both are accepted. Column aliases (`Due Date` -> target_date, `Cycle Name` -> cycles,
`Module Name` -> modules) are applied and reported.

Descriptions arrive as Linear markdown and are converted to HTML (headings, lists,
code spans and fences, bold/italic, links, blockquotes), escaping anything that is not
markdown. Pass `--no-markdown` to store them as plain paragraphs instead.

Not carried over, by design or by API limits:

- **Comment text** — Plane Cloud's export writes the timestamp and author of each
  comment but leaves the body empty. The script counts and reports these rather than
  posting blank comments; there is nothing in the file to recover. The comments are
  still intact in the source instance — see `scripts/plane-sync-comments.py` below.
- **Descriptions** — present in the Cloud export, absent from the Community
  serializer (`IssueExportSerializer` has no description field). The script reports
  which case it is and warns before writing empty bodies.
- **Attachments** — the export records `attachment_count` only; the files stay in Cloud.
- **Relations** (blocks / blocked-by / duplicates) — no relation endpoint in the CE
  public API.
- **created_at / created_by** — server-assigned, so every item is stamped with the
  import date. Comment authors are preserved as a text prefix instead.

Carried over: projects, work items, states (missing ones created, group inferred from
the name), labels, priority, assignees matched by display name or email, start/target
dates, parent-child links, comments, links, cycles and modules.

## Recovering the comments

`scripts/plane-sync-comments.py` reads comments straight from the source instance's
API instead of the export file, and posts them onto the matching work items here.
Both Cloud (`https://api.plane.so`) and Community expose the same `/api/v1/` paths.

```shell
export PLANE_SOURCE_TOKEN=...   # Plane Cloud
export PLANE_TARGET_TOKEN=...   # this instance
scripts/plane-sync-comments.py --source-workspace <cloud-slug> \
    --target-url https://<virtual_host> --target-workspace <slug> \
    --ledger plane-import-state.json --dry-run
```

Matching goes through the ledger from the CSV import: its keys are the source
identifiers (`PROJ-123`), which is exactly `project.identifier` + `sequence_id` as
reported by the source API — no title guessing. Work items that are not in the ledger
are counted and reported rather than skipped silently. Each copied comment is recorded
by its source id, so re-running copies nothing twice.

The original author and timestamp are preserved as a prefix line, because the API
assigns `created_by`/`created_at` from the token making the request.
