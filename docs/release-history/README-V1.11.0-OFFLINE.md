# FIC POS Mobile V1.11.0+40 — OFFLINE CORE (Android + iOS)

Baseline: Mobile V1.10.4 QR Bell + 429 Backoff.

## Offline Core
- Login offline bằng tài khoản/mật khẩu đã đăng nhập online thành công trên thiết bị trong 30 ngày gần nhất.
- Cache SQLite cục bộ cho bootstrap/menu/bàn, phiên tài khoản, order hiện tại và hàng đợi đồng bộ.
- Mất mạng vẫn mở POS, xem menu/bàn đã cache, tạo đơn, thêm món, đổi số lượng, xóa món.
- Hỗ trợ nhiều đơn trên cùng một bàn khi offline; mỗi đơn có mã OFF-* độc lập.
- Thanh toán tiền mặt/chuyển khoản offline được đưa vào queue và tự đồng bộ khi có mạng.
- Chuyển khoản có QR VietQR tạo trực tiếp trên máy từ BIN/STK/tên chủ tài khoản đã cache; không cần tải ảnh QR từ Internet.
- Thanh trạng thái hiển thị chế độ Offline và số đơn chờ đồng bộ.
- Tự thử đồng bộ queue mỗi 10 giây khi Internet trở lại.
- Queue dùng client_id và backend idempotency để chống tạo trùng khi retry.

## Giới hạn của Offline Core V1.11.0
- Topping/cấu hình topping chưa được đồng bộ offline; cần online cho thao tác topping chi tiết.
- QR khách tự gọi món, push notification, SePay xác nhận tự động cần Internet. Chuyển khoản offline vẫn tạo QR và lưu trạng thái chờ đồng bộ/xác nhận.
- Các module kho/chấm công/công việc... chưa phải offline-first ở bản Core.

## Build
Project Flutter dùng chung source cho Android + iOS.
- Android: `flutter build apk --release` hoặc `flutter build appbundle --release`.
- iOS: chạy `tool/prepare_ios.sh`, sau đó build trên macOS/Xcode/Codemagic.

Backend tương ứng: FIC POS Web V255.8 OFFLINE SYNC.
