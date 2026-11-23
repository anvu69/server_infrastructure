# AGENTS.md

Ansible repo that deploys docker-compose services onto a few VPS hosts.

## Layout

- `install-<service>.yml` — one playbook per service, `hosts: all`.
- `tasks/<service>/`, `templates/<service>/`, `docker/<service>/`, `roles/` — what the playbooks use.
- `inventories/prod/hosts.yml` — hosts with neutral names (`srv1`…`srv4`).
- `inventories/prod/group_vars/all/main.yml` — service settings shared by every host. Secrets are only referenced as `"{{ vault_... }}"`.
- `inventories/prod/{group_vars/all,host_vars/<host>}/vault.yml` — Ansible Vault files (encrypted).
- `tools/check-secrets.sh` — secret leak guard, also the pre-commit hook.

## Checks

```bash
ansible-playbook -i inventories/prod --syntax-check install-<service>.yml
bash tools/check-secrets.sh <changed files>     # must exit 0
bash -n <script>.sh
```

## Conventions

- Variables are namespaced by service (`vaultwarden_pg_host`, not `pg_host`).
- Any new secret value goes in a vault file — never as a literal in YAML, templates, compose files or scripts. If you need one, stop and report it instead.
- Keep YAML two-space indented, `---` at the top.
- Commit messages: Conventional Commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`).

## Forbidden

- `ansible-vault view|decrypt|edit|encrypt|rekey`, reading `~/.ansible/vault/*`, or printing decrypted values.
- Anything that connects to a real host: `ansible`/`ansible-playbook` without `--syntax-check`, `ssh`, `scp`, `docker` against remote hosts.
- Editing any `vault.yml`, `ansible.cfg`, `.gitignore`, `tools/check-secrets*`.
- `git push`, merging, rebasing other branches, deleting branches.

## Reporting

When done, report: files changed, a short summary, the exact output of the checks above, and anything you were unsure about.
