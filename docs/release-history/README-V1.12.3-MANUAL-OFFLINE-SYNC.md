# FIC POS Mobile V1.12.3+48 — Manual Offline Sync

- Thêm nút icon đồng bộ ngay trên thanh trạng thái `Đang ngoại tuyến • N đơn chờ đồng bộ`.
- Nút hiển thị cả khi đang offline và khi đã có mạng nhưng vẫn còn dữ liệu chờ.
- Bấm icon sẽ gọi đồng bộ ngay thay vì chờ timer tự động 10 giây.
- Trong lúc đồng bộ icon đổi thành vòng xoay và khóa bấm lặp.
- Có thông báo rõ ràng: đồng bộ hoàn tất, số mục còn chờ, chưa có Internet, hoặc không có dữ liệu cần đồng bộ.
- Không thay đổi backend/API; dùng lại cơ chế idempotent sync hiện có.
- Áp dụng chung cho Android và iOS.
