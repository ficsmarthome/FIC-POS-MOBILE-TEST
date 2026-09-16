# FIC POS Mobile V1.12.6+51 — Sync Error Detail & Recovery

- Chạm vào banner lỗi đồng bộ để xem chính xác mục đang kẹt.
- Hiển thị loại nghiệp vụ, client_id/action_id, số lần lỗi, thời gian lỗi gần nhất và nguyên văn lỗi server.
- Nút "Đối soát server": dùng endpoint idempotency `/offline/status`; nếu server đã nhận thì tự clear queue local, không tạo trùng.
- Nút "Thử lại mục này": chỉ retry đúng bản ghi lỗi thay vì retry toàn bộ queue.
- Không có nút xóa lỗi thủ công nhằm tránh làm mất đơn/thao tác offline chưa lên server.
- SQLite nâng schema v4 để lưu `retry_count` và `last_attempt_at`; có migration tự động từ DB cũ.
- Giữ nguyên toàn bộ Full Offline Business, Android và iOS dùng chung source Flutter.
