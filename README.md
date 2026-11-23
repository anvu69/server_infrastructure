# Server Infrastructure

## Include
- btop
- Git
- Docker & Docker compose
- Zsh with Oh-My-Zsh
- lazydocker
- Nginx Proxy with ACME companion
- Redis 6 (optional)
- Mysql 5.7 & Mysql 8 (optional)
- Postgresql (optional)
- Mongodb (optional)
- Dockovpn (optional)

### Install galaxy packages

```shell
ansible-galaxy install -r requirements.yml
```

### Set up vault keys

Configuration lives in `inventories/<env>/`. Non-sensitive values are committed
in plaintext; credentials are committed encrypted with ansible-vault, one key
per environment.

Obtain the three key files from the password manager and install them:

```shell
mkdir -p ~/.ansible/vault && chmod 700 ~/.ansible/vault
# copy dev.key, staging.key, prod.key into ~/.ansible/vault/
chmod 600 ~/.ansible/vault/*.key
./tools/install-hooks.sh
```

Without the matching key, `ansible-playbook` cannot decrypt that environment.
The keys are never committed and never leave the password manager over git.

### Edit configuration

```shell
# shared service settings
$EDITOR inventories/prod/group_vars/all/main.yml

# shared service credentials
ansible-vault edit inventories/prod/group_vars/all/vault.yml
```

A secret belongs in `vault.yml` as `vault_<name>`, referenced from `main.yml`
as `{{ vault_<name> }}`. `tools/check-secrets.sh` runs on every commit and
fails when any of three things is true:

1. a file matching `vault.yml` is not ansible-vault encrypted;
2. a value it decrypted out of a vault file also appears, verbatim, in a
   plaintext file;
3. a line matches one of four high-confidence credential shapes (the specific
   API-key and token formats that have leaked in this project before).

**What it does not do:** it has no idea what a secret looks like in general. A
brand-new password typed straight into a plaintext `main.yml` is not in any
vault, so check 2 has nothing to match it against, and unless it happens to
look like one of the four shapes in check 3, it commits cleanly. The guard
catches a vaulted value that escaped into plaintext; it does not catch a
credential that was never vaulted in the first place. Put the secret in
`vault.yml` first - nothing downstream will do it for you.

It also depends on having the keys. On a machine with no `~/.ansible/vault/`
keys, the vault files cannot be decrypted, check 2 prints
`note: vault at ... could not be decrypted, skipping plaintext-match check`
and the run still exits 0. So the guard protects the person who holds the
keys; a contributor who does not gets only checks 1 and 3.

### Run a playbook

```shell
ansible-playbook -i inventories/prod install-pg.yml
```

Add `--check --diff` to preview without changing anything.

### Which host runs what

Each host's encrypted inventory defines `vault_services`, the list of services
it should run. A service name is the playbook filename without `install-` and
`.yml`. Install playbooks select hosts using this list, so they no longer need
`--limit`.

- `tools/where.sh` lists the declared services on every host.
- `tools/where.sh pg` lists the hosts that declare `pg`.
- `ansible-playbook -i inventories/prod tools/service-drift.yml` compares the
  declarations with Compose container states on each host.

### Coverage of existing services

Shared service settings live in `inventories/prod/group_vars/all/main.yml`.
Some services still need their settings migrated into the inventory before
they can be installed on a host that declares them.

`roles/pg/` and `roles/redis/` are worked examples for converting the
remaining services: `pg` shows a templated service (config files rendered
from Jinja2 templates plus vault-backed secrets), and `redis` shows a
compose-only service (a static `roles/redis/files/docker-compose.yml`
installed with `copy:`, no templates at all). Use whichever one matches the
shape of the service you are converting next.

### Setup optional service
```shell
ansible-playbook install-redis.yml
```

```shell
ansible-playbook install-mysql5_7.yml
```

```shell
ansible-playbook install-mysql8.yml
```

```shell
ansible-playbook install-pg.yml
```

```shell
ansible-playbook install-pg-rep.yml
```

```shell
ansible-playbook install-mongodb.yml
```
