# Example inventory

`hosts.yml` declares one server, `srv1`. The address `203.0.113.10` is
reserved for documentation. The plaintext `vault.example.yml` files show
how to supply shared secrets, connection settings, and the host's
`vault_services` list. Ansible reads the samples as ordinary inventory
variables, so you can inspect the hierarchy with
`ansible-inventory -i inventories/example --list`. If the project
configuration points at vault identities you do not have, select a local
Ansible configuration with no vault identities for this command.

Copy this directory before adding your server details. Follow the public
clone steps in the [project README](../../README.md#public-clones) to fill
in and encrypt the copied inventory. See [Playbook variables](../../docs/variables.md)
for the inputs used by each service.
