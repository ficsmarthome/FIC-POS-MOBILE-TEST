# FIC POS Mobile V1.13.10+64

Build-fix phát triển từ V1.13.9+63.

## Sửa lỗi
- Sửa lỗi compile `tableHasPromotion` không tồn tại trong `TableCard`.
- Tính `hasPromotion` tại Home State, nơi có quyền truy cập cache promotion offline, rồi truyền boolean vào `TableCard`.
- Giữ nguyên chức năng 🎁 ngoài bàn, offline promotion cache, multi-order, payment, QR, notification, sync và license.
- Không dùng lại navigation thay đổi của bản V1.13.8 cũ đã revert.
