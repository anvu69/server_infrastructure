# Server Infrastructure

## Include
- Git
- Docker & Docker compose
- Zsh with Oh-My-Zsh
- lazydocker
- Nginx Proxy
- Let's Encrypt Nginx Proxy Companion (TODO migrate to nginxproxy/acme-companion)

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
