# FIC POS Mobile V1.13.12+66 — FAST TOPPING + OFFLINE TOPPING

## Mục tiêu
- Giữ nguyên flow chọn món/topping hiện tại.
- Topping +/- phản hồi ngay, không chờ API.
- Tổng tiền, khuyến mãi, giảm giá và phải trả cập nhật cùng optimistic state.
- Debounce topping 220ms: nhiều lần bấm liên tục chỉ gửi trạng thái cuối.
- Không reload toàn bộ đơn sau mỗi lần bấm topping; chỉ reload một lần khi đóng sheet cấu hình.
- Topping options đọc từ `bootstrap.topping_map`, không gọi API riêng trên hot path.
- Offline dùng cùng sheet topping, cùng dữ liệu cache, lưu topping vào order local và queue sync.

## Đồng bộ
Web V255.27 bổ sung `topping_map` trong menu bootstrap và reconcile topping trong offline sync.
Không đổi multi-order/payment/QR/notification/license/navigation.

## Version
- pubspec: 1.13.12+66
- UI: FIC POS Mobile • V1.13.12+66
