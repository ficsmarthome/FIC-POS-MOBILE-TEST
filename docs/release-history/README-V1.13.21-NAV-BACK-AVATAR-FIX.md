# FIC POS Mobile V1.13.21+75

- Sửa mục Hóa đơn/Đơn trên navigation: luôn hiển thị nút Quay lại riêng và pop đúng route.
- Sửa avatar nhân viên: không dùng CircleAvatar.backgroundImage trực tiếp nữa; tải bytes bằng Bearer Authorization rồi render Image.memory, có fallback chữ cái nếu tải lỗi.
- Hỗ trợ cả avatar_url tuyệt đối và tương đối.
- Không thay đổi nghiệp vụ order/offline/promotion/payment.
