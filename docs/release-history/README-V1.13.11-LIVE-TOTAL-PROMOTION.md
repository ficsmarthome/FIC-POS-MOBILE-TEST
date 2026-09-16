# FIC POS Mobile V1.13.11+65

## Mục tiêu
Sửa hiện tượng số lượng món đã thay đổi ngay nhưng Tổng tiền / Khuyến mãi / Phải trả vẫn giữ preview cũ cho tới khi server reload.

## Thay đổi
- Giữ nguyên FAST ORDER và debounce số lượng 250ms.
- Khi add / +/- / remove món, cập nhật item state trước như cũ và đồng thời tính preview local ngay từ promotion snapshot đã cache.
- Tổng tiền, giảm giá, phải trả, banner khuyến mãi và quà tặng cập nhật cùng một nhịp UI với số lượng món.
- Sau khi mutation API thành công, gọi preview chính thức ở background; không block thao tác người dùng.
- Preview server chỉ ghi đè khi không có thao tác mới hơn, tránh response cũ làm UI nhảy ngược.
- Offline tiếp tục dùng cùng promotion engine/cache hiện tại.
- Không đổi payment, QR, notification, multi-order, sync, license, navigation hay API mutation flow.

## Version
- pubspec: 1.13.11+65
- UI: FIC POS Mobile • V1.13.11+65
