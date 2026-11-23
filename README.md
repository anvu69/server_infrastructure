# Server Infrastructure

## Using this repo

### Owners with private inventory access

```shell
git clone --recurse-submodules <url>
cd <repo-directory>
./tools/install-hooks.sh
```

The production inventory is a private Git submodule at `inventories/prod`.
Run `git submodule update --remote inventories/prod` to pull inventory
updates, then commit the updated submodule pointer in the parent repository.
For your own inventory changes, work on a branch in `inventories/prod`,
commit there first, then stage and commit `inventories/prod` in the parent.
The hook installer sets up the secret guard for commits in both repositories.

### Public clones

Clone the public repository with `git clone <url>`. A recursive clone will
fail when it reaches the private production submodule. You can continue
from the public checkout with your own inventory.

1. Install Ansible and its dependencies with
   `ansible-galaxy install -r requirements.yml` once Ansible is available.
2. Copy the starter inventory with
   `cp -R inventories/example inventories/my-servers`. Replace the example
   address and SSH key path, and list each host's services in
   `vault_services`. Use the [playbook variable reference](docs/variables.md)
   to fill in settings for those services. For the sample Nginx deployment,
   set `nginx_app: nginx-proxy`, `acme: nginx-proxy-acme`,
   `docker_gen: nginx-proxy`, and `nginx_files_path: ./data` in
   `group_vars/all/main.yml`. The Nginx Compose project expects Docker
   Compose and the external `nginx_proxy` network to exist on the server.
3. Store credentials in the appropriate vault sample and refer to them
   from `main.yml` as `"{{ vault_<name> }}"`. Remove unused placeholders
   and use `{}` if the shared vault has no entries. Rename each
   `vault.example.yml` to `vault.yml`. Create a local vault password file
   and set `vault_identity_list` in your
   local `ansible.cfg` to your identity, for example
   `my-servers@~/.ansible/vault/my-servers.key`. Keep the password file out
   of Git. Encrypt both files.

   ```shell
   ansible-vault encrypt --encrypt-vault-id my-servers \
     inventories/my-servers/group_vars/all/vault.yml \
     inventories/my-servers/host_vars/srv1/vault.yml
   ```

4. Set `inventory = ./inventories/my-servers` in your local `ansible.cfg`
   or pass `-i inventories/my-servers` to each Ansible command. The repo's
   `tools/where.sh` reads `inventories/prod` explicitly. For your own
   inventory, use this command to print the declared services by host.

   ```shell
   ansible-inventory -i inventories/my-servers --list | python3 -I -c '
   import json, sys
   for host, settings in sorted(json.load(sys.stdin)["_meta"]["hostvars"].items()):
       print(f"{host}:", " ".join(settings.get("vault_services", [])))
   '
   ```

5. Run the playbook for each service you declared. Use the drift playbook
   to compare declarations with the Compose state on your servers.

   ```shell
   ansible-playbook -i inventories/my-servers install-nginx.yml
   ansible-playbook -i inventories/my-servers install-lazydocker.yml
   ansible-playbook -i inventories/my-servers tools/service-drift.yml
   ```

Run `./tools/install-hooks.sh` to install the parent repository's secret
guard in a public clone.

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

### Set up the owner's vault keys

The private production inventory tracks service settings in plaintext and
credentials in encrypted vault files. Each environment uses its own key.

Obtain the three key files from the password manager and install them:

```shell
mkdir -p ~/.ansible/vault && chmod 700 ~/.ansible/vault
# copy dev.key, staging.key, prod.key into ~/.ansible/vault/
chmod 600 ~/.ansible/vault/*.key
./tools/install-hooks.sh
```

Without the matching key, `ansible-playbook` cannot decrypt that environment.
The keys are never committed and never leave the password manager over git.

### Edit production configuration

In the private submodule, edit `group_vars/all/main.yml` for shared service
settings and use `ansible-vault edit group_vars/all/vault.yml` for shared
credentials. Use `tools/vault-skeleton.sh --help` for the command that
prints placeholder values for the keys in an existing inventory.

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

In production, shared service settings live in `group_vars/all/main.yml`
inside the private inventory submodule.
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
