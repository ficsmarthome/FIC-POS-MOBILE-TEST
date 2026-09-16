# FIC POS Mobile V1.12.5+50 — Offline Sync Reconcile Fix

- Fix queue có thể đứng mãi ở trạng thái `pending` khi API trả lỗi HTTP/validation nhưng app trước đây chỉ xử lý lỗi mạng.
- Lỗi không phải mạng sẽ chuyển sang `error`, dừng retry nền vô hạn và cho phép retry thủ công.
- Thêm đối soát `/offline/status`: nếu server đã commit `client_id/action_id` nhưng app bị timeout/mất ACK thì local tự đánh dấu synced, không tạo dữ liệu trùng.
- Đối soát cả offline invoice để cập nhật `payment_id` / `ma_thanhtoan` khi server đã có hóa đơn.
- Giữ toàn bộ Full Offline Business, Android + iOS.
