# FIC POS Mobile V1.11.4+44 — Offline Invoice Finalization

- Thanh toán offline tạo hóa đơn local ngay lập tức và đóng đơn local.
- Bàn được giải phóng ngay sau thanh toán offline nếu không còn đơn mở khác.
- Hóa đơn offline xuất hiện trong mục Hóa đơn gần đây, kể cả khi mất Internet.
- Queue vẫn giữ snapshot đơn + payment để đồng bộ lên server khi có mạng.
- Khi server đồng bộ xong, app nhận `payment_id`/`ma_thanhtoan` và đánh dấu hóa đơn local là Đã đồng bộ.
- Áp dụng chung Android + iOS.
