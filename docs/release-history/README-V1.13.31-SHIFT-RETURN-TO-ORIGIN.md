# FIC POS Mobile V1.13.31+85 - Shift return-to-origin

- Android/iOS dùng chung source Flutter.
- Order: nếu chưa mở ca -> Mở ca -> mở thành công tự quay lại và tiếp tục vào Order.
- Sổ thu chi: nếu chưa mở ca -> Mở ca -> mở thành công tự quay lại và mở Sổ thu chi.
- ShiftPage có `returnAfterOpen`, chỉ tự pop khi được gọi bởi shift gate; mở Ca/Két từ menu vẫn hoạt động như cũ.
- Giữ nguyên logic offline hiện tại.
