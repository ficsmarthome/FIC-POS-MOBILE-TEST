# FIC POS Mobile V1.13.26+80 — Hoàn thiện Lazy Load

Bản này hoàn thiện các danh sách còn lại sau V1.13.25:

- Ứng lương: 20 yêu cầu/lần, cuộn gần cuối tự tải thêm.
- Chọn khách hàng trong màn bán hàng: server-side search + 20 khách/lần + cuộn tải thêm; debounce 350ms để tránh gọi API liên tục khi gõ.
- Notification Center: QR fallback chỉ lấy 20 đơn đầu thay vì gọi danh sách QR không giới hạn.

Không thay đổi cơ chế offline và không có migration.
