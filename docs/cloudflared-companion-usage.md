# Hướng dẫn sử dụng Cloudflared Companion

## Giới thiệu

Cloudflared Companion tự động tạo cấu hình Cloudflare Tunnel dựa trên các Docker containers đang chạy, tương tự như nginx-proxy.

## Cách hoạt động

1. **Cloudflared Companion** theo dõi Docker socket để phát hiện containers mới
2. Khi phát hiện container có labels phù hợp, nó tự động:
   - Tạo routing rules trong Cloudflare Tunnel config
   - Reload cloudflared để áp dụng config mới

## Lỗi khi khởi động

### Template Error khi chưa có container nào

```
Template error: template: config.tmpl:5:9: executing "config.tmpl" at <.Containers>: can't evaluate field Containers in type *dockergen.Context
```

**Đây KHÔNG phải là lỗi nghiêm trọng!**

- Lỗi này xuất hiện khi cloudflared-companion khởi động trước các service khác
- Cloudflared vẫn chạy bình thường với config mặc định (trả về 404)
- Khi bạn khởi động các service khác, config sẽ tự động được tạo lại

## Cách sử dụng

### 1. Khởi động Cloudflared Companion

```bash
ansible-playbook -i inventories/production install-cloudflared-companion.yml
```

### 2. Thêm labels vào containers cần expose

Ví dụ với một web service:

```yaml
services:
  myapp:
    image: nginx:alpine
    container_name: myapp
    labels:
      - "cloudflare.enable=true"
      - "cloudflare.account=zcloudf"  # Tên account trong vars/cloudflared-companion.yml
      - "cloudflare.hostname=myapp.example.com"
      - "cloudflare.port=80"
    networks:
      - cloudflare-zcloudf-net  # Phải kết nối vào network của account tương ứng

networks:
  cloudflare-zcloudf-net:
    external: true
```

### 3. Kiểm tra config đã được tạo

```bash
# Xem logs của cloudflared-companion
docker logs cloudflared-companion-zcloudf

# Xem config đã được tạo
docker exec cloudflared-companion-zcloudf cat /etc/cloudflared/config.yml
```

## Labels hỗ trợ

| Label | Bắt buộc | Mô tả | Ví dụ |
|-------|----------|-------|-------|
| `cloudflare.enable` | Có | Bật cloudflare routing | `true` |
| `cloudflare.account` | Có | Tên account cloudflare | `zcloudf` |
| `cloudflare.hostname` | Có | Hostname để expose | `app.example.com` |
| `cloudflare.port` | Không | Port của service (mặc định: 80) | `3000` |
| `cloudflare.protocol` | Không | Protocol (mặc định: http) | `https`, `tcp`, `ssh` |

## Ví dụ nâng cao

### Expose nhiều services

```yaml
services:
  web:
    image: nginx:alpine
    labels:
      - "cloudflare.enable=true"
      - "cloudflare.account=zcloudf"
      - "cloudflare.hostname=web.example.com"
    networks:
      - cloudflare-zcloudf-net

  api:
    image: node:alpine
    labels:
      - "cloudflare.enable=true"
      - "cloudflare.account=zcloudf"
      - "cloudflare.hostname=api.example.com"
      - "cloudflare.port=3000"
    networks:
      - cloudflare-zcloudf-net

networks:
  cloudflare-zcloudf-net:
    external: true
```

### Expose TCP service (SSH, Database, etc.)

```yaml
services:
  postgres:
    image: postgres:15
    labels:
      - "cloudflare.enable=true"
      - "cloudflare.account=zcloudf"
      - "cloudflare.hostname=db.example.com"
      - "cloudflare.port=5432"
      - "cloudflare.protocol=tcp"
    networks:
      - cloudflare-zcloudf-net

networks:
  cloudflare-zcloudf-net:
    external: true
```

## Troubleshooting

### Container không được tự động thêm vào config

1. Kiểm tra container có đúng labels không:
   ```bash
   docker inspect <container_name> | grep -A 10 Labels
   ```

2. Kiểm tra container có kết nối đúng network không:
   ```bash
   docker inspect <container_name> | grep -A 5 Networks
   ```

3. Xem logs của cloudflared-companion:
   ```bash
   docker logs -f cloudflared-companion-zcloudf
   ```

### Cloudflared không kết nối được

1. Kiểm tra tunnel token có đúng không trong `vars/cloudflared-companion.yml`
2. Kiểm tra logs:
   ```bash
   docker logs cloudflared-companion-zcloudf | grep -i error
   ```

## Quản lý nhiều Cloudflare accounts

Bạn có thể thêm nhiều accounts trong `vars/cloudflared-companion.yml`:

```yaml
cloudflare_accounts:
  - name: "account1"
    api_token: "xxx"
    tunnel_token: "yyy"
    tunnel_cname: "zzz.cfargotunnel.com"
  
  - name: "account2"
    api_token: "aaa"
    tunnel_token: "bbb"
    tunnel_cname: "ccc.cfargotunnel.com"
```

Mỗi account sẽ có:
- Container riêng: `cloudflared-companion-account1`, `cloudflared-companion-account2`
- Network riêng: `cloudflare-account1-net`, `cloudflare-account2-net`

Khi expose service, chỉ định account tương ứng:

```yaml
labels:
  - "cloudflare.account=account1"  # hoặc account2
networks:
  - cloudflare-account1-net  # hoặc cloudflare-account2-net
```

