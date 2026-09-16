# FIC POS Mobile V1.12.1+46 – Build Fix Android + iOS

Baseline: V1.12.0 Full Offline Business.

Sửa lỗi build được phát hiện khi chạy Android:
- Sửa cấu trúc ngoặc/widget của màn Trả hàng (`SalesReturnsPage`).
- Bổ sung helper `maxInt()` dùng bởi Trả hàng và Thành viên & tích điểm.
- Giữ nguyên toàn bộ chức năng Full Offline Business của V1.12.0.
- Dùng chung Flutter source cho Android và iOS; quy trình `tool/prepare_ios.sh`/Codemagic được giữ nguyên.

Version: `1.12.1+46`.
