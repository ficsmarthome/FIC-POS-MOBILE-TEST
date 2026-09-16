# FIC POS Mobile V1.11.3+43 — Offline Core Complete (Android + iOS)

Bản này sửa toàn bộ luồng POS Offline Core trên source Flutter dùng chung cho Android và iOS.

## Sửa lỗi chính
- Offline login vẫn giữ cơ chế xác thực local 30 ngày.
- Khi đã vào trạng thái offline, bấm bàn KHÔNG gọi `/shift` hoặc API order trước khi mở bàn.
- Mở bàn lấy order cache/SQLite ngay; bàn chưa có cache vẫn tạo được order local khi thêm món.
- Add / tăng giảm / xóa món / ghi chú / tạo nhiều đơn / chọn đơn offline xử lý local ngay, không chờ socket timeout.
- Thanh toán tiền mặt, chuyển khoản, kết hợp, ghi nợ được lưu queue local; VietQR chuyển khoản tạo trực tiếp trên máy.
- Phiếu bếp / nhãn có thể mở từ dữ liệu món hiện tại khi offline.
- Background polling QR/notification/table sync dừng khi offline để tránh SocketFailed/host lookup spam.
- Mỗi 10 giây offline sync vẫn thử reconnect. Có mạng lại sẽ tự đẩy queue lên `/offline/sync` và refresh bootstrap.
- Home khi offline chỉ đọc cache, không gọi `/me`/`/bootstrap` mỗi lần quay lại từ bàn.
- Bàn có order chờ sync được đánh dấu đang sử dụng ngay cả khi server chưa nhận dữ liệu.
- Request HTTP có timeout để chuyển sang offline nhanh nếu mạng rớt đột ngột.
- Các nghiệp vụ dễ xung đột nhiều thiết bị (đổi/tách/gộp bàn/đơn, đổi bảng giá, tìm khách mới, các module quản trị) được chặn bằng thông báo rõ ràng khi offline thay vì hiện lỗi SocketFailed.
- Có banner `Đang ngoại tuyến` ngay trong màn order.

## iOS / Android
Toàn bộ logic nằm trong Dart + sqflite nên chạy chung Android và iOS. Không có nhánh xử lý offline riêng theo nền tảng.

## Backend
Tiếp tục dùng FIC POS Web V255.8 Offline Sync Backend với endpoint `/api/mobile/v1/offline/sync` và idempotency `client_id`.

## Kiểm thử khuyến nghị
1. Đăng nhập online ít nhất một lần và vào POS để cache bootstrap.
2. Logout, tắt Wi‑Fi/4G, login offline.
3. Bấm bàn trống -> thêm món -> +/- -> ghi chú -> tạo đơn 2.
4. Thanh toán tiền mặt hoặc chuyển khoản/VietQR.
5. Quay về danh sách bàn; bàn có đơn offline phải hiện đang sử dụng.
6. Bật Internet; chờ tối đa khoảng 10 giây, queue tự sync và giao diện trở lại online.
