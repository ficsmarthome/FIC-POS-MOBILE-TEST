# FIC POS Mobile V1.12.4+49

Fix hàng đợi offline hiển thị 1 đơn và icon đồng bộ quay lặp lại.

- Tách số lượng đơn offline / thao tác nghiệp vụ / lỗi đồng bộ.
- Không gọi tất cả pending là “đơn”.
- Lỗi nghiệp vụ server được chuyển sang state=error thay vì retry tự động 10 giây/lần.
- Nút đồng bộ thủ công sẽ chủ động retry các mục lỗi.
- Spinner chỉ quay khi người dùng bấm Đồng bộ ngay, không quay theo background sync.
- Parse errors của /offline/sync và /offline/actions để không còn pending mồ côi.
- Android/iOS dùng chung source Flutter.
