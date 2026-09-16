class OfflinePromotionEngine {
  static Map<String, dynamic> evaluate({
    required Map<String, dynamic> orderData,
    required Map<String, dynamic> bootstrap,
  }) {
    final items = List<dynamic>.from(orderData['items'] as List? ?? const []);
    final activeItems = items.where((raw) {
      if (raw is! Map) return false;
      return '${raw['trangthai'] ?? 1}' != '0';
    }).cast<Map>().toList();

    double subtotal = 0;
    for (final item in activeItems) {
      subtotal += _n(item['soluong'], 1) * _n(item['dongia']);
    }
    subtotal = _round2(subtotal);

    final result = <String, dynamic>{
      'tongtien': subtotal,
      'giamgia': 0.0,
      'phaitra': subtotal,
      'promotions': <dynamic>[],
      'gifts': <dynamic>[],
      'offline_preview': true,
    };
    if (subtotal <= 0 || activeItems.isEmpty) return result;

    final snapshot = bootstrap['promotion_snapshot'];
    if (snapshot is! Map) return result;
    final promotionRows = List<dynamic>.from(snapshot['promotions'] as List? ?? const []);
    if (promotionRows.isEmpty) return result;

    final at = _orderTime(orderData['order']);
    final productCategories = <int, int>{};
    for (final raw in List<dynamic>.from(bootstrap['products'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final id = _i(raw['id']);
      final category = _i(raw['id_danhmuc']);
      if (id > 0) productCategories[id] = category;
    }

    final conditionItems = activeItems.where((e) => _i(e['fic_is_topping']) != 1).toList();
    double discountTotal = 0;
    final gifts = <Map<String, dynamic>>[];
    final applied = <Map<String, dynamic>>[];

    for (final raw in promotionRows) {
      if (raw is! Map) continue;
      final promo = Map<String, dynamic>.from(raw);
      if (!_withinSchedule(promo, at)) continue;
      final match = _match(promo, conditionItems, productCategories, subtotal);
      if (match.matched != true) continue;

      double discount = 0;
      final giftRows = <Map<String, dynamic>>[];
      final rewardType = '${promo['reward_type'] ?? ''}';
      if (rewardType == 'percent' || rewardType == 'fixed') {
        final base = '${promo['reward_apply_to'] ?? ''}' == 'matched' ? match.matchedAmount : subtotal;
        if (rewardType == 'percent') {
          final percent = _n(promo['reward_value']).clamp(0, 100).toDouble();
          discount = _round2(base * percent / 100);
        } else {
          discount = _round2(_n(promo['reward_value']).clamp(0, double.infinity).toDouble());
        }
        discount = discount.clamp(0, (subtotal - discountTotal).clamp(0, double.infinity)).toDouble();
      } else if (rewardType == 'gift_products' || rewardType == 'gift_category') {
        for (final g in List<dynamic>.from(promo['resolved_gifts'] as List? ?? const [])) {
          if (g is Map) giftRows.add(Map<String, dynamic>.from(g));
        }
      }

      final giftValue = _round2(giftRows.fold<double>(0, (sum, g) => sum + _n(g['qty']) * _n(g['reference_price'])));
      final benefit = _round2(discount + giftValue);
      final budgetEnabled = promo['budget_enabled'] == true || '${promo['budget_enabled']}' == '1';
      final remaining = promo['budget_remaining'] == null ? null : _n(promo['budget_remaining']);
      if (budgetEnabled && (remaining == null || remaining <= 0 || benefit > remaining + 0.009)) continue;
      if (discount <= 0 && giftRows.isEmpty) continue;

      discountTotal = _round2(discountTotal + discount);
      gifts.addAll(giftRows);
      applied.add(<String, dynamic>{
        'id': promo['id'],
        'code': promo['code'],
        'name': promo['name'] ?? 'Khuyến mãi',
        'discount': discount,
        'gifts': giftRows,
        'gift_value': giftValue,
        'benefit_amount': benefit,
        'offline': true,
      });
      if (!(promo['stackable'] == true || '${promo['stackable']}' == '1')) break;
    }

    final grouped = <int, Map<String, dynamic>>{};
    for (final gift in gifts) {
      final pid = _i(gift['product_id']);
      if (pid <= 0) continue;
      if (!grouped.containsKey(pid)) {
        grouped[pid] = Map<String, dynamic>.from(gift);
      } else {
        grouped[pid]!['qty'] = _n(grouped[pid]!['qty']) + _n(gift['qty']);
      }
    }

    result['giamgia'] = discountTotal;
    result['phaitra'] = _round2((subtotal - discountTotal).clamp(0, double.infinity).toDouble());
    result['promotions'] = applied;
    result['gifts'] = grouped.values.toList();
    return result;
  }

  static DateTime _orderTime(dynamic rawOrder) {
    final order = rawOrder is Map ? rawOrder : const {};
    final date = '${order['ngayban'] ?? ''}'.trim();
    var time = '${order['giovao'] ?? ''}'.trim();
    if (date.isNotEmpty && time.isNotEmpty && !time.contains('T')) {
      if (time.length == 5) time = '$time:00';
      final parsed = DateTime.tryParse('${date}T$time');
      if (parsed != null) return parsed;
    }
    final iso = DateTime.tryParse(time);
    return iso?.toLocal() ?? DateTime.now();
  }

  static bool _withinSchedule(Map<String, dynamic> promo, DateTime at) {
    final date = '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';
    final startDate = '${promo['start_date'] ?? ''}'.trim();
    final endDate = '${promo['end_date'] ?? ''}'.trim();
    if (startDate.isNotEmpty && date.compareTo(startDate) < 0) return false;
    if (endDate.isNotEmpty && date.compareTo(endDate) > 0) return false;

    final start = _timeSeconds('${promo['time_start'] ?? ''}');
    final end = _timeSeconds('${promo['time_end'] ?? ''}');
    if (start == null || end == null) return true;
    final now = at.hour * 3600 + at.minute * 60 + at.second;
    if (start <= end) return now >= start && now <= end;
    return now >= start || now <= end;
  }

  static _PromoMatch _match(Map<String, dynamic> promo, List<Map> items, Map<int, int> categories, double subtotal) {
    final type = '${promo['condition_type'] ?? ''}';
    final qtyRequired = _n(promo['condition_qty'], 1).clamp(0.001, double.infinity).toDouble();
    if (type == 'order_total') {
      return _PromoMatch(subtotal >= _n(promo['order_min']), subtotal);
    }

    final ids = List<dynamic>.from(promo['condition_ids'] as List? ?? const []).map(_i).where((e) => e > 0).toSet();
    if (ids.isEmpty) return const _PromoMatch(false, 0);
    final all = '${promo['condition_mode'] ?? ''}' == 'all';
    final counts = <int, double>{};
    double matchedAmount = 0;

    for (final item in items) {
      final pid = _i(item['id_sanpham'] ?? item['product_id']);
      final key = type == 'categories' ? (categories[pid] ?? 0) : pid;
      if (!ids.contains(key)) continue;
      final qty = _n(item['soluong'], 1);
      counts[key] = (counts[key] ?? 0) + qty;
      matchedAmount += qty * _n(item['dongia']);
    }
    if (all) {
      for (final id in ids) {
        if ((counts[id] ?? 0) < qtyRequired) return _PromoMatch(false, matchedAmount);
      }
      return _PromoMatch(true, matchedAmount);
    }
    return _PromoMatch(counts.values.fold<double>(0, (a, b) => a + b) >= qtyRequired, matchedAmount);
  }

  static int? _timeSeconds(String raw) {
    if (raw.trim().isEmpty) return null;
    final p = raw.split(':');
    if (p.length < 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final s = p.length > 2 ? int.tryParse(p[2]) ?? 0 : 0;
    if (h == null || m == null) return null;
    return h * 3600 + m * 60 + s;
  }

  static double _n(dynamic v, [double fallback = 0]) => v is num ? v.toDouble() : (double.tryParse('$v') ?? fallback);
  static int _i(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);
  static double _round2(double v) => (v * 100).roundToDouble() / 100;
}

class _PromoMatch {
  final bool matched;
  final double matchedAmount;
  const _PromoMatch(this.matched, this.matchedAmount);
}
