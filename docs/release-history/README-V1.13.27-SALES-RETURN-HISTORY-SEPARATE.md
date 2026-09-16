# FIC POS Mobile V1.13.27+81

- Màn Trả hàng không còn hiển thị Phiếu trả gần đây ở đầu danh sách.
- Thêm nút `Danh sách phiếu trả` và icon lịch sử trên AppBar.
- Nút mở màn riêng `Danh sách phiếu trả`.
- Danh sách phiếu trả riêng lazy-load 20 bản ghi/lần.
- Màn Trả hàng chính chỉ tải Hóa đơn có thể trả, cũng 20 bản ghi/lần.
- Offline: phiếu trả mới chờ đồng bộ được lưu vào cache lịch sử riêng.
- Backend V255.46 hỗ trợ `section=payments|returns` để tránh tải thừa hai danh sách cùng lúc.
