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

### Install galaxy package

```shell
ansible-galaxy install -r requirements.yml
```

### Add hosts file
Make new `hosts` file from `hosts.example` then edit target host address IP.

### Setup server
```shell
ansible-playbook setup-server.yml
```

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