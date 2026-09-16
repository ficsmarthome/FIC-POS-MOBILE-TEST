# FIC POS Mobile V1.13.8+62 — Offline promotion by order time

Baseline: V1.13.7+61 (không dùng code navigation V1.13.8 cũ).

- Cache `promotion_snapshot` từ Web V255.25.
- Khi offline, thêm/xóa/tăng giảm món sẽ tính lại khuyến mãi ngay trên máy.
- Online và offline đều xét giờ vàng theo mốc tạo của chính từng đơn.
- Đơn offline mới lưu `ngayban` + `giovao` cố định.
- Khi hóa đơn được chốt offline, khóa subtotal/discount/payable + promotion snapshot; sync lên server không đổi theo CTKM mới.
- Hóa đơn offline hiển thị tạm tính và số tiền khuyến mãi đã khóa.
- Không dùng thay đổi `popUntil()` của bản V1.13.8 cũ; navigation giữ baseline V1.13.7.
