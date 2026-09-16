# FIC POS Mobile V1.13.25+79 — Lazy Load Pagination

## Thay đổi chính
- Chuẩn lazy-load 20 bản ghi/lần cho các danh sách lớn.
- Cuộn gần cuối tự tải trang kế tiếp và nối vào danh sách hiện có.
- Pull-to-refresh quay về trang 1.
- Phiếu trả hàng gần đây được đưa lên trên Hóa đơn có thể trả.

## Màn hình áp dụng
- Trả hàng bán
- Hóa đơn gần đây
- Nhập hàng
- Thu chi
- Trung tâm thông báo
- Khách hàng
- Tích điểm và lịch sử điểm
- Kiểm kho
- Trả nhập hàng (qua module list)
- Yêu cầu thanh toán
- Đơn QR
- Xin đi trễ/nghỉ/về sớm
- Đặt bàn (qua module list)
- Các module list có API pagination tương thích

## Offline
Cache trang đầu vẫn dùng được khi offline. Những catalog cần nghiệp vụ offline vẫn giữ dữ liệu cần thiết; không biến toàn bộ catalog thành lazy-load nếu điều đó làm hỏng luồng offline.
