import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class OfflineStore {
  static Database? _db;

  static Future<Database> db() async {
    if (_db != null) return _db!;
    final root = await getDatabasesPath();
    _db = await openDatabase(
      p.join(root, 'fic_pos_offline_v1.db'),
      version: 4,
      onCreate: (d, _) async {
        await d.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL, updated_at INTEGER NOT NULL)');
        await d.execute('CREATE TABLE order_cache (table_id INTEGER PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)');
        await d.execute('''CREATE TABLE offline_orders (
          client_id TEXT PRIMARY KEY,
          table_id INTEGER NOT NULL,
          madonhang TEXT NOT NULL,
          payload TEXT NOT NULL,
          payment TEXT,
          state TEXT NOT NULL DEFAULT 'pending',
          last_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_attempt_at INTEGER,
          updated_at INTEGER NOT NULL
        )''');
        await d.execute('''CREATE TABLE offline_invoices (
          local_invoice_id TEXT PRIMARY KEY,
          client_id TEXT NOT NULL UNIQUE,
          table_id INTEGER NOT NULL,
          madonhang TEXT NOT NULL,
          local_invoice_code TEXT NOT NULL,
          payload TEXT NOT NULL,
          payment TEXT NOT NULL,
          sync_state TEXT NOT NULL DEFAULT 'pending',
          server_payment_id INTEGER,
          server_payment_code TEXT,
          paid_at TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )''');
        await d.execute('''CREATE TABLE module_cache (
          cache_key TEXT PRIMARY KEY,
          payload TEXT NOT NULL,
          updated_at INTEGER NOT NULL
        )''');
        await d.execute('''CREATE TABLE offline_actions (
          action_id TEXT PRIMARY KEY,
          action_type TEXT NOT NULL,
          payload TEXT NOT NULL,
          state TEXT NOT NULL DEFAULT 'pending',
          last_error TEXT,
          retry_count INTEGER NOT NULL DEFAULT 0,
          last_attempt_at INTEGER,
          updated_at INTEGER NOT NULL
        )''');
      },
      onUpgrade: (d, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await d.execute('''CREATE TABLE IF NOT EXISTS offline_invoices (
            local_invoice_id TEXT PRIMARY KEY,
            client_id TEXT NOT NULL UNIQUE,
            table_id INTEGER NOT NULL,
            madonhang TEXT NOT NULL,
            local_invoice_code TEXT NOT NULL,
            payload TEXT NOT NULL,
            payment TEXT NOT NULL,
            sync_state TEXT NOT NULL DEFAULT 'pending',
            server_payment_id INTEGER,
            server_payment_code TEXT,
            paid_at TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
        }
        if (oldVersion < 3) {
          await d.execute('''CREATE TABLE IF NOT EXISTS module_cache (
            cache_key TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            updated_at INTEGER NOT NULL
          )''');
          await d.execute('''CREATE TABLE IF NOT EXISTS offline_actions (
            action_id TEXT PRIMARY KEY,
            action_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            state TEXT NOT NULL DEFAULT 'pending',
            last_error TEXT,
            updated_at INTEGER NOT NULL
          )''');
        }
        if (oldVersion < 4) {
          try { await d.execute('ALTER TABLE offline_orders ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0'); } catch (_) {}
          try { await d.execute('ALTER TABLE offline_orders ADD COLUMN last_attempt_at INTEGER'); } catch (_) {}
          try { await d.execute('ALTER TABLE offline_actions ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0'); } catch (_) {}
          try { await d.execute('ALTER TABLE offline_actions ADD COLUMN last_attempt_at INTEGER'); } catch (_) {}
        }
      },
    );
    return _db!;
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> setJson(String key, Map<String, dynamic> value) async {
    final d = await db();
    await d.insert('kv', {'k': key, 'v': jsonEncode(value), 'updated_at': _now()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> getJson(String key) async {
    final d = await db();
    final rows = await d.query('kv', where: 'k=?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return null;
    try { return Map<String, dynamic>.from(jsonDecode(rows.first['v'] as String) as Map); } catch (_) { return null; }
  }


  static Future<Set<int>> locallyFreedTableIds() async {
    final row = await getJson('offline_freed_tables');
    final raw = row?['ids'];
    if (raw is! List) return <int>{};
    return raw.map((e) => e is num ? e.toInt() : int.tryParse('$e') ?? 0).where((e) => e > 0).toSet();
  }

  static Future<void> markTableFreed(int tableId) async {
    if (tableId <= 0) return;
    final ids = await locallyFreedTableIds();
    ids.add(tableId);
    await setJson('offline_freed_tables', {'ids': ids.toList()..sort()});
  }

  static Future<void> clearTableFreed(int tableId) async {
    if (tableId <= 0) return;
    final ids = await locallyFreedTableIds();
    if (!ids.remove(tableId)) return;
    await setJson('offline_freed_tables', {'ids': ids.toList()..sort()});
  }

  static Future<Set<int>> pendingInvoiceTableIds() async {
    final d = await db();
    final rows = await d.rawQuery("SELECT DISTINCT table_id FROM offline_invoices WHERE sync_state!='synced'");
    return rows.map((r) => (r['table_id'] as num?)?.toInt() ?? 0).where((e) => e > 0).toSet();
  }

  // Drop only overrides whose paid offline invoice is already confirmed by the server.
  // Overrides for invoices still pending/error must survive fresh bootstrap responses because
  // the server may still show the pre-payment table state until that invoice is synchronized.
  static Future<void> clearConfirmedFreedTables() async {
    final freed = await locallyFreedTableIds();
    if (freed.isEmpty) return;
    final pendingInvoiceTables = await pendingInvoiceTableIds();
    final keep = freed.where(pendingInvoiceTables.contains).toList()..sort();
    await setJson('offline_freed_tables', {'ids': keep});
  }

  static Future<void> cacheBootstrap(String base, int branchId, Map<String, dynamic> value) => setJson('bootstrap::$base::$branchId', value);
  static Future<Map<String, dynamic>?> getBootstrap(String base, int branchId) => getJson('bootstrap::$base::$branchId');
  static Future<void> cachePromotionSnapshot(String base, int branchId, Map<String, dynamic> value) => setJson('promotions::$base::$branchId', value);
  static Future<Map<String, dynamic>?> getPromotionSnapshot(String base, int branchId) => getJson('promotions::$base::$branchId');
  static Future<void> cacheMe(String base, Map<String, dynamic> value) => setJson('me::$base', value);
  static Future<Map<String, dynamic>?> getMe(String base) => getJson('me::$base');
  static Future<void> cacheShift(String base, int branchId, Map<String, dynamic> value) => setJson('shift::$base::$branchId', value);
  static Future<Map<String, dynamic>?> getShift(String base, int branchId) => getJson('shift::$base::$branchId');

  static String _randomSalt() {
    final r = Random.secure();
    final bytes = List<int>.generate(24, (_) => r.nextInt(256));
    return base64UrlEncode(bytes);
  }

  static String _hashPassword(String password, String salt) {
    List<int> bytes = utf8.encode('$salt::$password');
    for (var i = 0; i < 12000; i++) {
      bytes = sha256.convert(bytes).bytes;
    }
    return base64UrlEncode(bytes);
  }

  static Future<void> saveOfflineLogin({
    required String base,
    required String slug,
    required String account,
    required String password,
    required String token,
    required Map<String, dynamic> loginResponse,
  }) async {
    final salt = _randomSalt();
    await setJson('offline_login::$base::${account.toLowerCase()}', {
      'base': base,
      'slug': slug,
      'account': account,
      'salt': salt,
      'verifier': _hashPassword(password, salt),
      'token': token,
      'login': loginResponse,
      'verified_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<Map<String, dynamic>?> verifyOfflineLogin({required String base, required String account, required String password, int maxDays = 30}) async {
    final row = await getJson('offline_login::$base::${account.toLowerCase()}');
    if (row == null) return null;
    final salt = '${row['salt'] ?? ''}';
    final verifier = '${row['verifier'] ?? ''}';
    if (salt.isEmpty || verifier.isEmpty || _hashPassword(password, salt) != verifier) return null;
    final verified = DateTime.tryParse('${row['verified_at'] ?? ''}');
    if (verified == null || DateTime.now().difference(verified).inDays > maxDays) {
      throw Exception('Phiên đăng nhập ngoại tuyến đã quá 30 ngày. Hãy kết nối Internet để xác thực lại.');
    }
    return row;
  }

  static Future<void> cacheOrder(int tableId, Map<String, dynamic> payload) async {
    final d = await db();
    await d.insert('order_cache', {'table_id': tableId, 'payload': jsonEncode(payload), 'updated_at': _now()}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<Map<String, dynamic>?> getOrder(int tableId) async {
    final d = await db();
    final rows = await d.query('order_cache', where: 'table_id=?', whereArgs: [tableId], limit: 1);
    if (rows.isEmpty) return null;
    try { return Map<String, dynamic>.from(jsonDecode(rows.first['payload'] as String) as Map); } catch (_) { return null; }
  }

  static String ensureClientId(Map<String, dynamic> orderData, int tableId) {
    final existing = '${orderData['offline_client_id'] ?? ''}'.trim();
    if (existing.isNotEmpty) return existing;
    return 'OFF-$tableId-${DateTime.now().microsecondsSinceEpoch}';
  }

  static Future<void> queueOrder({required int tableId, required Map<String, dynamic> orderData, Map<String, dynamic>? payment}) async {
    final d = await db();
    final clientId = ensureClientId(orderData, tableId);
    final code = '${(orderData['order'] as Map?)?['madonhang'] ?? clientId}';
    orderData['offline_client_id'] = clientId;
    // Any new/updated open offline order makes the table busy again.
    // Payment queue calls this first; finalizeInvoice() will free it again only
    // when no other unpaid offline order remains on the table.
    await clearTableFreed(tableId);
    await cacheOrder(tableId, orderData);
    await d.insert('offline_orders', {
      'client_id': clientId,
      'table_id': tableId,
      'madonhang': code,
      'payload': jsonEncode(orderData),
      'payment': payment == null ? null : jsonEncode(payment),
      'state': 'pending',
      'last_error': null,
      'retry_count': 0,
      'last_attempt_at': null,
      'updated_at': _now(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<int> pendingCount() async {
    final s = await pendingSummary();
    return (s['orders'] ?? 0) + (s['actions'] ?? 0) + (s['errors'] ?? 0);
  }

  static Future<Map<String, int>> pendingSummary() async {
    final d = await db();
    final op = await d.rawQuery("SELECT COUNT(*) c FROM offline_orders WHERE state='pending'");
    final ap = await d.rawQuery("SELECT COUNT(*) c FROM offline_actions WHERE state='pending'");
    final oe = await d.rawQuery("SELECT COUNT(*) c FROM offline_orders WHERE state='error'");
    final ae = await d.rawQuery("SELECT COUNT(*) c FROM offline_actions WHERE state='error'");
    return <String, int>{
      'orders': ((op.first['c'] as int?) ?? 0),
      'actions': ((ap.first['c'] as int?) ?? 0),
      'errors': ((oe.first['c'] as int?) ?? 0) + ((ae.first['c'] as int?) ?? 0),
    };
  }

  static Future<List<String>> unsyncedOrderIds({int limit = 100}) async {
    final d = await db();
    final rows = await d.query('offline_orders', columns:['client_id'], where: "state IN ('pending','error')", orderBy:'updated_at ASC', limit:limit);
    return rows.map((r) => '${r['client_id'] ?? ''}').where((x) => x.isNotEmpty).toList();
  }


  static Future<List<Map<String, dynamic>>> unsyncedOrderRefs({int limit = 100}) async {
    final d = await db();
    final rows = await d.query(
      'offline_orders',
      columns:['client_id','madonhang','table_id','payment','state'],
      where: "state IN ('pending','error')",
      orderBy:'updated_at ASC',
      limit:limit,
    );
    return rows.map((r) => <String,dynamic>{
      'client_id':'${r['client_id'] ?? ''}',
      'madonhang':'${r['madonhang'] ?? ''}',
      'table_id':(r['table_id'] as num?)?.toInt() ?? 0,
      'has_payment':('${r['payment'] ?? ''}').trim().isNotEmpty,
      'state':'${r['state'] ?? ''}',
    }).where((r) => (r['client_id'] as String).isNotEmpty).toList();
  }

  static Future<List<String>> unsyncedActionIds({int limit = 100}) async {
    final d = await db();
    final rows = await d.query('offline_actions', columns:['action_id'], where: "state IN ('pending','error')", orderBy:'updated_at ASC', limit:limit);
    return rows.map((r) => '${r['action_id'] ?? ''}').where((x) => x.isNotEmpty).toList();
  }

  static Future<void> retryErrors() async {
    final d = await db();
    final now = _now();
    await d.update('offline_orders', {'state':'pending','last_error':null,'last_attempt_at':now,'updated_at':now}, where:"state='error'");
    await d.update('offline_actions', {'state':'pending','last_error':null,'last_attempt_at':now,'updated_at':now}, where:"state='error'");
  }


  static Future<List<Map<String, dynamic>>> syncIssues({int limit = 50}) async {
    final d = await db();
    final out = <Map<String, dynamic>>[];
    final orders = await d.query('offline_orders', where: "state='error'", orderBy: 'updated_at DESC', limit: limit);
    for (final r in orders) {
      Map<String, dynamic> payload = <String, dynamic>{};
      try { payload = Map<String, dynamic>.from(jsonDecode('${r['payload']}') as Map); } catch (_) {}
      final order = payload['order'] is Map ? Map<String, dynamic>.from(payload['order'] as Map) : <String, dynamic>{};
      final table = payload['table'] is Map ? Map<String, dynamic>.from(payload['table'] as Map) : <String, dynamic>{};
      out.add(<String, dynamic>{
        'kind':'order', 'id':'${r['client_id']}', 'type':'order_sync',
        'title':'Đơn hàng ${r['madonhang'] ?? order['madonhang'] ?? ''}',
        'subtitle':'${table['tenban'] ?? table['name'] ?? 'Bàn ${r['table_id']}'}',
        'error':'${r['last_error'] ?? 'Không rõ lỗi'}',
        'retry_count':(r['retry_count'] as num?)?.toInt() ?? 0,
        'updated_at':(r['updated_at'] as num?)?.toInt() ?? 0,
        'last_attempt_at':(r['last_attempt_at'] as num?)?.toInt(),
      });
    }
    final actions = await d.query('offline_actions', where: "state='error'", orderBy: 'updated_at DESC', limit: limit);
    for (final r in actions) {
      out.add(<String, dynamic>{
        'kind':'action', 'id':'${r['action_id']}', 'type':'${r['action_type']}',
        'title': _actionLabel('${r['action_type']}'),
        'subtitle':'${r['action_id']}',
        'error':'${r['last_error'] ?? 'Không rõ lỗi'}',
        'retry_count':(r['retry_count'] as num?)?.toInt() ?? 0,
        'updated_at':(r['updated_at'] as num?)?.toInt() ?? 0,
        'last_attempt_at':(r['last_attempt_at'] as num?)?.toInt(),
      });
    }
    out.sort((a,b)=>((b['updated_at'] as int?)??0).compareTo((a['updated_at'] as int?)??0));
    return out.take(limit).toList();
  }

  static String _actionLabel(String type) {
    const labels = <String,String>{
      'sales_return':'Trả hàng', 'ingredient_report':'Báo nguyên liệu', 'loyalty_redeem':'Thành viên & tích điểm',
      'purchase':'Nhập hàng', 'stocktake':'Kiểm kho', 'cashbook':'Sổ thu chi', 'attendance':'Chấm công',
      'daily_task':'Công việc hằng ngày', 'price_list':'Đổi bảng giá', 'table_move':'Đổi bàn',
      'order_move':'Chuyển đơn', 'order_split':'Tách đơn', 'order_merge':'Gộp đơn',
    };
    return labels[type] ?? 'Thao tác offline: $type';
  }

  static Future<void> retryOne(String kind, String id) async {
    final d = await db();
    final now = _now();
    if (kind == 'order') {
      await d.update('offline_orders', {'state':'pending','last_error':null,'last_attempt_at':now,'updated_at':now}, where:'client_id=?', whereArgs:[id]);
    } else {
      await d.update('offline_actions', {'state':'pending','last_error':null,'last_attempt_at':now,'updated_at':now}, where:'action_id=?', whereArgs:[id]);
    }
  }

  static Future<List<int>> pendingTableIds() async {
    final d = await db();
    final rows = await d.rawQuery("SELECT DISTINCT table_id FROM offline_orders WHERE state='pending' AND (payment IS NULL OR payment='')");
    return rows.map((r) => (r['table_id'] as num?)?.toInt() ?? 0).where((x) => x > 0).toList();
  }

  /// V1.13.1: tổng tiền các đơn offline chưa thanh toán theo bàn và mã đơn.
  /// Payload offline là snapshot đầy đủ của đơn, nên có thể dùng nó để overlay lên
  /// open_orders server mà không cộng trùng khi một đơn online được chỉnh tiếp lúc mất mạng.
  static Future<Map<int, Map<String, double>>> pendingOpenOrderTotalsByTable() async {
    final d = await db();
    final rows = await d.query(
      'offline_orders',
      columns: ['table_id','madonhang','payload'],
      where: "state='pending' AND (payment IS NULL OR payment='')",
      orderBy: 'updated_at ASC',
    );
    final out = <int, Map<String, double>>{};
    for (final r in rows) {
      final tableId = (r['table_id'] as num?)?.toInt() ?? 0;
      final code = '${r['madonhang'] ?? ''}'.trim();
      if (tableId <= 0 || code.isEmpty) continue;
      try {
        final payload = Map<String, dynamic>.from(jsonDecode('${r['payload']}') as Map);
        final items = List.from(payload['items'] as List? ?? const []);
        double total = 0;
        for (final raw in items) {
          if (raw is! Map) continue;
          if ('${raw['trangthai'] ?? 1}' == '0') continue;
          final qty = double.tryParse('${raw['soluong'] ?? 1}') ?? 1;
          final price = double.tryParse('${raw['dongia'] ?? 0}') ?? 0;
          total += qty * price;
        }
        (out[tableId] ??= <String, double>{})[code] = total;
      } catch (_) {}
    }
    return out;
  }

  static Future<Set<int>> pendingPromotionTableIds() async {
    final d = await db();
    final rows = await d.query('offline_orders', columns: ['table_id','payload'], where: "state='pending' AND (payment IS NULL OR payment='')");
    final out = <int>{};
    for (final r in rows) {
      final tableId = (r['table_id'] as num?)?.toInt() ?? 0;
      if (tableId <= 0) continue;
      try {
        final payload = Map<String, dynamic>.from(jsonDecode('${r['payload']}') as Map);
        final preview = payload['offline_promotion_preview'];
        if (preview is Map) {
          final discount = double.tryParse('${preview['giamgia'] ?? preview['discount'] ?? 0}') ?? 0;
          final promos = preview['promotions'] as List? ?? const [];
          final gifts = preview['gifts'] as List? ?? const [];
          if (discount > 0 || promos.isNotEmpty || gifts.isNotEmpty) out.add(tableId);
        }
      } catch (_) {}
    }
    return out;
  }

  static Future<List<Map<String, dynamic>>> pendingForTable(int tableId) async {
    final d = await db();
    final rows = await d.query('offline_orders', where: "state='pending' AND (payment IS NULL OR payment='') AND table_id=?", whereArgs: [tableId], orderBy: 'updated_at ASC');
    return rows.map((r) {
      final payload = Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map);
      final paymentRaw = r['payment'] as String?;
      return {
        'client_id': r['client_id'],
        'table_id': r['table_id'],
        'madonhang': r['madonhang'],
        'payload': payload,
        if (paymentRaw != null && paymentRaw.isNotEmpty) 'payment': Map<String, dynamic>.from(jsonDecode(paymentRaw) as Map),
      };
    }).toList();
  }

  static Future<Map<String, dynamic>?> pendingByOrderCode(int tableId, String code) async {
    final rows = await pendingForTable(tableId);
    for (final row in rows) {
      if ('${row['madonhang']}' == code) return row;
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> pendingOrders({int limit = 20}) async {
    final d = await db();
    final rows = await d.query('offline_orders', where: "state='pending'", orderBy: 'updated_at ASC', limit: limit);
    return rows.map((r) {
      final payload = Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map);
      final paymentRaw = r['payment'] as String?;
      return {
        'client_id': r['client_id'],
        'table_id': r['table_id'],
        'madonhang': r['madonhang'],
        'payload': payload,
        if (paymentRaw != null && paymentRaw.isNotEmpty) 'payment': Map<String, dynamic>.from(jsonDecode(paymentRaw) as Map),
      };
    }).toList();
  }

  static Future<void> markSynced(Iterable<String> clientIds) async {
    final d = await db();
    final batch = d.batch();
    for (final id in clientIds) {
      batch.update('offline_orders', {'state': 'synced', 'last_error': null, 'updated_at': _now()}, where: 'client_id=?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> markError(String clientId, String error) async {
    final d = await db();
    await d.rawUpdate("UPDATE offline_orders SET state='error', last_error=?, retry_count=COALESCE(retry_count,0)+1, last_attempt_at=?, updated_at=? WHERE client_id=?", [error, _now(), _now(), clientId]);
  }
  static Future<void> finalizeInvoice({
    required int tableId,
    required Map<String, dynamic> orderData,
    required Map<String, dynamic> payment,
  }) async {
    final d = await db();
    final clientId = ensureClientId(orderData, tableId);
    final code = '${(orderData['order'] as Map?)?['madonhang'] ?? clientId}';
    final paidAt = '${payment['offline_paid_at'] ?? DateTime.now().toIso8601String()}';
    final localCode = '${payment['local_invoice_code'] ?? 'OFF-${DateTime.now().millisecondsSinceEpoch}'}';
    await d.insert('offline_invoices', {
      'local_invoice_id': 'INV::$clientId',
      'client_id': clientId,
      'table_id': tableId,
      'madonhang': code,
      'local_invoice_code': localCode,
      'payload': jsonEncode(orderData),
      'payment': jsonEncode(payment),
      'sync_state': 'pending',
      'server_payment_id': null,
      'server_payment_code': null,
      'paid_at': paidAt,
      'updated_at': _now(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await d.delete('order_cache', where: 'table_id=?', whereArgs: [tableId]);
    final openRows = await d.rawQuery("SELECT COUNT(*) c FROM offline_orders WHERE table_id=? AND state='pending' AND (payment IS NULL OR payment='')", [tableId]);
    final openCount = ((openRows.first['c'] as int?) ?? 0);
    if (openCount == 0) {
      await markTableFreed(tableId);
    } else {
      await clearTableFreed(tableId);
    }
  }

  static Future<void> markInvoiceSynced(String clientId, {int? paymentId, String? paymentCode}) async {
    final d = await db();
    final rows = await d.query('offline_invoices', columns: ['table_id'], where: 'client_id=?', whereArgs: [clientId], limit: 1);
    final tableId = rows.isEmpty ? 0 : ((rows.first['table_id'] as num?)?.toInt() ?? 0);
    await d.update('offline_invoices', {
      'sync_state': 'synced',
      'server_payment_id': paymentId,
      'server_payment_code': paymentCode,
      'updated_at': _now(),
    }, where: 'client_id=?', whereArgs: [clientId]);
    // V1.13.0: do NOT clear the local freed-table override here.
    // The payment ACK can arrive before a fresh bootstrap/table-state response. Clearing it now can
    // briefly (or permanently, if the server table flag is stale) make the just-paid table look busy
    // even though there is no open order. Home clears these overrides only after a fresh online
    // bootstrap has been received successfully.
  }

  static Future<List<Map<String, dynamic>>> recentInvoices({int limit = 50, bool onlyUnsynced = false}) async {
    final d = await db();
    final rows = await d.query(
      'offline_invoices',
      where: onlyUnsynced ? "sync_state!='synced'" : null,
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map((r) {
      final payload = Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map);
      final payment = Map<String, dynamic>.from(jsonDecode(r['payment'] as String) as Map);
      final order = payload['order'] is Map ? Map<String, dynamic>.from(payload['order'] as Map) : <String, dynamic>{};
      final table = payload['table'] is Map ? Map<String, dynamic>.from(payload['table'] as Map) : <String, dynamic>{};
      final items = (payload['items'] as List?) ?? const [];
      return <String, dynamic>{
        'offline_local': true,
        'local_invoice_id': r['local_invoice_id'],
        'client_id': r['client_id'],
        'table_id': r['table_id'],
        'madonhang': r['madonhang'],
        'ma_thanhtoan': (r['server_payment_code'] as String?)?.isNotEmpty == true ? r['server_payment_code'] : r['local_invoice_code'],
        'local_invoice_code': r['local_invoice_code'],
        'server_payment_id': r['server_payment_id'],
        'sync_state': r['sync_state'],
        'paid_at': r['paid_at'],
        'phuongthuc': payment['phuongthuc'],
        'phaitra': payment['amount'] ?? 0,
        'tenban': table['tenban'] ?? table['name'] ?? 'Bàn ${r['table_id']}',
        'ten_khachhang': order['ten_khachhang'] ?? order['khachhang'] ?? 'Khách lẻ',
        'payload': payload,
        'payment': payment,
        'items': items,
      };
    }).toList();
  }

  static String moduleKey(String base, int branchId, String module) => '$base::$branchId::$module';

  static Future<void> cacheModule(String base, int branchId, String module, dynamic payload) async {
    final d = await db();
    await d.insert('module_cache', {
      'cache_key': moduleKey(base, branchId, module),
      'payload': jsonEncode(payload),
      'updated_at': _now(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<dynamic> getModule(String base, int branchId, String module) async {
    final d = await db();
    final rows = await d.query('module_cache', where: 'cache_key=?', whereArgs: [moduleKey(base, branchId, module)], limit: 1);
    if (rows.isEmpty) return null;
    try { return jsonDecode(rows.first['payload'] as String); } catch (_) { return null; }
  }

  static String newActionId(String type) => 'ACT-${type.toUpperCase()}-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(999999)}';

  static Future<String> queueAction(String type, Map<String, dynamic> payload, {String? actionId}) async {
    final d = await db();
    final id = actionId ?? newActionId(type);
    await d.insert('offline_actions', {
      'action_id': id,
      'action_type': type,
      'payload': jsonEncode(payload),
      'state': 'pending',
      'last_error': null,
      'retry_count': 0,
      'last_attempt_at': null,
      'updated_at': _now(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  }

  static Future<List<Map<String, dynamic>>> pendingActions({int limit = 50}) async {
    final d = await db();
    final rows = await d.query('offline_actions', where: "state='pending'", orderBy: 'updated_at ASC', limit: limit);
    return rows.map((r) => <String, dynamic>{
      'action_id': r['action_id'],
      'type': r['action_type'],
      'payload': Map<String, dynamic>.from(jsonDecode(r['payload'] as String) as Map),
    }).toList();
  }

  static Future<void> markActionsSynced(Iterable<String> ids) async {
    final d = await db();
    final batch = d.batch();
    for (final id in ids) {
      batch.update('offline_actions', {'state':'synced','last_error':null,'updated_at':_now()}, where:'action_id=?', whereArgs:[id]);
    }
    await batch.commit(noResult:true);
  }

  static Future<void> markActionError(String id, String error) async {
    final d = await db();
    await d.rawUpdate("UPDATE offline_actions SET state='error', last_error=?, retry_count=COALESCE(retry_count,0)+1, last_attempt_at=?, updated_at=? WHERE action_id=?", [error, _now(), _now(), id]);
  }

  static Future<void> removeCachedOrder(int tableId) async {
    final d = await db();
    await d.delete('order_cache', where:'table_id=?', whereArgs:[tableId]);
  }


}
