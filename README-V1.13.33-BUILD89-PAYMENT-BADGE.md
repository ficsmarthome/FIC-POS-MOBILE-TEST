# FIC POS Mobile V1.13.33+89 – Payment Request Badge Fix

- Badge đỏ `Yêu cầu thanh toán` chỉ đếm các yêu cầu chưa mở trên thiết bị.
- Khi người dùng mở thành công 1 yêu cầu thanh toán, badge giảm ngay 1.
- Mở lại cùng một yêu cầu không bị trừ thêm lần nữa.
- Khi đã mở hết các yêu cầu hiện có, số về 0 và badge đỏ biến mất.
- Yêu cầu mới từ server vẫn được tính và badge sẽ xuất hiện lại.
- Trạng thái đã xem được lưu cục bộ bằng SharedPreferences và giới hạn 500 khóa gần nhất.
- Giữ nguyên các sửa lỗi iOS Push/APNs/FCM, Apple privacy purpose strings và Codemagic App Store workflow của build 89.
