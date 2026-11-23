#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [service]\n' "${0##*/}"
  printf 'List declared services by host, or list the hosts that declare a service.\n'
}

if [[ $# -eq 1 && $1 == --help ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 || ${1:-} == -* ]]; then
  usage >&2
  exit 2
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ansible-inventory -i inventories/prod --list | python3 -I -c '
import json
import sys

inventory = json.load(sys.stdin)
hostvars = inventory["_meta"]["hostvars"]
hosts = set(hostvars)
for group, details in inventory.items():
    if group != "_meta":
        hosts.update(details.get("hosts", []))

services_by_host = {
    host: hostvars.get(host, {}).get("vault_services", [])
    for host in sorted(hosts)
}
if len(sys.argv) == 1:
    for host, services in services_by_host.items():
        service_list = " ".join(services)
        print(f"{host}: {service_list}".rstrip())
else:
    service = sys.argv[1]
    matching_hosts = [host for host, services in services_by_host.items() if service in services]
    if not matching_hosts:
        sys.exit(f"No hosts declare service {service!r}.")
    print("\n".join(matching_hosts))
' "$@"
