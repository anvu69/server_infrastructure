#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

exec python3 -I -c '
from pathlib import Path
import re
import subprocess

import yaml


ROOT = Path.cwd()
TRACKED = {
    ROOT / path for path in subprocess.check_output(
        ["git", "ls-files", "-z", "--", "install-*.yml", "tasks", "templates", "roles"],
        text=True,
    ).split("\0") if path
}
NAME = r"[A-Za-z_]\w*"
EXPRESSION = re.compile(r"\{\{-?(.*?)-?\}\}|\{%-?(.*?)-?%\}", re.S)
IGNORED_BLOCK = re.compile(r"\{#.*?#\}|\{%-?\s*raw\s*-?%\}.*?\{%-?\s*endraw\s*-?%\}", re.S)
STRING = re.compile(r""" "([^"\\]|\\.)*" | \x27([^\x27\\]|\\.)*\x27 """, re.X)
QUALIFIER = re.compile(rf"(?:[.|]\s*|\bis\s+(?:not\s+)?){NAME}")
KEYWORDS = set("and as elif else endfor endif false for if in is loop none not or range set true".split())
CONDITIONS = {"when", "changed_when", "failed_when", "until"}


def expression_names(expression):
    expression = STRING.sub(" ", expression)
    expression = QUALIFIER.sub(" ", expression)
    return {name for name in re.findall(rf"\b{NAME}\b", expression) if name.lower() not in KEYWORDS}


def references(text):
    names = set()
    local_names = set()
    for output, statement in EXPRESSION.findall(IGNORED_BLOCK.sub("", text)):
        loop = re.fullmatch(r"\s*for\s+(.+?)\s+in\s+(.+?)\s*", statement, re.S)
        if loop:
            local_names.update(re.findall(NAME, loop[1]))
            names.update(expression_names(loop[2]))
        else:
            names.update(expression_names(output or statement))
    return names - local_names


def read_yaml(path):
    return yaml.safe_load(path.read_text())


def pairs(node):
    if isinstance(node, dict):
        for key, value in node.items():
            yield key, value
            yield from pairs(value)
    elif isinstance(node, list):
        for value in node:
            yield from pairs(value)


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)
    elif isinstance(node, dict):
        for key, value in node.items():
            yield from strings(key)
            yield from strings(value)


def find_source(source, bases):
    for base in bases:
        path = (base / source).resolve()
        if path in TRACKED and path.is_file():
            return path
    return None


def vault_aliases(node):
    return {
        key for key, value in pairs(node)
        if isinstance(key, str) and re.fullmatch(NAME, key)
        and any(name.startswith("vault_") for text in strings(value) for name in references(text))
    }


def scan_playbook(playbook):
    files = [(playbook, None)]
    seen = set()
    names = set()
    aliases = set()
    missing = set()
    while files:
        path, role = files.pop()
        if path in seen:
            continue
        seen.add(path)
        node = read_yaml(path)
        aliases.update(vault_aliases(node))
        for value in strings(node):
            names.update(references(value))
        for key, value in pairs(node):
            action = str(key).rsplit(".", 1)[-1]
            if action in CONDITIONS:
                for condition in strings(value):
                    if not EXPRESSION.search(condition):
                        names.update(expression_names(condition))
            elif action in {"include_tasks", "import_tasks", "import_playbook"} and isinstance(value, str):
                source = find_source(value, (path.parent, ROOT))
                if source:
                    files.append((source, role))
                else:
                    missing.add(value)
            elif action == "template" and isinstance(value, dict) and "src" in value:
                bases = (role / "templates", path.parent, ROOT) if role else (path.parent, ROOT)
                source = find_source(value["src"], bases)
                if source:
                    names.update(references(source.read_text()))
                else:
                    missing.add(value["src"])
            elif action in {"roles", "dependencies"} and isinstance(value, list):
                for entry in value:
                    role_name = entry["role"] if isinstance(entry, dict) else entry
                    role_path = ROOT / "roles" / role_name
                    if not find_source("tasks/main.yml", (role_path,)):
                        missing.add(f"roles/{role_name}/tasks/main.yml")
                    for directory in ("tasks", "defaults", "vars", "meta"):
                        main = find_source(f"{directory}/main.yml", (role_path,))
                        if main:
                            files.append((main, role_path))
                    readme = find_source("README.md", (role_path,))
                    if readme:
                        for line in readme.read_text().splitlines():
                            documented_name = re.match(rf"^\| `({NAME})` \|", line)
                            if documented_name and any(name.startswith("vault_") for name in references(line)):
                                aliases.add(documented_name[1])
    return names, aliases, missing


public_aliases = set()
for pattern in ("inventories/example/**/main.yml", "vars/*.example.yml"):
    for path in ROOT.glob(pattern):
        public_aliases.update(vault_aliases(read_yaml(path)))

print("""# Playbook variables

Generated by `tools/list-variables.sh`. Each section lists names referenced in
the playbook and the tracked tasks, roles, and templates it uses. The lists
include Ansible facts, runtime variables, and settings with defaults. Read
the corresponding task or role for context before adding inventory settings.

**Secret** marks `vault_` names and aliases that public files document or
define as vault-backed. Store other credential inputs in your vault too.
Private inventory files are outside the scan.""")

for playbook in sorted(path for path in TRACKED if path.parent == ROOT and path.match("install-*.yml")):
    names, aliases, missing = scan_playbook(playbook)
    print(f"\n## {playbook.name}\n")
    for name in sorted(names):
        secret = name.startswith("vault_") or name in (aliases | public_aliases)
        print(f"- `{name}`" + (" **(secret)**" if secret else ""))
    for source in sorted(missing):
        print(f"\nSource unavailable: `{source}`.")
'
