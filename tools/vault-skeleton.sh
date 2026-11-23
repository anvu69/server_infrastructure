#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [inventory-directory]\n' "${0##*/}"
  printf 'Print placeholder variables for each vault.yml (default: inventories/prod).\n'
  printf 'Requires ansible-vault, configured vault identities, and Python 3 with PyYAML.\n'
}

if [[ $# -eq 1 && $1 == --help ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 || ${1:-} == -* ]]; then
  usage >&2
  exit 2
fi

exec python3 -I -c '
from pathlib import Path
import re
import subprocess
import sys

import yaml


class SkeletonDumper(yaml.SafeDumper):
    def represent_list(self, value):
        return self.represent_sequence("tag:yaml.org,2002:seq", value, flow_style=True)


SkeletonDumper.add_representer(list, SkeletonDumper.represent_list)
inventory = Path(sys.argv[1]).resolve()
if not inventory.is_dir():
    sys.exit("vault-skeleton: inventory directory does not exist")

for vault in sorted(inventory.rglob("vault.yml")):
    if not vault.is_file():
        continue
    relative_path = vault.relative_to(inventory).as_posix()
    header = relative_path.replace("\r", "\\r").replace("\n", "\\n")
    try:
        decrypted = subprocess.run(
            ["ansible-vault", "view", str(vault)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            check=True,
        )
        document = yaml.compose(decrypted.stdout, Loader=yaml.SafeLoader)
        if not isinstance(document, yaml.MappingNode):
            raise ValueError
        skeleton = {}
        for key, value in document.value:
            if not isinstance(key, yaml.ScalarNode) or not re.fullmatch(r"[A-Za-z_]\w*", key.value):
                raise ValueError
            if key.tag != "tag:yaml.org,2002:str" or key.value in skeleton:
                raise ValueError
            skeleton[key.value] = ["CHANGE_ME"] if isinstance(value, yaml.SequenceNode) else "CHANGE_ME"
        rendered = yaml.dump(skeleton, Dumper=SkeletonDumper, sort_keys=False)
    except (OSError, subprocess.CalledProcessError, ValueError, yaml.YAMLError):
        sys.exit(f"vault-skeleton: could not read {header} as a vault variable mapping")
    print(f"# {header}\n{rendered}")
' "${1:-inventories/prod}"
