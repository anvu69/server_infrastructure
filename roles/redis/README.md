# redis

Deploys a single Redis container onto the Docker network named by `network`.

## Variables

| Name | Source | Description |
|---|---|---|
| `network` | `inventories/prod/group_vars/all/main.yml` | Docker network to join |
| `redis_deploy_path` | role default (`roles/redis/defaults/main.yml`) | Directory under `~/docker/` on the target |

No vault variables.
