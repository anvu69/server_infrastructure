docker compose exec config sh -c "mongosh < /scripts/init-configserver.js"
docker compose exec shard1-primary sh -c "mongosh < /scripts/init-shard01.js"
docker compose exec shard2-primary sh -c "mongosh < /scripts/init-shard02.js"
docker compose exec router sh -c "mongosh < /scripts/init-router.js"

docker compose exec config bash "/scripts/auth.js"
docker compose exec shard1-primary bash "/scripts/auth.js"
docker compose exec shard2-primary bash "/scripts/auth.js"