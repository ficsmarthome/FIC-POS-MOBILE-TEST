# FIC POS Mobile V1.13.22+76
- Xác minh scope store/branch của payload Công thức trước khi hiển thị/cache.
- Cache recipe cũ không có scope bị từ chối để tránh lộ dữ liệu chi nhánh trước.
- Sau switch branch, scope API là nguồn sự thật và cache tiếp theo gắn đúng branch.
- Offline chỉ mở recipe khi branch cache khớp chi nhánh hiện tại.
