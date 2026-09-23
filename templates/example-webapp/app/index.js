const express = require('express');
const Redis = require('ioredis');
const app = express();
const port = process.env.PORT || 3000;

// Cấu hình Sentinel sử dụng địa chỉ IP tĩnh
// Bạn có thể cấu hình các địa chỉ IP này từ biến môi trường hoặc hardcode chúng
// Trong ví dụ này, chúng ta sử dụng biến môi trường SENTINEL_IPS

// Phương án 1: Sử dụng biến môi trường
const sentinelIPs = process.env.SENTINEL_IPS
  ? process.env.SENTINEL_IPS.split(',')
  : ['172.28.0.21', '172.28.0.22', '172.28.0.23']; // IP mặc định nếu không có biến môi trường

const sentinelHosts = sentinelIPs.map(ip => {
  return {
    host: ip,
    port: 26379 // Port mặc định của Sentinel
  };
});

// Khởi tạo Redis client sử dụng Sentinel với IP
const redis = new Redis({
  sentinels: sentinelHosts,
  name: process.env.SENTINEL_MASTER_NAME || 'mymaster',
  password: process.env.REDIS_PASSWORD,
  sentinelPassword: process.env.REDIS_PASSWORD,
  enableReadyCheck: true,
  maxRetriesPerRequest: null,
  retryStrategy(times) {
    const delay = Math.min(times * 50, 2000);
    return delay;
  }
});

redis.on('connect', () => {
  console.log('Đã kết nối đến Redis master');
});

redis.on('error', (err) => {
  console.error('Lỗi Redis:', err);
});

// API đơn giản
app.get('/', async (req, res) => {
  try {
    // Tăng bộ đếm truy cập
    const visits = await redis.incr('visits');
    res.json({
      message: 'Ứng dụng web kết nối với Redis thông qua mạng proxy sử dụng IP tĩnh',
      visits,
      timestamp: new Date()
    });
  } catch (error) {
    console.error('Lỗi xử lý request:', error);
    res.status(500).json({ error: 'Lỗi máy chủ' });
  }
});

// Thông tin kết nối Redis
app.get('/redis-info', async (req, res) => {
  try {
    const info = await redis.info();
    const parsedInfo = info.split('\n').reduce((obj, line) => {
      const parts = line.split(':');
      if (parts.length === 2) {
        obj[parts[0]] = parts[1].trim();
      }
      return obj;
    }, {});

    res.json({
      redisInfo: parsedInfo,
      sentinel: {
        hosts: sentinelHosts,
        masterName: process.env.SENTINEL_MASTER_NAME || 'mymaster'
      }
    });
  } catch (error) {
    console.error('Lỗi lấy thông tin Redis:', error);
    res.status(500).json({ error: 'Lỗi máy chủ' });
  }
});

app.listen(port, () => {
  console.log(`Ứng dụng đang chạy tại http://localhost:${port}`);
}); 