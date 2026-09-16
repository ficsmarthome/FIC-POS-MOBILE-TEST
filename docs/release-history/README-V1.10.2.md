# FIC POS MOBILE V1.10.2+34

- Đồng bộ bàn/menu mỗi 2 giây bằng `/sync-version` nhẹ.
- Order đang mở kiểm tra version mỗi 1.5 giây; chỉ tải lại `/tables/{id}/order` khi version bàn đổi.
- Giữ nguyên FCM, notification center, payment request, cache menu và UI V1.10.1.
- Server V255 là bắt buộc để counter sync hoạt động đúng.

Test:
```powershell
cd C:\FIC-POS-MOBILE
flutter clean
flutter pub get
flutter analyze
flutter run -d emulator-5554
```
