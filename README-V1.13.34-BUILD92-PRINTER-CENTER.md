# FIC POS Mobile V1.13.34+92 — Printer Center

Bản Build 92 giữ Trial Banner và bổ sung trung tâm máy in dùng chung với POS Web.

## Chức năng
- Menu `Hệ thống -> Cài đặt máy in`.
- Đồng bộ cấu hình máy in theo chi nhánh từ POS Web/API.
- Tài khoản có quyền `system.settings` có thể thêm/sửa/xóa máy in ngay trên App.
- Hóa đơn, phiếu bếp và nhãn ưu tiên máy mặc định theo loại.
- Không có máy direct hoặc cấu hình `USB/PC` thì giữ luồng `Printing.layoutPdf` hiện tại.
- LAN/IP: Android + iOS gửi ESC/POS trực tiếp qua TCP (thường port 9100), dùng được trong cùng LAN kể cả Internet ngoài bị mất.
- Bluetooth Android: chọn thiết bị đã ghép đôi và in ESC/POS SPP.
- iOS: LAN/IP/AirPrint là lựa chọn dùng chung; Bluetooth generic phụ thuộc phần cứng/MFi/BLE nên App không giả định tương thích với mọi máy.
- Android thêm quyền Bluetooth Connect/Scan cho Android 12+.
- iOS `prepare_ios.sh` thêm `NSLocalNetworkUsageDescription`.

## Google Play signing
- package/applicationId: `com.ficpos.app`
- namespace Kotlin giữ `com.example.fic_pos_mobile`
- Release dùng upload key, không dùng debug signing.
- Version vẫn `1.13.34+92` vì đây là nội dung đã dự kiến cho Build 92 và Build 92 chưa được phát hành trước bản này.

## Test tối thiểu
1. Web tạo máy LAN/IP Hóa đơn mặc định -> App Android/iOS mở Cài đặt máy in phải thấy cùng máy.
2. App cùng Wi-Fi với máy in -> In thử LAN.
3. In hóa đơn -> gửi đúng máy Hóa đơn.
4. In bếp -> gửi đúng máy Bếp.
5. In nhãn -> gửi đúng máy Nhãn.
6. Android ghép đôi máy Bluetooth -> Cài đặt -> chọn thiết bị -> In thử.
7. Chọn USB/PC -> hành vi in PDF/hộp thoại hệ điều hành vẫn như Build 91/92 cũ.
