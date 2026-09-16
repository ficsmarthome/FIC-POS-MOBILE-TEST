# FIC POS Mobile V1.13.23+77 - Branch-aware all notifications

- Foreground FCM chỉ popup/rung/phát âm khi `branch_id` của push trùng chi nhánh đang hoạt động.
- Click push/initial push cũng kiểm tra branch trước khi điều hướng; push sai branch không mở màn hình trống.
- Push thiếu branch bị fail-closed, notification vẫn giữ unread trên server.
- Khi chuyển chi nhánh: cập nhật `offline_branch_id`, đăng ký lại push token ngay, sau đó reload và refresh notification badge.
- Notification Center/badge lấy dữ liệu đã được Web API V255.43 scope theo chi nhánh.
- QR polling và mobile event polling vốn đã branch-scoped, được giữ nguyên.
