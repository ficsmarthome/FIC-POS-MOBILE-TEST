# FIC POS Mobile V1.10.1+33 - Performance / Realtime-lite / Smart Cache

- Menu/danh mục giữ trong state và cache local theo chi nhánh; không cache lâu bàn/order nghiệp vụ.
- Home mỗi 3 giây chỉ gọi `/sync-version`; chỉ lấy `/bootstrap?sections=menu`, `tables`, hoặc cả hai khi version đổi.
- Order mỗi 3 giây chỉ kiểm tra version; chỉ tải order thật khi order_version thay đổi.
- Khi menu thay đổi trong lúc đang order, app tự lấy lại riêng menu.
- Add / +/- / remove phản hồi UI trước rồi đồng bộ server; lỗi rollback.
- Android/iOS dùng chung logic API Laravel.

Không thay đổi cấu hình Firebase/FCM đã có ở baseline V1.10.0.
