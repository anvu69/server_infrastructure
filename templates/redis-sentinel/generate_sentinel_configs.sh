#!/bin/bash

# Script này tạo các file cấu hình sentinel riêng cho từng instance
# Cần chạy script này trước khi khởi động docker-compose

# Đảm bảo biến môi trường được đặt
if [ -z "$SENTINEL_SCALE_FACTOR" ]; then
  echo "Vui lòng đặt biến SENTINEL_SCALE_FACTOR"
  exit 1
fi

if [ -z "$REDIS_MASTER_IP" ]; then
  echo "Vui lòng đặt biến REDIS_MASTER_IP"
  exit 1
fi

if [ -z "$REDIS_PASSWORD" ]; then
  echo "Vui lòng đặt biến REDIS_PASSWORD"
  exit 1
fi

if [ -z "$SENTINEL_IP_PREFIX" ]; then
  echo "Vui lòng đặt biến SENTINEL_IP_PREFIX"
  exit 1
fi

# Thông số Sentinel
SENTINEL_DOWN_AFTER=${SENTINEL_DOWN_AFTER:-5000}
SENTINEL_PARALLEL_SYNCS=${SENTINEL_PARALLEL_SYNCS:-1}
SENTINEL_FAILOVER_TIMEOUT=${SENTINEL_FAILOVER_TIMEOUT:-180000}

# Tính số lượng sentinel cần để đồng thuận (quorum)
if [ "$SENTINEL_SCALE_FACTOR" -gt 1 ]; then
  QUORUM=$(( (SENTINEL_SCALE_FACTOR + 1) / 2 ))
else
  QUORUM=1
fi

echo "Đang tạo $SENTINEL_SCALE_FACTOR file cấu hình sentinel..."

for i in $(seq 1 $SENTINEL_SCALE_FACTOR); do
  SENTINEL_INDEX=$i
  SENTINEL_IP="${SENTINEL_IP_PREFIX}.$(( i + 20 ))"
  
  cat > sentinel${i}.conf << EOF
port 26379

dir "/tmp"

daemonize no
protected-mode yes

# Đảm bảo có đủ thời gian để phân giải DNS khi khởi động
sentinel resolve-hostnames yes
sentinel announce-hostnames yes

# Sử dụng địa chỉ IP tĩnh của Redis master
sentinel monitor mymaster ${REDIS_MASTER_IP} 6379 ${QUORUM}

sentinel auth-pass mymaster ${REDIS_PASSWORD}

sentinel down-after-milliseconds mymaster ${SENTINEL_DOWN_AFTER}

sentinel parallel-syncs mymaster ${SENTINEL_PARALLEL_SYNCS}

sentinel failover-timeout mymaster ${SENTINEL_FAILOVER_TIMEOUT}

# Tự động cập nhật cấu hình sentinel runtime
sentinel deny-scripts-reconfig no

# Cấu hình thông báo cho sentinel
sentinel announce-ip ${SENTINEL_IP}
sentinel announce-port 26379
EOF

  echo "Đã tạo file sentinel${i}.conf"
done

echo "Hoàn tất tạo các file cấu hình sentinel!" 