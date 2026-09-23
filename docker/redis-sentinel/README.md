# Redis Sentinel trên Docker Compose

Cấu hình này triển khai một cụm Redis với Sentinel để đảm bảo tính sẵn sàng cao (high availability).

## Thành phần
- 1 Redis Master
- N Redis Replicas (có thể scale)
- M Redis Sentinels (có thể scale)

## Cấu trúc
- `redis-master`: Redis master node
- `redis-replica-1` đến `redis-replica-N`: Redis replica nodes (số lượng tùy chỉnh)
- `sentinel-1` đến `sentinel-M`: Redis sentinel nodes (số lượng tùy chỉnh)

## Cấu trúc thư mục (Ansible Role)

```
redis-sentinel/
├── defaults/           # Giá trị mặc định cho biến
│   └── main.yml
├── files/              # File tĩnh
│   └── nginx-config-guide.md
├── handlers/           # Handlers
│   └── main.yml
├── meta/               # Metadata của role
│   └── main.yml
├── tasks/              # Tasks chính của role
│   └── main.yml
├── templates/          # Template files
│   ├── docker-compose.yml.j2
│   └── sentinel.conf.j2
├── vars/               # Biến cho role
│   └── main.yml
└── redis-sentinel-playbook.yml  # Playbook sử dụng role
```

## Scale và Triển khai với Ansible

### Cách triển khai và scale

1. Sao chép role này vào thư mục roles của bạn
2. Tùy chỉnh các biến trong file `vars/main.yml` hoặc truyền các biến khi chạy playbook:
   ```yaml
   # Các thông số cấu hình cơ bản
   redis_password: "RedisSecurePassword123"  # Thay đổi mật khẩu này
   redis_data_dir: "/data/redis"
   sentinel_data_dir: "/data/sentinel"
   sentinel_conf_path: "/etc/redis/sentinel.conf"
   network_name: "nginx_proxy"  # Thay đổi tên network nếu cần
   network_subnet: "172.20.0.0/16"  # Subnet cho Docker network
   
   # Thông số scale
   replica_scale_factor: 2  # Số lượng replica nodes
   sentinel_scale_factor: 3  # Số lượng sentinel nodes
   
   # Thông số tối ưu hóa
   redis_maxclients: 10000  # Số lượng kết nối đồng thời tối đa
   redis_kernel_overcommit: true  # Bật overcommit_memory trên hệ thống
   redis_disable_thp: true  # Tắt Transparent Huge Pages
   redis_somaxconn: 1024  # Giá trị somaxconn
   ```
3. Chạy playbook:
   ```bash
   ansible-playbook -i your_inventory redis-sentinel-playbook.yml
   ```

4. Hoặc sử dụng role trong playbook của bạn:
   ```yaml
   - hosts: redis_servers
     roles:
       - role: redis-sentinel
         vars:
           replica_scale_factor: 5  # Tùy chỉnh số lượng replicas
           sentinel_scale_factor: 5  # Tùy chỉnh số lượng sentinels
   ```

### Khả năng scale

Bạn có thể scale cấu hình bằng cách điều chỉnh hai biến:

1. **replica_scale_factor**: Xác định số lượng Redis replicas
   - Ví dụ: `replica_scale_factor: 5` sẽ tạo 5 replica nodes

2. **sentinel_scale_factor**: Xác định số lượng Sentinel nodes
   - Ví dụ: `sentinel_scale_factor: 5` sẽ tạo 5 sentinel nodes

Quorum cho Sentinel được tự động tính toán dựa trên số lượng Sentinel (khoảng 50% số lượng sentinel + 1).

## Tối ưu hóa hệ thống cho Redis

Redis yêu cầu một số cấu hình kernel cụ thể để hoạt động tối ưu. Role này tự động cấu hình các thông số sau:

### 1. vm.overcommit_memory

Cấu hình này cần thiết để đảm bảo Redis có thể phân bổ bộ nhớ đúng cách, đặc biệt khi thực hiện sao lưu và sao chép. Nếu không có nó, các tác vụ nền có thể thất bại trong điều kiện bộ nhớ thấp.

- **Lỗi phổ biến**: `WARNING: Memory overcommit must be enabled!`
- **Giải pháp**: 
  - Role tự động thiết lập `vm.overcommit_memory = 1` ở cấp hệ thống thông qua sysctl.conf
  - Thông số này **CHỈ** có thể được cấu hình ở cấp máy chủ host, KHÔNG thể cấu hình trong container Docker
  - Điều này là do giới hạn bảo mật của Docker không cho phép container thay đổi một số tham số kernel nhất định

> **Lưu ý quan trọng**: Nếu bạn triển khai Redis trên Kubernetes hoặc một môi trường container được quản lý, bạn cần đảm bảo `vm.overcommit_memory = 1` được cấu hình ở cấp Node/máy chủ, không phải trong container.

### 2. Transparent Huge Pages (THP)

Redis khuyến nghị vô hiệu hóa THP vì nó có thể làm tăng độ trễ và gây ra hiệu suất không ổn định.

- **Lỗi phổ biến**: `WARNING: Transparent Huge Pages (THP) is enabled, this will create latency and memory usage issues with Redis...`
- **Giải pháp**: Role tự động vô hiệu hóa THP bằng cách đặt `echo never > /sys/kernel/mm/transparent_hugepage/enabled`.

### 3. Cấu hình TCP backlog

Các kết nối đồng thời cao yêu cầu cấu hình somaxconn thích hợp.

- **Lỗi phổ biến**: `WARNING: The TCP backlog setting of 511 cannot be enforced because...`
- **Giải pháp**: Role đặt `net.core.somaxconn=1024` trong Docker containers (tham số này được phép thiết lập ở cấp container).

### 4. Cấu hình maxclients

Giới hạn số lượng kết nối đồng thời được thiết lập để phù hợp với tài nguyên hệ thống.

- **Giá trị mặc định**: 10000 kết nối
- **Điều chỉnh**: Thay đổi biến `redis_maxclients` tùy theo nhu cầu.

## Cấu hình thủ công vm.overcommit_memory

Nếu bạn gặp vấn đề với Ansible role không thể tự động thiết lập `vm.overcommit_memory`, bạn có thể cấu hình thủ công:

1. **Thiết lập tạm thời**:
   ```bash
   sudo sysctl vm.overcommit_memory=1
   ```

2. **Thiết lập vĩnh viễn**:
   ```bash
   echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
   sudo sysctl -p
   ```

## Xử lý vấn đề phân giải tên máy chủ

Cấu hình này bao gồm một số tính năng đặc biệt để giải quyết vấn đề phổ biến "Can't resolve instance hostname" trong Redis Sentinel:

1. **Cấu hình hostname rõ ràng**:
   - Mỗi container được đặt tên rõ ràng với tham số `hostname`
   - Điều này đảm bảo các container có thể phân giải tên lẫn nhau

2. **Tùy chọn resolve-hostnames**:
   - Sentinel được cấu hình với `sentinel resolve-hostnames yes` 
   - Điều này giúp Sentinel có thể xử lý tên máy chủ thay vì chỉ sử dụng IP

3. **Healthcheck và phụ thuộc**:
   - Redis Master có healthcheck đảm bảo nó hoạt động đầy đủ trước khi Sentinel kết nối
   - Các phụ thuộc được cấu hình với điều kiện `condition: service_healthy`

4. **Kiểm tra mạng Docker**:
   - Playbook sẽ kiểm tra và tạo mạng Docker nếu cần
   - Subnet được cấu hình rõ ràng để tránh xung đột IP

## Môi trường Development

Trong môi trường development, bạn có thể mở các port để dễ dàng kết nối và kiểm tra. Để cấu hình này, hãy chỉnh sửa template `templates/docker-compose.yml.j2` và thay các phần `expose` bằng `ports` như sau:

```yaml
ports:
  - 6379:6379  # cho redis-master
  - "638{{ i }}:6379"  # cho redis-replica-{{ i }}
  - "2637{{ i }}:26379"  # cho sentinel-{{ i }}
```

## Môi trường Production

Trong môi trường production, cấu hình mặc định đã được thiết lập với các biện pháp bảo mật:

1. Không có port nào được mở ra bên ngoài network (chỉ dùng `expose` thay vì `ports`)
2. Tất cả các dịch vụ chỉ có thể truy cập từ bên trong network
3. Redis được cấu hình với chế độ `protected-mode`
4. Các dịch vụ có thể được quản lý thông qua Nginx proxy hiện có của bạn (xem hướng dẫn trong file `files/nginx-config-guide.md`)

## Kết nối

### Trong môi trường Development (với ports được mở):

Để kết nối đến Redis Master:
```
redis-cli -h localhost -p 6379 -a ${REDIS_PASSWORD}
```

Để kết nối đến Redis Replica:
```
redis-cli -h localhost -p 638N -a ${REDIS_PASSWORD}  # N là số thứ tự replica
```

Để kết nối đến Redis Sentinel:
```
redis-cli -h localhost -p 2637N  # N là số thứ tự sentinel
sentinel masters  # Hiển thị thông tin về master
sentinel slaves mymaster  # Hiển thị thông tin về replicas
```

### Trong môi trường Production:

Kết nối từ trong cùng network:
```
redis-cli -h redis-master -p 6379 -a ${REDIS_PASSWORD}
```

## Xử lý sự cố

### Vấn đề "Can't resolve instance hostname"

Nếu bạn vẫn gặp lỗi "Can't resolve instance hostname":

1. **Kiểm tra các container đã khởi động**:
   ```bash
   docker ps | grep redis
   ```

2. **Kiểm tra mạng Docker**:
   ```bash
   docker network inspect nginx_proxy
   ```

3. **Kiểm tra phân giải DNS**:
   ```bash
   docker exec -it sentinel-1 ping redis-master
   ```

4. **Khởi động lại Sentinel nếu cần**:
   ```bash
   docker restart redis-sentinel-1 redis-sentinel-2 redis-sentinel-3
   ```

5. **Kiểm tra log của Sentinel**:
   ```bash
   docker logs sentinel-1
   ```

### Vấn đề "Memory overcommit must be enabled"

Nếu bạn gặp lỗi khi cố gắng thiết lập `vm.overcommit_memory` trong container Docker:

```
Error response from daemon: failed to create task for container: failed to create shim task: OCI runtime create failed: runc create failed: sysctl "vm.overcommit_memory" is not in a separate kernel namespace: unknown
```

Đây là do giới hạn bảo mật của Docker, một số tham số kernel như `vm.overcommit_memory` không thể được thiết lập ở cấp container.

**Giải pháp**:

1. **Thiết lập trực tiếp trên máy chủ host**:
   ```bash
   sudo sysctl vm.overcommit_memory=1
   echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
   ```

2. **Kiểm tra cài đặt hiện tại**:
   ```bash
   cat /proc/sys/vm/overcommit_memory
   ```

3. **Xác nhận Redis đã nhận thấy cài đặt**:
   ```bash
   docker logs redis-master | grep overcommit
   ```

## Tích hợp với Nginx Proxy

Xem file `files/nginx-config-guide.md` để biết chi tiết về cách cấu hình Nginx proxy hiện có của bạn để quản lý Redis Sentinel.

## Kiểm tra failover

Để kiểm tra tính năng failover, bạn có thể dừng container Redis Master:
```
docker stop redis-master
```

Sau đó, một trong các replicas sẽ được thăng cấp lên làm master mới.
Để xem master hiện tại:
```
docker exec -it redis-sentinel-1 redis-cli -p 26379 sentinel get-master-addr-by-name mymaster
```

## Cấu hình ứng dụng

Khi cấu hình ứng dụng để kết nối với Redis Sentinel, sử dụng các thông số sau:

```
# Thông tin Sentinel
sentinel_hosts = sentinel-1:26379,sentinel-2:26379,...,sentinel-M:26379
master_name = mymaster
password = ${REDIS_PASSWORD}
```

## Tùy chỉnh cấu hình Sentinel

Các tham số Sentinel có thể được tùy chỉnh thông qua các biến Ansible:

- `sentinel_quorum`: Tự động tính toán dựa trên số lượng sentinel (khoảng 50% + 1)
- `sentinel_down_after`: Thời gian (ms) để xác định một node không phản hồi (mặc định: 5000)
- `sentinel_parallel_syncs`: Số lượng replicas được đồng bộ hóa song song trong quá trình failover (mặc định: 1)
- `sentinel_failover_timeout`: Thời gian (ms) chờ đợi trước khi thử failover lại (mặc định: 10000)

## Lưu ý về scale và hiệu suất

- **Cân bằng scale factor**: Tăng số lượng replica giúp tăng khả năng đọc, nhưng cũng đồng thời tăng tải cho master khi đồng bộ dữ liệu
- **Quorum**: Khi tăng số lượng sentinel, quorum tự động điều chỉnh để cần khoảng 50% số sentinel đồng ý trước khi thực hiện failover
- **Tài nguyên hệ thống**: Mỗi node Redis và Sentinel đều tiêu thụ tài nguyên, hãy cân nhắc khả năng của hệ thống khi scale

## Lưu ý bảo mật
- Sử dụng mật khẩu mạnh cho Redis trong biến `redis_password`
- Không mở các port Redis ra bên ngoài network
- Cân nhắc sử dụng TLS cho Redis trong môi trường production thực tế
- Đảm bảo network Docker được cấu hình đúng cách
- Cân nhắc sử dụng Ansible Vault cho thông tin nhạy cảm như mật khẩu

## Lưu ý khác
- Dữ liệu Redis được lưu trữ tại đường dẫn được chỉ định trong biến `redis_data_dir`
- Dữ liệu Sentinel được lưu trữ tại đường dẫn được chỉ định trong biến `sentinel_data_dir` 