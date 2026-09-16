# FIC POS Mobile V1.13.5+60 - Empty Order Auto Close

Baseline: V1.13.4+59.

## Fix
- Khi xóa món cuối cùng và server xác nhận `order_closed=true`:
  - nếu bàn còn đơn khác, app tự mở đơn còn lại;
  - nếu không còn đơn khác, app quay về danh sách bàn ngay.
- Không thay đổi FAST ORDER, offline queue, multi-order, payment, notification.
