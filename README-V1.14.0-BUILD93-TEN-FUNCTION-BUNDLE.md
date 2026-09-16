# FIC POS Mobile V1.14.0+93 — 10-function bundle

Base duy nhất: FIC-POS-MOBILE-V1.13.34+92-ORDER-OLD-UI-FIXED(1).zip.
Nguyên tắc: giữ Order Old UI và các luồng Build 92 hiện có; chỉ bổ sung/đồng bộ chức năng.

1. QR thanh toán local: dùng VietQrPayload (EMVCo/NAPAS) + qr_flutter/PDF Barcode, không cần tải ảnh QR từ Internet khi API trả BIN + account.
2. Ngân hàng theo chi nhánh: Mobile dùng bank từ bootstrap/print-data; companion Web API lấy bank theo chi nhánh của đơn và trả thêm BIN.
3. Mẫu tạm tính: Mobile nhận cấu hình template từ print-data (title/footer/paper width/show QR), không hard-code toàn bộ như trước.
4. Printer Center: giữ API /printers theo chi nhánh và cho phép cấu hình số bản 1-10 trên app.
5. Android Bluetooth: thêm Quét & chọn máy in; kết quả gồm thiết bị ghép đôi + thiết bị tìm thấy qua discovery.
6. In bếp 1/2 liên: direct printer đọc so_ban; nếu >1 tự thêm LIEN 1/n - BEP, LIEN 2/n - THU NGAN; không gọi lại kitchen dispatch nên không nhân món/đơn.
7. GPS chấm công: giữ payload latitude/longitude/accuracy hiện có; Web authoritative kiểm tra GPS theo chi nhánh, radius mặc định 200m và accuracy.
8. Shared weekday master: Mobile tiếp tục lấy schedule từ API, không tạo master/hard-code danh sách thứ riêng.
9. DI_MUON: Mobile không hard-code violation id; Web authoritative dùng mã DI_MUON cho lỗi hệ thống Đi muộn.
10. Offline + Smart Sync: giữ nguyên OfflineStore/queue/reconcile/table overlay của base ORDER-OLD-UI-FIXED, không viết lại luồng order để tránh regression.

Companion Web patch: app/Http/Controllers/FicMobileFullApiController.php
- print-data trả template settings + bank BIN.
- print-data ưu tiên chi nhánh của đơn nếu bh_donhang có fic_id_chinhanh.

Test bắt buộc trước Production:
- Online order/add/remove/pay + Order Old UI.
- Offline login/order/payment/sync/table state.
- QR local khi tắt Internet sau khi dữ liệu bank đã cache/load.
- Tạm tính 58/80mm + title/footer + show QR.
- Printer LAN, Bluetooth Android, so_ban=1 và so_ban=2 kitchen.
- Attendance GPS trong/ngoài bán kính và accuracy >200m.
