# FIC POS Mobile V1.11.2+42 — Offline Login Timeout Fix

- Sửa đăng nhập offline bị xoay mãi khi thiết bị mất Internet hoàn toàn.
- Request `/login` online có timeout 4 giây.
- Khi timeout / mất mạng, app fallback ngay sang `OfflineStore.verifyOfflineLogin(...)`.
- Bổ sung nhận diện `TimeoutException` và `Future not completed` là lỗi mạng.
- Không thay đổi cơ chế lưu verifier offline, thời hạn 30 ngày, sync queue, QR chuyển khoản, Android/iOS.
