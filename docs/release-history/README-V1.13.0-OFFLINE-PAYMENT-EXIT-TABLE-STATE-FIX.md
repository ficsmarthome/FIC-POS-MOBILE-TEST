# FIC POS Mobile V1.13.0+55

## Mục tiêu
Sửa 2 lỗi sau thanh toán offline:

1. Thanh toán thành công nhưng vẫn đứng lại trong màn đơn hàng.
2. Sau khi đồng bộ xong, bàn có thể hiện `Đang sử dụng` dù mở vào không có món.

## Thay đổi
- Sau khi thanh toán offline thành công và người dùng bấm `Xong`, app thoát ngay khỏi OrderPage và trở về danh sách bàn, giống luồng thanh toán online.
- Hóa đơn local đã được lưu trước khi thoát màn hình nên không mất dữ liệu.
- Bàn được đánh dấu trống ngay trên thiết bị sau thanh toán offline nếu không còn đơn offline mở khác.
- Không xóa local free-table override ngay khi chỉ nhận ACK đồng bộ hóa đơn.
- Local free-table override chỉ được bỏ sau khi hóa đơn đã xác nhận `synced` và app nhận fresh bootstrap từ server.
- Nếu invoice vẫn pending/error, trạng thái bàn trống local tiếp tục được giữ để không bị cache server cũ ghi đè.

## Phối hợp backend
Nên dùng cùng Web V255.14. Backend sẽ tự chuẩn hóa `bh_ban.trangthai` theo đơn đang mở thực tế sau offline sync/reconcile.
