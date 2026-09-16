# FIC POS Mobile V1.13.1+56 — Table Live Total

## Mục tiêu
Hiển thị số tiền hiện tại ngay trên card của các bàn đang sử dụng ở màn Danh sách bàn.

## Thay đổi
- Card bàn đang sử dụng hiển thị số tiền dạng `245.000 đ`.
- Bàn trống không hiển thị số tiền.
- Hỗ trợ bàn có nhiều đơn mở: cộng tổng các đơn.
- Hỗ trợ offline: lấy snapshot đơn local chưa thanh toán để cập nhật tiền ngay cả khi mất mạng.
- Khi một đơn online được chỉnh tiếp lúc offline, local snapshot thay thế đúng đơn cùng `madonhang`, không cộng trùng server + local.
- Theo dõi `order_version`: khi món/số lượng/bảng giá thay đổi trên thiết bị khác, danh sách bàn tự tải lại số tiền mà không cần chờ trạng thái bàn thay đổi.

## Backend yêu cầu
Cần Web FIC POS V255.15 trở lên để bootstrap tables trả `tongtien`, `so_don`, `open_orders`.
