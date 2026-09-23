# Ứng dụng mẫu kết nối Redis Sentinel bằng IP tĩnh

Đây là ứng dụng Node.js mẫu minh họa cách kết nối đến Redis Sentinel sử dụng địa chỉ IP tĩnh thay vì hostname trong mạng proxy.

## Ưu điểm của việc sử dụng IP tĩnh

1. **Tránh phụ thuộc vào DNS nội bộ của Docker**: DNS có thể gặp vấn đề trong một số trường hợp
2. **Kết nối nhanh hơn**: Không cần thời gian phân giải DNS
3. **Độ tin cậy cao hơn**: Đặc biệt quan trọng khi failover xảy ra
4. **Tương thích tốt với cấu trúc mạng phức tạp**: Hoạt động tốt trong các môi trường multi-host

## Cài đặt và chạy

### 1. Chuẩn bị môi trường

Đảm bảo Redis Sentinel đã được triển khai trong mạng proxy với IP tĩnh:

```bash
cd templates/redis-sentinel
docker-compose up -d
```

### 2. Cấu hình biến môi trường

Tạo một file `.env` trong thư mục này với nội dung:

```
# Thông tin Redis
REDIS_PASSWORD=your_strong_password

# Mạng proxy
REDIS_NETWORK_NAME=redis_proxy_network

# Tiền tố IP của Sentinel (tùy theo cấu hình mạng proxy)
SENTINEL_IP_PREFIX=172.28.0
```

### 3. Chạy ứng dụng web

```bash
docker-compose up -d
```

## Cách hoạt động

Ứng dụng kết nối đến Redis Sentinel sử dụng địa chỉ IP tĩnh thay vì hostname:

```javascript
// Cấu hình IP tĩnh của các sentinel
const sentinelIPs = ['172.28.0.21', '172.28.0.22', '172.28.0.23'];

const sentinelHosts = sentinelIPs.map(ip => {
  return {
    host: ip,
    port: 26379
  };
});

// Kết nối đến Redis thông qua Sentinel
const redis = new Redis({
  sentinels: sentinelHosts,
  name: 'mymaster',
  password: process.env.REDIS_PASSWORD,
  // ...
});
```

## API endpoints

- `GET /`: Hiển thị thông tin cơ bản và số lượt truy cập
- `GET /redis-info`: Hiển thị thông tin chi tiết về kết nối Redis

## Kiểm tra kết nối

Truy cập http://localhost:3000 sau khi ứng dụng đã chạy để xác nhận kết nối thành công.

## Lưu ý

- Nếu mạng proxy của bạn sử dụng dải IP khác, hãy điều chỉnh biến `SENTINEL_IP_PREFIX` trong file `.env`
- Đảm bảo mạng redis_proxy_network đã được tạo trước khi chạy ứng dụng 