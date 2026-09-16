# FIC POS Mobile V1.13.20+74

Baseline: V1.13.19+73.

## Thay đổi
- Sửa crash Chi tiết nhập hàng khi server trả `returned=[]`; App chấp nhận cả List rỗng và Map.
- Hiển thị đối soát tiền trả nhập và nút `Ghi nhận NCC đã hoàn tiền` khi có khoản NCC còn phải hoàn.
- Ghi nhận tiền NCC hoàn theo Tiền mặt / Chuyển khoản qua API Web, sau đó sinh Phiếu thu trên server.
- Sửa màn Trả hàng bán: toàn bộ card vẫn chạm được và có nút `Trả hàng` rõ ràng; normalize dữ liệu `returned` để không bị type cast.
- Sửa icon Hóa đơn/Đơn trên AppBar: mở màn bằng push trực tiếp, không pop màn chính trước nên có nút Back và không còn kẹt phải tắt App.
- Sửa avatar nhân viên: dùng endpoint Mobile bearer-auth và NetworkImage gửi Authorization header.
