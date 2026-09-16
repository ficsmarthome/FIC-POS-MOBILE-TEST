# FIC POS MOBILE V1.10.4+36

## 429 RATE LIMIT / VIỆT HÓA
- Mọi HTTP 429 từ thao tác trực tiếp hiển thị thống nhất: **Thao tác quá nhanh. Vui lòng thử lại sau ít giây.**
- Polling nền `qr-pending`, `notification-events`, `notifications-center`, `payment-requests`, `sync-version` và các refresh nền liên quan không hiện toast 429.
- Polling nền dùng backoff dùng chung; khi một request nhận 429, các polling khác tạm dừng và tự thử lại sau `Retry-After`/exponential backoff.
- Kết hợp Web V255.7 tăng quota Mobile API hợp lý và tách bucket theo Bearer token để xử lý nguyên nhân gốc thay vì chỉ đổi câu lỗi.


## QR TRONG CHUÔNG THÔNG BÁO
- Nhận notification `qr_order` do Web V255.7 persist vào notification center dùng chung.
- Badge đỏ của chuông dùng unread notification server để không đếm QR hai lần.
- Có fallback ghép QR pending nếu app chạy với server cũ; tự dedup theo `ref_id`.
- Bấm thông báo QR mở màn hình xử lý đơn QR.
