# FIC POS Mobile V1.12.9+54 — Auto Reconnect Sync Fix

- Khi app đang offline, probe kết nối nhẹ mỗi 3 giây bằng `/sync-version`.
- Khi Internet vừa quay lại: đồng bộ queue ngay, không chờ timer 10 giây.
- Khi app `resumed`: probe + sync ngay.
- Timer 10 giây vẫn giữ làm fallback cho queue `pending`.
- Không tự retry liên tục các lỗi nghiệp vụ đã ở state `error`.
- Có khóa `_offlineSyncing` chống chạy hai tiến trình sync cùng lúc.
- Sau sync thành công, reload bootstrap/trạng thái bàn/hóa đơn theo dữ liệu server.
- Không thêm dependency mới; dùng chung Android/iOS.
