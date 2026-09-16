# FIC POS Mobile V1.13.33+89

Baseline: FIC-POS-MOBILE-V1.13.32+86-FINAL-CLEAN(2).zip

## Thay đổi chính
- Đồng bộ version app/UI thành 1.13.33+89.
- Sửa layout menu `Yêu cầu thanh toán` trên Android và iOS: badge số không còn giãn toàn hàng, title giữ 1 dòng.
- Ổn định chiều rộng Drawer trên nhiều kích thước màn hình.
- iOS Push: chờ APNs token trước FCM token, retry khi token chưa sẵn sàng, log trạng thái và đăng ký `/push-token`.
- `tool/prepare_ios.sh`: force bundle `com.ficpos.app`, entitlements push production, Firebase plist, và thêm 2 purpose string Apple 90683.
- `codemagic.yaml`: giữ đủ 3 workflow Preview / Simulator / App Store, signing, validate plist, build IPA và App Store Connect integration.

## Apple 90683
Build iOS sẽ tự thêm:
- `NSMicrophoneUsageDescription`
- `NSSpeechRecognitionUsageDescription`

## Build App Store
Dùng workflow: `fic-pos-ios-app-store`.


## Build note
- Build 88 không dùng do lần build trước thất bại.
- Build thay thế để upload App Store Connect/TestFlight: **89**.
