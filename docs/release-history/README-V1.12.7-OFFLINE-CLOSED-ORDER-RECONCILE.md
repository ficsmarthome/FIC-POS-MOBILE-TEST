# FIC POS Mobile V1.12.7+52 — Offline Closed Order Reconcile

## Mục tiêu
Sửa dứt điểm trường hợp queue offline còn báo lỗi `Đơn hàng không tồn tại hoặc đã đóng.` sau khi đơn/hóa đơn thực tế đã được server ghi nhận.

## Thay đổi
- Khi đối soát, app gửi thêm `madonhang`, `table_id` và trạng thái local của từng `client_id`.
- Server có thể xác minh trực tiếp đơn/hóa đơn khi idempotency marker cũ bị thiếu do mất ACK/timeout.
- Nếu server xác nhận đơn cùng mã/cùng bàn đã đóng hoặc đã có hóa đơn hợp lệ, app đánh dấu queue local là `synced` và xóa badge lỗi.
- Không mở lại đơn đã đóng, không tạo đơn trùng, không xóa queue nếu server chưa xác nhận trạng thái cuối.
- Giữ nguyên màn Chi tiết lỗi đồng bộ, nút Đối soát server và Thử lại mục này.

## Version
`1.12.7+52`
