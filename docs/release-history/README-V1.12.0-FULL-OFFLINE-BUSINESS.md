# FIC POS Mobile V1.12.0+45 — FULL OFFLINE BUSINESS

Baseline: V1.11.4 Offline Invoice. Android + iOS dùng chung Flutter source.

## Nghiệp vụ bổ sung offline
- Trả hàng bán: xem hóa đơn đã cache/hóa đơn local chưa sync, tạo phiếu trả local và queue sync.
- Báo nguyên liệu: ghi nhận cảnh báo local + queue sync.
- Thành viên & tích điểm: cache khách/reward/lịch sử gần đây, đổi quà offline + queue sync.
- Nhập hàng: cache NCC/sản phẩm/phiếu nhập, tạo phiếu nhập offline + queue sync.
- Kiểm kho: tạo phiếu local, nhập số thực tế, hoàn thành offline + queue sync.
- Sổ thu chi: xem cache và tạo phiếu thu/chi từ danh mục đã cache.
- Chấm công: lấy GPS trên thiết bị, lưu check-in/check-out local + queue sync.
- Công việc hằng ngày: xem cache và hoàn thành việc offline + queue sync.
- Đổi bảng giá: bootstrap cache toàn bộ bảng giá + giá sản phẩm; đổi offline và queue sync.
- Đổi bàn / chuyển đơn / gộp đơn / gộp bàn / tách món: queue thao tác có idempotency; server kiểm tra xung đột khi sync.

## Cơ chế dữ liệu
SQLite DB version 3 có thêm `module_cache` và `offline_actions`. Home tự prefetch tuần tự các module quan trọng khi online để không cần mở từng màn trước khi mất mạng. Queue đơn/hóa đơn được sync trước queue nghiệp vụ để các thao tác phụ thuộc đơn offline có thể resolve sang bản ghi server.

## Lưu ý
- Xung đột nhiều thiết bị được server xác thực khi đồng bộ; thao tác không hợp lệ không bị đánh dấu synced và giữ lỗi để retry/xử lý.
- Tạo danh mục thu/chi mới vẫn yêu cầu online; khi offline dùng danh mục đã cache để tránh ID local không khớp server.
- Trả hàng nhập chưa nằm trong phạm vi bản này.
- Khách hàng mới/chọn khách cho đơn, đặt bàn và mở/đóng ca chưa được mở full offline trong bản này.

## Build
Môi trường tạo source không có Flutter CLI, vì vậy đã kiểm tra cấu trúc/static nhưng chưa chạy `flutter analyze` hay build APK/IPA tại đây.
