# FIC POS Mobile V1.13.33+91 - Payment/Notification Badge Sync

Bản này giữ build 91 vì build 91 chưa upload Apple.

Bổ sung:
- Khi mở 1 Yêu cầu thanh toán chưa đọc từ menu, badge Yêu cầu thanh toán giảm 1.
- Đồng thời đánh dấu notification payment_request tương ứng là đã đọc trong Notification Center.
- Badge/chấm đỏ trên chuông giảm ngay cùng lúc.
- Khi không còn thông báo chưa đọc tương ứng, dấu đỏ trên chuông biến mất.
- Trạng thái được đồng bộ server-side qua /notifications-center/read khi tìm được notification tương ứng.
- Giữ toàn bộ fix read/unread payment request, iOS push/APNs, Apple privacy, Codemagic của build 91.
