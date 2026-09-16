import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'offline/offline_store.dart';
import 'offline/offline_promotion.dart';
import 'offline/vietqr.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    final options=_firebaseOptionsFromEnv();
    if(options!=null) await Firebase.initializeApp(options: options);
    else await Firebase.initializeApp();
  } catch (_) {}
}

int maxInt(int a, int b) => a > b ? a : b;
Map<String,dynamic> ficMapOrEmpty(dynamic value) => value is Map ? value.map((k,v)=>MapEntry('$k',v)) : <String,dynamic>{};

// Version hiển thị tập trung tại một hằng số UI. Giữ đồng bộ với pubspec.yaml khi phát hành.
const String ficPosMobileVersion = '1.13.33+92 TEST';

// TEST ONLY: bypass TLS certificate errors only for *.test.ficpos.com.
// Production ficpos.com remains subject to normal certificate validation.
class FicTestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (X509Certificate cert, String host, int port) {
      final h = host.toLowerCase();
      return h == 'test.ficpos.com' || h.endsWith('.test.ficpos.com');
    };
    return client;
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = FicTestHttpOverrides();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  runApp(const FicPosApp());
}

class Api {
  static const String rateLimitMessage = 'Thao tác quá nhanh. Vui lòng thử lại sau ít giây.';
  String baseUrl = '';
  String? token;
  DateTime? _backgroundBlockedUntil;
  int _background429Streak = 0;

  Map<String, String> get headers => {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Map<String, String> get imageHeaders => {
        'Accept': 'image/*',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  int _retryAfterSeconds(http.Response response) {
    final header = int.tryParse(response.headers['retry-after'] ?? '');
    if (header != null && header > 0) return header.clamp(1, 60).toInt();
    final step = 2 << (_background429Streak.clamp(0, 4).toInt());
    return step.clamp(2, 30).toInt();
  }

  Map<String, dynamic> parse(http.Response response) {
    Map<String, dynamic> data = {};
    try {
      data = jsonDecode(response.body.isEmpty ? '{}' : response.body)
          as Map<String, dynamic>;
    } catch (_) {
      if (response.statusCode == 429) throw Exception(rateLimitMessage);
      throw Exception('Server trả dữ liệu không hợp lệ (${response.statusCode})');
    }
    if (response.statusCode == 429) {
      throw Exception(rateLimitMessage);
    }
    if (response.statusCode >= 400) {
      throw Exception(data['message'] ?? 'Lỗi ${response.statusCode}');
    }
    return data;
  }

  Future<Map<String, dynamic>> get(String path, {Duration timeout = const Duration(seconds: 6)}) async =>
      parse(await http.get(Uri.parse('$baseUrl/api/mobile/v1$path'), headers: headers).timeout(timeout));

  // Polling nền dùng chung một cửa backoff. Khi một endpoint chạm 429, các
  // polling nền khác tạm nhường quota và tự thử lại ở nhịp kế tiếp. Không toast.
  Future<Map<String, dynamic>> getBackground(String path) async {
    final now = DateTime.now();
    final blocked = _backgroundBlockedUntil;
    if (blocked != null && now.isBefore(blocked)) {
      throw Exception('__FIC_BACKGROUND_BACKOFF__');
    }

    final response = await http.get(Uri.parse('$baseUrl/api/mobile/v1$path'), headers: headers).timeout(const Duration(seconds: 4));
    if (response.statusCode == 429) {
      _background429Streak = (_background429Streak + 1).clamp(1, 6).toInt();
      final wait = _retryAfterSeconds(response);
      _backgroundBlockedUntil = DateTime.now().add(Duration(seconds: wait));
      throw Exception('__FIC_BACKGROUND_BACKOFF__');
    }

    _background429Streak = 0;
    _backgroundBlockedUntil = null;
    return parse(response);
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body, {Duration? timeout}) async {
    final future = http.post(Uri.parse('$baseUrl/api/mobile/v1$path'),
        headers: headers, body: jsonEncode(body));
    final response = await future.timeout(timeout ?? const Duration(seconds: 6));
    return parse(response);
  }

  Future<Map<String, dynamic>> put(String path, Map<String, dynamic> body) async =>
      parse(await http.put(Uri.parse('$baseUrl/api/mobile/v1$path'),
          headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 6)));

  Future<Map<String, dynamic>> delete(String path) async =>
      parse(await http.delete(Uri.parse('$baseUrl/api/mobile/v1$path'), headers: headers).timeout(const Duration(seconds: 6)));

  Future<Map<String, dynamic>> uploadImage(String path, String filePath) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/mobile/v1$path'));
    req.headers['Accept'] = 'application/json';
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('avatar', filePath));
    final streamed = await req.send();
    final response = await http.Response.fromStream(streamed);
    return parse(response);
  }
}

final api = Api();


// V1.13.32: gate dùng chung cho mọi thao tác bán hàng / phát sinh tiền.
// Chỉ gate lúc THAO TÁC làm thay đổi tiền; các màn hình xem lịch sử vẫn mở bình thường.
Future<bool> ficEnsureMoneyShift(BuildContext context, {String purpose = 'thực hiện giao dịch'}) async {
  final prefs = await SharedPreferences.getInstance();
  final branchId = prefs.getInt('offline_branch_id') ?? 0;
  if (ficOfflineMode) {
    final cached = branchId > 0 ? await OfflineStore.getShift(api.baseUrl, branchId) : null;
    if (cached != null && cached['required'] == true && cached['open'] != true) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ca gần nhất đang đóng. Hãy kết nối Internet để mở ca trước khi thực hiện giao dịch tiền.')));
      return false;
    }
    return true;
  }
  try {
    final shift = await api.get('/shift');
    if (branchId > 0) await OfflineStore.cacheShift(api.baseUrl, branchId, shift);
    if (shift['required'] != true || shift['open'] == true) return true;
    if (!context.mounted) return false;
    final go = await showDialog<bool>(context:context,barrierDismissible:false,builder:(dc)=>AlertDialog(
      icon:const Icon(Icons.lock_clock_outlined,size:46),title:const Text('Chưa mở ca'),
      content:Text('Cần mở ca trước khi $purpose.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(dc,false),child:const Text('ĐỂ SAU')),FilledButton.icon(onPressed:()=>Navigator.pop(dc,true),icon:const Icon(Icons.play_circle_outline),label:const Text('MỞ CA'))],
    ));
    if(go!=true || !context.mounted)return false;
    await Navigator.push(context,MaterialPageRoute(builder:(_)=>const ShiftPage(returnAfterOpen:true)));
    final refreshed=await api.get('/shift');
    if(branchId>0)await OfflineStore.cacheShift(api.baseUrl,branchId,refreshed);
    return refreshed['required']!=true || refreshed['open']==true;
  } catch(e) {
    if(context.mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));
    return false;
  }
}

// Trạng thái mạng dùng chung cho toàn app. Khi true, các luồng bán hàng
// phải ưu tiên SQLite và không chờ request mạng thất bại mới fallback.
bool ficOfflineMode = false;

Future<int> ficOfflineBranchId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getInt('offline_branch_id') ?? 0;
}

Future<dynamic> ficLoadCachedModule(String key, String endpoint) async {
  final branchId = await ficOfflineBranchId();
  if (ficOfflineMode) {
    if (branchId <= 0) throw Exception('Chưa có dữ liệu offline cho chi nhánh này. Hãy kết nối Internet một lần.');
    final cached = await OfflineStore.getModule(api.baseUrl, branchId, key);
    if (cached == null) throw Exception('Chưa có dữ liệu offline của mục này. Hãy mở mục này khi có mạng một lần để tải dữ liệu.');
    return cached;
  }
  try {
    final r = await api.get(endpoint);
    final payload = r['data'] ?? r;
    if (branchId > 0) await OfflineStore.cacheModule(api.baseUrl, branchId, key, payload);
    return payload;
  } catch (e) {
    if (_isNetworkError(e) && branchId > 0) {
      ficOfflineMode = true;
      final cached = await OfflineStore.getModule(api.baseUrl, branchId, key);
      if (cached != null) return cached;
    }
    rethrow;
  }
}

Future<String> ficQueueBusinessAction(String type, Map<String, dynamic> payload) async {
  ficOfflineMode = true;
  return OfflineStore.queueAction(type, payload);
}

Future<void> ficCacheModule(String key, dynamic payload) async {
  final branchId = await ficOfflineBranchId();
  if (branchId > 0) await OfflineStore.cacheModule(api.baseUrl, branchId, key, payload);
}

Future<Map<String,dynamic>> ficValidateRecipeScope(Map<String,dynamic> payload) async {
  final scopeRaw=payload['scope'];
  if(scopeRaw is! Map) throw Exception('Cache công thức cũ không có thông tin chi nhánh. Hãy kết nối mạng để tải lại.');
  final scope=Map<String,dynamic>.from(scopeRaw);
  final serverStore=int.tryParse('${scope['store_id']??0}')??0;
  final serverBranch=int.tryParse('${scope['branch_id']??0}')??0;
  if(serverStore<=0||serverBranch<=0) throw Exception('Server chưa xác định đúng cửa hàng/chi nhánh cho dữ liệu công thức.');
  final prefs=await SharedPreferences.getInstance();
  final localBranch=prefs.getInt('offline_branch_id')??0;
  if(ficOfflineMode){
    if(localBranch<=0||localBranch!=serverBranch) throw Exception('Dữ liệu công thức offline không thuộc chi nhánh hiện tại. Hãy kết nối mạng để tải lại.');
  }else if(localBranch!=serverBranch){
    // API là nguồn sự thật sau khi switch branch; cập nhật scope cache trước khi lưu dữ liệu.
    await prefs.setInt('offline_branch_id',serverBranch);
  }
  payload['_fic_recipe_scope']={'store_id':serverStore,'branch_id':serverBranch,'base_url':api.baseUrl};
  return payload;
}

Future<Map<String,dynamic>> ficCacheRecipeImages(Map<String,dynamic> payload) async {
  final branchId=await ficOfflineBranchId();
  final previous=branchId>0?await OfflineStore.getModule(api.baseUrl,branchId,'recipes'):null;
  final oldById=<String,Map<String,dynamic>>{};
  if(previous is Map){for(final x in List.from(previous['glasses'] as List? ?? const [])){if(x is Map)oldById['${x['id']}']=Map<String,dynamic>.from(x);}}
  final glasses = List.from(payload['glasses'] as List? ?? const []);
  for (var i=0;i<glasses.length;i++) {
    final raw=glasses[i]; if(raw is! Map) continue;
    final g=Map<String,dynamic>.from(raw),old=oldById['${raw['id']}'];
    final url='${g['image_url']??''}'.trim();
    if(old!=null && '${old['image_url']??''}'==url && '${old['image_b64']??''}'.isNotEmpty) g['image_b64']=old['image_b64'];
    if('${g['image_b64']??''}'.isEmpty && url.isNotEmpty && !ficOfflineMode) {
      try {
        final r=await http.get(Uri.parse(url)).timeout(const Duration(seconds:6));
        if(r.statusCode>=200 && r.statusCode<300 && r.bodyBytes.isNotEmpty) g['image_b64']=base64Encode(r.bodyBytes);
      } catch(_) {}
    }
    glasses[i]=g;
  }
  payload['glasses']=glasses;
  return payload;
}

bool _isNetworkError(Object e) {
  final m=e.toString().toLowerCase();
  return m.contains('socketexception') || m.contains('clientexception') ||
      m.contains('failed host lookup') || m.contains('connection refused') ||
      m.contains('connection reset') || m.contains('network is unreachable') ||
      m.contains('timed out') || m.contains('timeoutexception') ||
      m.contains('future not completed') || m.contains('connection closed');
}

String _offlineOrderCode(int tableId) => 'OFF-$tableId-${DateTime.now().millisecondsSinceEpoch}';

bool _setEqualsInt(Set<int> a, Set<int> b) => a.length == b.length && a.containsAll(b);

const _backgroundNotifications = MethodChannel('fic_pos/background_notifications');
final _localNotifications = FlutterLocalNotificationsPlugin();
Future<bool>? _firebaseInitFuture;
String? _pushToken;
bool _firebasePushReady=false;
Map<String, dynamic>? _pendingPushData;
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

FirebaseOptions? _firebaseOptionsFromEnv() {
  const apiKey=String.fromEnvironment('FIC_FIREBASE_API_KEY');
  const appId=String.fromEnvironment('FIC_FIREBASE_APP_ID');
  const sender=String.fromEnvironment('FIC_FIREBASE_MESSAGING_SENDER_ID');
  const project=String.fromEnvironment('FIC_FIREBASE_PROJECT_ID');
  if(apiKey.isEmpty || appId.isEmpty || sender.isEmpty || project.isEmpty) return null;
  return const FirebaseOptions(apiKey: apiKey, appId: appId, messagingSenderId: sender, projectId: project);
}

Future<int> _activeBranchIdForNotification() async {
  try {
    final prefs=await SharedPreferences.getInstance();
    return prefs.getInt('offline_branch_id') ?? 0;
  } catch (_) { return 0; }
}

Future<bool> _notificationBelongsToActiveBranch(Map<String,dynamic> data) async {
  final incoming=int.tryParse('${data['branch_id'] ?? data['fic_id_chinhanh'] ?? 0}') ?? 0;
  final active=await _activeBranchIdForNotification();
  // V1.13.23: fail closed. Push thiếu branch hoặc khác branch không được popup/rung/mở màn hình.
  // Thông báo vẫn còn unread trên server và sẽ xuất hiện khi quay về đúng chi nhánh.
  if(incoming<=0 || active<=0) return false;
  return incoming==active;
}

Future<bool> _ensureFirebasePush() {
  return _firebaseInitFuture ??= () async {
    try {
      if(Firebase.apps.isEmpty) {
        final options=_firebaseOptionsFromEnv();
        if(options != null) await Firebase.initializeApp(options: options);
        else await Firebase.initializeApp();
      }

      final messaging=FirebaseMessaging.instance;
      final permission=await messaging.requestPermission(
        alert:true,
        badge:true,
        sound:true,
        provisional:false,
      );
      debugPrint('[FIC PUSH] permission=${permission.authorizationStatus}');

      if(Platform.isIOS) {
        await messaging.setForegroundNotificationPresentationOptions(
          alert:false,
          badge:false,
          sound:false,
        );

        // Trên iOS/TestFlight, APNs token có thể xuất hiện chậm ngay sau khi app mở.
        // Chờ APNs token trước khi yêu cầu Firebase cấp FCM token.
        String? apnsToken;
        for(var attempt=0; attempt<20; attempt++) {
          try {
            apnsToken=await messaging.getAPNSToken();
          } catch(e) {
            debugPrint('[FIC PUSH] getAPNSToken attempt=$attempt error=$e');
          }
          if(apnsToken!=null && apnsToken.isNotEmpty) break;
          await Future.delayed(const Duration(milliseconds:500));
        }

        if(apnsToken==null || apnsToken.isEmpty) {
          debugPrint('[FIC PUSH] APNs token chưa sẵn sàng; sẽ thử lại.');
          _firebasePushReady=false;
          _firebaseInitFuture=null;
          return false;
        }
        debugPrint('[FIC PUSH] APNs token ready');
      }

      try {
        _pushToken=await messaging.getToken();
      } catch(e) {
        debugPrint('[FIC PUSH] getToken error=$e');
        _pushToken=null;
      }

      _firebasePushReady=_pushToken!=null && _pushToken!.isNotEmpty;
      if(!_firebasePushReady) {
        debugPrint('[FIC PUSH] FCM token chưa sẵn sàng; sẽ thử lại.');
        _firebaseInitFuture=null;
        return false;
      }
      debugPrint('[FIC PUSH] FCM token ready');

      FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
        _pushToken=token;
        _firebasePushReady=token.isNotEmpty;
        debugPrint('[FIC PUSH] token refreshed');
        await _registerPushToken();
      });
      FirebaseMessaging.onMessage.listen((message) async {
        final pushData=Map<String,dynamic>.from(message.data);
        if(!await _notificationBelongsToActiveBranch(pushData)) return;
        final n=message.notification;
        final title=n?.title ?? message.data['title'] ?? 'FIC POS';
        final body=n?.body ?? message.data['body'] ?? 'Bạn có thông báo mới';
        await _showLocalAlert(id: DateTime.now().millisecondsSinceEpoch.remainder(2147483647), title:'$title', body:'$body', sound:true);
        HapticFeedback.heavyImpact();
      });
      FirebaseMessaging.onMessageOpenedApp.listen((message) async {
        final pushData=Map<String,dynamic>.from(message.data);
        if(!await _notificationBelongsToActiveBranch(pushData)) return;
        _pendingPushData=pushData;
        _openPendingPushFromNavigator();
      });
      final initial=await messaging.getInitialMessage();
      if(initial!=null) {
        final pushData=Map<String,dynamic>.from(initial.data);
        if(await _notificationBelongsToActiveBranch(pushData)) _pendingPushData=pushData;
      }
      return true;
    } catch(e, st) {
      debugPrint('[FIC PUSH] init error=$e');
      debugPrint('$st');
      _firebasePushReady=false;
      // Cho phép lần login/resume sau thử khởi tạo lại.
      _firebaseInitFuture=null;
      return false;
    }
  }();
}

Future<void> _registerPushToken() async {
  if(api.token==null || api.baseUrl.isEmpty) return;
  if(!await _ensureFirebasePush()) return;
  final token=_pushToken ?? await FirebaseMessaging.instance.getToken();
  if(token==null || token.isEmpty) return;
  _pushToken=token;
  try {
    await api.post('/push-token', {
      'token':token,
      'platform':Platform.isIOS?'ios':'android',
      'device_id':'FIC POS Mobile',
    });
    debugPrint('[FIC PUSH] token registered to server (${Platform.isIOS ? 'ios' : 'android'})');
  } catch(e) {
    debugPrint('[FIC PUSH] register token error=$e');
  }
}

Future<void> _unregisterPushToken() async {
  final token=_pushToken;
  if(token==null || api.token==null) return;
  try { await api.post('/push-token/delete', {'token':token}); } catch (_) {}
}

Future<void> _openPendingPushFromNavigator() async {
  final data=_pendingPushData;
  final nav=_navigatorKey.currentState;
  if(data==null || nav==null || api.token==null) return;
  if(!await _notificationBelongsToActiveBranch(data)) { _pendingPushData=null; return; }
  _pendingPushData=null;
  final type='${data['type'] ?? ''}';
  if(type=='payment_request') nav.push(MaterialPageRoute(builder:(_)=>const PaymentRequestsPage()));
  else if(type=='ingredient_report') nav.push(MaterialPageRoute(builder:(_)=>const IngredientsPage()));
  else nav.push(MaterialPageRoute(builder:(_)=>const NotificationCenterPage()));
}

const Set<String> _countUnits = {
  'cái','gói','hộp','chai','lon','ly','tô','phần','suất','bộ','chiếc','thùng','bao'
};

String _unitOf(Map m) {
  final u='${m['donvitinh'] ?? ''}'.trim();
  return u.isEmpty ? 'cái' : u;
}

bool _isCountUnit(String unit) => _countUnits.contains(unit.trim().toLowerCase());

String _stockQtyText(dynamic value, String unit) {
  final n=num.tryParse('${value ?? 0}')?.toDouble() ?? 0;
  return _isCountUnit(unit) ? n.round().toString() : n.toStringAsFixed(2);
}

double _parseStockQty(String raw, String unit) {
  final normalized=raw.trim().replaceAll(',', '.');
  final n=double.tryParse(normalized) ?? 0;
  return _isCountUnit(unit) ? n.roundToDouble() : double.parse(n.toStringAsFixed(2));
}

class _StockQtyFormatter extends TextInputFormatter {
  final bool integerOnly;
  const _StockQtyFormatter(this.integerOnly);
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final t=newValue.text.replaceAll(',', '.');
    final re=integerOnly ? RegExp(r'^\d*$') : RegExp(r'^\d*(?:\.\d{0,2})?$');
    if(!re.hasMatch(t)) return oldValue;
    return newValue.copyWith(text:t, selection:TextSelection.collapsed(offset:t.length));
  }
}

Future<void> _startBackgroundNotifications() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final sound = prefs.getBool('qr_sound_enabled') ?? true;
    await _backgroundNotifications.invokeMethod('start', {'sound': sound});
  } catch (_) {}
}

Future<void> _stopBackgroundNotifications() async {
  try { await _backgroundNotifications.invokeMethod('stop'); } catch (_) {}
}

Future<void> _setBackgroundSound(bool enabled) async {
  try { await _backgroundNotifications.invokeMethod('setSound', {'sound': enabled}); } catch (_) {}
}

Future<void> _initLocalNotifications() async {
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  const ios = DarwinInitializationSettings(requestAlertPermission: true, requestBadgePermission: true, requestSoundPermission: true);
  await _localNotifications.initialize(const InitializationSettings(android: android, iOS: ios));
  if (Platform.isAndroid) {
    const channel=AndroidNotificationChannel('fic_pos_push_v253','FIC POS Push',description:'Thông báo FIC POS khi app đang nền hoặc đã đóng',importance:Importance.max,playSound:true,enableVibration:true);
    await _localNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
  }
  if (Platform.isIOS) {
    await _localNotifications.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(alert: true, badge: true, sound: true);
  }
}

Future<void> _showLocalAlert({required int id, required String title, required String body, bool sound = true}) async {
  final details = NotificationDetails(
    android: AndroidNotificationDetails(
      sound ? 'fic_pos_alert_sound_v1103' : 'fic_pos_alert_silent_v1103',
      sound ? 'FIC POS thông báo quan trọng' : 'FIC POS thông báo im lặng',
      importance: Importance.max,
      priority: Priority.high,
      playSound: sound,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 220, 120, 220]),
    ),
    iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: sound),
  );
  await _localNotifications.show(id, title, body, details);
}

class FicPosApp extends StatefulWidget {
  const FicPosApp({super.key});
  @override
  State<FicPosApp> createState() => _AppState();
}

class _AppState extends State<FicPosApp> {
  bool ready = false;
  bool logged = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initLocalNotifications();
    _ensureFirebasePush();
    load();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    api.baseUrl = prefs.getString('base') ?? '';
    final rememberLogin = prefs.getBool('remember_login') ?? true;
    api.token = rememberLogin ? prefs.getString('token') : null;
    if (api.baseUrl.isNotEmpty && api.token != null) {
      try {
        final me = await api.get('/me');
        await OfflineStore.cacheMe(api.baseUrl, me);
        logged = true;
        await _startBackgroundNotifications();
        await _registerPushToken();
      } catch (e) {
        if (_isNetworkError(e)) {
          final cachedMe = await OfflineStore.getMe(api.baseUrl);
          if (cachedMe != null) logged = true;
        }
      }
    }
    if (mounted) setState(() => ready = true);
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        navigatorKey: _navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'FIC POS',
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xff0875d1),
          scaffoldBackgroundColor: const Color(0xfff5f6f8),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(),
          ),
        ),
        home: !ready
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : logged
                ? HomePage(onLogout: () => setState(() => logged = false))
                : LoginPage(onLogin: () => setState(() => logged = true)),
      );
}

class LoginPage extends StatefulWidget {
  final VoidCallback onLogin;
  const LoginPage({super.key, required this.onLogin});
  @override
  State<LoginPage> createState() => _LoginState();
}

class _LoginState extends State<LoginPage> {
  final store = TextEditingController();
  final account = TextEditingController();
  final pass = TextEditingController();
  bool busy = false;
  bool hide = true;
  bool rememberLogin = true;
  String? error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        rememberLogin = p.getBool('remember_login') ?? true;
        store.text = p.getString('store_slug') ?? '';
        if (rememberLogin) account.text = p.getString('login_account') ?? '';
      });
    });
  }

  @override
  void dispose() {
    store.dispose();
    account.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var slug = store.text
          .trim()
          .toLowerCase()
          .replaceAll(RegExp(r'^https?://'), '')
          .replaceAll(RegExp(r'\.test\.ficpos\.com/?$'), '')
          .replaceAll(RegExp(r'\.ficpos\.com/?$'), '')
          .replaceAll('/', '');
      if (slug.isEmpty) throw Exception('Vui lòng nhập mã cửa hàng');
      api.baseUrl = 'https://$slug.test.ficpos.com';
      try {
        Map<String, dynamic>? response;
        Object? lastOnlineError;
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            response = await api.post('/login', {
              'account': account.text.trim(),
              'password': pass.text,
              'device_name': 'FIC POS Mobile',
            }, timeout: const Duration(seconds: 8));
            break;
          } catch (e) {
            if (!_isNetworkError(e)) rethrow;
            lastOnlineError = e;
            if (attempt == 0) await Future.delayed(const Duration(milliseconds: 800));
          }
        }
        if (response == null) throw lastOnlineError ?? Exception('Không thể kết nối máy chủ.');
        api.token = response['token'];
        ficOfflineMode = false;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('base', api.baseUrl);
        await prefs.setString('store_slug', slug);
        await prefs.setBool('remember_login', rememberLogin);
        if (rememberLogin) {
          await prefs.setString('login_account', account.text.trim());
          await prefs.setString('token', api.token!);
        } else {
          await prefs.remove('login_account');
          await prefs.remove('token');
        }
        await OfflineStore.saveOfflineLogin(
          base: api.baseUrl,
          slug: slug,
          account: account.text.trim(),
          password: pass.text,
          token: api.token!,
          loginResponse: response,
        );
        await _startBackgroundNotifications();
        await _registerPushToken();
        widget.onLogin();
      } catch (onlineError) {
        if (!_isNetworkError(onlineError)) rethrow;
        final cached = await OfflineStore.verifyOfflineLogin(
          base: api.baseUrl,
          account: account.text.trim(),
          password: pass.text,
        );
        if (cached == null) {
          throw Exception('Không có Internet và tài khoản này chưa từng đăng nhập thành công trên thiết bị.');
        }
        api.token = '${cached['token'] ?? ''}';
        ficOfflineMode = true;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('base', api.baseUrl);
        await prefs.setString('store_slug', slug);
        await prefs.setString('login_account', account.text.trim());
        await prefs.setString('token', api.token!);
        await prefs.setBool('remember_login', true);
        widget.onLogin();
      }
    } catch (e) {
      if (mounted) {
        var message = e.toString().replaceFirst('Exception: ', '');
        if (message.toLowerCase().contains('too many attempts')) {
          message = Api.rateLimitMessage;
        }
        setState(() => error = message);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  children: [
                    Image.asset('assets/images/fic_logo.png', height: 115),
                    const SizedBox(height: 14),
                    Text('Đăng nhập FIC POS',
                        style: Theme.of(context)
                            .textTheme
                            .headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 28),
                    TextField(
                      controller: store,
                      decoration: const InputDecoration(
                        labelText: 'Mã cửa hàng',
                        hintText: 'Mã cửa hàng',
                        prefixIcon: Icon(Icons.store_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: account,
                      decoration: const InputDecoration(
                        labelText: 'Tài khoản',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: pass,
                      obscureText: hide,
                      onSubmitted: (_) => login(),
                      decoration: InputDecoration(
                        labelText: 'Mật khẩu',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => hide = !hide),
                          icon: Icon(hide
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: InkWell(
                        onTap: () => setState(() => rememberLogin = !rememberLogin),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Checkbox(
                                value: rememberLogin,
                                onChanged: (v) => setState(() => rememberLogin = v ?? false),
                              ),
                              const Text('Ghi nhớ đăng nhập'),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(error!,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error)),
                      ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton(
                        onPressed: busy ? null : login,
                        child: busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('ĐĂNG NHẬP'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

class HomePage extends StatefulWidget {
  final VoidCallback onLogout;
  const HomePage({super.key, required this.onLogout});
  @override
  State<HomePage> createState() => _HomeState();
}

class _HomeState extends State<HomePage> with WidgetsBindingObserver {
  Map<String, dynamic>? me;
  Map<String, dynamic>? data;
  String? error;
  String filter = 'all';
  Timer? _qrTimer;
  Timer? _tableSyncTimer;
  Timer? _eventTimer;
  Timer? _notificationTimer;
  Timer? _offlineSyncTimer;
  Timer? _reconnectTimer;
  int _offlinePendingCount = 0;
  Set<int> _offlineBusyTables = <int>{};
  Set<int> _offlineFreedTables = <int>{};
  Map<int, Map<String, double>> _offlineTableOrderTotals = <int, Map<String, double>>{};
  Set<int> _offlinePromotionTables = <int>{};
  bool _offlineSyncing = false;
  bool _manualOfflineSyncing = false;
  int _offlinePendingOrders = 0;
  int _offlinePendingActions = 0;
  int _offlineSyncErrors = 0;
  bool _offlineMode = false;
  int _notificationUnreadCount = 0;
  int _paymentRequestPendingCount = 0;
  int _qrPendingCount = 0;
  int _lastQrLatestId = 0;
  bool _qrSoundEnabled = true;
  bool _qrPolling = false;
  int _lastEventId = 0;
  bool _eventCursorInitialized = false;
  bool _eventPolling = false;
  String? _menuVersion;
  String? _tableVersion;
  String? _homeOrderVersion;
  String? _promotionVersion;
  bool _dataSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    _initQrNotifications();
    _initEventNotifications();
    _initNotificationCenter();
    _initOfflineSync();
  }

  Future<void> _initQrNotifications() async {
    final prefs = await SharedPreferences.getInstance();
    _qrSoundEnabled = prefs.getBool('qr_sound_enabled') ?? true;
    if (mounted) setState(() {});
    await _pollQrPending(initial: true);
    _qrTimer?.cancel();
    _qrTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollQrPending());
    _tableSyncTimer?.cancel();
    _tableSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) => _syncTables());
  }


  Future<void> _initEventNotifications() async {
    await _pollEvents(initial: true);
    _eventTimer?.cancel();
    _eventTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollEvents());
  }

  Future<void> _initNotificationCenter() async {
    await _pollNotificationCenter();
    _notificationTimer?.cancel();
    _offlineSyncTimer?.cancel();
    _notificationTimer = Timer.periodic(const Duration(seconds: 5), (_) => _pollNotificationCenter());
  }

  Future<void> _initOfflineSync() async {
    await _refreshOfflinePendingCount();
    _offlineSyncTimer?.cancel();
    _offlineSyncTimer = Timer.periodic(const Duration(seconds: 10), (_) => _syncOfflineQueue());
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 3), (_) => _probeReconnectAndSync());
    await _syncOfflineQueue();
  }

  Future<void> _probeReconnectAndSync() async {
    if (_offlineSyncing || api.token == null || api.baseUrl.isEmpty) return;
    // Chỉ probe nhanh khi app đang biết mình offline. Khi online, timer 10 giây vẫn là fallback.
    if (!ficOfflineMode && !_offlineMode) return;
    try {
      await api.getBackground('/sync-version');
      ficOfflineMode = false;
      if (mounted) setState(() => _offlineMode = false);
      // Internet vừa quay lại: đồng bộ ngay, không chờ chu kỳ 10 giây.
      await _syncOfflineQueue();
      if (mounted) await load();
    } catch (_) {
      // Vẫn offline: giữ queue local, không tạo lỗi nghiệp vụ và không làm phiền người dùng.
    }
  }

  Future<void> _refreshOfflinePendingCount() async {
    final summary = await OfflineStore.pendingSummary();
    final orders = summary['orders'] ?? 0;
    final actions = summary['actions'] ?? 0;
    final errors = summary['errors'] ?? 0;
    final count = orders + actions + errors;
    final busyTables = (await OfflineStore.pendingTableIds()).toSet();
    final freedTables = await OfflineStore.locallyFreedTableIds();
    final offlineTotals = await OfflineStore.pendingOpenOrderTotalsByTable();
    final promoTables = await OfflineStore.pendingPromotionTableIds();
    if (mounted) {
      setState(() {
        _offlinePendingCount = count;
        _offlinePendingOrders = orders;
        _offlinePendingActions = actions;
        _offlineSyncErrors = errors;
        _offlineBusyTables = busyTables;
        _offlineFreedTables = freedTables;
        _offlineTableOrderTotals = offlineTotals;
        _offlinePromotionTables = promoTables;
      });
    }
  }

  String _offlinePendingLabel() {
    final parts = <String>[];
    if (_offlinePendingOrders > 0) parts.add('$_offlinePendingOrders đơn');
    if (_offlinePendingActions > 0) parts.add('$_offlinePendingActions thao tác');
    if (_offlineSyncErrors > 0) parts.add('$_offlineSyncErrors lỗi');
    if (parts.isEmpty) return '';
    return '${parts.join(' • ')} chờ đồng bộ';
  }

  String _syncIssueTime(dynamic ms) {
    final n = ms is num ? ms.toInt() : int.tryParse('$ms');
    if (n == null || n <= 0) return 'Chưa rõ';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)} ${two(d.day)}/${two(d.month)}/${d.year}';
  }

  Future<void> _showOfflineSyncIssues() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        var loading = true;
        var issues = <Map<String, dynamic>>[];
        return StatefulBuilder(builder: (context, setSheetState) {
          Future<void> reload() async {
            final rows = await OfflineStore.syncIssues();
            if (!sheetContext.mounted) return;
            setSheetState(() { issues = rows; loading = false; });
          }
          if (loading) {
            Future.microtask(reload);
          }
          Future<void> reconcile() async {
            setSheetState(() => loading = true);
            final fixed = await _reconcileOfflineQueue();
            await _refreshOfflinePendingCount();
            await reload();
            if (sheetContext.mounted) {
              ScaffoldMessenger.of(sheetContext).showSnackBar(SnackBar(content: Text(fixed > 0 ? 'Đã đối soát và xử lý $fixed mục.' : 'Server chưa ghi nhận mục lỗi này.')));
            }
          }
          Future<void> retry(Map<String, dynamic> issue) async {
            setSheetState(() => loading = true);
            await OfflineStore.retryOne('${issue['kind']}', '${issue['id']}');
            await _syncOfflineQueue();
            await _reconcileOfflineQueue();
            await _refreshOfflinePendingCount();
            await reload();
            if (sheetContext.mounted && issues.isEmpty) Navigator.of(sheetContext).pop();
          }
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.of(context).size.height * .78,
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                  child: Row(children: [
                    const Expanded(child: Text('Chi tiết lỗi đồng bộ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    TextButton.icon(onPressed: loading ? null : reconcile, icon: const Icon(Icons.fact_check_outlined), label: const Text('Đối soát server')),
                  ]),
                ),
                const Divider(height: 1),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : issues.isEmpty
                          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Không còn lỗi đồng bộ.', textAlign: TextAlign.center)))
                          : ListView.builder(
                              padding: const EdgeInsets.all(12),
                              itemCount: issues.length,
                              itemBuilder: (_, i) {
                                final x = issues[i];
                                final error = '${x['error'] ?? 'Không rõ lỗi'}';
                                final retries = int.tryParse('${x['retry_count'] ?? 0}') ?? 0;
                                return Card(
                                  child: Padding(
                                    padding: const EdgeInsets.all(14),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        const Icon(Icons.error_outline, color: Colors.redAccent),
                                        const SizedBox(width: 8),
                                        Expanded(child: Text('${x['title'] ?? 'Mục đồng bộ'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                                      ]),
                                      const SizedBox(height: 6),
                                      Text('${x['subtitle'] ?? ''}', style: const TextStyle(color: Colors.black54)),
                                      const SizedBox(height: 8),
                                      SelectableText('Mã: ${x['id']}', style: const TextStyle(fontSize: 12)),
                                      Text('Loại: ${x['type'] ?? ''}'),
                                      Text('Số lần lỗi: $retries • Lần cuối: ${_syncIssueTime(x['updated_at'])}'),
                                      const SizedBox(height: 8),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                                        child: SelectableText(error, style: TextStyle(color: Colors.red.shade900)),
                                      ),
                                      const SizedBox(height: 10),
                                      Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: loading ? null : () => retry(x), icon: const Icon(Icons.sync), label: const Text('Thử lại mục này'))),
                                    ]),
                                  ),
                                );
                              },
                            ),
                ),
              ]),
            ),
          );
        });
      },
    );
    await _refreshOfflinePendingCount();
  }

  Future<int> _reconcileOfflineQueue() async {
    if (api.token == null || api.baseUrl.isEmpty) return 0;
    final orderRefs = await OfflineStore.unsyncedOrderRefs();
    final clientIds = orderRefs.map((e) => '${e['client_id']}').where((e) => e.isNotEmpty).toList();
    final actionIds = await OfflineStore.unsyncedActionIds();
    if (clientIds.isEmpty && actionIds.isEmpty) return 0;
    try {
      final r = await api.post('/offline/status', {
        'client_ids': clientIds,
        'orders': orderRefs,
        'action_ids': actionIds,
      }, timeout: const Duration(seconds: 5));
      var fixed = 0;
      for (final raw in ((r['orders'] as List?) ?? const [])) {
        if (raw is! Map) continue;
        final clientId = '${raw['client_id'] ?? ''}';
        if (clientId.isEmpty) continue;
        await OfflineStore.markSynced([clientId]);
        await OfflineStore.markInvoiceSynced(
          clientId,
          paymentId: int.tryParse('${raw['payment_id'] ?? ''}'),
          paymentCode: '${raw['ma_thanhtoan'] ?? ''}'.trim().isEmpty ? null : '${raw['ma_thanhtoan']}',
        );
        fixed++;
      }
      final actionSynced = ((r['actions'] as List?) ?? const []).map((e) => '$e').where((e) => e.isNotEmpty).toList();
      if (actionSynced.isNotEmpty) {
        await OfflineStore.markActionsSynced(actionSynced);
        fixed += actionSynced.length;
      }
      return fixed;
    } catch (_) {
      return 0;
    }
  }

  Future<void> _manualSyncOfflineNow() async {
    if (_offlineSyncing || _manualOfflineSyncing) return;
    if (api.token == null || api.baseUrl.isEmpty) {
      _toast('Chưa có thông tin kết nối để đồng bộ.');
      return;
    }
    if (mounted) setState(() => _manualOfflineSyncing = true);
    try {
      // Đối soát trước: nếu server đã nhận nhưng app mất ACK/timeout thì xóa ngay queue local.
      final reconciledBefore = await _reconcileOfflineQueue();
      // Các lỗi nghiệp vụ không tự retry liên tục 10 giây/lần. Người dùng bấm nút này để thử lại chủ động.
      await OfflineStore.retryErrors();
      final before = await OfflineStore.pendingCount();
      await _syncOfflineQueue();
      final reconciledAfter = await _reconcileOfflineQueue();
      await _refreshOfflinePendingCount();
      final summary = await OfflineStore.pendingSummary();
      final after = (summary['orders'] ?? 0) + (summary['actions'] ?? 0) + (summary['errors'] ?? 0);
      if (!mounted) return;
      if (after == 0 && (before > 0 || reconciledBefore > 0 || reconciledAfter > 0)) {
        _toast('Đồng bộ hoàn tất.');
      } else if (_offlineMode || ficOfflineMode) {
        _toast('Chưa có Internet. Dữ liệu vẫn được giữ an toàn trên máy.');
      } else if ((summary['errors'] ?? 0) > 0) {
        _toast('Có ${summary['errors']} mục lỗi đồng bộ. Không tự thử lại liên tục; bấm Đồng bộ để thử lại.');
      } else if (after > 0) {
        _toast('Còn $after mục chờ đồng bộ.');
      } else {
        _toast('Không có dữ liệu cần đồng bộ.');
      }
    } finally {
      if (mounted) setState(() => _manualOfflineSyncing = false);
    }
  }

  Future<void> _syncOfflineQueue() async {
    if (_offlineSyncing || api.token == null || api.baseUrl.isEmpty) return;
    final pending = await OfflineStore.pendingOrders();
    final actions = await OfflineStore.pendingActions();
    if (pending.isEmpty && actions.isEmpty) {
      await _refreshOfflinePendingCount();
      if (ficOfflineMode) {
        try {
          await api.getBackground('/sync-version');
          ficOfflineMode = false;
          if (mounted) setState(() => _offlineMode = false);
          await load();
        } catch (_) {}
      }
      return;
    }
    _offlineSyncing = true;
    try {
      final synced = <String>[];
      if (pending.isNotEmpty) {
        final r = await api.post('/offline/sync', {'orders': pending});
        synced.addAll(((r['synced'] as List?) ?? const []).map((e) => '$e'));
        if (synced.isNotEmpty) await OfflineStore.markSynced(synced);
        for (final raw in ((r['errors'] as List?) ?? const [])) {
          if (raw is Map) await OfflineStore.markError('${raw['client_id'] ?? ''}', '${raw['message'] ?? 'Không đồng bộ được đơn offline.'}');
        }
        final syncResults = (r['results'] as List?) ?? const [];
        for (final raw in syncResults) {
          if (raw is! Map) continue;
          final clientId = '${raw['client_id'] ?? ''}';
          if (clientId.isEmpty) continue;
          await OfflineStore.markInvoiceSynced(
            clientId,
            paymentId: int.tryParse('${raw['payment_id'] ?? ''}'),
            paymentCode: '${raw['ma_thanhtoan'] ?? ''}'.trim().isEmpty ? null : '${raw['ma_thanhtoan']}',
          );
        }
      }
      if (actions.isNotEmpty) {
        final ar = await api.post('/offline/actions', {'actions': actions});
        final actionSynced = ((ar['synced'] as List?) ?? const []).map((e) => '$e').toList();
        if (actionSynced.isNotEmpty) await OfflineStore.markActionsSynced(actionSynced);
        for (final raw in ((ar['errors'] as List?) ?? const [])) {
          if (raw is Map) await OfflineStore.markActionError('${raw['action_id'] ?? ''}', '${raw['message'] ?? ''}');
        }
      }
      ficOfflineMode = false;
      if (mounted) setState(() => _offlineMode = false);
      await _refreshOfflinePendingCount();
      if (synced.isNotEmpty) {
        try {
          final fresh = await api.get('/bootstrap');
          if (mounted) {
            setState(() => data = fresh);
            _captureBootstrapVersions(fresh);
            await _saveBootstrapCache();
            // Drop local free-table overrides only for invoices already confirmed synced.
            await OfflineStore.clearConfirmedFreedTables();
            await _refreshOfflinePendingCount();
          }
        } catch (_) {}
      }
    } catch (e) {
      if (_isNetworkError(e)) {
        ficOfflineMode = true;
        if (mounted) setState(() => _offlineMode = true);
      } else {
        // Trước đây lỗi HTTP/validation bị nuốt và queue giữ state=pending mãi.
        // Đánh dấu error để dừng vòng lặp vô hạn và cho phép người dùng retry thủ công.
        final msg = e.toString().replaceFirst('Exception: ', '');
        for (final row in pending) {
          final id = '${row['client_id'] ?? ''}';
          if (id.isNotEmpty) await OfflineStore.markError(id, msg);
        }
        for (final row in actions) {
          final id = '${row['action_id'] ?? ''}';
          if (id.isNotEmpty) await OfflineStore.markActionError(id, msg);
        }
      }
      // Nếu server đã commit nhưng response bị lỗi sau đó, đối soát idempotency để clear queue.
      await _reconcileOfflineQueue();
      await _refreshOfflinePendingCount();
    } finally {
      _offlineSyncing = false;
    }
  }

  Future<void> _pollNotificationCenter() async {
    if (ficOfflineMode) return;
    if (api.token == null || api.baseUrl.isEmpty) return;
    try {
      final r = await api.getBackground('/notifications-center');
      final unread = int.tryParse('${r['unread_count'] ?? 0}') ?? 0;
      int pending = _paymentRequestPendingCount;
      final pr = me?['payment_request'];
      final enabled = pr is Map && pr['enabled'] == true;
      final canPay = pr is Map && pr['can_take_payment'] == true;
      if (enabled && canPay) {
        try {
          final rr = await api.getBackground('/payment-requests');
          final rawItems = (rr['items'] as List?) ?? const [];
          pending = await _countUnseenPaymentRequests(rawItems);
        } catch (_) {}
      } else { pending = 0; }
      if (mounted && (unread != _notificationUnreadCount || pending != _paymentRequestPendingCount)) {
        setState(() { _notificationUnreadCount = unread; _paymentRequestPendingCount = pending; });
      }
    } catch (_) {}
  }

  Future<String> _eventCursorKey() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedBranch = prefs.getInt('offline_branch_id') ?? 0;
    final branchId = me?['branch']?['id'] ?? me?['current_branch']?['id'] ?? me?['branch_id'] ?? (cachedBranch > 0 ? cachedBranch : 'default');
    final host = Uri.tryParse(api.baseUrl)?.host ?? api.baseUrl;
    return 'fic_event_cursor_${host}_$branchId';
  }

  Future<void> _saveEventCursor() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(await _eventCursorKey(), _lastEventId);
    } catch (_) {}
  }

  Future<void> _pollEvents({bool initial = false}) async {
    if (ficOfflineMode) return;
    if (_eventPolling || api.token == null || api.baseUrl.isEmpty) return;
    _eventPolling = true;
    try {
      // V1.13.4: the first successful poll after app start is always a baseline.
      // This prevents a startup race (initial poll before token is ready) from replaying old payment requests.
      if (!_eventCursorInitialized) {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getInt(await _eventCursorKey());
        if (saved != null && saved > 0) {
          _lastEventId = saved;
          _eventCursorInitialized = true;
        }
      }
      final r = await api.getBackground('/notification-events?after_id=$_lastEventId');
      final latest = int.tryParse('${r['latest_id'] ?? 0}') ?? 0;
      if (!_eventCursorInitialized) {
        // First run for this tenant/branch: establish a baseline and do not replay old history.
        _lastEventId = latest > _lastEventId ? latest : _lastEventId;
        _eventCursorInitialized = true;
        await _saveEventCursor();
        return;
      }
      final events = (r['events'] as List?) ?? const [];
      for (final raw in events) {
        if (raw is! Map) continue;
        final e = Map<String,dynamic>.from(raw);
        final id = int.tryParse('${e['id'] ?? 0}') ?? 0;
        if (id <= _lastEventId) continue;
        final type = '${e['type'] ?? ''}';
        if (type == 'qr_order_new' && !Platform.isIOS) continue;
        final title = '${e['title'] ?? 'FIC POS'}';
        final body = '${e['body'] ?? 'Có thông báo mới'}';
        final handledByPush = _firebasePushReady && type == 'payment_request';
        if (Platform.isIOS && !handledByPush) {
          await _showLocalAlert(id: id, title: title, body: body, sound: _qrSoundEnabled);
        }
        if (!handledByPush) HapticFeedback.heavyImpact();
        if (!handledByPush && type == 'payment_request' && _qrSoundEnabled) SystemSound.play(SystemSoundType.alert);
        if (type == 'payment_request' && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('$title\n$body'),
            duration: const Duration(seconds: 8),
            action: SnackBarAction(label: 'XEM', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentRequestsPage()))),
          ));
        }
        if (id > _lastEventId) _lastEventId = id;
      }
      if (latest > _lastEventId) _lastEventId = latest;
      await _saveEventCursor();
    } catch (_) {} finally { _eventPolling = false; }
  }

  String? _syncValue(dynamic value) { final s='${value ?? ''}'; return s.isEmpty ? null : s; }

  String _bootstrapCacheKey() {
    final branchId = me?['branch']?['id'] ?? me?['current_branch']?['id'] ?? me?['branch_id'] ?? 'default';
    return 'fic_pos_bootstrap_v1102_${api.baseUrl}_$branchId';
  }

  void _captureBootstrapVersions(Map<String, dynamic>? payload) {
    final versions = payload?['versions'];
    if (versions is Map) {
      _menuVersion = _syncValue(versions['menu_version']);
      _tableVersion = _syncValue(versions['table_version']);
      _homeOrderVersion = _syncValue(versions['order_version']);
    }
    _promotionVersion = _syncValue(payload?['promotion_version']) ?? _promotionVersion;
  }

  Future<void> _saveBootstrapCache() async {
    if (data == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_bootstrapCacheKey(), jsonEncode(data));
      final branchId = int.tryParse('${data?['branch']?['id'] ?? me?['branch']?['id'] ?? 0}') ?? 0;
      if (branchId > 0) {
        await prefs.setInt('offline_branch_id', branchId);
        await OfflineStore.cacheBootstrap(api.baseUrl, branchId, Map<String, dynamic>.from(data!));
        if (data!['promotion_snapshot'] is Map) {
          await OfflineStore.cachePromotionSnapshot(api.baseUrl, branchId, <String,dynamic>{
            'promotion_version': data!['promotion_version'],
            'promotion_snapshot': Map<String,dynamic>.from(data!['promotion_snapshot'] as Map),
          });
        }
      }
      if (me != null) await OfflineStore.cacheMe(api.baseUrl, Map<String, dynamic>.from(me!));
    } catch (_) {}
  }

  Future<void> _mergeBootstrapSection(Map<String, dynamic> fresh) async {
    if (!mounted) return;
    final merged = Map<String, dynamic>.from(data ?? const {});
    if (fresh.containsKey('categories')) merged['categories'] = fresh['categories'];
    if (fresh.containsKey('products')) merged['products'] = fresh['products'];
    if (fresh.containsKey('topping_map')) merged['topping_map'] = fresh['topping_map'];
    if (fresh.containsKey('tables')) merged['tables'] = fresh['tables'];
    if (fresh.containsKey('branch')) merged['branch'] = fresh['branch'];
    if (fresh.containsKey('price_lists')) merged['price_lists'] = fresh['price_lists'];
    if (fresh.containsKey('bank')) merged['bank'] = fresh['bank'];
    if (fresh.containsKey('promotion_snapshot')) merged['promotion_snapshot'] = fresh['promotion_snapshot'];
    if (fresh.containsKey('promotion_version')) merged['promotion_version'] = fresh['promotion_version'];
    if (fresh.containsKey('versions')) merged['versions'] = fresh['versions'];
    _captureBootstrapVersions(merged);
    setState(() { data = merged; error = null; });
    await _saveBootstrapCache();
  }

  Future<void> _prefetchOfflineBusiness() async {
    if (ficOfflineMode || api.token == null || api.baseUrl.isEmpty) return;
    final branchId = await ficOfflineBranchId();
    if (branchId <= 0) return;
    const modules = <String, String>{
      'recipes': '/recipes',
      'sales_returns': '/sales-returns',
      'loyalty': '/loyalty',
      'purchases': '/purchases',
      'inventory': '/inventory',
      'ingredients': '/ingredients',
      'cashbook': '/cashbook',
      'attendance': '/attendance',
      'tasks': '/tasks',
    };
    // Prefetch tuần tự để không tạo burst request/429. Lỗi một module không làm hỏng Home.
    for (final entry in modules.entries) {
      if (ficOfflineMode) break;
      try {
        final r = await api.getBackground(entry.value);
        dynamic payload = r['data'] ?? r;
        if (entry.key == 'recipes' && payload is Map) payload = await ficCacheRecipeImages(Map<String,dynamic>.from(payload));
        await OfflineStore.cacheModule(api.baseUrl, branchId, entry.key, payload);
      } catch (_) {}
    }
  }

  Future<void> _syncTables() async {
    if (ficOfflineMode) return;
    if (_dataSyncing || api.token == null || api.baseUrl.isEmpty) return;
    _dataSyncing = true;
    try {
      final versions = await api.getBackground('/sync-version');
      final remoteMenu = _syncValue(versions['menu_version']);
      final remoteTables = _syncValue(versions['table_version']);
      final remoteOrders = _syncValue(versions['order_version']);
      final remotePromotions = _syncValue(versions['promotion_version']);
      final needMenu = remoteMenu != null && remoteMenu != _menuVersion;
      final needPromotions = remotePromotions != null && remotePromotions != _promotionVersion;
      // Tổng tiền / hộp quà trên card bàn thay đổi theo order_version, kể cả trạng thái bàn không đổi.
      final needTables = (remoteTables != null && remoteTables != _tableVersion) ||
          (remoteOrders != null && remoteOrders != _homeOrderVersion);
      if (!needMenu && !needTables && !needPromotions) return;

      final sections = <String>[];
      if (needMenu) sections.add('menu');
      if (needTables) sections.add('tables');
      if (needPromotions) sections.add('promotions');
      final fresh = await api.getBackground('/bootstrap?sections=${sections.join(',')}');
      await _mergeBootstrapSection(fresh);
    } catch (_) {
      // Chỉ kiểm tra version nhỏ; mất mạng không được làm gián đoạn thao tác bán hàng.
    } finally {
      _dataSyncing = false;
    }
  }

  Future<void> _toggleQrSound() async {
    final next = !_qrSoundEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('qr_sound_enabled', next);
    await _setBackgroundSound(next);
    if (!mounted) return;
    setState(() => _qrSoundEnabled = next);
    _toast(next ? 'Đã bật âm thông báo' : 'Đã tắt âm thông báo');
    if (next) SystemSound.play(SystemSoundType.alert);
  }

  void _showQrIncomingBanner(Map<String, dynamic>? order, int pendingCount, {bool playAlert = true}) {
    if (!mounted) return;
    final table = (order?['tenban'] ?? order?['table_name'] ?? 'Bàn').toString();
    final code = (order?['public_code'] ?? order?['code'] ?? '').toString();
    final items = order?['items'];
    int qty = 0;
    if (items is List) {
      for (final raw in items) {
        if (raw is Map) qty += (num.tryParse('${raw['quantity'] ?? raw['soluong'] ?? 1}') ?? 1).round();
      }
    }
    final detail = qty > 0
        ? '$qty món đang chờ xác nhận${code.isNotEmpty ? ' • $code' : ''}'
        : '$pendingCount yêu cầu đang chờ${code.isNotEmpty ? ' • $code' : ''}';

    if (playAlert) {
      if (_qrSoundEnabled) SystemSound.play(SystemSoundType.alert);
      HapticFeedback.mediumImpact();
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 9),
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 18),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        content: Row(
          children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.restaurant_menu_rounded, color: Colors.white, size: 25),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Đơn QR mới • $table', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 3),
                  Text(detail, style: const TextStyle(fontSize: 12.5, height: 1.25)),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'XEM ĐƠN',
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const QrRequestPage()));
            await _pollQrPending();
          },
        ),
      ),
    );
  }

  Future<void> _pollQrPending({bool initial = false}) async {
    if (ficOfflineMode) return;
    if (_qrPolling || api.token == null || api.baseUrl.isEmpty) return;
    _qrPolling = true;
    try {
      final r = await api.getBackground('/qr-pending');
      final count = int.tryParse('${r['count'] ?? 0}') ?? 0;
      final latestId = int.tryParse('${r['latest_id'] ?? 0}') ?? 0;
      final hasNew = !initial && latestId > _lastQrLatestId && latestId > 0;
      if (initial) {
        _lastQrLatestId = latestId;
      } else if (latestId > _lastQrLatestId) {
        _lastQrLatestId = latestId;
      }
      if (mounted && count != _qrPendingCount) setState(() => _qrPendingCount = count);
      // V1.7.3: luôn hiện banner đẹp ngay trong app khi có đơn QR mới.
      // Native foreground service vẫn chịu trách nhiệm notification khi app ở nền.
      if (hasNew && mounted) {
        Map<String, dynamic>? newest;
        try {
          final queue = await api.getBackground('/qr-orders');
          final qd=queue['data']; final rows = qd is Map ? ((qd['items'] as List?)??const []) : ((qd is List)?qd:const []);
          for (final raw in rows) {
            if (raw is! Map) continue;
            final row = Map<String, dynamic>.from(raw);
            final id = int.tryParse('${row['id'] ?? 0}') ?? 0;
            if (id == latestId || (newest == null && '${row['status']}' == 'pending')) {
              newest = row;
              if (id == latestId) break;
            }
          }
        } catch (_) {}
        if (Platform.isAndroid) {
          final table = (newest?['tenban'] ?? newest?['table_name'] ?? 'Bàn').toString();
          final code = (newest?['public_code'] ?? newest?['code'] ?? '').toString();
          await _showLocalAlert(
            id: 900000 + latestId,
            title: 'Đơn QR mới • $table',
            body: '${count > 0 ? count : 1} yêu cầu đang chờ${code.isNotEmpty ? ' • $code' : ''}',
            sound: _qrSoundEnabled,
          );
          HapticFeedback.heavyImpact();
          _showQrIncomingBanner(newest, count, playAlert: false);
        } else {
          _showQrIncomingBanner(newest, count);
        }
      }
    } catch (_) {
      // Polling notification must not interrupt normal POS operation.
    } finally {
      _qrPolling = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      WakelockPlus.enable();
      _pollQrPending();
      _pollEvents();
      _pollNotificationCenter();
      // V1.12.9: app vừa quay lại foreground thì kiểm tra Internet và sync ngay.
      unawaited(_probeReconnectAndSync());
      unawaited(_syncOfflineQueue());
      unawaited(load());
    }
    else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) { WakelockPlus.disable(); }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _qrTimer?.cancel();
    _tableSyncTimer?.cancel();
    _eventTimer?.cancel();
    _notificationTimer?.cancel();
    _offlineSyncTimer?.cancel();
    _reconnectTimer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _loadOfflineHomeCache() async {
    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getInt('offline_branch_id') ?? 0;
    final cachedMe = await OfflineStore.getMe(api.baseUrl);
    final cachedBoot = branchId > 0 ? await OfflineStore.getBootstrap(api.baseUrl, branchId) : null;
    final cachedPromo = branchId > 0 ? await OfflineStore.getPromotionSnapshot(api.baseUrl, branchId) : null;
    if (cachedBoot != null && cachedPromo != null) {
      if (cachedPromo['promotion_snapshot'] is Map) cachedBoot['promotion_snapshot'] = cachedPromo['promotion_snapshot'];
      if (cachedPromo['promotion_version'] != null) cachedBoot['promotion_version'] = cachedPromo['promotion_version'];
    }
    await _refreshOfflinePendingCount();
    if (mounted) {
      setState(() {
        if (cachedMe != null) me = cachedMe;
        if (cachedBoot != null) data = cachedBoot;
        _offlineMode = true;
        error = data == null ? 'Chưa có dữ liệu offline. Hãy kết nối Internet ít nhất một lần để tải dữ liệu cửa hàng.' : null;
      });
    }
  }

  Future<void> load() async {
    if (ficOfflineMode) {
      await _loadOfflineHomeCache();
      return;
    }
    try {
      final meFresh = await api.get('/me');
      me = meFresh;
      await OfflineStore.cacheMe(api.baseUrl, meFresh);
      ficOfflineMode = false;
      if (mounted) setState(() { error = null; _offlineMode = false; });

      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString(_bootstrapCacheKey());
        if (cached != null && cached.isNotEmpty) {
          final decoded = jsonDecode(cached);
          if (decoded is Map && mounted) {
            final cachedMap = Map<String, dynamic>.from(decoded);
            _captureBootstrapVersions(cachedMap);
            setState(() => data = cachedMap);
          }
        }
      } catch (_) {}

      final fresh = await api.get('/bootstrap');
      if (mounted) {
        ficOfflineMode = false;
        setState(() { data = fresh; error = null; _offlineMode = false; });
        _captureBootstrapVersions(fresh);
        await _saveBootstrapCache();
        // Fresh server state is authoritative only for paid invoices already confirmed synced.
        await OfflineStore.clearConfirmedFreedTables();
        await _refreshOfflinePendingCount();
        await _registerPushToken();
        await _syncOfflineQueue();
        unawaited(_prefetchOfflineBusiness());
        WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingPushFromNavigator());
      }
    } catch (e) {
      if (_isNetworkError(e)) {
        ficOfflineMode = true;
        await _loadOfflineHomeCache();
      } else if (mounted && data == null) {
        setState(() => error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> logout() async {
    await _unregisterPushToken();
    try {
      await api.post('/logout', {});
    } catch (_) {}
    await _stopBackgroundNotifications();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    api.token = null;
    widget.onLogout();
  }

  List get tables => (data?['tables'] as List?) ?? [];
  bool isBusy(Map table) {
    final id = int.tryParse('${table['id']}') ?? 0;
    // A successful offline payment must release the table immediately on this device.
    // The local free override wins over stale cached bootstrap state until the paid invoice
    // is confirmed by the server. A new unpaid offline order clears this override again.
    if (_offlineFreedTables.contains(id) && !_offlineBusyTables.contains(id)) return false;
    return '${table['trangthai'] ?? 1}' == '2' || _offlineBusyTables.contains(id);
  }


  num tableCurrentTotal(Map table) {
    final tableId = int.tryParse('${table['id']}') ?? 0;
    final serverOrders = <String, double>{};
    final rawServerOrders = table['open_orders'];
    if (rawServerOrders is List) {
      for (final raw in rawServerOrders) {
        if (raw is! Map) continue;
        final code = '${raw['madonhang'] ?? ''}'.trim();
        if (code.isEmpty) continue;
        serverOrders[code] = double.tryParse('${raw['tongtien'] ?? 0}') ?? 0;
      }
    }
    // Local pending snapshot replaces the same server order code and adds new offline orders.
    // This keeps the amount correct across online -> offline transitions and multi-order tables.
    final localOrders = _offlineTableOrderTotals[tableId];
    if (localOrders != null) serverOrders.addAll(localOrders);
    if (serverOrders.isNotEmpty) {
      return serverOrders.values.fold<double>(0, (sum, v) => sum + v);
    }
    return num.tryParse('${table['tongtien'] ?? 0}') ?? 0;
  }

  bool tableHasPromotion(Map table) {
    final tableId = int.tryParse('${table['id']}') ?? 0;
    if (_offlinePromotionTables.contains(tableId)) return true;
    if (table['has_promotion'] == true || '${table['has_promotion']}' == '1') return true;
    final raw = table['open_orders'];
    if (raw is List) {
      return raw.any((o) => o is Map && (o['has_promotion'] == true || '${o['has_promotion']}' == '1'));
    }
    return false;
  }

  Future<void> openPage(Widget page, {bool offlineCapable = false}) async {
    if (ficOfflineMode && !offlineCapable) { _toast('Mục này cần Internet. Bán hàng offline vẫn hoạt động bình thường.'); return; }
    Navigator.pop(context);
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    await load();
  }

  Future<bool> _ensureOpenShiftForSale({String purpose = 'order hoặc thanh toán'}) async {
    final prefs = await SharedPreferences.getInstance();
    final branchId = prefs.getInt('offline_branch_id') ?? 0;

    // Offline: tuyệt đối không gọi /shift. Dùng trạng thái ca đã cache gần nhất.
    // Nếu chưa từng cache trạng thái ca, vẫn cho phép bán offline và server sẽ
    // đối soát lúc đồng bộ; không chặn người dùng chỉ vì mất Internet.
    if (ficOfflineMode || _offlineMode) {
      final cachedShift = branchId > 0 ? await OfflineStore.getShift(api.baseUrl, branchId) : null;
      if (cachedShift != null && cachedShift['required'] == true && cachedShift['open'] != true) {
        _toast('Ca gần nhất đang đóng. Hãy kết nối Internet để mở ca trước khi bán hàng.');
        return false;
      }
      return true;
    }

    try {
      final shift = await api.get('/shift');
      if (branchId > 0) await OfflineStore.cacheShift(api.baseUrl, branchId, shift);
      final required = shift['required'] == true;
      final open = shift['open'] == true;
      if (!required || open) return true;
      if (!mounted) return false;

      final shouldOpen = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dc) => AlertDialog(
          icon: const Icon(Icons.lock_clock_outlined, size: 46),
          title: const Text('Chưa mở ca bán hàng'),
          content: Text(
            'Chi nhánh này yêu cầu mở ca trước khi $purpose. '
            'Hãy kiểm đếm tiền đầu ca theo từng mệnh giá rồi mở ca.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('ĐỂ SAU')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(dc, true),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('MỞ CA'),
            ),
          ],
        ),
      );
      if (shouldOpen != true || !mounted) return false;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const ShiftPage(returnAfterOpen: true)));
      final refreshed = await api.get('/shift');
      if (branchId > 0) await OfflineStore.cacheShift(api.baseUrl, branchId, refreshed);
      return refreshed['required'] != true || refreshed['open'] == true;
    } catch (e) {
      if (_isNetworkError(e)) {
        ficOfflineMode = true;
        if (mounted) setState(() => _offlineMode = true);
        final cachedShift = branchId > 0 ? await OfflineStore.getShift(api.baseUrl, branchId) : null;
        if (cachedShift != null && cachedShift['required'] == true && cachedShift['open'] != true) {
          _toast('Ca gần nhất đang đóng. Hãy kết nối Internet để mở ca trước khi bán hàng.');
          return false;
        }
        return true;
      }
      if (mounted) _toast(e.toString().replaceFirst('Exception: ', ''));
      return false;
    }
  }

  Future<void> _openOrderForTable(Map table) async {
    if (data == null) return;
    if (!await _ensureOpenShiftForSale()) return;
    if (!mounted) return;
    final paid = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => OrderPage(table: table, bootstrap: data!)),
    );
    if (!mounted) return;
    if (paid == true) {
      final tableId = int.tryParse('${table['id']}') ?? 0;
      if (tableId > 0 && data != null) {
        final next = Map<String, dynamic>.from(data!);
        final rows = List<dynamic>.from(next['tables'] as List? ?? const []);
        next['tables'] = rows.map((raw) {
          if (raw is! Map || int.tryParse('${raw['id']}') != tableId) return raw;
          final t = Map<String, dynamic>.from(raw);
          t['trangthai'] = 1;
          t['tongtien'] = 0;
          t['so_don'] = 0;
          t['open_orders'] = <dynamic>[];
          return t;
        }).toList();
        setState(() => data = next);
      }
      await _refreshOfflinePendingCount();
      // Hiện danh sách bàn ngay; refresh server chạy nền để không có khung đen/chờ route.
      unawaited(load());
      return;
    }
    await load();
  }

  Future<void> switchBranch() async {
    final branches = (me?['branches'] as List?) ?? [];
    if (branches.isEmpty) {
      _toast('Tài khoản chưa có chi nhánh khác.');
      return;
    }
    Navigator.pop(context);
    final selected = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (bc) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Chọn chi nhánh', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            ...branches.map((e) {
              final b = e as Map;
              return ListTile(
                leading: const Icon(Icons.store_mall_directory_outlined),
                title: Text('${b['ten'] ?? 'Chi nhánh'}'),
                trailing: '${me?['branch']?['id']}' == '${b['id']}' ? const Icon(Icons.check_circle) : null,
                onTap: () => Navigator.pop(bc, int.parse('${b['id']}')),
              );
            }),
          ],
        ),
      ),
    );
    if (selected == null) return;
    try {
      await api.post('/switch-branch', {'branch_id': selected, if(_pushToken!=null && _pushToken!.isNotEmpty) 'push_token': _pushToken});
      // Cập nhật scope local + push token ngay sau khi server đổi branch, trước khi tải màn hình.
      // Nhờ vậy push của chi nhánh cũ bị chặn sớm nhất có thể.
      final prefs=await SharedPreferences.getInstance();
      await prefs.setInt('offline_branch_id', selected);
      await _registerPushToken();
      await load();
      await _pollNotificationCenter();
      _toast('Đã chuyển chi nhánh');
    } catch (e) {
      _toast(e.toString());
    }
  }

  Future<void> changeAvatar() async {
    Navigator.pop(context);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1200);
      if (picked == null) return;
      await api.uploadImage('/me/avatar', picked.path);
      await load();
      _toast('Đã cập nhật ảnh đại diện');
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> openWebModule(String module) async {
    const offlineModules = {'returns','purchases','inventory','ingredients','recipes','cashbook','attendance','tasks'};
    if (ficOfflineMode && !offlineModules.contains(module)) { _toast('Mục này cần Internet. Các nghiệp vụ bán hàng/kho cần thiết vẫn dùng offline bình thường.'); return; }
    Navigator.pop(context);
    if (!mounted) return;

    // V1.13.31: các màn hình nghiệp vụ cần ca dùng cùng một gate.
    // Sau khi mở ca thành công ShiftPage tự pop và luồng này tiếp tục mở đúng màn hình ban đầu.
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ficModulePage(module)),
    );
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text)));

  Map<String, dynamic>? get _trialEntitlement {
    final raw = me?['entitlement'];
    if (raw is! Map) return null;
    final entitlement = Map<String, dynamic>.from(raw);
    if ('${entitlement['license_type'] ?? ''}'.toLowerCase() != 'trial') return null;
    final trialRaw = entitlement['trial'];
    if (trialRaw is! Map) return null;
    final trial = Map<String, dynamic>.from(trialRaw);
    if (trial['active'] != true) return null;
    return trial;
  }

  String _trialExpiryLabel(dynamic raw) {
    final value = '${raw ?? ''}'.trim();
    if (value.isEmpty) return '—';
    try {
      final d = DateTime.parse(value).toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${two(d.day)}/${two(d.month)}/${d.year}';
    } catch (_) {
      final dateOnly = value.length >= 10 ? value.substring(0, 10) : value;
      final parts = dateOnly.split('-');
      if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
      return value;
    }
  }

  Future<void> _openTrialUpgrade() async {
    final url = '${_trialEntitlement?['upgrade_url'] ?? ''}'.trim();
    if (url.isEmpty) {
      _toast('Chưa có đường dẫn nâng cấp từ FIC Platform.');
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
      _toast('Đường dẫn nâng cấp không hợp lệ.');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _toast('Không mở được trang nâng cấp.');
    } catch (_) {
      _toast('Không mở được trang nâng cấp.');
    }
  }

  Widget _trialBanner(Map<String, dynamic> trial) {
    final days = int.tryParse('${trial['days_remaining'] ?? ''}');
    final expires = _trialExpiryLabel(trial['expires_at']);
    return Material(
      color: Colors.amber.shade50,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: Colors.amber.shade200)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.workspace_premium_outlined, size: 21, color: Colors.orange.shade800),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('FIC POS đang ở chế độ dùng thử.', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  const SizedBox(height: 1),
                  Text(
                    '${days == null ? 'Còn — ngày' : 'Còn $days ngày'} · Hết hạn $expires',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            TextButton(
              onPressed: _openTrialUpgrade,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              ),
              child: const Text('Nâng cấp ngay', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = tables.where((e) {
      final x = e as Map;
      if (filter == 'busy') return isBusy(x);
      if (filter == 'empty') return !isBusy(x);
      return true;
    }).toList();
    final trial = _trialEntitlement;

    return Scaffold(
      drawer: AppMenu(
        me: me,
        onLogout: logout,
        onRefresh: () {
          Navigator.pop(context);
          load();
        },
        onOpenShift: () => openPage(const ShiftPage()),
        onReservations: () => openPage(const ApiListPage(
          title: 'Danh sách đặt bàn',
          endpoint: '/reservations',
          icon: Icons.event_available_outlined,
        )),
        onRecentOrders: () => openPage(const RecentInvoicesPage(), offlineCapable: true),
        onCustomers: () => openPage(const CustomerPage()),
        onQr: () => openPage(const QrRequestPage()),
        onPaymentRequests: () => openPage(PaymentRequestsPage(
          onSeen: () {
            if (!mounted) return;
            setState(() {
              if (_paymentRequestPendingCount > 0) _paymentRequestPendingCount--;
              // Yêu cầu thanh toán cũng là một thông báo trên chuông.
              // Khi người dùng đã mở yêu cầu từ menu, giảm badge chuông ngay.
              if (_notificationUnreadCount > 0) _notificationUnreadCount--;
            });
          },
        )),
        paymentRequestPendingCount: _paymentRequestPendingCount,
        onNotifications: () => openPage(const NotificationCenterPage()),
        onSwitchBranch: switchBranch,
        onAvatar: changeAvatar,
        onLoyalty: () => openPage(const LoyaltyPage(), offlineCapable: true),
        onWebModule: openWebModule,
      ),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        titleSpacing: 0,
        title: Row(
          children: [
            Image.asset('assets/images/fic_logo.png', height: 38),
            const SizedBox(width: 8),
            const Text('FIC POS', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tìm bàn',
            onPressed: () async {
              final selected = await showSearch<Map?>(
                context: context,
                delegate: TableSearch(tables),
              );
              if (selected == null || !mounted || data == null) return;
              await _openOrderForTable(selected);
            },
            icon: const Icon(Icons.search, size: 30),
          ),
          IconButton(
            tooltip: _qrSoundEnabled ? 'Tắt âm thông báo' : 'Bật âm thông báo',
            onPressed: _toggleQrSound,
            icon: Icon(
              _qrSoundEnabled ? Icons.volume_up_outlined : Icons.volume_off_outlined,
              size: 28,
            ),
          ),
          IconButton(
            tooltip: 'Thông báo',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationCenterPage()));
              await _pollNotificationCenter();
            },
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_none, size: 29),
                if (_notificationUnreadCount > 0)
                  Positioned(
                    right: -7,
                    top: -7,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(10)),
                      alignment: Alignment.center,
                      child: Text(
                        _notificationUnreadCount > 99
                            ? '99+'
                            : '$_notificationUnreadCount',
                        style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const RecentInvoicesPage()));
              if (mounted) await load();
            },
            icon: const Icon(Icons.receipt_long_outlined, size: 28),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!),
                  FilledButton.tonal(onPressed: load, child: const Text('Thử lại')),
                ],
              ),
            )
          : data == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (trial != null) _trialBanner(trial),
                    if (_offlineMode || _offlinePendingCount > 0)
                      Material(
                        color: _offlineMode ? Colors.orange.shade100 : (_offlineSyncErrors > 0 ? Colors.red.shade50 : Colors.blue.shade50),
                        child: InkWell(
                          onTap: _offlineSyncErrors > 0 ? _showOfflineSyncIssues : null,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            child: Row(children: [
                              Icon(_offlineSyncErrors > 0 ? Icons.error_outline : (_offlineMode ? Icons.cloud_off_outlined : Icons.sync_outlined), size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(_offlineMode
                                  ? 'Đang ngoại tuyến${_offlinePendingCount > 0 ? ' • ${_offlinePendingLabel()}' : ''}'
                                  : '${_offlinePendingLabel()}${_offlineSyncErrors > 0 ? ' • Bấm để xem lỗi' : ''}', style: const TextStyle(fontWeight: FontWeight.w700))),
                              if (_offlineSyncErrors > 0)
                                IconButton(tooltip: 'Xem chi tiết lỗi', onPressed: _showOfflineSyncIssues, icon: const Icon(Icons.info_outline, size: 22)),
                              const SizedBox(width: 2),
                              IconButton(
                                tooltip: _manualOfflineSyncing ? 'Đang đồng bộ...' : (_offlineSyncErrors > 0 ? 'Thử lại đồng bộ lỗi' : 'Đồng bộ ngay'),
                                onPressed: _manualOfflineSyncing ? null : _manualSyncOfflineNow,
                                icon: _manualOfflineSyncing
                                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                                    : Icon(_offlineSyncErrors > 0 ? Icons.sync_problem_outlined : Icons.sync, size: 22),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    Container(
                      color: Colors.white,
                      child: Row(
                        children: [
                          FilterTab('Tất cả', filter == 'all',
                              () => setState(() => filter = 'all')),
                          FilterTab('Sử dụng', filter == 'busy',
                              () => setState(() => filter = 'busy')),
                          FilterTab('Còn trống', filter == 'empty',
                              () => setState(() => filter = 'empty')),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: load,
                        child: GridView.builder(
                          padding: const EdgeInsets.all(14),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            childAspectRatio: 1.18,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                          ),
                          itemCount: shown.length,
                          itemBuilder: (_, i) {
                            final table = shown[i] as Map;
                            return TableCard(
                              table: table,
                              isBusy: isBusy(table),
                              total: tableCurrentTotal(table),
                              hasPromotion: tableHasPromotion(table),
                              onTap: () => _openOrderForTable(table),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}


class FicRemoteAvatar extends StatefulWidget {
  final String url;
  final String initials;
  final double radius;
  const FicRemoteAvatar({super.key, required this.url, required this.initials, this.radius = 25});

  @override
  State<FicRemoteAvatar> createState() => _FicRemoteAvatarState();
}

class _FicRemoteAvatarState extends State<FicRemoteAvatar> {
  Uint8List? _bytes;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant FicRemoteAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  Future<void> _load() async {
    final raw = widget.url.trim();
    if (raw.isEmpty) {
      if (mounted) setState(() { _bytes = null; _loading = false; });
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      String resolved = raw;
      if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
        final base = api.baseUrl.replaceFirst(RegExp(r'/api/mobile/v1/?$'), '');
        resolved = '${base.replaceAll(RegExp(r'/$'), '')}/${raw.replaceAll(RegExp(r'^/'), '')}';
      }
      final response = await http.get(Uri.parse(resolved), headers: api.imageHeaders).timeout(const Duration(seconds: 12));
      if (response.statusCode >= 200 && response.statusCode < 300 && response.bodyBytes.isNotEmpty) {
        if (mounted) setState(() => _bytes = response.bodyBytes);
      } else {
        if (mounted) setState(() => _bytes = null);
      }
    } catch (_) {
      if (mounted) setState(() => _bytes = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.radius * 2;
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true)
            : Container(
                alignment: Alignment.center,
                color: Theme.of(context).colorScheme.primaryContainer,
                child: _loading
                    ? SizedBox(width: widget.radius, height: widget.radius, child: const CircularProgressIndicator(strokeWidth: 2))
                    : Text(widget.initials, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
      ),
    );
  }
}

class AppMenu extends StatelessWidget {
  final Map? me;
  final VoidCallback onLogout;
  final VoidCallback onRefresh;
  final VoidCallback onOpenShift;
  final VoidCallback onReservations;
  final VoidCallback onRecentOrders;
  final VoidCallback onCustomers;
  final VoidCallback onQr;
  final VoidCallback onPaymentRequests;
  final int paymentRequestPendingCount;
  final VoidCallback onNotifications;
  final VoidCallback onSwitchBranch;
  final VoidCallback onAvatar;
  final VoidCallback onLoyalty;
  final Future<void> Function(String module) onWebModule;

  const AppMenu({
    super.key,
    this.me,
    required this.onLogout,
    required this.onRefresh,
    required this.onOpenShift,
    required this.onReservations,
    required this.onRecentOrders,
    required this.onCustomers,
    required this.onQr,
    required this.onPaymentRequests,
    required this.paymentRequestPendingCount,
    required this.onNotifications,
    required this.onSwitchBranch,
    required this.onAvatar,
    required this.onLoyalty,
    required this.onWebModule,
  });

  @override
  Widget build(BuildContext context) {
    final user = me?['user'] is Map ? Map<String, dynamic>.from(me!['user'] as Map) : <String, dynamic>{};
    final branch = me?['branch'] is Map ? Map<String, dynamic>.from(me!['branch'] as Map) : <String, dynamic>{};
    final paymentRequest = me?['payment_request'] is Map
        ? Map<String, dynamic>.from(me!['payment_request'] as Map)
        : <String, dynamic>{};
    final menuTheme = Theme.of(context).copyWith(
      scaffoldBackgroundColor: Colors.white,
      canvasColor: Colors.white,
      iconTheme: const IconThemeData(color: Color(0xFF202432)),
      listTileTheme: const ListTileThemeData(
        textColor: Color(0xFF202432),
        iconColor: Color(0xFF202432),
      ),
      expansionTileTheme: const ExpansionTileThemeData(
        textColor: Color(0xFF202432),
        collapsedTextColor: Color(0xFF202432),
        iconColor: Color(0xFF202432),
        collapsedIconColor: Color(0xFF202432),
        backgroundColor: Colors.white,
        collapsedBackgroundColor: Colors.white,
      ),
    );

    return Drawer(
        backgroundColor: Colors.white,
        width: (MediaQuery.of(context).size.width * .90).clamp(300.0, 380.0).toDouble(),
        child: Theme(
          data: menuTheme,
          child: SafeArea(
            child: Column(
            children: [
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                leading: GestureDetector(
                  onTap: onAvatar,
                  child: FicRemoteAvatar(
                    url: '${user['avatar_url'] ?? ''}',
                    initials: _initial('${user['name'] ?? 'F'}'),
                    radius: 25,
                  ),
                ),
                title: Text('${user['name'] ?? 'Tài khoản'}',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                subtitle: Text('@${user['ten_nhanvien'] ?? user['account'] ?? ''} · ${branch['ten'] ?? ''}'),
                trailing: IconButton(tooltip:'Đổi ảnh đại diện', onPressed:onAvatar, icon:const Icon(Icons.photo_camera_outlined)),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    _parent(context, Icons.point_of_sale, 'Bán hàng', [
                      _child(context, Icons.grid_view_rounded, 'Phòng bàn / Order', () => Navigator.pop(context)),
                      _child(context, Icons.qr_code_scanner, 'Yêu cầu gọi món QR', onQr),
                      if (paymentRequest['enabled'] == true && paymentRequest['can_take_payment'] == true)
                        ListTile(
                          dense: true,
                          leading: const Icon(
                            Icons.notifications_active_outlined,
                            size: 23,
                          ),
                          title: const Text(
                            'Yêu cầu thanh toán',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15.5),
                          ),
                          trailing: paymentRequestPendingCount > 0
                              ? Container(
                                  constraints: const BoxConstraints(minWidth: 28),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.red,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    paymentRequestPendingCount > 99
                                        ? '99+'
                                        : '$paymentRequestPendingCount',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      height: 1,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.chevron_right, size: 18),
                          onTap: onPaymentRequests,
                        ),
                      _child(context, Icons.soup_kitchen_outlined, 'Báo bếp / Pha chế', () => onWebModule('kitchen')),
                      _child(context, Icons.science_outlined, 'Xem công thức', () => onWebModule('recipes')),
                      _child(context, Icons.event_available_outlined, 'Đặt bàn', onReservations),
                      _child(context, Icons.receipt_long_outlined, 'Lịch sử hóa đơn', onRecentOrders),
                      _child(context, Icons.assignment_return_outlined, 'Trả hàng', () => onWebModule('returns')),
                    ], initiallyExpanded: true),
                    _parent(context, Icons.people_alt_outlined, 'Khách hàng', [
                      _child(context, Icons.people_outline, 'Danh sách / Thêm khách hàng', onCustomers),
                      _child(context, Icons.stars_outlined, 'Thành viên & tích điểm', onLoyalty),
                    ]),
                    _parent(context, Icons.inventory_2_outlined, 'Kho & nguyên liệu', [
                      _child(context, Icons.move_to_inbox_outlined, 'Nhập hàng', () => onWebModule('purchases')),
                      _child(context, Icons.keyboard_return, 'Trả hàng nhập', () => onWebModule('purchase_returns')),
                      _child(context, Icons.fact_check_outlined, 'Kiểm kho', () => onWebModule('inventory')),
                      _child(context, Icons.warning_amber_outlined, 'Báo nguyên liệu', () => onWebModule('ingredients')),
                      _child(context, Icons.science_outlined, 'Xem công thức', () => onWebModule('recipes')),
                    ]),
                    _parent(context, Icons.account_balance_wallet_outlined, 'Tài chính', [
                      _child(context, Icons.point_of_sale_outlined, 'Ca & két', onOpenShift),
                      _child(context, Icons.menu_book_outlined, 'Sổ thu chi', () => onWebModule('cashbook')),
                      _child(context, Icons.bar_chart_outlined, 'Báo cáo cuối ngày', () => onWebModule('daily_report')),
                    ]),
                    _parent(context, Icons.badge_outlined, 'Nhân sự', [
                      _child(context, Icons.fingerprint, 'Chấm công', () => onWebModule('attendance')),
                      _child(context, Icons.task_alt, 'Công việc hằng ngày', () => onWebModule('tasks')),
                      _child(context, Icons.calendar_month_outlined, 'Lịch làm việc', () => onWebModule('schedule')),
                      _child(context, Icons.event_available_outlined, 'Đăng ký lịch làm việc', () => Navigator.push(context, MaterialPageRoute(builder:(_)=>const SchedulePage()))),
                      _child(context, Icons.schedule_outlined, 'Xin đi trễ / nghỉ / về sớm', () => onWebModule('late_request')),
                      _child(context, Icons.request_quote_outlined, 'Ứng lương', () => onWebModule('salary_advance')),
                      _child(context, Icons.payments_outlined, 'Bảng lương của tôi', () => onWebModule('payroll')),
                      _child(context, Icons.gavel_outlined, 'Vi phạm', () => onWebModule('violations')),
                    ]),
                    _parent(context, Icons.settings_outlined, 'Hệ thống', [
                      _child(context, Icons.swap_horiz, 'Chuyển chi nhánh', onSwitchBranch),
                      _child(context, Icons.notifications_none, 'Thông báo', onNotifications),
                      _child(context, Icons.sync, 'Đồng bộ dữ liệu', onRefresh),
                      _child(context, Icons.lock_outline, 'Đổi mật khẩu', () => _changePassword(context)),
                      _child(context, Icons.print_outlined, 'Cài đặt máy in', () => Navigator.push(context, MaterialPageRoute(builder:(_)=>const PrinterSettingsPage()))),
                      _child(context, Icons.settings_outlined, 'Thiết lập app', () => onWebModule('settings')),
                      _child(context, Icons.logout, 'Đăng xuất', onLogout),
                    ]),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text('FIC POS Mobile • V$ficPosMobileVersion', style: TextStyle(color: Colors.black45)),
              ),
            ],
            ),
          ),
        ),
      );
  }

  static String _initial(String name) {
    final t = name.trim();
    return t.isEmpty ? 'F' : t.substring(0, 1).toUpperCase();
  }

  Widget _parent(BuildContext context, IconData icon, String title, List<Widget> children,
          {bool initiallyExpanded = false}) =>
      ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: Icon(icon, size: 26),
        title: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        childrenPadding: const EdgeInsets.only(left: 14),
        children: children,
      );

  Widget _child(BuildContext context, IconData icon, String text, VoidCallback tap) => ListTile(
        dense: true,
        leading: Icon(icon, size: 23),
        title: Text(text, style: const TextStyle(fontSize: 15.5)),
        trailing: const Icon(Icons.chevron_right, size: 18),
        onTap: tap,
      );

  Future<void> _changePassword(BuildContext context) async {
    Navigator.pop(context);
    final oldPass = TextEditingController();
    final newPass = TextEditingController();
    final confirm = TextEditingController();
    bool hideOld=true, hideNew=true, hideConfirm=true;
    await showDialog(
      context: context,
      builder: (dc) => StatefulBuilder(builder:(dc,setD)=>AlertDialog(
        title: const Text('Đổi mật khẩu'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: oldPass, obscureText: hideOld, decoration: InputDecoration(labelText: 'Mật khẩu hiện tại', suffixIcon: IconButton(onPressed:()=>setD(()=>hideOld=!hideOld), icon:Icon(hideOld?Icons.visibility_outlined:Icons.visibility_off_outlined)))),
          const SizedBox(height: 10),
          TextField(controller: newPass, obscureText: hideNew, decoration: InputDecoration(labelText: 'Mật khẩu mới', suffixIcon: IconButton(onPressed:()=>setD(()=>hideNew=!hideNew), icon:Icon(hideNew?Icons.visibility_outlined:Icons.visibility_off_outlined)))),
          const SizedBox(height: 10),
          TextField(controller: confirm, obscureText: hideConfirm, decoration: InputDecoration(labelText: 'Nhập lại mật khẩu mới', suffixIcon: IconButton(onPressed:()=>setD(()=>hideConfirm=!hideConfirm), icon:Icon(hideConfirm?Icons.visibility_outlined:Icons.visibility_off_outlined)))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Hủy')),
          FilledButton(onPressed: () async {
            if (newPass.text != confirm.text) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mật khẩu nhập lại không khớp.')));
              return;
            }
            try {
              await api.post('/change-password', {'current_password': oldPass.text, 'password': newPass.text, 'password_confirmation': confirm.text});
              if (dc.mounted) Navigator.pop(dc);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đổi mật khẩu thành công.')));
            } catch (e) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
            }
          }, child: const Text('Đổi mật khẩu')),
        ],
      )),
    );
  }

  void _info(BuildContext context, String message) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class FilterTab extends StatelessWidget {
  final String text;
  final bool selected;
  final VoidCallback tap;
  const FilterTab(this.text, this.selected, this.tap, {super.key});

  @override
  Widget build(BuildContext context) => Expanded(
        child: InkWell(
          onTap: tap,
          child: Container(
            height: 56,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: 3,
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                ),
              ),
            ),
            alignment: Alignment.center,
            child: Text(text,
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.black87)),
          ),
        ),
      );
}

class TableCard extends StatelessWidget {
  final Map table;
  final bool isBusy;
  final num total;
  final bool hasPromotion;
  final VoidCallback onTap;
  const TableCard(
      {super.key,
      required this.table,
      required this.isBusy,
      required this.total,
      required this.hasPromotion,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(
                color: isBusy
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black12,
                width: isBusy ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Icon(
                    isBusy
                        ? Icons.groups_2_outlined
                        : Icons.table_restaurant_outlined,
                    color: Theme.of(context).colorScheme.primary,
                    size: 27,
                  ),
                  const Spacer(),
                  Text('${table['tenban'] ?? table['ten'] ?? 'Bàn'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(isBusy ? 'Đang sử dụng' : 'Còn trống',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: isBusy
                              ? Theme.of(context).colorScheme.primary
                              : Colors.black54)),
                  if (isBusy && total > 0) ...[
                    const SizedBox(height: 3),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Text('${money(total)} đ',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                              color: Theme.of(context).colorScheme.primary))),
                      if (hasPromotion) const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text('🎁', style: TextStyle(fontSize: 16)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

class OrderPage extends StatefulWidget {
  final Map table;
  final Map<String, dynamic> bootstrap;
  final String? initialOrderCode;
  const OrderPage({super.key, required this.table, required this.bootstrap, this.initialOrderCode});
  @override
  State<OrderPage> createState() => _OrderState();
}

class _OrderState extends State<OrderPage> {
  Map<String, dynamic>? orderData;
  Map<String, dynamic>? preview;
  bool loading = true;
  bool changing = false;
  String category = 'all';
  String query = '';
  final Map<int, num> priceOverrides = {};
  Timer? _orderSyncTimer;
  bool _orderSyncing = false;
  bool paymentRequestPending = false;
  bool _paymentRequestChecking = false;
  bool _paymentRequestSending = false;
  String? _orderVersion;
  String? _orderMenuVersion;
  int _optimisticSequence = 0;
  int _fastMutationInFlight = 0;
  final Map<int, Timer> _quantityTimers = {};
  // V1.13.12: topping taps are optimistic and debounced independently per topping.
  final Map<String, Timer> _toppingTimers = {};
  final Map<String, Map<String, dynamic>> _pendingToppings = {};
  final Map<String, Future<void>> _toppingInFlight = {};

  // V1.13.11: pricing/promotion UI follows the optimistic item state immediately.
  // The server preview remains authoritative and replaces this local preview in background.
  int _pricingRevision = 0;
  int _previewRevision = 0;
  Map<String, dynamic>? _livePreview;

  int get tableId => int.parse(widget.table['id'].toString());
  String? get orderCode => orderData?['order']?['madonhang']?.toString();
  Map get paymentPolicy => (orderData?['payment_policy'] as Map?) ?? const {};
  bool get requireCashierRequest => paymentPolicy['require_cashier_request'] == true || '${paymentPolicy['require_cashier_request']}' == '1';
  bool get canTakePayment => paymentPolicy['can_take_payment'] == true || '${paymentPolicy['can_take_payment']}' == '1';
  List get allItems => (orderData?['items'] as List?) ?? [];
  List get mainItems => allItems
      .where((e) => '${(e as Map)['fic_is_topping'] ?? 0}' != '1')
      .toList();

  bool get _offlineNow => ficOfflineMode;

  Future<void> _enterOfflineMode() async {
    ficOfflineMode = true;
    if (mounted) setState(() {});
  }

  Future<Map<String, dynamic>> _loadLocalOrder({String? madonhang}) async {
    final pending = await OfflineStore.pendingForTable(tableId);
    Map<String, dynamic>? selected;
    if (madonhang != null && madonhang.isNotEmpty) {
      for (final row in pending) {
        if ('${row['madonhang']}' == madonhang && row['payload'] is Map) {
          selected = Map<String, dynamic>.from(row['payload'] as Map);
          break;
        }
      }
    }
    if (selected == null && pending.isNotEmpty && pending.first['payload'] is Map) {
      selected = Map<String, dynamic>.from(pending.first['payload'] as Map);
    }
    selected ??= await OfflineStore.getOrder(tableId);
    if (selected == null) {
      selected = <String, dynamic>{
        'table': widget.table,
        'order': null,
        'orders': <dynamic>[],
        'items': <dynamic>[],
        'price_lists': widget.bootstrap['price_lists'] ?? const [],
        'payment_policy': const {'require_cashier_request': false, 'can_take_payment': true},
        'offline': true,
      };
    }
    final headers = <Map<String, dynamic>>[];
    for (final row in pending) {
      final payload = row['payload'];
      if (payload is Map && payload['order'] is Map) {
        headers.add(Map<String, dynamic>.from(payload['order'] as Map));
      }
    }
    if (headers.isNotEmpty) selected['orders'] = headers;
    selected['table'] ??= widget.table;
    selected['offline'] = true;
    return selected;
  }

  Future<void> _saveLocalPayment(String method, {
    num? customerCash,
    num cashAmount = 0,
    num bankAmount = 0,
    num debtReceived = 0,
    String debtMethod = 'tienmat',
    String? dueDate,
    int redeemPoints = 0,
  }) async {
    final localInvoiceCode = 'OFF-${DateTime.now().millisecondsSinceEpoch}';
    // V1.13.8: khi hóa đơn được chốt offline, khóa kết quả khuyến mãi ngay tại thời điểm phát hành.
    // Khi sync, server dùng snapshot đã ký để xác nhận lại theo đúng mốc tạo đơn, không recalc bằng CTKM mới.
    final lockedPreview = Map<String, dynamic>.from(effectivePreview ?? <String, dynamic>{
      'tongtien': _rawTotal(), 'giamgia': 0, 'phaitra': _rawTotal(), 'promotions': const [], 'gifts': const [],
    });
    final payment = <String, dynamic>{
      'phuongthuc': method,
      'amount': num.tryParse('${lockedPreview['phaitra'] ?? _rawTotal()}') ?? _rawTotal(),
      'subtotal': num.tryParse('${lockedPreview['tongtien'] ?? _rawTotal()}') ?? _rawTotal(),
      'discount': num.tryParse('${lockedPreview['giamgia'] ?? 0}') ?? 0,
      'promotions': lockedPreview['promotions'] ?? const [],
      'gifts': lockedPreview['gifts'] ?? const [],
      if (widget.bootstrap['promotion_snapshot'] is Map) 'promotion_snapshot': widget.bootstrap['promotion_snapshot'],
      'local_invoice_code': localInvoiceCode,
      if (customerCash != null) 'tien_khach_dua': customerCash,
      if (method == 'ket_hop') 'tienmat': cashAmount,
      if (method == 'ket_hop') 'chuyenkhoan': bankAmount,
      if (method == 'ghi_no') 'thu_truoc': debtReceived,
      if (method == 'ghi_no') 'phuongthuc_thu_truoc': debtMethod,
      if (method == 'ghi_no' && dueDate != null && dueDate.isNotEmpty) 'han_thanh_toan': dueDate,
      if (redeemPoints > 0) 'redeem_points': redeemPoints,
      'offline_paid_at': DateTime.now().toIso8601String(),
      'status': 'offline_paid',
    };
    final next = _ensureLocalOrderData();
    next['offline_payment'] = payment;
    next['offline_locked_preview'] = lockedPreview;
    final order = next['order'];
    if (order is Map) {
      order['tongtien'] = payment['subtotal'];
      order['giamgia'] = payment['discount'];
      order['phaitra'] = payment['amount'];
    }
    next['offline_closed'] = true;
    if (mounted) setState(() => orderData = next);
    await _queueCurrentOffline(payment: payment);
    await OfflineStore.finalizeInvoice(tableId: tableId, orderData: next, payment: payment);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dc) => AlertDialog(
        icon: const Icon(Icons.cloud_off_outlined, size: 46),
        title: const Text('Thanh toán thành công'),
        content: Text((method == 'chuyenkhoan' || (method == 'ket_hop' && bankAmount > 0))
            ? 'Hóa đơn $localInvoiceCode đã được tạo trên máy. Thanh toán chuyển khoản được xem là đã hoàn tất và sẽ tự đồng bộ khi có Internet.'
            : 'Hóa đơn $localInvoiceCode đã được tạo trên máy và sẽ tự đồng bộ lên hệ thống khi có Internet.'),
        actions: [
          OutlinedButton.icon(
            onPressed: () async {
              Navigator.pop(dc);
              await _openOfflinePrint('invoice', payment: payment);
            },
            icon: const Icon(Icons.print_outlined),
            label: const Text('In hóa đơn'),
          ),
          FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Xong')),
        ],
      ),
    );
    // V1.13.0: payment is a terminal action for this order screen.
    // Match the online flow: after the user acknowledges success, leave OrderPage immediately.
    // finalizeInvoice() has already persisted the invoice, removed the local order cache and marked
    // the table locally free, so returning to the table list is safe even without Internet.
    if (!mounted) return;
    await Future<void>.delayed(Duration.zero);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop(true);
    }
  }


  Map<String, dynamic> _ensureLocalOrderData() {
    final next = Map<String, dynamic>.from(orderData ?? const {});
    var order = next['order'];
    if (order is! Map) {
      final code = _offlineOrderCode(tableId);
      final createdAt = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      order = <String, dynamic>{
        'madonhang': code,
        'id_ban': tableId,
        'trangthai': 1,
        'offline': true,
        // V1.13.8: mốc xét khuyến mãi thuộc riêng đơn này và không thay đổi khi thanh toán/sync.
        'ngayban': '${createdAt.year.toString().padLeft(4, '0')}-${two(createdAt.month)}-${two(createdAt.day)}',
        'giovao': '${two(createdAt.hour)}:${two(createdAt.minute)}:${two(createdAt.second)}',
        'created_at_local': createdAt.toIso8601String(),
      };
      next['order'] = order;
      next['orders'] = [order];
    }
    next['table'] ??= widget.table;
    next['payment_policy'] ??= const {'require_cashier_request': false, 'can_take_payment': true};
    next['offline'] = true;
    next['offline_client_id'] ??= OfflineStore.ensureClientId(next, tableId);
    return next;
  }

  Future<void> _queueCurrentOffline({Map<String, dynamic>? payment}) async {
    if (orderData == null) return;
    final queued = Map<String, dynamic>.from(orderData!);
    // V1.13.9: persist current offline promotion result so Home can show 🎁 without Internet.
    if (payment == null) {
      queued['offline_promotion_preview'] = OfflinePromotionEngine.evaluate(orderData: queued, bootstrap: widget.bootstrap);
      if (mounted) orderData!['offline_promotion_preview'] = queued['offline_promotion_preview'];
    }
    await OfflineStore.queueOrder(tableId: tableId, orderData: queued, payment: payment);
  }

  Future<bool> _showTransferQr(num amount) async {
    final bank = widget.bootstrap['bank'];
    if (bank is! Map) return true;
    final acqId = '${bank['bin'] ?? ''}'.trim();
    final accountNo = '${bank['account_no'] ?? ''}'.trim();
    if (acqId.isEmpty || accountNo.isEmpty) return true;
    final code = orderCode ?? _offlineOrderCode(tableId);
    final payload = VietQrPayload.build(
      acqId: acqId,
      accountNo: accountNo,
      amount: amount,
      addInfo: 'FIC $code',
    );
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dc) => AlertDialog(
        title: const Text('Quét QR chuyển khoản'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          QrImageView(data: payload, size: 220, backgroundColor: Colors.white),
          const SizedBox(height: 10),
          Text('${bank['name'] ?? ''} • $accountNo', textAlign: TextAlign.center),
          if ('${bank['holder'] ?? ''}'.trim().isNotEmpty)
            Text('${bank['holder']}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('${money(amount)} đ', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 6),
          const Text('QR tạo trực tiếp trên máy, vẫn hiển thị khi POS mất Internet.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('Tiếp tục')),
        ],
      ),
    );
    return ok == true;
  }

  @override
  void initState() {
    super.initState();
    final bootVersions = widget.bootstrap['versions'];
    if (bootVersions is Map) _orderMenuVersion = '${bootVersions['menu_version'] ?? ''}'.isEmpty ? null : '${bootVersions['menu_version']}';
    load(madonhang: widget.initialOrderCode);
    _orderSyncTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _syncOrderState());
  }

  @override
  void dispose() {
    _orderSyncTimer?.cancel();
    for (final timer in _quantityTimers.values) { timer.cancel(); }
    _quantityTimers.clear();
    for (final timer in _toppingTimers.values) { timer.cancel(); }
    _toppingTimers.clear();
    _pendingToppings.clear();
    super.dispose();
  }

  Future<void> _refreshPaymentRequestStatus({bool silent = true}) async {
    final code = orderCode;
    if (code == null || code.isEmpty || _paymentRequestChecking) return;
    if (!(requireCashierRequest && !canTakePayment)) {
      if (mounted && paymentRequestPending) setState(() => paymentRequestPending = false);
      return;
    }
    _paymentRequestChecking = true;
    try {
      final r = silent
          ? await api.getBackground('/orders/payment-request-status?madonhang=${Uri.encodeQueryComponent(code)}')
          : await api.get('/orders/payment-request-status?madonhang=${Uri.encodeQueryComponent(code)}');
      final pending = r['pending'] == true || '${r['pending']}' == '1';
      if (mounted && paymentRequestPending != pending) {
        setState(() => paymentRequestPending = pending);
      }
    } catch (e) {
      if (!silent) _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      _paymentRequestChecking = false;
    }
  }

  Future<void> _syncOrderState() async {
    if (_offlineNow) return;
    if (_orderSyncing || changing || _fastMutationInFlight > 0 || _quantityTimers.isNotEmpty || _toppingTimers.isNotEmpty || _toppingInFlight.isNotEmpty || !mounted) return;
    _orderSyncing = true;
    try {
      // Nhịp thường chỉ đọc version nhỏ; order chỉ tải lại khi thật sự có thay đổi.
      final version = await api.getBackground('/sync-version?table_id=$tableId');
      final remoteVersion = '${version['order_version'] ?? ''}'.isEmpty ? null : '${version['order_version']}';
      final remoteMenuVersion = '${version['menu_version'] ?? ''}'.isEmpty ? null : '${version['menu_version']}';
      if (remoteMenuVersion != null && remoteMenuVersion != _orderMenuVersion) {
        try {
          final menu = await api.get('/bootstrap?sections=menu');
          final categories = menu['categories'];
          final products = menu['products'];
          if (mounted) {
            setState(() {
              if (categories != null) widget.bootstrap['categories'] = categories;
              if (products != null) widget.bootstrap['products'] = products;
              if (menu.containsKey('topping_map')) widget.bootstrap['topping_map'] = menu['topping_map'];
              if (menu.containsKey('promotion_snapshot')) widget.bootstrap['promotion_snapshot'] = menu['promotion_snapshot'];
              widget.bootstrap['versions'] = menu['versions'] ?? widget.bootstrap['versions'];
              _orderMenuVersion = remoteMenuVersion;
            });
          }
        } catch (_) {}
      }
      if (_orderVersion != null && remoteVersion != null && remoteVersion == _orderVersion) {
        await _refreshPaymentRequestStatus();
        return;
      }

      final current = orderCode;
      final fresh = await api.get('/tables/$tableId/order');
      final orders = (fresh['orders'] as List?) ?? const [];
      final freshVersion = '${fresh['sync_version'] ?? remoteVersion ?? ''}'.isEmpty ? null : '${fresh['sync_version'] ?? remoteVersion}';
      if (current != null && current.isNotEmpty) {
        final stillOpen = orders.any((e) => '${(e as Map)['madonhang'] ?? ''}' == current);
        if (!stillOpen && mounted) {
          if (orders.isEmpty) {
            _orderVersion = freshVersion;
            _toast('Đơn đã được thanh toán. Bàn đã trống.');
            Navigator.pop(context);
            return;
          }
          final next = '${(orders.first as Map)['madonhang'] ?? ''}';
          await load(madonhang: next);
          _toast('Đơn vừa thanh toán đã đóng. Đã chuyển sang đơn còn lại.');
          return;
        }
      }
      await load(madonhang: current);
    } catch (e) {
      if (_isNetworkError(e)) await _enterOfflineMode();
      // Mất mạng tạm thời: giữ nguyên màn hiện tại và thử lại ở nhịp sau.
    } finally {
      _orderSyncing = false;
    }
  }

  void _markPricingChanged() {
    _pricingRevision++;
    if (orderData != null) {
      _livePreview = OfflinePromotionEngine.evaluate(
        orderData: orderData!,
        bootstrap: widget.bootstrap,
      );
    } else {
      _livePreview = null;
    }
  }

  Future<void> _refreshOfficialPreview(int revision) async {
    if (_offlineNow || !mounted) return;
    final code = orderCode;
    if (code == null || code.isEmpty) return;
    try {
      final pr = await api.getBackground('/orders/$code/preview');
      final official = pr['preview'];
      if (!mounted || revision != _pricingRevision || official is! Map) return;
      setState(() {
        preview = Map<String, dynamic>.from(official);
        _previewRevision = revision;
        _livePreview = null;
      });
    } catch (_) {
      // Keep the instant local preview. The normal sync loop will retry later.
    }
  }

  Future<void> load({String? madonhang}) async {
    if (_offlineNow) {
      final local = await _loadLocalOrder(madonhang: madonhang);
      if (mounted) setState(() { orderData = local; preview = null; _markPricingChanged(); loading = false; });
      return;
    }
    try {
      final suffix = madonhang == null || madonhang.isEmpty
          ? ''
          : '?madonhang=${Uri.encodeQueryComponent(madonhang)}';
      final result = await api.get('/tables/$tableId/order$suffix');
      Map<String, dynamic>? p;
      final code = result['order']?['madonhang']?.toString();
      final items = (result['items'] as List?) ?? [];
      if (code != null && items.isNotEmpty) {
        try {
          final pr = await api.get('/orders/$code/preview');
          p = pr['preview'] as Map<String, dynamic>?;
        } catch (_) {}
      }
      ficOfflineMode = false;
      if (mounted) {
        setState(() {
          orderData = result;
          preview = p;
          _pricingRevision++;
          _previewRevision = _pricingRevision;
          _livePreview = null;
          _orderVersion = '${result['sync_version'] ?? ''}'.isEmpty ? null : '${result['sync_version']}';
          loading = false;
        });
        await OfflineStore.cacheOrder(tableId, result);
      }
      await _refreshPaymentRequestStatus();
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        final local = await _loadLocalOrder(madonhang: madonhang);
        if (mounted) setState(() { orderData = local; preview = null; _markPricingChanged(); loading = false; });
        return;
      }
      if (mounted) {
        setState(() => loading = false);
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  List get products => ((widget.bootstrap['products'] as List?) ?? []).where((e) {
        final x = e as Map;
        final catOk = category == 'all' || '${x['id_danhmuc']}' == category;
        final q = query.toLowerCase();
        return catOk &&
            (q.isEmpty || '${x['tensanpham'] ?? ''}'.toLowerCase().contains(q));
      }).toList();

  num productPrice(Map x) => priceOverrides[int.tryParse('${x['id']}') ?? 0] ?? (num.tryParse('${x['giaban'] ?? x['gia'] ?? 0}') ?? 0);

  void _replaceLocalItems(List<dynamic> nextItems) {
    final next = Map<String, dynamic>.from(orderData ?? const {});
    next['items'] = nextItems;
    orderData = next;
  }

  void _applyFastServerItem(Map serverItem, int optimisticId) {
    final current = List<dynamic>.from(allItems);
    current.removeWhere((raw) => raw is Map && '${raw['id']}' == '$optimisticId');
    final sid = '${serverItem['id'] ?? ''}';
    final idx = current.indexWhere((raw) => raw is Map && '${raw['id']}' == sid);
    if (idx >= 0) {
      final existing = Map<String, dynamic>.from(current[idx] as Map);
      final serverQty = int.tryParse('${serverItem['soluong']}') ?? 1;
      final existingQty = int.tryParse('${existing['soluong']}') ?? 0;
      existing.addAll(Map<String, dynamic>.from(serverItem));
      // Add-item responses can arrive out of order. Never let an older response
      // reduce a quantity already confirmed by a newer add response.
      if (existingQty > serverQty) existing['soluong'] = existingQty;
      existing['fic_optimistic'] = false;
      current[idx] = existing;
    } else {
      final committed = Map<String, dynamic>.from(serverItem);
      committed['fic_optimistic'] = false;
      current.add(committed);
    }
    _replaceLocalItems(current);
  }

  void _applyFastOrderMeta(Map result) {
    final code = '${result['madonhang'] ?? ''}'.trim();
    final next = Map<String, dynamic>.from(orderData ?? const {});
    if (code.isNotEmpty) {
      final oldOrder = (next['order'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      oldOrder['madonhang'] = code;
      if (result['tongtien'] != null) oldOrder['tongtien'] = result['tongtien'];
      if (result['tongsoluong'] != null) oldOrder['tongsoluong'] = result['tongsoluong'];
      next['order'] = oldOrder;
    }
    orderData = next;
    final v = '${result['sync_version'] ?? ''}'.trim();
    if (v.isNotEmpty) _orderVersion = v;
  }

  Future<void> add(Map product) async {
    if (_offlineNow) {
      final nextData = _ensureLocalOrderData();
      final items = List<dynamic>.from((nextData['items'] as List?) ?? const []);
      final id = -DateTime.now().microsecondsSinceEpoch;
      final localItem = <String,dynamic>{'id':id,'id_sanpham':product['id'],'soluong':1,'dongia':productPrice(product),'ghichu':'','fic_is_topping':0,'offline':true,'tensanpham':product['tensanpham'],'sanpham':<String,dynamic>{'tensanpham':product['tensanpham']}};
      items.add(localItem);
      nextData['items'] = items;
      if (mounted) setState(() { orderData = nextData; _markPricingChanged(); });
      await _queueCurrentOffline();
      if ((product['fic_has_topping'] == true || '${product['fic_has_topping']}' == '1') && mounted) {
        await configureItem(localItem);
      }
      return;
    }

    final optimisticId = -DateTime.now().millisecondsSinceEpoch - (++_optimisticSequence);
    final optimistic = <String, dynamic>{
      'id': optimisticId,
      'id_sanpham': product['id'],
      'soluong': 1,
      'dongia': productPrice(product),
      'ghichu': '',
      'fic_is_topping': 0,
      'fic_optimistic': true,
      'tensanpham': product['tensanpham'],
      'sanpham': <String, dynamic>{'tensanpham': product['tensanpham']},
    };
    if (mounted) setState(() { _replaceLocalItems([...allItems, optimistic]); _markPricingChanged(); });

    _fastMutationInFlight++;
    try {
      final result = await api.post('/orders/items', {
        'table_id': tableId,
        'product_id': product['id'],
      });
      final item = result['item'];
      if (mounted) {
        setState(() {
          if (item is Map) {
            _applyFastServerItem(Map<String, dynamic>.from(item), optimisticId);
          } else {
            final current = List<dynamic>.from(allItems)
              ..removeWhere((raw) => raw is Map && '${raw['id']}' == '$optimisticId');
            _replaceLocalItems(current);
          }
          _applyFastOrderMeta(Map<String, dynamic>.from(result));
          _markPricingChanged();
        });
        unawaited(_refreshOfficialPreview(_pricingRevision));
      }
      if ((product['fic_has_topping'] == true || '${product['fic_has_topping']}' == '1') && item is Map && mounted) {
        await configureItem(Map<String, dynamic>.from(item));
      }
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        final nextData = _ensureLocalOrderData();
        final items = List<dynamic>.from((nextData['items'] as List?) ?? const []);
        final idx = items.indexWhere((x) => x is Map && '${x['id']}' == '$optimisticId');
        if (idx >= 0) {
          final committed = Map<String, dynamic>.from(items[idx] as Map);
          committed['fic_optimistic'] = false;
          committed['offline'] = true;
          items[idx] = committed;
        } else {
          final committed = Map<String, dynamic>.from(optimistic);
          committed['fic_optimistic'] = false;
          committed['offline'] = true;
          items.add(committed);
        }
        nextData['items'] = items;
        if (mounted) setState(() { orderData = nextData; _markPricingChanged(); });
        await _queueCurrentOffline();
        _toast('Đã lưu món ngoại tuyến. Sẽ tự đồng bộ khi có Internet.');
      } else {
        if (mounted) {
          setState(() {
            final current = List<dynamic>.from(allItems)
              ..removeWhere((raw) => raw is Map && '${raw['id']}' == '$optimisticId');
            _replaceLocalItems(current);
            _markPricingChanged();
          });
        }
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      _fastMutationInFlight = _fastMutationInFlight > 0 ? _fastMutationInFlight - 1 : 0;
    }
  }

  Future<void> quantity(Map detail, int quantity) async {
    if (quantity < 1) return remove(detail);
    if (_offlineNow) {
      final next = List<dynamic>.from(allItems).map((raw) { if (raw is Map && '${raw['id']}' == '${detail['id']}') { final changed=Map<String,dynamic>.from(raw); changed['soluong']=quantity; changed['offline']=true; return changed; } return raw; }).toList();
      final nextData=_ensureLocalOrderData(); nextData['items']=next;
      if (mounted) setState(() { orderData=nextData; _markPricingChanged(); });
      await _queueCurrentOffline();
      return;
    }

    final detailId = int.tryParse('${detail['id']}') ?? 0;
    if (detailId <= 0) return;
    final next = List<dynamic>.from(allItems).map((raw) {
      if (raw is Map && '${raw['id']}' == '$detailId') {
        final changed = Map<String,dynamic>.from(raw);
        changed['soluong'] = quantity;
        return changed;
      }
      return raw;
    }).toList();
    if (mounted) setState(() { _replaceLocalItems(next); _markPricingChanged(); });

    _quantityTimers[detailId]?.cancel();
    _quantityTimers[detailId] = Timer(const Duration(milliseconds: 250), () {
      _quantityTimers.remove(detailId);
      _flushQuantity(detailId, int.tryParse('${detail['id_sanpham']}') ?? 0);
    });
  }

  Future<void> _flushQuantity(int detailId, int productId) async {
    if (!mounted || _offlineNow) return;
    Map? current;
    for (final raw in allItems) {
      if (raw is Map && '${raw['id']}' == '$detailId') { current = raw; break; }
    }
    if (current == null) return;
    final desired = int.tryParse('${current['soluong']}') ?? 1;
    final code = orderCode;
    if (code == null || code.isEmpty) return;

    _fastMutationInFlight++;
    try {
      final result = await api.post('/orders/items/quantity', {
        'madonhang': code,
        'detail_id': detailId,
        'product_id': productId,
        'quantity': desired,
      });
      if (!mounted) return;
      setState(() {
        // Only apply the server quantity when the user has not tapped again
        // while this request was in flight.
        final latest = allItems.where((raw) => raw is Map && '${raw['id']}' == '$detailId').cast<Map>().toList();
        final latestQty = latest.isEmpty ? desired : (int.tryParse('${latest.first['soluong']}') ?? desired);
        final serverItem = result['detail'];
        if (serverItem is Map && latestQty == desired) {
          final rows = List<dynamic>.from(allItems);
          final idx = rows.indexWhere((raw) => raw is Map && '${raw['id']}' == '$detailId');
          if (idx >= 0) {
            final merged = Map<String,dynamic>.from(rows[idx] as Map)..addAll(Map<String,dynamic>.from(serverItem));
            rows[idx] = merged;
            _replaceLocalItems(rows);
          }
        }
        _applyFastOrderMeta(<String,dynamic>{
          'madonhang': code,
          'tongtien': result['tongtien'],
          'tongsoluong': result['tongsoluong'],
          'sync_version': result['sync_version'],
        });
        _markPricingChanged();
      });
      unawaited(_refreshOfficialPreview(_pricingRevision));
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        final nextData = _ensureLocalOrderData();
        nextData['items'] = List<dynamic>.from(allItems);
        if (mounted) setState(() { orderData = nextData; _markPricingChanged(); });
        await _queueCurrentOffline();
        _toast('Đã lưu thay đổi ngoại tuyến.');
      } else {
        _toast(e.toString().replaceFirst('Exception: ', ''));
        await load(madonhang: code);
      }
    } finally {
      _fastMutationInFlight = _fastMutationInFlight > 0 ? _fastMutationInFlight - 1 : 0;
    }
  }

  Future<void> remove(Map detail) async {
    if (_offlineNow) {
      final next=List<dynamic>.from(allItems).where((raw)=>raw is! Map || '${raw['id']}'!='${detail['id']}').toList();
      final nextData=_ensureLocalOrderData(); nextData['items']=next;
      if (mounted) setState(() { orderData=nextData; _markPricingChanged(); });
      await _queueCurrentOffline();
      return;
    }
    final before = List<dynamic>.from(allItems);
    final next = before.where((raw) => raw is! Map || '${raw['id']}' != '${detail['id']}').toList();
    if (mounted) setState(() { _replaceLocalItems(next); _markPricingChanged(); });
    try {
      final result = await api.post('/orders/items/remove', {
        'madonhang': orderCode,
        'detail_id': detail['id'],
        'product_id': detail['id_sanpham'],
      });
      final closed = result['order_closed'] == true || '${result['order_closed']}' == '1';
      if (closed) {
        final nextCode = '${result['next_madonhang'] ?? ''}'.trim();
        if (nextCode.isNotEmpty) {
          // Bàn còn đơn khác: chuyển sang đơn còn lại, không giải phóng bàn.
          await load(madonhang: nextCode);
        } else if (mounted) {
          // Đây là đơn cuối cùng của bàn: backend đã trả bàn về trống.
          Navigator.of(context).pop(true);
        }
      } else {
        // Keep the optimistic totals/promotion visible; confirm official pricing in background.
        unawaited(_refreshOfficialPreview(_pricingRevision));
      }
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        final nextData = _ensureLocalOrderData();
        nextData['items'] = next;
        if (mounted) setState(() { orderData = nextData; _markPricingChanged(); });
        await _queueCurrentOffline();
        _toast('Đã lưu thay đổi ngoại tuyến.');
      } else {
        if (mounted) setState(() { _replaceLocalItems(before); _markPricingChanged(); });
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  List<Map> childToppings(Map parent) => allItems
      .where((e) {
        final d = e as Map;
        return '${d['fic_is_topping'] ?? 0}' == '1' &&
            '${d['fic_parent_detail_id']}' == '${parent['id']}';
      })
      .cast<Map>()
      .toList();

  List _cachedToppingOptions(int productId) {
    final raw = widget.bootstrap['topping_map'];
    if (raw is! Map) return const [];
    final rows = raw['$productId'] ?? raw[productId];
    return rows is List ? List<dynamic>.from(rows) : const [];
  }

  void _applyLocalTopping(Map detail, Map topping, int quantity) {
    final parentId = int.tryParse('${detail['id']}') ?? 0;
    final toppingId = int.tryParse('${topping['id']}') ?? 0;
    if (parentId == 0 || toppingId <= 0) return;
    final rows = List<dynamic>.from(allItems);
    final idx = rows.indexWhere((raw) => raw is Map &&
        '${raw['fic_is_topping'] ?? 0}' == '1' &&
        '${raw['fic_parent_detail_id']}' == '$parentId' &&
        '${raw['id_sanpham']}' == '$toppingId');
    if (quantity <= 0) {
      if (idx >= 0) rows.removeAt(idx);
    } else if (idx >= 0) {
      final changed = Map<String, dynamic>.from(rows[idx] as Map);
      changed['soluong'] = quantity;
      changed['dongia'] = num.tryParse('${topping['gia']}') ?? changed['dongia'] ?? 0;
      if (_offlineNow) changed['offline'] = true;
      rows[idx] = changed;
    } else {
      rows.add(<String, dynamic>{
        'id': -DateTime.now().microsecondsSinceEpoch - (++_optimisticSequence),
        'id_sanpham': toppingId,
        'soluong': quantity,
        'dongia': num.tryParse('${topping['gia']}') ?? 0,
        'ghichu': '',
        'trangthai': 1,
        'fic_parent_detail_id': parentId,
        'fic_is_topping': 1,
        'fic_optimistic': !_offlineNow,
        'offline': _offlineNow,
        'tensanpham': topping['ten'] ?? 'Topping',
        'sanpham': <String, dynamic>{'tensanpham': topping['ten'] ?? 'Topping'},
      });
    }
    if (mounted) {
      setState(() {
        _replaceLocalItems(rows);
        _markPricingChanged();
      });
    }
  }

  Future<void> _sendToppingMutation(Map<String, dynamic> payload, int revision) async {
    if (_offlineNow) {
      await _queueCurrentOffline();
      return;
    }
    try {
      final result = await api.post('/orders/items/topping', {
        'parent_detail_id': payload['parent_detail_id'],
        'topping_id': payload['topping_id'],
        'quantity': payload['quantity'],
      });
      if (!mounted) return;
      // Do not reload the full order here. Keep the instant local state and only
      // refresh authoritative pricing in background after the server confirms.
      final code = '${result['madonhang'] ?? orderCode ?? ''}'.trim();
      if (code.isNotEmpty) {
        setState(() {
          _applyFastOrderMeta(<String, dynamic>{
            'madonhang': code,
            'tongtien': result['tongtien'],
            'tongsoluong': result['tongsoluong'],
          });
        });
      }
      unawaited(_refreshOfficialPreview(revision));
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        await _queueCurrentOffline();
        _toast('Đã lưu topping ngoại tuyến. Sẽ tự đồng bộ khi có Internet.');
      } else {
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _commitToppingKey(String key) async {
    final inFlight = _toppingInFlight[key];
    if (inFlight != null) {
      await inFlight;
      if (_pendingToppings.containsKey(key)) return _commitToppingKey(key);
      return;
    }
    final payload = _pendingToppings.remove(key);
    if (payload == null) return;
    final revision = int.tryParse('${payload['revision']}') ?? _pricingRevision;
    final future = _sendToppingMutation(payload, revision);
    _toppingInFlight[key] = future;
    try {
      await future;
    } finally {
      if (identical(_toppingInFlight[key], future)) _toppingInFlight.remove(key);
    }
    if (_pendingToppings.containsKey(key)) await _commitToppingKey(key);
  }

  Future<void> _setToppingFast(Map detail, Map topping, int quantity) async {
    final parentId = int.tryParse('${detail['id']}') ?? 0;
    final toppingId = int.tryParse('${topping['id']}') ?? 0;
    if (parentId == 0 || toppingId <= 0) return;
    _applyLocalTopping(detail, topping, quantity);
    final key = '$parentId:$toppingId';
    _pendingToppings[key] = <String, dynamic>{
      'parent_detail_id': parentId,
      'topping_id': toppingId,
      'quantity': quantity,
      'revision': _pricingRevision,
    };
    _toppingTimers[key]?.cancel();
    _toppingTimers[key] = Timer(const Duration(milliseconds: 220), () {
      _toppingTimers.remove(key);
      unawaited(_commitToppingKey(key));
    });
  }

  Future<void> _flushToppingsForParent(int parentId) async {
    final prefix = '$parentId:';
    final keys = <String>{
      ..._pendingToppings.keys.where((k) => k.startsWith(prefix)),
      ..._toppingTimers.keys.where((k) => k.startsWith(prefix)),
      ..._toppingInFlight.keys.where((k) => k.startsWith(prefix)),
    };
    for (final key in keys) {
      _toppingTimers.remove(key)?.cancel();
      await _commitToppingKey(key);
      final running = _toppingInFlight[key];
      if (running != null) await running;
      if (_pendingToppings.containsKey(key)) await _commitToppingKey(key);
    }
    if (_offlineNow) await _queueCurrentOffline();
  }

  Future<void> configureItem(Map detail) async {
    final productId = int.tryParse('${detail['id_sanpham']}') ?? 0;
    List toppings = _cachedToppingOptions(productId);
    // Backward-compatible fallback for a server/menu cache created before V255.27.
    // New versions normally never hit this request because topping_map is in bootstrap.
    if (!_offlineNow && toppings.isEmpty) {
      try {
        final result = await api.get('/products/$productId/toppings');
        toppings = (result['toppings'] as List?) ?? [];
        final map = widget.bootstrap['topping_map'] is Map
            ? Map<dynamic, dynamic>.from(widget.bootstrap['topping_map'] as Map)
            : <dynamic, dynamic>{};
        map['$productId'] = toppings;
        widget.bootstrap['topping_map'] = map;
      } catch (_) {}
    }
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ItemConfigSheet(
        detail: detail,
        toppingOptions: toppings,
        selectedToppings: childToppings(detail),
        onSetTopping: (toppingId, quantity) async {
          final matches = toppings.where((raw) => raw is Map && '${raw['id']}' == '$toppingId').cast<Map>().toList();
          if (matches.isEmpty) return;
          await _setToppingFast(detail, matches.first, quantity);
        },
        onAddNote: (note, applyQty) async {
          if (_offlineNow) {
            final items = List<dynamic>.from(allItems).map((raw) {
              if (raw is Map && '${raw['id']}' == '${detail['id']}') {
                final x = Map<String, dynamic>.from(raw);
                x['ghichu'] = note;
                x['offline'] = true;
                return x;
              }
              return raw;
            }).toList();
            if (mounted) setState(() => _replaceLocalItems(items));
            await _queueCurrentOffline();
            return;
          }
          await api.post('/orders/items/note', {
            'detail_id': detail['id'],
            'note': note,
            'apply_quantity': applyQty,
          });
        },
      ),
    );

    final parentId = int.tryParse('${detail['id']}') ?? 0;
    await _flushToppingsForParent(parentId);
    if (_offlineNow) return;
    try {
      await api.post('/orders/items/finalize', {'detail_id': detail['id']});
    } catch (_) {}
    // One authoritative reload when leaving the configuration sheet replaces the old
    // reload-after-every-tap behavior and preserves the existing order/finalize flow.
    await load(madonhang: orderCode);
  }

  Map<String, dynamic> _offlinePrintData(String kind, {Map<String, dynamic>? payment}) {
    final previewData = effectivePreview ?? OfflinePromotionEngine.evaluate(
      orderData: orderData ?? _ensureLocalOrderData(),
      bootstrap: widget.bootstrap,
    );
    final order = Map<String, dynamic>.from((orderData?['order'] as Map?) ?? const {});
    order['madonhang'] ??= orderCode ?? _offlineOrderCode(tableId);
    order['ban'] ??= orderData?['table']?['tenban'] ?? widget.table['tenban'] ?? widget.table['ten'];
    order['tongtien'] = num.tryParse('${previewData['tongtien'] ?? _rawTotal()}') ?? _rawTotal();
    order['giamgia'] = num.tryParse('${previewData['giamgia'] ?? 0}') ?? 0;
    order['phaitra'] = num.tryParse('${previewData['phaitra'] ?? _rawTotal()}') ?? _rawTotal();

    final rows = mainItems.map((raw) {
      final item = Map<String, dynamic>.from(raw as Map);
      final qty = num.tryParse('${item['soluong'] ?? 1}') ?? 1;
      final price = num.tryParse('${item['dongia'] ?? 0}') ?? 0;
      item['thanhtien'] ??= qty * price;
      return item;
    }).toList();

    final bank = widget.bootstrap['bank'] is Map
        ? Map<String, dynamic>.from(widget.bootstrap['bank'] as Map)
        : <String, dynamic>{};
    final branch = widget.bootstrap['branch'] is Map
        ? Map<String, dynamic>.from(widget.bootstrap['branch'] as Map)
        : <String, dynamic>{};
    final print = <String, dynamic>{
      // Offline uses the same receipt renderer/layout as Web POS. Only the data
      // source changes to cached bootstrap + local order; VietQR stays local.
      'store_name': '${widget.bootstrap['store_name'] ?? 'FIC POS'}',
      'branch_name': '${branch['ten'] ?? ''}',
      'address': '${branch['diachi'] ?? ''}',
      'phone': '${branch['dienthoai'] ?? branch['sodienthoai'] ?? ''}',
      'payment_qr': '',
      'show_payment_qr': bank['bin'] != null && '${bank['bin']}'.trim().isNotEmpty
          && bank['account_no'] != null && '${bank['account_no']}'.trim().isNotEmpty,
      'bank': bank,
      'template': <String, dynamic>{
        'template_name': 'compact',
        'temp_title': 'ĐƠN TẠM TÍNH',
        'temp_footer': 'Vui lòng kiểm tra trước khi thanh toán.',
        'invoice_title': 'HÓA ĐƠN THANH TOÁN',
        'invoice_footer': 'Cảm ơn quý khách!',
        'temp_show_logo': '1',
        'temp_show_branch': '1',
        'temp_show_address': '1',
        'temp_show_phone': '1',
        'temp_show_customer': '1',
        'temp_show_staff': '1',
        'temp_show_payment_qr': '1',
        'invoice_show_payment_qr': '1',
      },
    };

    if (kind == 'temporary') {
      return <String, dynamic>{
        'kind': 'temporary',
        'bill': <String, dynamic>{'order': order, 'items': rows, 'print': print},
      };
    }

    final pay = Map<String, dynamic>.from(payment ?? (orderData?['offline_payment'] as Map?) ?? const {});
    pay['madonhang'] ??= order['madonhang'];
    pay['tongtien'] ??= order['tongtien'];
    pay['giamgia'] ??= order['giamgia'];
    pay['phaitra'] ??= order['phaitra'];
    return <String, dynamic>{
      'kind': 'invoice',
      'payment': pay,
      'order': order,
      'items': rows,
      'print': print,
    };
  }

  Future<void> _openOfflinePrint(String kind, {Map<String, dynamic>? payment}) async {
    if (!mounted) return;
    final local = _offlinePrintData(kind, payment: payment);
    await Navigator.push(context, MaterialPageRoute(
      builder: (_) => NativePrintPage(kind: kind, data: local),
    ));
  }

  Future<void> openPrint(String kind, String ref) async {
    if (_offlineNow) {
      await _openOfflinePrint(kind);
      return;
    }
    try {
      final result = await api.post('/print-data', {'kind': kind, 'ref': ref});
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => NativePrintPage(kind: kind, data: (result['data'] as Map?)?.cast<String, dynamic>() ?? result),
      ));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> printKitchenOrLabels(String type) async {
    final code = orderCode;
    if (_offlineNow) {
      if (code == null || code.isEmpty || mainItems.isEmpty) { _toast('Chưa có món để in'); return; }
      if (!mounted) return;
      final tableName='${orderData?['table']?['tenban'] ?? widget.table['tenban'] ?? ''}';
      await Navigator.push(context, MaterialPageRoute(builder:(_)=>KitchenLabelPrintPage(kind:type,orderCode:code,tableName:tableName,items:mainItems.cast<dynamic>())));
      return;
    }
    if (code == null || code.isEmpty) {
      _toast('Chưa có đơn hàng để in');
      return;
    }
    try {
      final result = await api.post('/kitchen/dispatch', {
        'madonhang': code,
        'print_type': type,
      });
      if (result['nothing_new'] == true) {
        _toast(type == 'kitchen' ? 'Không có món mới cần in phiếu bếp.' : 'Không có nhãn mới cần in.');
        return;
      }
      final key = type == 'kitchen' ? 'kitchen_items' : 'label_items';
      final rows = List.from(result[key] as List? ?? const []);
      if (rows.isEmpty) {
        _toast(type == 'kitchen' ? 'Không có món được cấu hình in bếp.' : 'Không có món được cấu hình in nhãn.');
        return;
      }
      if (!mounted) return;
      final tableName = '${orderData?['table']?['tenban'] ?? orderData?['order']?['tenban'] ?? widget.table['tenban'] ?? ''}';
      await Navigator.push(context, MaterialPageRoute(
        builder: (_) => KitchenLabelPrintPage(
          kind: type,
          orderCode: code,
          tableName: tableName,
          items: rows.cast<dynamic>(),
        ),
      ));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> requestCashierPayment() async {
    if (_offlineNow) { _toast('Yêu cầu thu ngân cần Internet. Khi offline hãy dùng thanh toán trực tiếp theo quyền đã cache.'); return; }
    final code = orderCode;
    if (code == null || code.isEmpty || paymentRequestPending || _paymentRequestSending) return;
    setState(() => _paymentRequestSending = true);
    try {
      final r = await api.post('/orders/payment-request', {'madonhang': code});
      if (!mounted) return;
      setState(() => paymentRequestPending = true);
      HapticFeedback.mediumImpact();
      await showDialog<void>(context: context, builder: (dc) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined, size: 46),
        title: Text(r['already_pending'] == true ? 'Đang chờ thu ngân' : 'Đã gửi thu ngân'),
        content: Text('${r['message'] ?? 'Yêu cầu thanh toán đã được gửi.'}'),
        actions: [FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Đóng'))],
      ));
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
      await _refreshPaymentRequestStatus();
    } finally {
      if (mounted) setState(() => _paymentRequestSending = false);
    }
  }

  Future<void> pay(String method, {
    num? customerCash,
    num cashAmount = 0,
    num bankAmount = 0,
    num debtReceived = 0,
    String debtMethod = 'tienmat',
    String? dueDate,
    int redeemPoints = 0,
    Map<String,dynamic> einvoice = const <String,dynamic>{},
  }) async {
    if (orderCode == null) return;
    if (_offlineNow) {
      await _saveLocalPayment(method, customerCash: customerCash, cashAmount: cashAmount, bankAmount: bankAmount, debtReceived: debtReceived, debtMethod: debtMethod, dueDate: dueDate, redeemPoints: redeemPoints);
      return;
    }
    try {
      final response = await api.post('/orders/pay', {
        'madonhang': orderCode,
        'phuongthuc': method,
        if (customerCash != null) 'tien_khach_dua': customerCash,
        if (method == 'ket_hop') 'tienmat': cashAmount,
        if (method == 'ket_hop') 'chuyenkhoan': bankAmount,
        if (method == 'ghi_no') 'thu_truoc': debtReceived,
        if (method == 'ghi_no') 'phuongthuc_thu_truoc': debtMethod,
        if (method == 'ghi_no' && dueDate != null && dueDate.isNotEmpty) 'han_thanh_toan': dueDate,
        if (redeemPoints > 0) 'redeem_points': redeemPoints,
        ...einvoice,
      });
      if (!mounted) return;
      final payment = (response['data'] as Map?)?.cast<String, dynamic>() ?? {};
      final paymentId = '${payment['payment_id'] ?? ''}';
      final amount = num.tryParse('${payment['phaitra'] ?? payable}') ?? payable;
      final change = num.tryParse('${payment['tien_thoi'] ?? 0}') ?? 0;
      final debt = num.tryParse('${payment['con_no'] ?? 0}') ?? 0;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dc) => AlertDialog(
          icon: Icon(debt > 0 ? Icons.receipt_long_outlined : Icons.check_circle, size: 48),
          title: Text(debt > 0 ? 'Đã ghi nhận bán nợ' : 'Thanh toán thành công'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Hóa đơn: ${payment['ma_thanhtoan'] ?? ''}'),
              Text('Tổng phải trả: ${money(amount)} đ'),
              if (debt > 0) Text('Còn nợ: ${money(debt)} đ', style: const TextStyle(fontWeight: FontWeight.w800)),
              if (change > 0) Text('Tiền thừa: ${money(change)} đ'),
            ],
          ),
          actions: [
            if (paymentId.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => openPrint('invoice', paymentId),
                icon: const Icon(Icons.print_outlined),
                label: const Text('In hóa đơn'),
              ),
            FilledButton(onPressed: () => Navigator.pop(dc), child: const Text('Xong')),
          ],
        ),
      );
      await Future<void>.delayed(Duration.zero);
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop(true);
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        await _saveLocalPayment(method, customerCash: customerCash, cashAmount: cashAmount, bankAmount: bankAmount, debtReceived: debtReceived, debtMethod: debtMethod, dueDate: dueDate, redeemPoints: redeemPoints);
      } else {
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }


  Map<String, dynamic>? get effectivePreview {
    // V1.13.11: item quantity/selection and money/promotion must move together.
    // While a mutation is newer than the last server preview, render the cached local preview
    // immediately. Server preview is fetched in background and remains authoritative.
    if (orderData != null && (_offlineNow || _previewRevision != _pricingRevision || preview == null)) {
      return _livePreview ?? OfflinePromotionEngine.evaluate(orderData: orderData!, bootstrap: widget.bootstrap);
    }
    return preview;
  }

  num get subtotal => num.tryParse('${effectivePreview?['tongtien'] ?? _rawTotal()}') ?? 0;
  num get discount => num.tryParse('${effectivePreview?['giamgia'] ?? 0}') ?? 0;
  num get payable => num.tryParse('${effectivePreview?['phaitra'] ?? _rawTotal()}') ?? 0;

  List get activeOrders => (orderData?['orders'] as List?) ?? const [];
  List get priceLists => (orderData?['price_lists'] as List?) ?? const [];
  List get allTables => (widget.bootstrap['tables'] as List?) ?? const [];

  String tableName(Map t) => '${t['tenban'] ?? t['ten'] ?? 'Bàn ${t['id']}'}';
  bool tableAvailable(Map t) => '${t['trangthai'] ?? 1}' != '0';
  bool tableBusy(Map t) => '${t['trangthai'] ?? 1}' == '2';

  Future<int?> _pickTable(String title, {bool onlyEmpty = false}) async {
    final candidates = allTables.cast<Map>().where((t) {
      final id = int.tryParse('${t['id']}') ?? 0;
      if (id == tableId || !tableAvailable(t)) return false;
      return !onlyEmpty || !tableBusy(t);
    }).toList();
    if (!mounted) return null;
    return showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (bc) => FractionallySizedBox(
        heightFactor: .75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(children: [
              Expanded(child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
              IconButton(onPressed: () => Navigator.pop(bc), icon: const Icon(Icons.close)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(child: ListView.separated(
            itemCount: candidates.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final t = candidates[i];
              return ListTile(
                leading: Icon(tableBusy(t) ? Icons.table_bar : Icons.event_seat_outlined),
                title: Text(tableName(t), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(tableBusy(t) ? 'Đang sử dụng' : 'Bàn trống'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.pop(bc, int.tryParse('${t['id']}')),
              );
            },
          )),
        ]),
      ),
    );
  }

  Future<void> createNewOrder() async {
    if (_offlineNow) {
      if (orderData != null && orderCode != null) await _queueCurrentOffline();
      final pending=await OfflineStore.pendingForTable(tableId);
      final code=_offlineOrderCode(tableId);
      final header=<String,dynamic>{'madonhang':code,'id_ban':tableId,'trangthai':1,'offline':true,'giovao':DateTime.now().toIso8601String()};
      final headers=<Map<String,dynamic>>[];for(final row in pending){final payload=row['payload'];if(payload is Map && payload['order'] is Map)headers.add(Map<String,dynamic>.from(payload['order'] as Map));}headers.add(header);
      final next=<String,dynamic>{'table':widget.table,'order':header,'orders':headers,'items':<dynamic>[],'price_lists':orderData?['price_lists']??const [],'payment_policy':orderData?['payment_policy']??const {'require_cashier_request':false,'can_take_payment':true},'offline':true};next['offline_client_id']=OfflineStore.ensureClientId(next,tableId);if(mounted)setState((){orderData=next;preview=null;});await _queueCurrentOffline();return;
    }
    try {
      final r = await api.post('/tables/$tableId/orders', {});
      final code = '${(r['order'] as Map?)?['madonhang'] ?? ''}';
      await load(madonhang: code.isEmpty ? null : code);
      _toast('Đã tạo đơn mới');
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        if (orderData != null && orderCode != null) await _queueCurrentOffline();
        final pending = await OfflineStore.pendingForTable(tableId);
        final code = _offlineOrderCode(tableId);
        final header = <String,dynamic>{'madonhang': code, 'id_ban': tableId, 'trangthai': 1, 'offline': true, 'giovao': DateTime.now().toIso8601String()};
        final headers = <Map<String,dynamic>>[];
        for (final row in pending) {
          final payload = row['payload'];
          if (payload is Map && payload['order'] is Map) headers.add(Map<String,dynamic>.from(payload['order'] as Map));
        }
        headers.add(header);
        final next = <String,dynamic>{
          'table': widget.table,
          'order': header,
          'orders': headers,
          'items': <dynamic>[],
          'price_lists': orderData?['price_lists'] ?? const [],
          'payment_policy': orderData?['payment_policy'] ?? const {'require_cashier_request': false, 'can_take_payment': true},
          'offline': true,
        };
        next['offline_client_id'] = OfflineStore.ensureClientId(next, tableId);
        if (mounted) setState(() { orderData = next; preview = null; });
        await _queueCurrentOffline();
        _toast('Đã tạo đơn mới ngoại tuyến');
      } else {
        _toast(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> selectOrder(String code) async {
    if (_offlineNow) {
      final row=await OfflineStore.pendingByOrderCode(tableId,code);
      if(row!=null && row['payload'] is Map && mounted){final next=Map<String,dynamic>.from(row['payload'] as Map);final pending=await OfflineStore.pendingForTable(tableId);next['orders']=pending.where((x)=>x['payload'] is Map && (x['payload'] as Map)['order'] is Map).map((x)=>Map<String,dynamic>.from((x['payload'] as Map)['order'] as Map)).toList();setState((){orderData=next;preview=null;});}return;
    }
    try {
      await api.post('/orders/activate', {'madonhang': code, 'table_id': tableId});
      await load(madonhang: code);
    } catch (e) {
      if (_isNetworkError(e)) {
        await _enterOfflineMode();
        final row = await OfflineStore.pendingByOrderCode(tableId, code);
        if (row != null && row['payload'] is Map && mounted) {
          final next = Map<String,dynamic>.from(row['payload'] as Map);
          final pending = await OfflineStore.pendingForTable(tableId);
          next['orders'] = pending.where((x)=>x['payload'] is Map && (x['payload'] as Map)['order'] is Map)
              .map((x)=>Map<String,dynamic>.from((x['payload'] as Map)['order'] as Map)).toList();
          setState(() { orderData = next; preview = null; });
          return;
        }
      }
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> choosePriceList() async {
    if (orderCode == null || priceLists.isEmpty) return;
    final selected = await showModalBottomSheet<Map>(
      context: context,
      useSafeArea: true,
      builder: (bc) => ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Chọn bảng giá', style: TextStyle(fontWeight: FontWeight.w800))),
          ...priceLists.cast<Map>().map((x) => ListTile(
            title: Text('${x['ten'] ?? x['ma'] ?? 'Bảng giá'}'),
            subtitle: Text('${x['phantram'] ?? 0}%'),
            onTap: () => Navigator.pop(bc, x),
          )),
        ],
      ),
    );
    if (selected == null) return;
    try {
      if (_offlineNow) {
        await ficQueueBusinessAction('price_list', {'madonhang': orderCode, 'price_list_id': selected['id']});
        final prices = selected['prices'];
        if (prices is Map) {
          priceOverrides.clear();
          prices.forEach((k,v){final id=int.tryParse('$k');final price=num.tryParse('$v');if(id!=null&&price!=null)priceOverrides[id]=price;});
          for(final raw in allItems){final d=raw as Map;final pid=int.tryParse('${d['id_sanpham']??d['product_id']}');if(pid!=null&&priceOverrides[pid]!=null)d['dongia']=priceOverrides[pid];}
        }
        final order=orderData?['order'];if(order is Map)order['idbangia']=selected['id'];
        await _queueCurrentOffline(); if(mounted)setState((){preview=null;}); _toast('Đã đổi bảng giá offline • chờ đồng bộ');
      } else {
        final r = await api.post('/orders/price-list', {'madonhang': orderCode, 'price_list_id': selected['id']});
        final prices = r['prices'];
        if (prices is Map) {
          priceOverrides.clear();
          prices.forEach((k, v) {final id = int.tryParse('$k'); final price = num.tryParse('$v');if (id != null && price != null) priceOverrides[id] = price;});
        }
        await load(madonhang: orderCode); _toast('Đã đổi bảng giá');
      }
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> chooseCustomer() async {
    if (_offlineNow) { _toast('Tìm/chọn khách hàng mới cần Internet. Đơn vẫn bán và thanh toán offline bình thường.'); return; }
    if (orderCode == null) return;
    final search = TextEditingController();
    Timer? debounce;
    List customers = [];
    bool busy = true, loadingMore = false, hasMore = true;
    int page = 1;

    Future<void> loadFirst() async {
      final q=Uri.encodeQueryComponent(search.text.trim());
      final r=await api.get('/customers?page=1&per_page=20${q.isEmpty?'':'&q=$q'}');
      customers=List.from(r['items'] as List? ?? []);
      page=1;
      hasMore=r['has_more']==true;
    }

    try { await loadFirst(); } catch (_) {}
    busy = false;
    if (!mounted) { search.dispose(); return; }
    final selected = await showModalBottomSheet<Map>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (bc) => StatefulBuilder(builder: (context, setLocal) {
        Future<void> find(String _) async {
          debounce?.cancel();
          debounce=Timer(const Duration(milliseconds:350),() async {
            if(!bc.mounted)return;
            setLocal(() { busy = true; loadingMore=false; });
            try { await loadFirst(); } catch (_) {}
            if(bc.mounted)setLocal(() => busy = false);
          });
        }
        Future<void> loadMore() async {
          if(busy||loadingMore||!hasMore)return;
          setLocal(()=>loadingMore=true);
          try{
            final next=page+1;
            final q=Uri.encodeQueryComponent(search.text.trim());
            final r=await api.get('/customers?page=$next&per_page=20${q.isEmpty?'':'&q=$q'}');
            customers.addAll(List.from(r['items'] as List? ?? []));
            page=next;
            hasMore=r['has_more']==true;
          }catch(_){}finally{if(bc.mounted)setLocal(()=>loadingMore=false);}
        }
        return FractionallySizedBox(heightFactor: .82, child: Column(children: [
          Padding(padding: const EdgeInsets.all(12), child: TextField(
            controller: search,
            onChanged: find,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Tìm tên / số điện thoại'),
          )),
          if (busy) const LinearProgressIndicator(),
          ListTile(leading: const Icon(Icons.person_off_outlined), title: const Text('Khách lẻ'), onTap: () => Navigator.pop(bc, {'id': null})),
          Expanded(child: NotificationListener<ScrollNotification>(
            onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},
            child:ListView.builder(
              itemCount: customers.length+(loadingMore?1:0),
              itemBuilder: (_, i) {
                if(i>=customers.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                final c = customers[i] as Map;
                return ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                  title: Text('${c['ten_khachhang'] ?? c['ma_khachhang'] ?? 'Khách hàng'}'),
                  subtitle: Text('${c['sodienthoai'] ?? ''}'),
                  onTap: () => Navigator.pop(bc, c),
                );
              },
            ),
          )),
        ]));
      }),
    );
    debounce?.cancel();
    search.dispose();
    if (selected == null) return;
    try {
      await api.post('/orders/customer', {'madonhang': orderCode, 'customer_id': selected['id']});
      await load(madonhang: orderCode);
      _toast('Đã cập nhật khách hàng');
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> changeTable() async {
    if (orderCode == null) return;
    final target = await _pickTable('Đổi bàn', onlyEmpty: true);
    if (target == null) return;
    try {
      if(_offlineNow){await ficQueueBusinessAction('change_table',{'madonhang':orderCode,'source_table_id':tableId,'target_table_id':target});_toast('Đã ghi nhận đổi bàn offline • chờ đồng bộ');}
      else{await api.post('/orders/change-table', {'madonhang': orderCode, 'source_table_id': tableId, 'target_table_id': target});_toast('Đổi bàn thành công');}
      if (mounted) Navigator.pop(context, true);
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> moveOrder() async {
    if (orderCode == null) return;
    final target = await _pickTable('Chuyển đơn sang bàn');
    if (target == null) return;
    try {
      if(_offlineNow){await ficQueueBusinessAction('move_order',{'madonhang':orderCode,'target_table_id':target});_toast('Đã ghi nhận chuyển đơn offline • chờ đồng bộ');}
      else{await api.post('/orders/move', {'madonhang': orderCode, 'target_table_id': target});_toast('Đã chuyển đơn');}
      if (mounted) Navigator.pop(context, true);
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> mergeCurrentOrder() async {
    if (orderCode == null) return;
    final others = activeOrders.cast<Map>().where((o) => '${o['madonhang']}' != orderCode).toList();
    if (others.isEmpty) { _toast('Bàn này chưa có đơn khác để gộp'); return; }
    final target = await showModalBottomSheet<Map>(
      context: context, useSafeArea: true,
      builder: (bc) => ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Gộp đơn hiện tại vào', style: TextStyle(fontWeight: FontWeight.w800))),
        ...others.map((o) => ListTile(
          leading: const Icon(Icons.receipt_long_outlined),
          title: Text('${o['madonhang']}'),
          subtitle: Text('${money(num.tryParse('${o['tongtien'] ?? 0}') ?? 0)} đ'),
          onTap: () => Navigator.pop(bc, o),
        )),
      ]),
    );
    if (target == null) return;
    try {
      if(_offlineNow){await ficQueueBusinessAction('merge_orders',{'source_madonhang':orderCode,'target_madonhang':target['madonhang']});_toast('Đã ghi nhận gộp đơn offline • chờ đồng bộ');if(mounted)Navigator.pop(context,true);}
      else{final r = await api.post('/orders/merge', {'source_madonhang': orderCode, 'target_madonhang': target['madonhang']});await load(madonhang: '${r['target_madonhang'] ?? target['madonhang']}');_toast('Đã gộp đơn');}
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> mergeTable() async {
    final target = await _pickTable('Gộp bàn hiện tại sang bàn');
    if (target == null) return;
    try {
      if(_offlineNow){await ficQueueBusinessAction('merge_tables',{'source_table_id':tableId,'target_table_id':target});_toast('Đã ghi nhận gộp bàn offline • chờ đồng bộ');}
      else{await api.post('/tables/merge', {'source_table_id': tableId, 'target_table_id': target});_toast('Đã gộp bàn');}
      if (mounted) Navigator.pop(context, true);
    } catch (e) { _toast(e.toString()); }
  }

  Future<void> splitOrder() async {
    if (orderCode == null || mainItems.isEmpty) return;
    final target = await _pickTable('Tách món sang bàn');
    if (target == null || !mounted) return;
    final qty = <int, int>{};
    for (final item in mainItems.cast<Map>()) qty[int.parse('${item['id']}')] = 0;
    final chosen = await showModalBottomSheet<List<Map<String, int>>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (bc) => StatefulBuilder(builder: (context, setLocal) => FractionallySizedBox(
        heightFactor: .82,
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16,14,8,8), child: Row(children: [
            const Expanded(child: Text('Chọn món cần tách', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            IconButton(onPressed: () => Navigator.pop(bc), icon: const Icon(Icons.close)),
          ])),
          Expanded(child: ListView.builder(itemCount: mainItems.length, itemBuilder: (_, i) {
            final d = mainItems[i] as Map;
            final id = int.parse('${d['id']}');
            final maxQ = (num.tryParse('${d['soluong']}') ?? 1).round();
            final q = qty[id] ?? 0;
            final sp = d['sanpham'] as Map?;
            return ListTile(
              title: Text('${sp?['tensanpham'] ?? d['tensanpham'] ?? 'Món'}'),
              subtitle: Text('Đang có: $maxQ'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(onPressed: q <= 0 ? null : () => setLocal(() => qty[id] = q - 1), icon: const Icon(Icons.remove_circle_outline)),
                Text('$q', style: const TextStyle(fontWeight: FontWeight.w800)),
                IconButton(onPressed: q >= maxQ ? null : () => setLocal(() => qty[id] = q + 1), icon: const Icon(Icons.add_circle_outline)),
              ]),
            );
          })),
          Padding(padding: const EdgeInsets.all(16), child: SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: () {
              final out = qty.entries.where((e) => e.value > 0).map((e) {
                final item = mainItems.cast<Map>().firstWhere((x) => int.tryParse('${x['id']}') == e.key, orElse: () => <String,dynamic>{});
                return <String, int>{
                  'id_chitiet': e.key,
                  'soluong': e.value,
                  'product_id': int.tryParse('${item['id_sanpham'] ?? item['product_id'] ?? 0}') ?? 0,
                };
              }).toList();
              if (out.isEmpty) return;
              Navigator.pop(bc, out);
            },
            icon: const Icon(Icons.call_split), label: const Text('Xác nhận tách món'),
          ))),
        ]),
      )),
    );
    if (chosen == null || chosen.isEmpty) return;
    try {
      if(_offlineNow){await ficQueueBusinessAction('split_order',{'madonhang':orderCode,'target_table_id':target,'items':chosen});_toast('Đã ghi nhận tách món offline • chờ đồng bộ');if(mounted)Navigator.pop(context,true);}
      else{await api.post('/orders/split', {'madonhang': orderCode, 'target_table_id': target, 'items': chosen});await load();_toast('Đã tách món sang bàn khác');}
    } catch (e) { _toast(e.toString()); }
  }

  void openTableActions() {
    showModalBottomSheet(
      context: context, useSafeArea: true,
      builder: (bc) => Wrap(children: [
        const ListTile(title: Text('Tách / Gộp bàn', style: TextStyle(fontWeight: FontWeight.w800))),
        ListTile(leading: const Icon(Icons.call_split), title: const Text('Tách món sang bàn khác'), onTap: () { Navigator.pop(bc); splitOrder(); }),
        ListTile(leading: const Icon(Icons.layers_outlined), title: const Text('Gộp bàn'), subtitle: const Text('Chuyển toàn bộ đơn của bàn này sang bàn khác'), onTap: () { Navigator.pop(bc); mergeTable(); }),
      ]),
    );
  }

  void openOrderActions() {
    showModalBottomSheet(
      context: context, useSafeArea: true,
      builder: (bc) => Wrap(children: [
        const ListTile(title: Text('Chuyển / Gộp đơn', style: TextStyle(fontWeight: FontWeight.w800))),
        ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Chuyển đơn'), subtitle: const Text('Giữ riêng đơn, có thể chuyển vào bàn đang dùng'), onTap: () { Navigator.pop(bc); moveOrder(); }),
        ListTile(leading: const Icon(Icons.merge_type), title: const Text('Gộp đơn'), subtitle: const Text('Gộp với một đơn khác cùng bàn'), onTap: () { Navigator.pop(bc); mergeCurrentOrder(); }),
      ]),
    );
  }

  num _rawTotal() => allItems.fold<num>(0, (sum, e) {
        final d = e as Map;
        return sum +
            (num.tryParse('${d['dongia'] ?? 0}') ?? 0) *
                (num.tryParse('${d['soluong'] ?? 1}') ?? 1);
      });

  Future<void> openWebModule(String module) async {
    Navigator.pop(context);
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ficModulePage(module)),
    );
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text.replaceFirst('Exception: ', ''))));

  @override
  Widget build(BuildContext context) {
    final categories = (widget.bootstrap['categories'] as List?) ?? [];
    final promos = (effectivePreview?['promotions'] as List?) ?? [];
    final gifts = (effectivePreview?['gifts'] as List?) ?? [];

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${widget.table['tenban'] ?? widget.table['ten'] ?? 'Bàn'}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            if (orderCode != null)
              Text(orderCode!, style: const TextStyle(fontSize: 11, color: Colors.black54)),
          ],
        ),
        actions: [IconButton(onPressed: load, icon: const Icon(Icons.refresh))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_offlineNow)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    color: Colors.orange.shade100,
                    child: const Row(children: [Icon(Icons.cloud_off_outlined, size: 18), SizedBox(width: 8), Expanded(child: Text('Đang ngoại tuyến • Mọi thay đổi được lưu trên máy và sẽ tự đồng bộ', style: TextStyle(fontWeight: FontWeight.w700)))]),
                  ),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                  child: Column(children: [
                    SizedBox(
                      height: 44,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          ...activeOrders.asMap().entries.map((entry) {
                            final o = entry.value as Map;
                            final code = '${o['madonhang'] ?? ''}';
                            return Padding(
                              padding: const EdgeInsets.only(right: 7),
                              child: ChoiceChip(
                                label: Text('Đơn ${entry.key + 1}'),
                                selected: code == orderCode,
                                onSelected: (_) => selectOrder(code),
                              ),
                            );
                          }),
                          ActionChip(
                            avatar: const Icon(Icons.add, size: 18),
                            label: const Text('Đơn mới'),
                            onPressed: createNewOrder,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(onPressed: orderCode == null ? null : choosePriceList, icon: const Icon(Icons.sell_outlined), label: const Text('Bảng giá'))),
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton.icon(onPressed: orderCode == null ? null : chooseCustomer, icon: const Icon(Icons.person_search_outlined), label: const Text('Khách hàng'))),
                    ]),
                    const SizedBox(height: 6),
                    Row(children: [
                      Expanded(child: OutlinedButton(onPressed: orderCode == null ? null : changeTable, child: const Text('Đổi bàn'))),
                      const SizedBox(width: 6),
                      Expanded(child: OutlinedButton(onPressed: orderCode == null ? null : openTableActions, child: const Text('Tách / Gộp bàn'))),
                      const SizedBox(width: 6),
                      Expanded(child: OutlinedButton(onPressed: orderCode == null ? null : openOrderActions, child: const Text('Chuyển / Gộp đơn'))),
                    ]),
                  ]),
                ),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => query = v),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Tìm món / mã món',
                      filled: true,
                      border: OutlineInputBorder(borderSide: BorderSide.none),
                    ),
                  ),
                ),
                Container(
                  height: 50,
                  color: Colors.white,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    children: [
                      ChoiceChip(
                        label: const Text('Tất cả'),
                        selected: category == 'all',
                        onSelected: (_) => setState(() => category = 'all'),
                      ),
                      ...categories.map((e) {
                        final x = e as Map;
                        final id = '${x['id']}';
                        return Padding(
                          padding: const EdgeInsets.only(left: 7),
                          child: ChoiceChip(
                            label: Text('${x['tendanhmuc'] ?? x['ten'] ?? 'Danh mục'}'),
                            selected: category == id,
                            onSelected: (_) => setState(() => category = id),
                          ),
                        );
                      }),
                    ],
                  ),
                ),
                if (promos.isNotEmpty || gifts.isNotEmpty)
                  PromotionBanner(promotions: promos, gifts: gifts),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      childAspectRatio: 1.25,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: products.length,
                    itemBuilder: (_, i) {
                      final p = products[i] as Map;
                      final hasTopping = p['fic_has_topping'] == true ||
                          '${p['fic_has_topping']}' == '1';
                      return Card(
                        color: Colors.white,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => add(p),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text('${p['tensanpham'] ?? 'Món'}',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700,
                                              fontSize: 16)),
                                    ),
                                    if (hasTopping)
                                      const Icon(Icons.add_circle_outline,
                                          size: 18, color: Colors.orange),
                                  ],
                                ),
                                Text('ĐVT: ${p['donvitinh'] ?? 'cái'}', style: const TextStyle(fontSize: 11,color: Colors.black45)),
                                const Spacer(),
                                if (hasTopping)
                                  const Text('Có topping',
                                      style: TextStyle(
                                          fontSize: 11, color: Colors.black45)),
                                Text('${money(productPrice(p))} đ',
                                    style: TextStyle(
                                        color: Theme.of(context).colorScheme.primary,
                                        fontWeight: FontWeight.w800)),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (mainItems.isNotEmpty)
                  OrderBottomBar(
                    itemCount: mainItems.length,
                    subtotal: subtotal,
                    discount: discount,
                    payable: payable,
                    onOpen: () => openCart(context),
                  ),
              ],
            ),
    );
  }

  void openCart(BuildContext rootContext) {
    showModalBottomSheet(
      context: rootContext,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => FractionallySizedBox(
          heightFactor: .88,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                child: Row(
                  children: [
                    const Text('Đơn hàng',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const Spacer(),
                    IconButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close)),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: mainItems.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (_, i) {
                    final d = mainItems[i] as Map;
                    final sp = d['sanpham'] as Map?;
                    final q = (num.tryParse('${d['soluong']}') ?? 1).round();
                    final children = childToppings(d);
                    return InkWell(
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        await configureItem(d);
                        if (mounted) openCart(rootContext);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${sp?['tensanpham'] ?? d['tensanpham'] ?? 'Món'}',
                                      style: const TextStyle(
                                          fontSize: 16, fontWeight: FontWeight.w700)),
                                  Text('${money(num.tryParse('${d['dongia']}') ?? 0)} đ'),
                                  if ('${d['ghichu'] ?? ''}'.trim().isNotEmpty)
                                    Text('Ghi chú: ${d['ghichu']}',
                                        style: const TextStyle(
                                            fontSize: 12, color: Colors.deepOrange)),
                                  ...children.map((t) => Text(
                                      '+ ${(t['sanpham'] as Map?)?['tensanpham'] ?? t['tensanpham'] ?? 'Topping'} × ${t['soluong']}',
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.black54))),
                                  const SizedBox(height: 4),
                                  const Text('Chạm để chọn topping / ghi chú',
                                      style: TextStyle(fontSize: 11, color: Colors.black38)),
                                ],
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: () async {
                                    await quantity(d, q - 1);
                                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                                    if (mounted && mainItems.isNotEmpty) openCart(rootContext);
                                  },
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                Text('$q',
                                    style: const TextStyle(fontWeight: FontWeight.w700)),
                                IconButton(
                                  onPressed: () async {
                                    await quantity(d, q + 1);
                                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                                    if (mounted) openCart(rootContext);
                                  },
                                  icon: const Icon(Icons.add_circle_outline),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              Container(
                color: Colors.white,
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    MoneyRow('Tạm tính', subtotal),
                    if (discount > 0) MoneyRow('Khuyến mãi', -discount),
                    const Divider(),
                    MoneyRow('Khách cần trả', payable, strong: true),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.restaurant_menu),
                        label: const Text('Thêm món'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await printKitchenOrLabels('kitchen');
                          },
                          icon: const Icon(Icons.soup_kitchen_outlined),
                          label: const Text('Phiếu bếp'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            Navigator.pop(sheetContext);
                            await printKitchenOrLabels('labels');
                          },
                          icon: const Icon(Icons.local_offer_outlined),
                          label: const Text('In nhãn'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            showTemporaryBill(rootContext);
                          },
                          icon: const Icon(Icons.receipt_long_outlined),
                          label: const Text('Tạm tính'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: (requireCashierRequest && !canTakePayment && (paymentRequestPending || _paymentRequestSending))
                              ? null
                              : () {
                                  Navigator.pop(sheetContext);
                                  if (requireCashierRequest && !canTakePayment) {
                                    requestCashierPayment();
                                  } else {
                                    choosePayment(rootContext);
                                  }
                                },
                          icon: Icon(
                            requireCashierRequest && !canTakePayment
                                ? (paymentRequestPending ? Icons.hourglass_top_rounded : Icons.notifications_active_outlined)
                                : Icons.payments_outlined,
                          ),
                          label: Text(
                            requireCashierRequest && !canTakePayment
                                ? (paymentRequestPending
                                    ? 'Đang chờ thu ngân'
                                    : (_paymentRequestSending ? 'Đang gửi...' : 'Yêu cầu thanh toán'))
                                : 'Thanh toán',
                          ),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> showTemporaryBill(BuildContext context) async {
    final code = orderCode;
    if (code == null || code.isEmpty) {
      _toast('Chưa có đơn hàng để tạm tính');
      return;
    }
    try {
      // Offline must never call /temporary-bill. Build the preview from the
      // locally cached order/items so temporary printing (including VietQR)
      // remains available without DNS/network access.
      final Map<String, dynamic> data;
      if (_offlineNow) {
        final localPrint = _offlinePrintData('temporary');
        data = (localPrint['bill'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      } else {
        data = await api.get('/orders/$code/temporary-bill');
      }
      if (!mounted) return;
      final order = (data['order'] as Map?)?.cast<String, dynamic>() ?? {};
      final items = (data['items'] as List? ?? const []).cast<dynamic>();
      final subtotal = num.tryParse('${order['tongtien'] ?? 0}') ?? 0;
      final discount = num.tryParse('${order['giamgia'] ?? 0}') ?? 0;
      final payable = num.tryParse('${order['phaitra'] ?? 0}') ?? 0;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: .86,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(children: [
                  const Expanded(child: Text('Đơn tạm tính', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: const Icon(Icons.close)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(alignment: Alignment.centerLeft, child: Text('${order['ban'] ?? ''} • $code\nKhách: ${order['khachhang'] ?? 'Khách lẻ'}')),
              ),
              const Divider(),
              Expanded(child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: items.length,
                separatorBuilder: (_, __) => const Divider(height: 12),
                itemBuilder: (_, i) {
                  final x = (items[i] as Map).cast<String, dynamic>();
                  final tops = (x['toppings'] as List? ?? const []);
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('${x['ten'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      Text('${x['soluong'] ?? 0} × ${money(num.tryParse('${x['dongia'] ?? 0}') ?? 0)} đ'),
                    ]),
                    if ('${x['ghichu'] ?? ''}'.trim().isNotEmpty) Text('Ghi chú: ${x['ghichu']}', style: const TextStyle(fontSize: 12)),
                    ...tops.map((t) => Text('+ ${t['ten']} × ${t['soluong']}  ${money(num.tryParse('${t['thanhtien'] ?? 0}') ?? 0)} đ', style: const TextStyle(fontSize: 12))),
                  ]);
                },
              )),
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  MoneyRow('Tạm tính', subtotal),
                  if (discount > 0) MoneyRow('Khuyến mãi', -discount),
                  const Divider(),
                  MoneyRow('Khách cần trả', payable, strong: true),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: OutlinedButton.icon(
                      onPressed: () => openPrint('temporary', code),
                      icon: const Icon(Icons.print_outlined),
                      label: const Text('In tạm tính'),
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.check),
                      label: const Text('Đóng'),
                    )),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      );
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void choosePayment(BuildContext context) {
    final cash = TextEditingController(text: payable.round().toString());
    final mixedCash = TextEditingController(text: (payable / 2).round().toString());
    final mixedBank = TextEditingController(text: (payable - (payable / 2).round()).round().toString());
    final debtReceived = TextEditingController(text: '0');
    final redeemCtrl = TextEditingController(text: '0');
    final einvoiceCompany = TextEditingController();
    final einvoiceTaxCode = TextEditingController();
    final einvoiceAddress = TextEditingController();
    final einvoiceEmail = TextEditingController();
    final einvoiceBuyer = TextEditingController();
    final loyalty = (preview?['loyalty'] as Map?) ?? {};
    final einvoiceEnabled = preview?['einvoice_enabled'] == true || '${preview?['einvoice_enabled']}' == '1';
    bool requestEinvoice = false;
    final maxRedeemPoints = int.tryParse('${loyalty['max_redeem_points'] ?? 0}') ?? 0;
    final pointValue = num.tryParse('${loyalty['point_value'] ?? 0}') ?? 0;
    String method = 'tienmat';
    String debtMethod = 'tienmat';
    DateTime? dueDate;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (bc) => StatefulBuilder(builder: (bc, setSheetState) {
        final customerName = '${preview?['khachhang'] ?? 'Khách lẻ'}';
        final hasCustomer = customerName.trim().isNotEmpty && customerName != 'Khách lẻ';
        num value(TextEditingController c) => num.tryParse(c.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final redeemPoints = value(redeemCtrl).toInt().clamp(0, maxRedeemPoints).toInt();
        final loyaltyDiscount = redeemPoints * pointValue;
        final finalPayable = (payable - loyaltyDiscount).clamp(0, double.infinity);
        final mixedRemain = finalPayable - value(mixedCash) - value(mixedBank);
        final debtRemain = finalPayable - value(debtReceived);

        Widget methodButton(String valueKey, IconData icon, String label) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 5),
                backgroundColor: method == valueKey ? Theme.of(bc).colorScheme.primaryContainer : null,
              ),
              onPressed: () => setSheetState(() => method = valueKey),
              child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon), const SizedBox(height: 4), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12))]),
            ),
          ),
        );

        Future<void> submit() async {
          if (method == 'ket_hop' && mixedRemain.abs() > 0.01) {
            _toast('Tiền mặt + chuyển khoản phải đúng ${money(finalPayable)} đ');
            return;
          }
          if (method == 'ghi_no') {
            if (!hasCustomer) {
              _toast('Ghi nợ bắt buộc phải chọn khách hàng cho đơn.');
              return;
            }
            if (value(debtReceived) >= finalPayable) {
              _toast('Thu trước phải nhỏ hơn số tiền phải trả.');
              return;
            }
          }
          if (requestEinvoice) {
            if (einvoiceCompany.text.trim().isEmpty || einvoiceTaxCode.text.trim().isEmpty || einvoiceAddress.text.trim().isEmpty || einvoiceEmail.text.trim().isEmpty) {
              _toast('Vui lòng nhập đủ Tên công ty, Mã số thuế, Địa chỉ và Email nhận hóa đơn.');
              return;
            }
            if (!RegExp(r'^[0-9\-]{8,20}$').hasMatch(einvoiceTaxCode.text.trim())) {
              _toast('Mã số thuế chỉ được gồm chữ số và dấu gạch ngang.');
              return;
            }
          }
          if (method == 'chuyenkhoan') {
            final proceed = await _showTransferQr(finalPayable);
            if (!proceed) return;
          }
          Navigator.pop(bc);
          await pay(
            method,
            customerCash: method == 'tienmat' ? value(cash) : null,
            cashAmount: value(mixedCash),
            bankAmount: value(mixedBank),
            debtReceived: value(debtReceived),
            debtMethod: debtMethod,
            dueDate: dueDate == null ? null : '${dueDate!.year.toString().padLeft(4,'0')}-${dueDate!.month.toString().padLeft(2,'0')}-${dueDate!.day.toString().padLeft(2,'0')}',
            redeemPoints: redeemPoints,
            einvoice: requestEinvoice ? <String,dynamic>{
              'yeucau_hoadon': true,
              'hddt_ten_cong_ty': einvoiceCompany.text.trim(),
              'hddt_ma_so_thue': einvoiceTaxCode.text.trim(),
              'hddt_dia_chi': einvoiceAddress.text.trim(),
              'hddt_email': einvoiceEmail.text.trim(),
              'hddt_ten_nguoi_mua': einvoiceBuyer.text.trim(),
            } : const <String,dynamic>{'yeucau_hoadon': false},
          );
        }

        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(bc).viewInsets.bottom),
          child: SingleChildScrollView(child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                const Expanded(child: Text('Thanh toán đơn hàng', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
                IconButton(onPressed: () => Navigator.pop(bc), icon: const Icon(Icons.close)),
              ]),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Theme.of(bc).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
                child: Column(children: [
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Khách hàng'), Flexible(child: Text(customerName, style: const TextStyle(fontWeight: FontWeight.w700)))]),
                  const SizedBox(height: 7),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Phải trả'), Text('${money(finalPayable)} đ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Theme.of(bc).colorScheme.primary))]),
                ]),
              ),
              if (maxRedeemPoints > 0) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: redeemCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) {
                    var pts=value(redeemCtrl).toInt(); if(pts>maxRedeemPoints){pts=maxRedeemPoints; redeemCtrl.text='$pts'; redeemCtrl.selection=TextSelection.collapsed(offset:redeemCtrl.text.length);}
                    final fp=(payable-pts*pointValue).clamp(0,double.infinity);
                    cash.text=fp.round().toString(); mixedCash.text='0'; mixedBank.text=fp.round().toString();
                    setSheetState((){});
                  },
                  decoration: InputDecoration(labelText:'Dùng điểm giảm hóa đơn', helperText:'Tối đa $maxRedeemPoints điểm · 1 điểm = ${money(pointValue)} đ', prefixIcon:const Icon(Icons.stars_outlined)),
                ),
              ],
              const SizedBox(height: 14),
              const Text('Phương thức thanh toán', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Row(children: [
                methodButton('tienmat', Icons.payments_outlined, 'Tiền mặt'),
                methodButton('chuyenkhoan', Icons.account_balance_outlined, 'Chuyển khoản'),
                methodButton('ket_hop', Icons.swap_horiz, 'Kết hợp'),
                methodButton('ghi_no', Icons.credit_card_outlined, 'Ghi nợ'),
              ]),
              const SizedBox(height: 14),
              if (method == 'tienmat') ...[
                TextField(controller: cash, keyboardType: TextInputType.number, onChanged: (_) => setSheetState(() {}), decoration: const InputDecoration(labelText: 'Tiền khách đưa', prefixIcon: Icon(Icons.payments_outlined))),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Tiền thừa'), Text('${money((value(cash)-finalPayable).clamp(0, double.infinity))} đ', style: const TextStyle(fontWeight: FontWeight.w700))]),
              ],
              if (method == 'ket_hop') ...[
                Row(children: [
                  Expanded(child: TextField(controller: mixedCash, keyboardType: TextInputType.number, onChanged: (v) { final c=value(mixedCash); if(c<=finalPayable) mixedBank.text=(finalPayable-c).round().toString(); setSheetState((){}); }, decoration: const InputDecoration(labelText: 'Tiền mặt'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: mixedBank, keyboardType: TextInputType.number, onChanged: (v) { final b=value(mixedBank); if(b<=finalPayable) mixedCash.text=(finalPayable-b).round().toString(); setSheetState((){}); }, decoration: const InputDecoration(labelText: 'Chuyển khoản'))),
                ]),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Còn thiếu'), Text('${money(mixedRemain > 0 ? mixedRemain : 0)} đ', style: TextStyle(fontWeight: FontWeight.w800, color: mixedRemain.abs()<0.01 ? Colors.green : Colors.red))]),
              ],
              if (method == 'ghi_no') ...[
                if (!hasCustomer) Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Colors.orange.withValues(alpha: .12), borderRadius: BorderRadius.circular(10)), child: const Text('Ghi nợ yêu cầu đơn phải chọn khách hàng.', style: TextStyle(fontWeight: FontWeight.w600))),
                const SizedBox(height: 8),
                TextField(controller: debtReceived, keyboardType: TextInputType.number, onChanged: (_) => setSheetState(() {}), decoration: const InputDecoration(labelText: 'Thu trước (có thể để 0)')),
                const SizedBox(height: 10),
                SegmentedButton<String>(segments: const [ButtonSegment(value:'tienmat', label:Text('Tiền mặt')), ButtonSegment(value:'chuyenkhoan', label:Text('Chuyển khoản'))], selected:{debtMethod}, onSelectionChanged:(v)=>setSheetState(()=>debtMethod=v.first)),
                const SizedBox(height: 10),
                OutlinedButton.icon(onPressed: () async { final d=await showDatePicker(context: bc, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days:3650)), initialDate: dueDate ?? DateTime.now().add(const Duration(days:30))); if(d!=null)setSheetState(()=>dueDate=d); }, icon: const Icon(Icons.event_outlined), label: Text(dueDate==null?'Chọn hạn thanh toán (không bắt buộc)':'Hạn: ${dueDate!.day.toString().padLeft(2,'0')}/${dueDate!.month.toString().padLeft(2,'0')}/${dueDate!.year}')),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Còn nợ'), Text('${money(debtRemain > 0 ? debtRemain : 0)} đ', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.red))]),
              ],
              if (einvoiceEnabled && !_offlineNow) ...[
                const SizedBox(height: 14),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: requestEinvoice,
                  onChanged: (v) => setSheetState(() => requestEinvoice = v),
                  title: const Text('Yêu cầu xuất hóa đơn VAT / HĐĐT', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Giá bán hiện tại được giữ nguyên; nhập thông tin để chuẩn bị dữ liệu HĐĐT.'),
                ),
                if (requestEinvoice) ...[
                  TextField(controller: einvoiceCompany, decoration: const InputDecoration(labelText:'Tên công ty / đơn vị')),
                  const SizedBox(height:8),
                  TextField(controller: einvoiceTaxCode, keyboardType:TextInputType.number, decoration: const InputDecoration(labelText:'Mã số thuế')),
                  const SizedBox(height:8),
                  TextField(controller: einvoiceEmail, keyboardType:TextInputType.emailAddress, decoration: const InputDecoration(labelText:'Email nhận hóa đơn')),
                  const SizedBox(height:8),
                  TextField(controller: einvoiceAddress, decoration: const InputDecoration(labelText:'Địa chỉ xuất hóa đơn')),
                  const SizedBox(height:8),
                  TextField(controller: einvoiceBuyer, decoration: const InputDecoration(labelText:'Tên người mua (không bắt buộc)')),
                ],
              ],
              const SizedBox(height: 18),
              FilledButton.icon(onPressed: submit, icon: const Icon(Icons.check_circle_outline), label: Text(method=='ghi_no'?'Xác nhận ghi nợ':'Xác nhận thanh toán'), style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14))),
            ],
          )),
        );
      }),
    );
  }

}


Widget ficModulePage(String module) {
  switch (module) {
    case 'kitchen': return const KitchenPage();
    case 'returns': return const SalesReturnsPage();
    case 'cashbook': return const CashbookPage();
    case 'attendance': return const AttendancePage();
    case 'purchases': return const PurchasesPage();
    case 'inventory': return const InventoryPage();
    case 'ingredients': return const IngredientsPage();
    case 'recipes': return const RecipesPage();
    case 'tasks': return const TasksPage();
    case 'schedule': return const SchedulePage();
    case 'late_request': return const LateRequestPage();
    case 'salary_advance': return const SalaryAdvancePage();
    case 'daily_report': return const DailyReportPage();
    default: return NativeModulePage(module: module);
  }
}





class SalesReturnsPage extends StatefulWidget {
  const SalesReturnsPage({super.key});
  @override State<SalesReturnsPage> createState()=>_SalesReturnsPageState();
}
class _SalesReturnsPageState extends State<SalesReturnsPage> {
  bool loading=true; bool loadingMore=false; bool hasMore=true; int page=1; Map data={}; String? error;
  @override void initState(){super.initState();load();}
  bool _moreFrom(Map d){final p=(d['payments_pagination'] as Map?)??const {};return p['has_more']==true;}
  Future<void> load() async {setState((){loading=true;error=null;page=1;hasMore=true;});try{final x=await ficLoadCachedModule('sales_returns','/sales-returns?section=payments&page=1&per_page=20');data=(x as Map?)?.cast<String,dynamic>()??{};final locals=await OfflineStore.recentInvoices(limit:50,onlyUnsynced:true);final payments=List.from(data['payments'] as List? ?? []);for(final inv in locals){final items=List.from(inv['items'] as List? ?? []);payments.insert(0,<String,dynamic>{'id':inv['server_payment_id'],'client_id':inv['client_id'],'madonhang':inv['madonhang'],'ma_thanhtoan':inv['ma_thanhtoan'],'tenban':inv['tenban'],'phaitra':inv['phaitra'],'paid_at':inv['paid_at'],'items':items,'returned':<String,dynamic>{},'offline_local_invoice':true});}data['payments']=payments;hasMore=!ficOfflineMode&&_moreFrom(data);}catch(e){error=e.toString().replaceFirst('Exception: ','');}if(mounted)setState(()=>loading=false);}
  Future<void> loadMore() async {if(ficOfflineMode||loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/sales-returns?section=payments&page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};data['payments']=[...List.from(data['payments'] as List? ?? []),...List.from(d['payments'] as List? ?? [])];data['payments_pagination']=d['payments_pagination'];page=next;hasMore=_moreFrom(d);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}
  Future<void> makeReturn(Map p) async {
    if (!await ficEnsureMoneyShift(context, purpose: 'trả hàng và hoàn/điều chỉnh tiền cho khách')) return;
    bool hasPromotions=false;
    List appliedPromotions=[];
    if(!ficOfflineMode && p['id']!=null){
      try{
        final r=await api.get('/sales-returns/payment/${p['id']}');
        final ctx=(r['data'] as Map?)?.cast<String,dynamic>()??{};
        if(ctx['items'] is List) p['items']=ctx['items'];
        if(ctx['returned'] is Map) p['returned']=ctx['returned'];
        if(ctx['reasons'] is Map) data['reasons']=ctx['reasons'];
        hasPromotions=ctx['has_promotions']==true || '${ctx['has_promotions']}'=='1';
        appliedPromotions=List.from(ctx['applied_promotions'] as List? ?? []);
      }catch(e){
        if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));
        return;
      }
    }
    final items=List.from(p['items'] as List? ?? []);
    if(items.isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Hóa đơn chưa có dữ liệu món để trả. Hãy kết nối Internet và thử lại.')));return;}
    final returned=ficMapOrEmpty(p['returned']);
    final qty=<String,int>{}; for(final raw in items){final m=raw as Map;qty['${m['id']}']=0;}
    String reason='customer_change';
    String method='tienmat';
    String? policy=hasPromotions?null:'keep';
    Map<String,dynamic>? preview;
    bool previewLoading=false;
    String? previewError;
    final detail=TextEditingController();
    final reasons=Map<String,dynamic>.from((data['reasons'] as Map?)??const {'customer_change':'Khách đổi ý','damaged':'Hàng lỗi / hỏng','quality':'Không đạt chất lượng','other':'Lý do khác'});

    final ok=await showModalBottomSheet<bool>(context:context,isScrollControlled:true,useSafeArea:true,builder:(bc)=>StatefulBuilder(builder:(_,setD){
      Future<void> runPreview() async {
        if(ficOfflineMode || p['id']==null)return;
        if(!qty.values.any((x)=>x>0)){setD(()=>previewError='Chọn ít nhất một món cần trả.');return;}
        if(hasPromotions && policy==null){setD(()=>previewError='Chọn Giữ khuyến mãi hoặc Tính lại khuyến mãi.');return;}
        setD((){previewLoading=true;previewError=null;});
        try{
          final r=await api.post('/sales-returns/payment/${p['id']}/preview',{'qty':qty,'promotion_policy':hasPromotions?policy:null});
          final raw=(r['data'] as Map?)?.cast<String,dynamic>()??{};
          final calc=(raw['data'] as Map?)?.cast<String,dynamic>()??raw;
          setD(()=>preview=calc);
        }catch(e){setD(()=>previewError=e.toString().replaceFirst('Exception: ',''));}
        finally{setD(()=>previewLoading=false);}
      }
      Widget amountRow(String label,dynamic value,{bool strong=false})=>Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(children:[Expanded(child:Text(label)),Text('${money(num.tryParse('$value')??0)} đ',style:TextStyle(fontWeight:strong?FontWeight.w800:FontWeight.w600))]));
      return FractionallySizedBox(heightFactor:.94,child:Column(children:[
        Padding(padding:const EdgeInsets.fromLTRB(16,12,8,8),child:Row(children:[Expanded(child:Text('Trả hàng • ${p['ma_thanhtoan']??p['madonhang']??''}',style:const TextStyle(fontSize:19,fontWeight:FontWeight.w800))),IconButton(onPressed:()=>Navigator.pop(bc),icon:const Icon(Icons.close))])),
        const Divider(height:1),
        Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[
          ...items.map((raw){final m=raw as Map;final id='${m['id']}';final sold=(num.tryParse('${m['soluong']??0}')??0).toInt();final old=(num.tryParse('${returned[id]??0}')??0).toInt();final maxQ=maxInt(0,sold-old);final q=qty[id]??0;return Card(child:ListTile(title:Text('${m['tensanpham']??'Món'}'),subtitle:Text('Đã bán: $sold • Đã trả: $old'),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(onPressed:q<=0?null:()=>setD((){qty[id]=q-1;preview=null;}),icon:const Icon(Icons.remove_circle_outline)),Text('$q',style:const TextStyle(fontWeight:FontWeight.w800)),IconButton(onPressed:q>=maxQ?null:()=>setD((){qty[id]=q+1;preview=null;}),icon:const Icon(Icons.add_circle_outline))])));} ),
          const SizedBox(height:8),
          DropdownButtonFormField<String>(value:reason,decoration:const InputDecoration(labelText:'Lý do trả hàng'),items:reasons.entries.map((e)=>DropdownMenuItem(value:e.key,child:Text('${e.value}'))).toList(),onChanged:(v)=>setD(()=>reason=v??reason)),
          const SizedBox(height:8),TextField(controller:detail,maxLines:2,decoration:const InputDecoration(labelText:'Chi tiết lý do')),
          if(hasPromotions)...[
            const SizedBox(height:16),
            const Text('Xử lý khuyến mãi',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
            if(appliedPromotions.isNotEmpty) Padding(padding:const EdgeInsets.only(top:5,bottom:5),child:Text(appliedPromotions.map((x)=>(x as Map)['promotion_name']??(x as Map)['promotion_code']??'Khuyến mãi').join(' • '),style:const TextStyle(color:Colors.grey))),
            RadioListTile<String>(contentPadding:EdgeInsets.zero,value:'keep',groupValue:policy,title:const Text('Giữ quyền lợi khuyến mãi'),subtitle:const Text('Hoàn theo giá thực khách đã trả cho món, giống Web.'),onChanged:(v)=>setD((){policy=v;preview=null;})),
            RadioListTile<String>(contentPadding:EdgeInsets.zero,value:'recalculate',groupValue:policy,title:const Text('Tính lại khuyến mãi'),subtitle:const Text('Tính lại phần hàng còn giữ và thu hồi giảm giá/quà nếu không còn đủ điều kiện.'),onChanged:(v)=>setD((){policy=v;preview=null;})),
          ],
          const SizedBox(height:8),SegmentedButton<String>(segments:const [ButtonSegment(value:'tienmat',label:Text('Hoàn tiền mặt')),ButtonSegment(value:'chuyenkhoan',label:Text('Hoàn chuyển khoản'))],selected:{method},onSelectionChanged:(v)=>setD(()=>method=v.first)),
          if(!ficOfflineMode)...[
            const SizedBox(height:14),
            OutlinedButton.icon(onPressed:previewLoading?null:runPreview,icon:previewLoading?const SizedBox(width:18,height:18,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.calculate_outlined),label:const Text('Tính thử như Web')),
            if(previewError!=null) Padding(padding:const EdgeInsets.only(top:8),child:Text(previewError!,style:const TextStyle(color:Colors.red))),
            if(preview!=null) Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(children:[
              amountRow('Giá trị hàng trả',preview!['gross_return']),
              amountRow('KM phân bổ vào hàng trả',preview!['allocated_discount']),
              amountRow('KM cần thu hồi',preview!['promotion_recovery']),
              amountRow('Quà cần thu hồi',preview!['gift_recovery']),
              const Divider(),
              amountRow('Hoàn cho khách',preview!['refund_amount'],strong:true),
              if((num.tryParse('${preview!['collect_amount']??0}')??0)>0) amountRow('Cần thu lại từ khách',preview!['collect_amount'],strong:true),
              if(preview!['messages'] is List)...(preview!['messages'] as List).map((m)=>Padding(padding:const EdgeInsets.only(top:4),child:Align(alignment:Alignment.centerLeft,child:Text('• $m',style:const TextStyle(fontSize:12))))),
            ]))),
          ],
          if(ficOfflineMode) const Padding(padding:EdgeInsets.only(top:12),child:Text('Offline: App ghi nhận lựa chọn; số tiền hoàn/khuyến mãi sẽ được server tính chính xác khi đồng bộ.',style:TextStyle(color:Colors.orange,fontWeight:FontWeight.w600))),
        ])),
        Padding(padding:const EdgeInsets.all(14),child:SizedBox(width:double.infinity,child:FilledButton(onPressed:qty.values.any((x)=>x>0)&&(!hasPromotions||policy!=null)?()=>Navigator.pop(bc,true):null,child:const Text('Xác nhận trả hàng'))))
      ]));
    }));
    if(ok!=true)return;
    final isLocal=p['offline_local_invoice']==true && p['id']==null;
    final payload=<String,dynamic>{'payment_id':p['id'],'qty':qty,'lydo_code':reason,'lydo_chitiet':detail.text.trim(),'promotion_policy':hasPromotions?policy:null,'phuongthuc_hoan':method};
    if(isLocal){payload['client_id']=p['client_id'];payload['items']=items.map((raw){final m=raw as Map;final q=qty['${m['id']}']??0;return {'product_id':m['id_sanpham']??m['product_id'],'qty':q};}).where((e)=>(e['qty'] as int)>0).toList();}
    try{
      if(ficOfflineMode){
        await ficQueueBusinessAction(isLocal?'sales_return_offline_invoice':'sales_return',payload);
        final localReturn=<String,dynamic>{'id':-DateTime.now().millisecondsSinceEpoch,'ma':'OFF-TRA-${DateTime.now().millisecondsSinceEpoch}','id_thanhtoan':p['id'],'madonhang':p['madonhang'],'lydo':reasons[reason],'promotion_policy':policy,'trangthai':'Chờ đồng bộ','offline':true};
        final branchId=await ficOfflineBranchId();
        final cachedHistory=branchId>0?await OfflineStore.getModule(api.baseUrl,branchId,'sales_return_history'):null;
        final history=Map<String,dynamic>.from((cachedHistory as Map?)??const {});
        final historyRows=List.from(history['returns'] as List? ?? []);historyRows.insert(0,localReturn);history['returns']=historyRows;await ficCacheModule('sales_return_history',history);
        for(final e in qty.entries){if(e.value>0)returned[e.key]=(num.tryParse('${returned[e.key]??0}')??0)+e.value;}p['returned']=returned;await ficCacheModule('sales_returns',data);if(mounted)setState((){});ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã ghi nhận trả hàng offline • chờ đồng bộ')));
      }else{
        if(isLocal){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Hóa đơn local đang chờ đồng bộ. Hãy đồng bộ trước khi trả hàng online.')));return;}
        await api.post('/sales-returns/payment/${p['id']}',payload);
        await load();
      }
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  @override
  Widget build(BuildContext context) {
    final payments = List.from(data['payments'] as List? ?? []);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trả hàng'),
        actions:[IconButton(tooltip:'Danh sách phiếu trả',onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const SalesReturnHistoryPage())),icon:const Icon(Icons.history))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(error!),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification:(n){ if(n.metrics.pixels>=n.metrics.maxScrollExtent-240) loadMore(); return false; },
                    child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      if (ficOfflineMode)
                        const Card(
                          child: ListTile(
                            leading: Icon(Icons.cloud_off),
                            title: Text('Đang dùng dữ liệu trả hàng đã lưu trên máy'),
                            subtitle: Text('Thao tác mới sẽ đồng bộ khi có Internet.'),
                          ),
                        ),
                      SizedBox(width:double.infinity,child:OutlinedButton.icon(
                        onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const SalesReturnHistoryPage())),
                        icon:const Icon(Icons.history),
                        label:const Text('Danh sách phiếu trả'),
                      )),
                      const SizedBox(height:14),
                      const Text('HÓA ĐƠN CÓ THỂ TRẢ',style: TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 8),
                      ...payments.map((raw) { final p=raw as Map; final total=num.tryParse('${p['phaitra']??p['tongtien']??0}')??0; return Card(child:ListTile(onTap:()=>makeReturn(p),leading:const Icon(Icons.receipt_long_outlined),title:Text('${p['ma_thanhtoan']??p['madonhang']??'Hóa đơn'}'),subtitle:Text('${p['tenban']??''} • ${p['created_at']??p['paid_at']??''}'),trailing:TextButton.icon(onPressed:()=>makeReturn(p),icon:const Icon(Icons.keyboard_return,size:18),label:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.end,children:[Text('${money(total)} đ'),const Text('Trả hàng',style:TextStyle(fontSize:11,fontWeight:FontWeight.w700))])))); }),
                      if(loadingMore) const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2))),
                    ],
                  ),
                  ),
                ),
    );
  }

}


class SalesReturnHistoryPage extends StatefulWidget {
  const SalesReturnHistoryPage({super.key});
  @override State<SalesReturnHistoryPage> createState()=>_SalesReturnHistoryPageState();
}

class _SalesReturnHistoryPageState extends State<SalesReturnHistoryPage> {
  bool loading=true,loadingMore=false,hasMore=true;
  int page=1;
  List rows=[];
  String? error;
  @override void initState(){super.initState();load();}
  bool _hasMore(Map d)=>((d['returns_pagination'] as Map?)??const {})['has_more']==true;
  Future<void> load() async {
    setState((){loading=true;error=null;page=1;hasMore=true;});
    try{
      final x=await ficLoadCachedModule('sales_return_history','/sales-returns?section=returns&page=1&per_page=20');
      final d=(x as Map?)?.cast<String,dynamic>()??{};
      rows=List.from(d['returns'] as List? ?? []);
      hasMore=!ficOfflineMode&&_hasMore(d);
    }catch(e){error=e.toString().replaceFirst('Exception: ','');}
    if(mounted)setState(()=>loading=false);
  }
  Future<void> loadMore() async {
    if(ficOfflineMode||loadingMore||!hasMore)return;
    setState(()=>loadingMore=true);
    try{
      final next=page+1;
      final r=await api.get('/sales-returns?section=returns&page=$next&per_page=20');
      final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};
      rows=[...rows,...List.from(d['returns'] as List? ?? [])];
      page=next;hasMore=_hasMore(d);
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
    finally{if(mounted)setState(()=>loadingMore=false);}
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Danh sách phiếu trả')),
    body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Text(error!))):RefreshIndicator(
      onRefresh:load,
      child:NotificationListener<ScrollNotification>(
        onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},
        child:ListView(padding:const EdgeInsets.all(14),children:[
          if(ficOfflineMode)const Card(child:ListTile(leading:Icon(Icons.cloud_off),title:Text('Đang xem danh sách phiếu trả đã lưu trên máy'))),
          if(rows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(20),child:Text('Chưa có phiếu trả hàng.'))),
          ...rows.map((raw){final r=raw as Map;return Card(child:ListTile(leading:const Icon(Icons.assignment_return_outlined),title:Text('${r['ma']??'Phiếu trả'}'),subtitle:Text('${r['madonhang']??''}${('${r['lydo']??''}').isNotEmpty?' • ${r['lydo']}':''}'),trailing:r['offline']==true?const Chip(label:Text('Chờ đồng bộ')):null));}),
          if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2))),
        ]),
      ),
    ),
  );
}

class KitchenPage extends StatefulWidget {
  const KitchenPage({super.key});
  @override State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  bool loading = true;
  String? error;
  List orders = [];
  Timer? timer;

  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load(silent: true));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load({bool silent = false}) async {
    if (!silent && mounted) setState(() => loading = true);
    try {
      final r = await api.get('/kitchen');
      final d = r['data'];
      orders = d is List ? d : [];
      error = null;
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> dispatch(Map order) async {
    final code = '${order['madonhang'] ?? ''}'.trim();
    if (code.isEmpty) return;
    try {
      final r = await api.post('/kitchen/dispatch', {'madonhang': code});
      final msg = '${r['message'] ?? (r['nothing_new'] == true ? 'Không có món mới cần báo bếp.' : 'Đã gửi báo bếp.')}';
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      await load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  String qty(dynamic v) {
    final n = num.tryParse('$v') ?? 0;
    return n == n.roundToDouble() ? '${n.toInt()}' : '$n';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Báo bếp / Pha chế'),
        actions: [IconButton(onPressed: () => load(), icon: const Icon(Icons.refresh))],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(error!)))
              : RefreshIndicator(
                  onRefresh: load,
                  child: orders.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 120),
                          Center(child: Text('Chưa có đơn đang hoạt động.')),
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: orders.length,
                          itemBuilder: (context, index) {
                            final o = orders[index] as Map;
                            final items = (o['items'] as List?) ?? [];
                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Row(children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('${o['tenban'] ?? 'Không xác định bàn'}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                            const SizedBox(height: 2),
                                            Text('Đơn ${o['madonhang'] ?? ''}', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                          ],
                                        ),
                                      ),
                                      const Icon(Icons.soup_kitchen_outlined),
                                    ]),
                                    const Divider(height: 22),
                                    if (items.isEmpty)
                                      const Text('Đơn chưa có món.')
                                    else
                                      ...items.map((e) {
                                        final m = e as Map;
                                        final note = '${m['ghichu'] ?? ''}'.trim();
                                        return Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 5),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Container(
                                                constraints: const BoxConstraints(minWidth: 38),
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(8),
                                                  color: Theme.of(context).colorScheme.secondaryContainer,
                                                ),
                                                child: Text('${qty(m['soluong'])}x', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text('${m['tensanpham'] ?? 'Món'}', style: const TextStyle(fontWeight: FontWeight.w700)),
                                                    if (note.isNotEmpty) Text(note, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }),
                                    const SizedBox(height: 12),
                                    FilledButton.icon(
                                      onPressed: () => dispatch(o),
                                      icon: const Icon(Icons.campaign_outlined),
                                      label: const Text('Gửi báo bếp'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}

class LoyaltyPage extends StatefulWidget {
  const LoyaltyPage({super.key});
  @override State<LoyaltyPage> createState()=>_LoyaltyPageState();
}
class _LoyaltyPageState extends State<LoyaltyPage> {
  bool loading=true,loadingMore=false,hasMore=true; int page=1; Map data={}; String? error;

  String _initial(String name) {
    final t = name.trim();
    if (t.isEmpty) return 'K';
    return t.characters.first.toUpperCase();
  }
  @override void initState(){super.initState();load();}
  Future<void> load() async {setState((){loading=true;error=null;page=1;hasMore=true;});try{final x=await ficLoadCachedModule('loyalty','/loyalty?page=1&per_page=20');data=(x as Map?)?.cast<String,dynamic>()??{};final pg=(data['pagination'] as Map?)??const {};hasMore=!ficOfflineMode&&pg['has_more']==true;}catch(e){error=e.toString().replaceFirst('Exception: ','');}if(mounted)setState(()=>loading=false);}
  Future<void> loadMore()async{if(ficOfflineMode||loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/loyalty?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};data['customers']=[...List.from(data['customers'] as List? ?? []),...List.from(d['customers'] as List? ?? [])];final h=Map<String,dynamic>.from((data['histories'] as Map?)??{});h.addAll(Map<String,dynamic>.from((d['histories'] as Map?)??{}));data['histories']=h;data['pagination']=d['pagination'];page=next;hasMore=((d['pagination'] as Map?)?['has_more']==true);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}
  Future<void> history(Map c) async {
    try{
      final key='loyalty_history_${c['id']}'; final branchId=await ficOfflineBranchId();
      List rows=[]; int hPage=1; bool hMore=false; bool hLoading=false;
      if(ficOfflineMode){
        final histories=(data['histories'] as Map?)?.cast<String,dynamic>();
        dynamic raw=histories?['${c['id']}']; raw??=branchId>0?await OfflineStore.getModule(api.baseUrl,branchId,key):null;
        if(raw==null)throw Exception('Chưa có lịch sử điểm offline.');
        if(raw is Map) rows=List.from(raw['items'] as List? ?? []); else rows=List.from(raw as List? ?? []);
      }else{
        final r=await api.get('/loyalty/${c['id']}/history?page=1&per_page=20');
        final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};
        rows=List.from(d['items'] as List? ?? []); hMore=d['has_more']==true;
        if(branchId>0)await OfflineStore.cacheModule(api.baseUrl,branchId,key,d);
      }
      if(!mounted)return;
      await showModalBottomSheet(context:context,isScrollControlled:true,useSafeArea:true,builder:(bc)=>StatefulBuilder(builder:(_,setD){
        Future<void> more() async {if(ficOfflineMode||hLoading||!hMore)return;setD(()=>hLoading=true);try{final next=hPage+1;final r=await api.get('/loyalty/${c['id']}/history?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};rows.addAll(List.from(d['items'] as List? ?? []));hPage=next;hMore=d['has_more']==true;}finally{setD(()=>hLoading=false);}}
        return DraggableScrollableSheet(expand:false,initialChildSize:.72,maxChildSize:.92,builder:(_,sc)=>Column(children:[
          ListTile(title:Text('${c['ten_khachhang']??'Khách hàng'}',style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text('Điểm khả dụng: ${c['fic_diem_khadung']??0} · ${c['fic_hang_thanhvien']??'Thành viên'}'),trailing:IconButton(onPressed:()=>Navigator.pop(bc),icon:const Icon(Icons.close))),
          const Divider(height:1), Expanded(child:rows.isEmpty?const Center(child:Text('Chưa có lịch sử điểm')):NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-160)more();return false;},child:ListView.builder(controller:sc,itemCount:rows.length+(hLoading?1:0),itemBuilder:(_,i){if(i>=rows.length)return const Padding(padding:EdgeInsets.all(14),child:Center(child:CircularProgressIndicator(strokeWidth:2)));final x=rows[i] as Map;final pts=int.tryParse('${x['points']??0}')??0;return ListTile(leading:CircleAvatar(child:Icon(pts>=0?Icons.add:Icons.remove)),title:Text('${pts>=0?'+':''}$pts điểm',style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${x['note']??x['reference']??''}\nSố dư: ${x['balance_after']??0}'),isThreeLine:true);})))
        ]));
      }));
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  Future<void> rewards(Map c) async {
    final rows=List.from(data['rewards'] as List? ?? []);
    if(rows.isEmpty){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Chưa có chương trình đổi quà.')));return;}
    await showModalBottomSheet(context:context,useSafeArea:true,isScrollControlled:true,builder:(bc)=>DraggableScrollableSheet(expand:false,initialChildSize:.65,maxChildSize:.9,builder:(_,sc)=>ListView(controller:sc,padding:const EdgeInsets.all(14),children:[
      Text('Đổi quà • ${c['ten_khachhang']??''}',style:const TextStyle(fontSize:20,fontWeight:FontWeight.w800)),Text('Điểm hiện có: ${c['fic_diem_khadung']??0}'),const SizedBox(height:10),
      ...rows.map((e){final x=e as Map;final need=int.tryParse('${x['points_required']??0}')??0;final balance=int.tryParse('${c['fic_diem_khadung']??0}')??0;final rewardValue=num.tryParse('${x['value_amount']??0}')??0;return Card(child:ListTile(title:Text('${x['name']??'Quà'}'),subtitle:Text('$need điểm${rewardValue>0?' · Giá trị ${money(rewardValue)} đ':''}'),trailing:FilledButton.tonal(onPressed:balance<need?null:()async{try{if(ficOfflineMode){await ficQueueBusinessAction('loyalty_redeem',{'customer_id':c['id'],'reward_id':x['id']});c['fic_diem_khadung']=maxInt(0,balance-need);await ficCacheModule('loyalty',data);if(bc.mounted)Navigator.pop(bc);if(mounted)setState((){});if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Đã ghi nhận đổi ${x['name']} • chờ đồng bộ')));}else{await api.post('/loyalty/${c['id']}/redeem-reward',{'reward_id':x['id']});if(bc.mounted)Navigator.pop(bc);await load();if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Đã đổi ${x['name']}')));}}catch(err){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(err.toString().replaceFirst('Exception: ',''))));}},child:const Text('Đổi'))));}),
    ])));
  }
  @override Widget build(BuildContext context){final rows=List.from(data['customers'] as List? ?? []);return Scaffold(appBar:AppBar(title:const Text('Thành viên & tích điểm')),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Text(error!),const SizedBox(height:10),FilledButton(onPressed:load,child:const Text('Thử lại'))])):RefreshIndicator(onRefresh:load,child:NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(padding:const EdgeInsets.all(14),children:[
    if(rows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(20),child:Text('Chưa có khách hàng thành viên.'))),
    ...rows.map((e){final c=e as Map;return Card(child:ListTile(leading:CircleAvatar(child:Text(_initial('${c['ten_khachhang']??'K'}'))),title:Text('${c['ten_khachhang']??''}',style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text('${c['fic_hang_thanhvien']??'Thành viên'} · ${c['fic_diem_khadung']??0} điểm khả dụng'),trailing:PopupMenuButton<String>(onSelected:(v){if(v=='history')history(c);if(v=='reward')rewards(c);},itemBuilder:(_)=>const [PopupMenuItem(value:'history',child:Text('Lịch sử điểm')),PopupMenuItem(value:'reward',child:Text('Đổi quà'))]),onTap:()=>history(c)));}),
    if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)))
  ]))));}
}

class CashbookPage extends StatefulWidget { const CashbookPage({super.key}); @override State<CashbookPage> createState()=>_CashbookPageState(); }
class _CashbookPageState extends State<CashbookPage>{
  bool loading=true,loadingMore=false,hasMore=true; int page=1; Map data={}; String? error;
  @override void initState(){super.initState();load();}
  Future<void> load() async {setState((){loading=true;page=1;hasMore=true;});try{final x=await ficLoadCachedModule('cashbook','/cashbook?page=1&per_page=20');data=(x as Map?)?.cast<String,dynamic>()??{};error=null;hasMore=!ficOfflineMode&&((data['pagination'] as Map?)?['has_more']==true);}catch(e){error=e.toString();}if(mounted)setState(()=>loading=false);}
  Future<void> loadMore()async{if(ficOfflineMode||loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/cashbook?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};data['entries']=[...List.from(data['entries'] as List? ?? []),...List.from(d['entries'] as List? ?? [])];data['pagination']=d['pagination'];page=next;hasMore=((d['pagination'] as Map?)?['has_more']==true);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}
  Future<void> create() async {
    int kind = 1;
    int method = 1;
    int? category;
    int? employee;
    final amount = TextEditingController();
    final note = TextEditingController();
    List cats = List.from(data['categories'] as List? ?? []);
    final employees = List.from(data['employees'] as List? ?? []);

    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setD) {
          final filtered = cats.where((e) => int.tryParse('${(e as Map)['loaithuchi']}') == kind).toList();
          if (category != null && !filtered.any((e) => '${(e as Map)['id']}' == '$category')) category = null;
          return AlertDialog(
            title: Text(kind == 1 ? 'Tạo phiếu chi' : 'Tạo phiếu thu'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 1, label: Text('Phiếu chi')),
                        ButtonSegment(value: 2, label: Text('Phiếu thu')),
                      ],
                      selected: {kind},
                      onSelectionChanged: (v) => setD(() => kind = v.first),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      value: category,
                      decoration: const InputDecoration(labelText: 'Nội dung thu/chi'),
                      items: filtered.map((e) {
                        final m = e as Map;
                        return DropdownMenuItem<int>(
                          value: int.tryParse('${m['id']}'),
                          child: Text('${m['tenthuchi'] ?? ''}'),
                        );
                      }).toList(),
                      onChanged: (v) => setD(() => category = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Số tiền', suffixText: 'đ')),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: method,
                      decoration: const InputDecoration(labelText: 'Phương thức'),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('Tiền mặt')),
                        DropdownMenuItem(value: 2, child: Text('Chuyển khoản')),
                      ],
                      onChanged: (v) => setD(() => method = v ?? 1),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: employee,
                      decoration: const InputDecoration(labelText: 'Nhân viên thực hiện'),
                      items: employees.map((e) {
                        final m = e as Map;
                        return DropdownMenuItem<int>(
                          value: int.tryParse('${m['id']}'),
                          child: Text('${m['name'] ?? m['ten_nhanvien'] ?? m['id']}'),
                        );
                      }).toList(),
                      onChanged: (v) => setD(() => employee = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(controller: note, maxLines: 2, decoration: const InputDecoration(labelText: 'Ghi chú')),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('Thêm nội dung mới'),
                        onPressed: () async {
                          final c = TextEditingController();
                          final n = TextEditingController();
                          await showDialog<void>(
                            context: dc,
                            builder: (cctx) => AlertDialog(
                              title: const Text('Thêm nội dung thu/chi'),
                              content: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextField(controller: c, decoration: const InputDecoration(labelText: 'Tên nội dung')),
                                  TextField(controller: n, decoration: const InputDecoration(labelText: 'Mô tả')),
                                ],
                              ),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(cctx), child: const Text('Hủy')),
                                FilledButton(
                                  onPressed: () async {
                                    if (c.text.trim().isEmpty) return;
                                    if (ficOfflineMode) {
                                      if (cctx.mounted) Navigator.pop(cctx);
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tạo nội dung thu/chi mới cần Internet. Offline vẫn lập phiếu bằng các nội dung đã tải sẵn.')));
                                    } else {
                                      await api.post('/cashbook/categories', {'name': c.text.trim(), 'kind': kind, 'note': n.text.trim()});
                                      if (cctx.mounted) Navigator.pop(cctx);
                                      final rr = await api.get('/cashbook?page=1&per_page=20');
                                      data = (rr['data'] as Map?) ?? {};
                                      await ficCacheModule('cashbook', data);
                                      cats = List.from(data['categories'] as List? ?? []);
                                      setD(() {});
                                    }
                                  },
                                  child: const Text('Thêm'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Hủy')),
              FilledButton(
                onPressed: () async {
                  final v = num.tryParse(amount.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                  if (category == null || v <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Chọn nội dung và nhập số tiền hợp lệ')));
                    return;
                  }
                  final payload = <String,dynamic>{
                    'danhsachthuchi': category,
                    'nhanvienthuchi': employee,
                    'giatri': v,
                    'phuongthuc': method,
                    'loaithuchi': kind,
                    'ghichu': note.text.trim(),
                  };
                  if (ficOfflineMode) {
                    await ficQueueBusinessAction('cashbook_create', payload);
                    final entries = List.from(data['entries'] as List? ?? []);
                    entries.insert(0, <String,dynamic>{...payload, 'id': -DateTime.now().millisecondsSinceEpoch, 'created_at': DateTime.now().toIso8601String(), 'offline': true});
                    data['entries'] = entries;
                    final summary = Map<String,dynamic>.from((data['summary'] as Map?) ?? {});
                    final inc = kind == 2; final oldThu = num.tryParse('${summary['tongthu'] ?? 0}') ?? 0; final oldChi = num.tryParse('${summary['tongchi'] ?? 0}') ?? 0; final oldTon = num.tryParse('${summary['quyton'] ?? 0}') ?? 0;
                    summary['tongthu'] = inc ? oldThu + v : oldThu; summary['tongchi'] = inc ? oldChi : oldChi + v; summary['quyton'] = oldTon + (inc ? v : -v); data['summary'] = summary;
                    await ficCacheModule('cashbook', data);
                    if (dc.mounted) Navigator.pop(dc); if (mounted) setState(() {});
                  } else {
                    await api.post('/cashbook', payload);
                    if (dc.mounted) Navigator.pop(dc);
                    await load();
                  }
                },
                child: const Text('Lưu phiếu'),
              ),
            ],
          );
        },
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    final summary = data['summary'] as Map? ?? {};
    final entries = List.from(data['entries'] as List? ?? []);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sổ thu chi'),
        actions: [
          IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: create,
        icon: const Icon(Icons.add),
        label: const Text('Tạo thu/chi'),
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : RefreshIndicator(
                  onRefresh: load,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240) {
                        loadMore();
                      }
                      return false;
                    },
                    child: ListView(
                      padding: const EdgeInsets.all(14),
                      children: [
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'SỔ QUỸ',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _kv('Quỹ đầu kỳ', summary['quydauky']),
                                _kv('Tổng thu', summary['tongthu']),
                                _kv('Tổng chi', summary['tongchi']),
                                const Divider(),
                                _kv('Quỹ tồn', summary['quyton'], bold: true),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ...entries.map((e) {
                          final m = e as Map;
                          final kind = int.tryParse('${m['loaithuchi']}') == 2
                              ? 'THU'
                              : 'CHI';
                          final category = m['danhsachthuchi'] is Map
                              ? '${(m['danhsachthuchi'] as Map)['tenthuchi'] ?? ''}'
                              : '';

                          return Card(
                            child: ListTile(
                              leading: CircleAvatar(child: Text(kind)),
                              title: Text(
                                '${money(num.tryParse('${m['giatri']}') ?? 0)} đ',
                              ),
                              subtitle: Text(
                                '${category.isNotEmpty ? category : (m['ghichu'] ?? '')}\n${m['created_at'] ?? ''}',
                              ),
                              isThreeLine: true,
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CashbookDetailPage(initial: m),
                                ),
                              ),
                            ),
                          );
                        }),
                        if (loadingMore)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
    );
  }
  Widget _kv(String k,dynamic v,{bool bold=false})=>Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(children:[Expanded(child:Text(k)),Text('${money(num.tryParse('$v')??0)} đ',style:TextStyle(fontWeight:bold?FontWeight.bold:FontWeight.w500))]));
}

class CashbookDetailPage extends StatefulWidget {
  final Map initial;
  const CashbookDetailPage({super.key, required this.initial});
  @override State<CashbookDetailPage> createState()=>_CashbookDetailPageState();
}
class _CashbookDetailPageState extends State<CashbookDetailPage>{
  late Map data; bool loading=false; String? error;
  @override void initState(){super.initState();data=Map<String,dynamic>.from(widget.initial);_refresh();}
  Future<void> _refresh() async {
    final id=int.tryParse('${data['id']??0}')??0;
    if(id<=0||ficOfflineMode)return;
    setState(()=>loading=true);
    try{final r=await api.get('/cashbook/$id');data=(r['data'] as Map?)?.cast<String,dynamic>()??data;error=null;}catch(e){error=e.toString().replaceFirst('Exception: ','');}
    if(mounted)setState(()=>loading=false);
  }
  String _person(dynamic v){if(v is! Map)return '—';return '${v['ten_nhanvien']??v['name']??v['email']??'—'}';}
  Widget _row(String label,dynamic value,{bool moneyValue=false}){final text=moneyValue?'${money(num.tryParse('$value')??0)} đ':('${value??''}'.trim().isEmpty?'—':'$value');return Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(width:135,child:Text(label,style:const TextStyle(color:Colors.black54))),Expanded(child:Text(text,style:const TextStyle(fontWeight:FontWeight.w600))) ]));}
  @override Widget build(BuildContext context){
    final kind=int.tryParse('${data['loaithuchi']}')==2?'Phiếu thu':'Phiếu chi';
    final method=int.tryParse('${data['phuongthuc']}')==2?'Chuyển khoản':'Tiền mặt';
    final category=data['danhsachthuchi'] is Map?(data['danhsachthuchi'] as Map)['tenthuchi']:data['danhsachthuchi'];
    final offline=data['offline']==true||(int.tryParse('${data['id']??0}')??0)<0;
    return Scaffold(appBar:AppBar(title:const Text('Chi tiết thu/chi')),body:loading&&data.isEmpty?const Center(child:CircularProgressIndicator()):RefreshIndicator(onRefresh:_refresh,child:ListView(padding:const EdgeInsets.all(14),children:[
      if(error!=null)Card(child:Padding(padding:const EdgeInsets.all(12),child:Text(error!,style:const TextStyle(color:Colors.red)))),
      Card(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Expanded(child:Text(kind,style:const TextStyle(fontSize:20,fontWeight:FontWeight.bold))),if(offline)const Chip(label:Text('Chờ đồng bộ'))]),
        const SizedBox(height:6),
        Text('${money(num.tryParse('${data['giatri']}')??0)} đ',style:Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight:FontWeight.bold)),
        const Divider(height:26),
        _row('Nội dung',category),_row('Phương thức',method),_row('Nhân viên thực hiện',_person(data['nhanvienthuchi'])),_row('Người tạo',_person(data['nhanvientao'])),
        if(data['nhanviensua']!=null)_row('Người sửa',_person(data['nhanviensua'])),
        if('${data['id_hoadon']??''}'.trim().isNotEmpty)_row('Mã liên kết/HĐ',data['id_hoadon']),
        _row('Ghi chú',data['ghichu']),_row('Ngày tạo',data['created_at']),
        if('${data['thoigiansua']??''}'.trim().isNotEmpty)_row('Cập nhật',data['thoigiansua']),
      ])))
    ])));
  }
}

class AttendancePage extends StatefulWidget {const AttendancePage({super.key});@override State<AttendancePage> createState()=>_AttendancePageState();}
class _AttendancePageState extends State<AttendancePage>{bool loading=true;dynamic data;String? error;@override void initState(){super.initState();load();}Future<void>load()async{setState(()=>loading=true);try{data=await ficLoadCachedModule('attendance','/attendance');error=null;}catch(e){error=e.toString();}if(mounted)setState(()=>loading=false);}List schedules(){final out=<Map>[];final s=(data is Map?data['schedule']:null);if(s is Map){for(final v in s.values){if(v is List)for(final x in v)if(x is Map)out.add(x);}}return out;}Future<Position>pos()async{var p=await Geolocator.checkPermission();if(p==LocationPermission.denied)p=await Geolocator.requestPermission();if(p==LocationPermission.denied||p==LocationPermission.deniedForever)throw Exception('Cần cấp quyền vị trí để chấm công.');return Geolocator.getCurrentPosition(desiredAccuracy:LocationAccuracy.high);}Future<void>act(Map s,String a)async{try{final p=await pos();final payload=<String,dynamic>{'action':a,'schedule_id':s['id'],'latitude':p.latitude,'longitude':p.longitude,'accuracy':p.accuracy,'early':false,'overtime':false};if(ficOfflineMode){await ficQueueBusinessAction('attendance',payload);final now=DateTime.now().toIso8601String();if(a=='checkin'){s['chamCong']={'trangthai':0,'giovao':now,'offline':true};}else{final cc=Map<String,dynamic>.from((s['chamCong'] as Map?)??{});cc['trangthai']=1;cc['giora']=now;cc['offline']=true;s['chamCong']=cc;}await ficCacheModule('attendance',data);if(mounted)setState((){});if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(a=='checkin'?'Đã chấm công vào offline • chờ đồng bộ':'Đã chấm công ra offline • chờ đồng bộ')));}else{await api.post('/attendance',payload);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(a=='checkin'?'Đã chấm công vào':'Đã chấm công ra')));await load();}}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}}@override Widget build(BuildContext c){final rows=schedules();return Scaffold(appBar:AppBar(title:const Text('Chấm công')),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Text(error!)):ListView(padding:const EdgeInsets.all(14),children:[const Text('Chấm công theo đúng ca làm việc và vị trí chi nhánh.',style:TextStyle(color:Colors.black54)),const SizedBox(height:10),if(rows.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(20),child:Text('Hôm nay chưa có ca làm việc.'))),...rows.map((s){final cc=s['chamCong'];final checkedIn=cc!=null;final done=cc is Map&&cc['trangthai']==1;return Card(child:ListTile(title:Text('Ca #${s['id_calamviec']??''}'),subtitle:Text('${s['calamviec']?['thoigianlam']??''}\n${checkedIn?'Đã vào: ${cc['giovao']??''}':'Chưa chấm vào'}'),isThreeLine:true,trailing:done?const Icon(Icons.check_circle,color:Colors.green):FilledButton(onPressed:()=>act(s,checkedIn?'checkout':'checkin'),child:Text(checkedIn?'Ra ca':'Vào ca'))));})]));}}

class PurchasesPage extends StatefulWidget {
  const PurchasesPage({super.key});
  @override State<PurchasesPage> createState() => _PurchasesPageState();
}

class _PurchasesPageState extends State<PurchasesPage> {
  bool loading = true, loadingMore=false, hasMore=true;
  int page=1;
  Map data = {};

  @override
  void initState() { super.initState(); load(); }

  Future<void> load() async {setState((){loading=true;page=1;hasMore=true;});try{final x=await ficLoadCachedModule('purchases','/purchases?page=1&per_page=20');data=(x as Map?)?.cast<String,dynamic>()??{};hasMore=!ficOfflineMode&&((data['pagination'] as Map?)?['has_more']==true);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}if(mounted)setState(()=>loading=false);}
  Future<void> loadMore()async{if(ficOfflineMode||loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/purchases?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};data['purchases']=[...List.from(data['purchases'] as List? ?? []),...List.from(d['purchases'] as List? ?? [])];data['pagination']=d['pagination'];page=next;hasMore=((d['pagination'] as Map?)?['has_more']==true);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}

  Future<void> create() async {
    final products = List.from(data['products'] as List? ?? []);
    final suppliers = List.from(data['suppliers'] as List? ?? []);
    if (products.isEmpty) return;
    int? supplier;
    final note = TextEditingController();
    final paid = TextEditingController();
    String paymentMethod = 'tienmat';
    final lines = <Map<String, dynamic>>[
      {
        'product': products.first,
        'qty': TextEditingController(text: '1'),
        'price': TextEditingController(text: '${(products.first as Map)['giagoc'] ?? 0}'),
      }
    ];

    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc, setD) => AlertDialog(
          title: const Text('Tạo phiếu nhập hàng'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<int>(
                    value: supplier,
                    decoration: const InputDecoration(labelText: 'Nhà cung cấp'),
                    items: suppliers.map((e) {
                      final m = e as Map;
                      return DropdownMenuItem<int>(
                        value: int.tryParse('${m['id']}'),
                        child: Text('${m['ten'] ?? m['id']}'),
                      );
                    }).toList(),
                    onChanged: (v) => setD(() => supplier = v),
                  ),
                  const SizedBox(height: 8),
                  ...lines.asMap().entries.map((entry) {
                    final i = entry.key;
                    final l = entry.value;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            DropdownButtonFormField<dynamic>(
                              value: l['product'],
                              decoration: const InputDecoration(labelText: 'Sản phẩm'),
                              items: products.map((e) => DropdownMenuItem<dynamic>(
                                value: e,
                                child: Text('${(e as Map)['tensanpham'] ?? e['id']}'),
                              )).toList(),
                              onChanged: (v) => setD(() {
                                l['product'] = v;
                                l['price'].text = '${(v as Map)['giagoc'] ?? 0}';
                              }),
                            ),
                            Row(
                              children: [
                                Expanded(child: TextField(controller: l['qty'], keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(labelText: 'SL'))),
                                const SizedBox(width: 8),
                                Expanded(child: TextField(controller: l['price'], keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Giá nhập'))),
                                IconButton(
                                  onPressed: lines.length > 1 ? () => setD(() => lines.removeAt(i)) : null,
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  TextButton.icon(
                    onPressed: () => setD(() => lines.add({
                      'product': products.first,
                      'qty': TextEditingController(text: '1'),
                      'price': TextEditingController(text: '${(products.first as Map)['giagoc'] ?? 0}'),
                    })),
                    icon: const Icon(Icons.add),
                    label: const Text('Thêm dòng'),
                  ),
                  TextField(controller: paid, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Đã thanh toán')),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: paymentMethod,
                    decoration: const InputDecoration(labelText: 'Phương thức thanh toán'),
                    items: const [
                      DropdownMenuItem(value: 'tienmat', child: Text('Tiền mặt')),
                      DropdownMenuItem(value: 'chuyenkhoan', child: Text('Chuyển khoản')),
                    ],
                    onChanged: (v) => setD(() => paymentMethod = v ?? 'tienmat'),
                  ),
                  TextField(controller: note, decoration: const InputDecoration(labelText: 'Ghi chú')),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Hủy')),
            FilledButton(
              onPressed: () async {
                final items = lines.map((l) => {
                  'product_id': (l['product'] as Map)['id'],
                  'qty': int.tryParse((l['qty'] as TextEditingController).text) ?? 0,
                  'price': num.tryParse((l['price'] as TextEditingController).text) ?? 0,
                }).toList();
                final payload=<String,dynamic>{
                  'supplier_id': supplier,
                  'paid': num.tryParse(paid.text) ?? 0,
                  'payment_method': paymentMethod,
                  'note': note.text.trim(),
                  'items': items,
                };
                if ((num.tryParse(paid.text) ?? 0) > 0) {
                  final shiftOk = await ficEnsureMoneyShift(context, purpose: 'thanh toán tiền nhập hàng');
                  if (!shiftOk) return;
                }
                if (ficOfflineMode) {
                  await ficQueueBusinessAction('purchase_create', payload);
                  final total=items.fold<num>(0,(sum,e)=>sum+((e['qty'] as num?)??0)*((e['price'] as num?)??0));
                  final rows=List.from(data['purchases'] as List? ?? []);
                  rows.insert(0,<String,dynamic>{'id':-DateTime.now().millisecondsSinceEpoch,'ma':'OFF-NH-${DateTime.now().millisecondsSinceEpoch}','ngaynhap':DateTime.now().toIso8601String(),'trangthai':'Chờ đồng bộ','tongtien':total,'offline':true});
                  data['purchases']=rows; await ficCacheModule('purchases',data);
                  if (dc.mounted) Navigator.pop(dc); if(mounted)setState((){});
                } else {
                  await api.post('/purchases', payload);
                  if (dc.mounted) Navigator.pop(dc);
                  await load();
                }
              },
              child: const Text('Nhập hàng'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = List.from(data['purchases'] as List? ?? []);
    return Scaffold(
      appBar: AppBar(title: const Text('Nhập hàng')),
      floatingActionButton: FloatingActionButton.extended(onPressed: create, icon: const Icon(Icons.add), label: const Text('Phiếu nhập')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: load,
              child: NotificationListener<ScrollNotification>(
                onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},
                child:ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  ...rows.map((e) {
                    final m = e as Map;
                    final id=int.tryParse('${m['id']}')??0;
                    return Card(
                      child: ListTile(
                        onTap: id>0?() async {await Navigator.push(context,MaterialPageRoute(builder:(_)=>PurchaseDetailPage(id:id,summary:Map<String,dynamic>.from(m))));await load();}:null,
                        leading: const Icon(Icons.inventory_2_outlined),
                        title: Text('${m['ma'] ?? 'Phiếu nhập'}'),
                        subtitle: Text('${m['ngaynhap'] ?? ''} • ${m['trangthai'] ?? ''}${m['offline']==true?' • Chờ đồng bộ':''}'),
                        trailing: Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.end,children:[Text('${money(num.tryParse('${m['tongtien']}') ?? 0)} đ'),if(id>0)const Text('Chi tiết ›',style:TextStyle(fontSize:11,fontWeight:FontWeight.w600))]),
                      ),
                    );
                  }),
                  if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2))),
                ],
              )),
            ),
    );
  }
}


class PurchaseDetailPage extends StatefulWidget{
  final int id; final Map<String,dynamic> summary;
  const PurchaseDetailPage({super.key,required this.id,required this.summary});
  @override State<PurchaseDetailPage> createState()=>_PurchaseDetailPageState();
}
class _PurchaseDetailPageState extends State<PurchaseDetailPage>{
  bool loading=true; String? error; Map<String,dynamic> data={};
  @override void initState(){super.initState();load();}
  Future<void>load()async{
    if(mounted)setState((){loading=true;error=null;});
    try{final x=await ficLoadCachedModule('purchase_detail_${widget.id}','/purchases/${widget.id}');data=(x as Map?)?.cast<String,dynamic>()??{};}
    catch(e){error=e.toString().replaceFirst('Exception: ','');}
    finally{if(mounted)setState(()=>loading=false);}
  }
  num _n(dynamic v)=>num.tryParse('$v')??0;
  Future<void>returnPurchase()async{
    if(ficOfflineMode){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Trả nhập hàng cần Internet để trừ tồn và lô/HSD chính xác.')));return;}
    final items=List.from(data['items'] as List? ?? []); final returned=ficMapOrEmpty(data['returned']);
    if(items.isEmpty)return;
    final qty=<String,int>{}; for(final raw in items){final m=raw as Map;qty['${m['id']}']=0;}
    final reason=TextEditingController();
    final ok=await showModalBottomSheet<bool>(context:context,isScrollControlled:true,useSafeArea:true,builder:(bc)=>StatefulBuilder(builder:(_,setD)=>FractionallySizedBox(heightFactor:.9,child:Column(children:[
      Padding(padding:const EdgeInsets.fromLTRB(16,12,8,8),child:Row(children:[const Expanded(child:Text('Trả nhập hàng',style:TextStyle(fontSize:19,fontWeight:FontWeight.w800))),IconButton(onPressed:()=>Navigator.pop(bc),icon:const Icon(Icons.close))])),
      const Divider(height:1),Expanded(child:ListView(padding:const EdgeInsets.all(14),children:[
        ...items.map((raw){final m=raw as Map;final id='${m['id']}';final received=_n(m['soluong']);final old=_n(returned[id]);final max=(received-old).clamp(0,double.infinity).toDouble();final q=qty[id]??0;return Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${m['masanpham']??''} - ${m['tensanpham']??'Sản phẩm'}',style:const TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:4),Text('Đã nhập: $received • Đã trả: $old • Còn trả được: $max'),const SizedBox(height:8),Row(children:[IconButton(onPressed:q<=0?null:()=>setD(()=>qty[id]=(q-1).clamp(0,max.toInt()).toInt()),icon:const Icon(Icons.remove_circle_outline)),Expanded(child:Slider(value:q.toDouble().clamp(0,max),min:0,max:max<=0?1:max,divisions:max>0&&max<=100?max.round():null,onChanged:max<=0?null:(v)=>setD(()=>qty[id]=v.round()))),SizedBox(width:48,child:Text('${qty[id]?.toInt()??0}',textAlign:TextAlign.center,style:const TextStyle(fontWeight:FontWeight.w800))),IconButton(onPressed:q>=max?null:()=>setD(()=>qty[id]=(q+1).clamp(0,max.toInt()).toInt()),icon:const Icon(Icons.add_circle_outline))])])));} ),
        const SizedBox(height:8),TextField(controller:reason,maxLines:2,onChanged:(_)=>setD((){}),decoration:const InputDecoration(labelText:'Lý do trả nhập hàng')),
      ])),
      Padding(padding:const EdgeInsets.all(14),child:SizedBox(width:double.infinity,child:FilledButton(onPressed:qty.values.any((v)=>v>0)&&reason.text.trim().isNotEmpty?()=>Navigator.pop(bc,true):()=>setD((){}),child:const Text('Xác nhận trả nhập'))))
    ]))));
    if(ok!=true)return;
    final payload=<String,dynamic>{'qty':{for(final e in qty.entries)if(e.value>0)e.key:e.value},'reason':reason.text.trim()};
    try{await api.post('/purchases/${widget.id}/return',payload);if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã trả nhập hàng và trừ tồn kho.')));await load();}
    catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  Future<void>receiveSupplierRefund()async{
    if (!await ficEnsureMoneyShift(context, purpose: 'ghi nhận tiền nhà cung cấp hoàn')) return;
    if(ficOfflineMode){ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Ghi nhận tiền NCC hoàn cần Internet.')));return;}
    final f=ficMapOrEmpty(data['financials']); final due=_n(f['refund_due']); if(due<=0)return;
    final amount=TextEditingController(text:'${due.round()}'); final note=TextEditingController(); int method=1;
    final ok=await showDialog<bool>(context:context,builder:(dc)=>StatefulBuilder(builder:(_,setD)=>AlertDialog(
      title:const Text('Nhận tiền NCC hoàn'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        Text('NCC còn phải hoàn: ${money(due)} đ'),const SizedBox(height:12),
        TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Số tiền thực nhận')),
        const SizedBox(height:10),SegmentedButton<int>(segments:const [ButtonSegment(value:1,label:Text('Tiền mặt')),ButtonSegment(value:2,label:Text('Chuyển khoản'))],selected:{method},onSelectionChanged:(v)=>setD(()=>method=v.first)),
        const SizedBox(height:10),TextField(controller:note,decoration:const InputDecoration(labelText:'Ghi chú')),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(dc,false),child:const Text('Hủy')),FilledButton(onPressed:()=>Navigator.pop(dc,true),child:const Text('Đã nhận tiền'))],
    )));
    if(ok!=true)return;
    final value=num.tryParse(amount.text.replaceAll(',','').trim())??0;
    if(value<=0||value>due){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Số tiền nhận không hợp lệ.')));return;}
    try{await api.post('/purchases/${widget.id}/refund-receipt',{'amount':value,'method':method,'note':note.text.trim()});if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã ghi Phiếu thu tiền NCC hoàn.')));await load();}
    catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  @override Widget build(BuildContext context){
    final p=Map<String,dynamic>.from((data['purchase'] as Map?)??widget.summary); final items=List.from(data['items'] as List? ?? []); final returned=ficMapOrEmpty(data['returned']); final returns=List.from(data['returns'] as List? ?? []); final financials=ficMapOrEmpty(data['financials']);
    final total=_n(p['tongtien']),paid=_n(p['dathanhtoan']); final net=_n(financials['net_total']??total),debt=_n(financials['debt']??(total-paid).clamp(0,double.infinity)),refundDue=_n(financials['refund_due']),refundReceived=_n(financials['refund_received']);
    return Scaffold(appBar:AppBar(title:Text('${p['ma']??'Chi tiết phiếu nhập'}'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Text(error!))):RefreshIndicator(onRefresh:load,child:ListView(padding:const EdgeInsets.all(14),children:[
      Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${p['ncc']??'Không chọn NCC'}',style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800)),Text('Ngày nhập: ${p['ngaynhap']??''}'),const SizedBox(height:8),Text('Tổng gốc: ${money(total)} đ • Sau trả: ${money(net)} đ • Đã trả NCC: ${money(paid)} đ • Còn nợ: ${money(debt)} đ')]))),
      const SizedBox(height:8),const Text('CHI TIẾT HÀNG NHẬP',style:TextStyle(fontWeight:FontWeight.w800)),
      ...items.map((raw){final m=raw as Map;final rt=_n(returned['${m['id']}']);return Card(child:ListTile(title:Text('${m['masanpham']??''} - ${m['tensanpham']??'Sản phẩm'}'),subtitle:Text('Nhập ${m['soluong']??0} • Đã trả $rt • Giá ${money(_n(m['dongia']))} đ'),trailing:Text('${money(_n(m['thanhtien']))} đ')));} ),
      const SizedBox(height:8),FilledButton.icon(onPressed:returnPurchase,icon:const Icon(Icons.keyboard_return),label:const Text('Trả nhập hàng')),
      if(refundDue>0||refundReceived>0)...[const SizedBox(height:12),Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('ĐỐI SOÁT TIỀN TRẢ NHẬP',style:TextStyle(fontWeight:FontWeight.w800)),const SizedBox(height:6),Text('Đã nhận NCC hoàn: ${money(refundReceived)} đ'),Text('NCC còn phải hoàn: ${money(refundDue)} đ',style:const TextStyle(fontWeight:FontWeight.w800)),if(refundDue>0)...[const SizedBox(height:10),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:receiveSupplierRefund,icon:const Icon(Icons.payments_outlined),label:const Text('Ghi nhận NCC đã hoàn tiền')))] ])))],
      if(returns.isNotEmpty)...[const SizedBox(height:16),const Text('LỊCH SỬ TRẢ NHẬP',style:TextStyle(fontWeight:FontWeight.w800)),...returns.map((raw){final r=raw as Map;return Card(child:ListTile(title:Text('${r['ma']??'Phiếu trả'}'),subtitle:Text('${r['ngaytra']??''} • ${r['lydo']??''}'),trailing:Text('${money(_n(r['tongtien']))} đ')));})]
    ])));
  }
}

class InventoryPage extends StatefulWidget{const InventoryPage({super.key});@override State<InventoryPage>createState()=>_InventoryPageState();}
class _InventoryPageState extends State<InventoryPage>{
  bool loading=true,loadingMore=false,hasMore=true;int page=1;Map data={};String? error;
  @override void initState(){super.initState();load();}
  Future<void>load()async{if(mounted)setState((){loading=true;error=null;page=1;hasMore=true;});try{final x=await ficLoadCachedModule('inventory','/inventory?page=1&per_page=20');data=(x as Map?)?.cast<String,dynamic>()??{};hasMore=!ficOfflineMode&&((data['pagination'] as Map?)?['has_more']==true);}catch(e){error=e.toString().replaceFirst('Exception: ','');}finally{if(mounted)setState(()=>loading=false);}}
  Future<void>loadMore()async{if(ficOfflineMode||loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/inventory?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};data['stocktakes']=[...List.from(data['stocktakes'] as List? ?? []),...List.from(d['stocktakes'] as List? ?? [])];data['pagination']=d['pagination'];page=next;hasMore=((d['pagination'] as Map?)?['has_more']==true);}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}
  Future<void>create()async{
    try{
      if(ficOfflineMode){
        final localId=-DateTime.now().millisecondsSinceEpoch;
        final products=List.from(data['products'] as List? ?? []);
        final items=<Map<String,dynamic>>[];
        for(final raw in products){final p=raw as Map;final pid=int.tryParse('${p['id']}')??0;if(pid<=0)continue;final stock=num.tryParse('${p['tonkho']??p['soluongton']??p['soluong']??0}')??0;items.add(<String,dynamic>{'id':-pid,'id_sanpham':pid,'masanpham':p['masanpham'],'tensanpham':p['tensanpham'],'donvitinh':p['donvitinh']??'cái','tonhethong':stock,'tonthucte':stock});}
        final sheet=<String,dynamic>{'id':localId,'ma':'OFF-KK-${DateTime.now().millisecondsSinceEpoch}','ngaykiem':DateTime.now().toIso8601String(),'trangthai':'tam','offline':true};
        final local=<String,dynamic>{'sheet':sheet,'items':items};await ficCacheModule('stocktake_$localId',local);
        final rows=List.from(data['stocktakes'] as List? ?? []);rows.insert(0,sheet);data['stocktakes']=rows;await ficCacheModule('inventory',data);if(mounted)Navigator.push(context,MaterialPageRoute(builder:(_)=>StocktakePage(id:localId)));return;
      }
      final r=await api.post('/stocktakes',{});final sheet=(r['data'] as Map?)?['sheet'] as Map?;await load();if(sheet!=null&&mounted)Navigator.push(context,MaterialPageRoute(builder:(_)=>StocktakePage(id:int.parse('${sheet['id']}'))));
    }
    catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  @override Widget build(BuildContext c){final rows=List.from(data['stocktakes'] as List? ?? []);return Scaffold(appBar:AppBar(title:const Text('Kiểm kho')),floatingActionButton:FloatingActionButton.extended(onPressed:loading?null:create,icon:const Icon(Icons.add_task),label:const Text('Tạo phiếu kiểm')),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.error_outline,size:48),const SizedBox(height:12),Text(error!,textAlign:TextAlign.center),const SizedBox(height:16),FilledButton.icon(onPressed:load,icon:const Icon(Icons.refresh),label:const Text('Thử lại'))]))):RefreshIndicator(onRefresh:load,child:NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(padding:const EdgeInsets.all(14),children:[...rows.map((e){final m=e as Map;return Card(child:ListTile(onTap:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>StocktakePage(id:int.parse('${m['id']}')))),title:Text('${m['ma']??''}'),subtitle:Text('${m['ngaykiem']??''} • ${m['trangthai']??''}'),trailing:const Icon(Icons.chevron_right)));}),if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)))]))));}}
class StocktakePage extends StatefulWidget{final int id;const StocktakePage({super.key,required this.id});@override State<StocktakePage>createState()=>_StocktakePageState();}
class _StocktakePageState extends State<StocktakePage>{
  bool loading=true;Map data={};final ctrls=<int,TextEditingController>{};
  @override void initState(){super.initState();load();}
  String? error;
  Future<void>load()async{
    if(mounted)setState((){loading=true;error=null;});
    try{
      if(ficOfflineMode || widget.id<0){
        final branchId=await ficOfflineBranchId();final cached=branchId>0?await OfflineStore.getModule(api.baseUrl,branchId,'stocktake_${widget.id}'):null;if(cached==null)throw Exception('Chưa có dữ liệu kiểm kho offline.');data=(cached as Map).cast<String,dynamic>();
      }else{
        final r=await api.get('/stocktakes/${widget.id}');data=(r['data'] as Map?)??{};await ficCacheModule('stocktake_${widget.id}',data);
      }
      for(final e in (data['items'] as List? ?? [])){
        final m=e as Map;final id=int.parse('${m['id']}');final unit=_unitOf(m);
        ctrls[id]?.dispose();
        ctrls[id]=TextEditingController(text:_stockQtyText(m['tonthucte'],unit));
      }
    }catch(e){error=e.toString().replaceFirst('Exception: ','');}
    finally{if(mounted)setState(()=>loading=false);}
  }
  Future<void>save()async{
    final items=(data['items'] as List? ?? []).map((e){
      final m=e as Map;final id=int.parse('${m['id']}');final unit=_unitOf(m);
      final v=_parseStockQty(ctrls[id]?.text??'0',unit);
      return {'detail_id':m['id'],'actual':_isCountUnit(unit)?v.toInt():v};
    }).toList();
    if(ficOfflineMode || widget.id<0){
      for(final raw in (data['items'] as List? ?? [])){final m=raw as Map;final id=int.tryParse('${m['id']}')??0;final unit=_unitOf(m);final v=_parseStockQty(ctrls[id]?.text??'0',unit);m['tonthucte']=_isCountUnit(unit)?v.toInt():v;}
      await ficCacheModule('stocktake_${widget.id}',data);
      if(widget.id>0) await ficQueueBusinessAction('stocktake_update',{'stocktake_id':widget.id,'items':items});
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã lưu kiểm kho offline')));
    }else{await api.put('/stocktakes/${widget.id}',{'items':items});await load();}
  }
  Future<void>complete()async{
    if(ficOfflineMode || widget.id<0){
      await save();
      if(widget.id<0){final payloadItems=(data['items'] as List? ?? []).map((e){final m=e as Map;return {'product_id':m['id_sanpham'],'actual':m['tonthucte']??0};}).toList();await ficQueueBusinessAction('stocktake_full',{'items':payloadItems,'complete':true});}
      else{await ficQueueBusinessAction('stocktake_complete',{'stocktake_id':widget.id});}
      final sheet=(data['sheet'] as Map?)??{};sheet['trangthai']='cho_dong_bo';sheet['offline']=true;await ficCacheModule('stocktake_${widget.id}',data);if(mounted)setState((){});if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã hoàn thành kiểm kho offline • chờ đồng bộ')));
    }else{await save();await api.post('/stocktakes/${widget.id}/complete',{});await load();}
  }
  @override void dispose(){for(final c in ctrls.values)c.dispose();super.dispose();}
  @override Widget build(BuildContext c){
    final sheet=data['sheet'] as Map? ?? {};final items=List.from(data['items'] as List? ?? []);final temp='${sheet['trangthai']??'tam'}'=='tam';
    return Scaffold(
      appBar:AppBar(title:Text('${sheet['ma']??'Kiểm kho'}')),
      bottomNavigationBar:temp?SafeArea(child:Padding(padding:const EdgeInsets.all(10),child:Row(children:[Expanded(child:OutlinedButton(onPressed:save,child:const Text('Lưu tạm'))),const SizedBox(width:8),Expanded(child:FilledButton(onPressed:complete,child:const Text('Hoàn thành & cập nhật kho')))]))):null,
      body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[const Icon(Icons.error_outline,size:48),const SizedBox(height:12),Text(error!,textAlign:TextAlign.center),const SizedBox(height:16),FilledButton.icon(onPressed:load,icon:const Icon(Icons.refresh),label:const Text('Thử lại'))]))):ListView(
        padding:const EdgeInsets.all(12),
        children:items.map((e){
          final m=e as Map;final id=int.parse('${m['id']}');final unit=_unitOf(m);final integerOnly=_isCountUnit(unit);
          return Card(child:Padding(padding:const EdgeInsets.fromLTRB(14,12,14,12),child:Row(crossAxisAlignment:CrossAxisAlignment.center,children:[
            Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('${m['tensanpham']??''}',style:const TextStyle(fontWeight:FontWeight.w600,fontSize:16)),
              const SizedBox(height:4),
              Text('Tồn hệ thống: ${_stockQtyText(m['tonhethong'],unit)} $unit',style:TextStyle(color:Theme.of(c).colorScheme.onSurfaceVariant)),
            ])),
            const SizedBox(width:12),
            SizedBox(width:120,child:TextField(
              enabled:temp,controller:ctrls[id],
              keyboardType:TextInputType.numberWithOptions(decimal:!integerOnly),
              inputFormatters:[_StockQtyFormatter(integerOnly)],
              textAlign:TextAlign.right,
              decoration:InputDecoration(labelText:'Thực tế',suffixText:unit,isDense:true),
            )),
          ])));
        }).toList(),
      ),
    );
  }
}


class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});
  @override State<RecipesPage> createState()=>_RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  bool loading=true;
  bool searchOpen=false;
  bool listening=false;
  String? error;
  Map<String,dynamic> data={};
  String query='';
  int? groupId;
  final search=TextEditingController();
  final speech=stt.SpeechToText();

  @override void initState(){super.initState();load();}
  @override void dispose(){speech.stop();search.dispose();super.dispose();}

  Future<void> load() async {
    setState(()=>loading=true);
    try {
      dynamic x=await ficLoadCachedModule('recipes','/recipes');
      var next=(x as Map?)?.cast<String,dynamic>()??{};
      next=await ficValidateRecipeScope(next);
      if(!ficOfflineMode){ next=await ficCacheRecipeImages(next); await ficCacheModule('recipes',next); }
      data=next; error=null;
    } catch(e){error=e.toString().replaceFirst('Exception: ','');}
    if(mounted)setState(()=>loading=false);
  }

  Future<void> startVoiceSearch() async {
    if(listening){
      await speech.stop();
      if(mounted)setState(()=>listening=false);
      return;
    }
    final ok=await speech.initialize(
      onStatus:(status){
        if(!mounted)return;
        if(status=='done'||status=='notListening')setState(()=>listening=false);
      },
      onError:(_){if(mounted)setState(()=>listening=false);},
    );
    if(!ok){
      if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Không thể bật nhận diện giọng nói trên thiết bị này.')));
      return;
    }
    if(mounted)setState(()=>listening=true);
    await speech.listen(
      localeId:'vi_VN',
      listenOptions:stt.SpeechListenOptions(partialResults:true,cancelOnError:true),
      onResult:(result){
        if(!mounted)return;
        final text=result.recognizedWords.trim();
        search.value=TextEditingValue(text:text,selection:TextSelection.collapsed(offset:text.length));
        setState(()=>query=text);
      },
    );
  }

  void closeSearch(){
    speech.stop();
    search.clear();
    setState((){searchOpen=false;listening=false;query='';});
  }

  List<Map<String,dynamic>> get groups=>List.from(data['groups'] as List? ?? const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();
  List<Map<String,dynamic>> get glasses=>List.from(data['glasses'] as List? ?? const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();
  Map<String,dynamic>? glass(dynamic id){for(final g in glasses){if('${g['id']}'=='$id')return g;}return null;}
  List<Map<String,dynamic>> get rows {
    final q=query.trim().toLowerCase();
    return List.from(data['recipes'] as List? ?? const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).where((r){
      if(groupId!=null && int.tryParse('${r['nhom_id']}')!=groupId)return false;
      if(q.isEmpty)return true;
      return '${r['ten_cong_thuc']??''}'.toLowerCase().contains(q);
    }).toList();
  }
  ImageProvider? glassImage(Map<String,dynamic>? g){
    if(g==null)return null;
    final b='${g['image_b64']??''}';
    if(b.isNotEmpty){try{return MemoryImage(base64Decode(b));}catch(_){}}
    final u='${g['image_url']??''}';
    if(u.isNotEmpty&&!ficOfflineMode)return NetworkImage(u);
    return null;
  }
  void showGlass(Map<String,dynamic> g){
    final provider=glassImage(g);
    showDialog(context:context,builder:(dc)=>AlertDialog(title:Text('${g['ten']??'Ly sử dụng'}'),content:Column(mainAxisSize:MainAxisSize.min,children:[Container(height:260,width:260,decoration:BoxDecoration(borderRadius:BorderRadius.circular(16),color:Colors.white),alignment:Alignment.center,child:provider==null?const Icon(Icons.local_cafe_outlined,size:80):Image(image:provider,fit:BoxFit.contain)),if('${g['ma']??''}'.isNotEmpty)Padding(padding:const EdgeInsets.only(top:10),child:Text('${g['ma']}')),if('${g['ghi_chu']??''}'.isNotEmpty)Padding(padding:const EdgeInsets.only(top:6),child:Text('${g['ghi_chu']}',textAlign:TextAlign.center,style:const TextStyle(color:Colors.black54)))]),actions:[TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Đóng'))]));
  }
  Widget ingredientList(Map<String,dynamic> r){
    final a='${r['nguyen_lieu']??''}'.split('\n'),b='${r['dinh_luong']??''}'.split('\n'),n=maxInt(a.length,b.length);
    if(a.join('').trim().isEmpty&&b.join('').trim().isEmpty)return const Text('—',style:TextStyle(color:Colors.black45));
    return Column(children:List.generate(n,(i)=>Padding(padding:const EdgeInsets.symmetric(vertical:3),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Text(i<a.length?a[i]:'')),const SizedBox(width:10),Text(i<b.length?b[i]:'',style:const TextStyle(fontWeight:FontWeight.w700))]))));
  }
  Widget recipeCard(Map<String,dynamic> r){
    final g=glass(r['ly_su_dung']); final gp=r['group'] is Map?Map<String,dynamic>.from(r['group'] as Map):null;
    final provider=glassImage(g);
    return Card(margin:const EdgeInsets.only(bottom:12),child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('${r['ten_cong_thuc']??''}',style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800)),if(gp!=null&&'${gp['ten']??''}'.isNotEmpty)Padding(padding:const EdgeInsets.only(top:4),child:Text('${gp['ten']}',style:const TextStyle(color:Colors.black54)))])),if(g!=null)InkWell(onTap:()=>showGlass(g),borderRadius:BorderRadius.circular(12),child:Container(width:72,padding:const EdgeInsets.all(6),decoration:BoxDecoration(borderRadius:BorderRadius.circular(12),border:Border.all(color:Theme.of(context).colorScheme.outlineVariant)),child:Column(children:[SizedBox(width:54,height:54,child:provider==null?const Icon(Icons.local_cafe_outlined):Image(image:provider,fit:BoxFit.contain)),const SizedBox(height:4),Text('${g['ten']??'Ly'}',maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:11,fontWeight:FontWeight.w700))]))) ]),
      const Divider(height:22),const Text('NGUYÊN LIỆU & ĐỊNH LƯỢNG',style:TextStyle(fontSize:12,fontWeight:FontWeight.w800,color:Colors.black54)),const SizedBox(height:6),ingredientList(r),
      if('${r['cach_lam']??''}'.trim().isNotEmpty)...[const SizedBox(height:12),const Text('CÁCH LÀM',style:TextStyle(fontSize:12,fontWeight:FontWeight.w800,color:Colors.black54)),const SizedBox(height:5),Text('${r['cach_lam']}')],
      if('${r['ghi_chu']??''}'.trim().isNotEmpty)Container(margin:const EdgeInsets.only(top:10),padding:const EdgeInsets.all(10),decoration:BoxDecoration(borderRadius:BorderRadius.circular(10),color:Colors.amber.withValues(alpha:.12)),child:Text('Ghi chú: ${r['ghi_chu']}')),
    ])));
  }

  Widget searchBar(){
    return Material(
      elevation:3,
      borderRadius:BorderRadius.circular(16),
      child:TextField(
        controller:search,
        autofocus:true,
        onChanged:(v)=>setState(()=>query=v),
        decoration:InputDecoration(
          hintText:'Tìm theo tên công thức...',
          prefixIcon:const Icon(Icons.search),
          suffixIcon:Row(mainAxisSize:MainAxisSize.min,children:[
            IconButton(
              tooltip:listening?'Dừng nghe':'Tìm bằng giọng nói',
              onPressed:startVoiceSearch,
              icon:Icon(listening?Icons.mic:Icons.mic_none),
            ),
            IconButton(tooltip:'Đóng tìm kiếm',onPressed:closeSearch,icon:const Icon(Icons.close)),
          ]),
          border:OutlineInputBorder(borderRadius:BorderRadius.circular(16),borderSide:BorderSide.none),
          filled:true,
        ),
      ),
    );
  }

  @override Widget build(BuildContext context){
    final rs=rows;
    final content=loading
      ? const Center(child:CircularProgressIndicator())
      : error!=null
        ? Center(child:Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[Text(error!,textAlign:TextAlign.center),const SizedBox(height:12),FilledButton(onPressed:load,child:const Text('Thử lại'))])))
        : RefreshIndicator(onRefresh:load,child:ListView(padding:EdgeInsets.fromLTRB(14,14,14,searchOpen?92:78),children:[
            SizedBox(height:42,child:ListView(scrollDirection:Axis.horizontal,children:[ChoiceChip(label:const Text('Tất cả'),selected:groupId==null,onSelected:(_)=>setState(()=>groupId=null)),const SizedBox(width:7),...groups.map((g)=>Padding(padding:const EdgeInsets.only(right:7),child:ChoiceChip(label:Text('${g['ten']??''}'),selected:groupId==int.tryParse('${g['id']}'),onSelected:(_)=>setState(()=>groupId=int.tryParse('${g['id']}')))))])),
            const SizedBox(height:12),
            if(rs.isEmpty)Card(child:Padding(padding:const EdgeInsets.all(24),child:Text(query.trim().isEmpty?'Chưa có công thức.':'Không tìm thấy công thức tên "$query".',textAlign:TextAlign.center))),
            ...rs.map(recipeCard),
          ]));
    return Scaffold(
      appBar:AppBar(title:const Text('Công thức'),actions:[if(ficOfflineMode)const Padding(padding:EdgeInsets.only(right:8),child:Center(child:Chip(label:Text('Offline')))),IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),
      body:Stack(children:[
        Positioned.fill(child:content),
        if(searchOpen&&!loading&&error==null)Positioned(left:14,right:14,bottom:14,child:SafeArea(top:false,child:searchBar())),
      ]),
      floatingActionButton:(!searchOpen&&!loading&&error==null)?FloatingActionButton(onPressed:()=>setState(()=>searchOpen=true),tooltip:'Tìm công thức',child:const Icon(Icons.search)):null,
    );
  }
}

class IngredientsPage extends StatefulWidget{const IngredientsPage({super.key});@override State<IngredientsPage>createState()=>_IngredientsPageState();}
class _IngredientsPageState extends State<IngredientsPage>{
  bool loading=true,selectedOnly=false,reporting=false;Map data={};String? error;final search=TextEditingController();final Set<int> selected={};
  @override void initState(){super.initState();search.addListener(_refresh);load();}
  @override void dispose(){search.removeListener(_refresh);search.dispose();super.dispose();}
  void _refresh(){if(mounted)setState((){});}
  int _id(Map m)=>int.tryParse('${m['id']??0}')??0;
  bool _reported(Map m)=>int.tryParse('${m['dabao']}')==1;
  Future<void>load()async{setState((){loading=true;error=null;});try{final x=await ficLoadCachedModule('ingredients','/ingredients');data=(x as Map?)?.cast<String,dynamic>()??{};final ids=List.from(data['ingredients'] as List? ?? []).map((e)=>_id(e as Map)).toSet();selected.removeWhere((id)=>!ids.contains(id));}catch(e){error='$e';}finally{if(mounted)setState(()=>loading=false);}}
  Future<void>reportSelected()async{if(selected.isEmpty||reporting)return;final ids=selected.toList();setState(()=>reporting=true);try{if(ficOfflineMode){await ficQueueBusinessAction('ingredient_report',{'ids':ids});for(final e in List.from(data['ingredients'] as List? ?? [])){final m=e as Map;if(selected.contains(_id(m)))m['dabao']=1;}await ficCacheModule('ingredients',data);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Đã ghi nhận báo ${ids.length} nguyên liệu • chờ đồng bộ')));}else{await api.post('/ingredients/report',{'ids':ids});await load();if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Đã báo ${ids.length} nguyên liệu')));}selected.clear();selectedOnly=false;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Không gửi được báo nguyên liệu: $e')));}finally{if(mounted)setState(()=>reporting=false);}}
  @override Widget build(BuildContext c){
    final all=List.from(data['ingredients'] as List? ?? []).cast<dynamic>();final q=search.text.trim().toLowerCase();
    final rows=all.where((e){final m=e as Map;final name='${m['tensanpham']??''}'.toLowerCase();if(q.isNotEmpty&&!name.contains(q))return false;if(selectedOnly&&!selected.contains(_id(m)))return false;return true;}).toList();
    return Scaffold(appBar:AppBar(title:const Text('Báo nguyên liệu')),bottomNavigationBar:selected.isEmpty?null:SafeArea(child:Container(padding:const EdgeInsets.fromLTRB(14,8,14,10),decoration:BoxDecoration(color:Theme.of(c).colorScheme.surface,boxShadow:const [BoxShadow(blurRadius:10,color:Color(0x22000000),offset:Offset(0,-2))]),child:Row(children:[Expanded(child:Text('Đã chọn ${selected.length} nguyên liệu',style:const TextStyle(fontWeight:FontWeight.w600))),FilledButton.icon(onPressed:reporting?null:reportSelected,icon:reporting?const SizedBox(width:16,height:16,child:CircularProgressIndicator(strokeWidth:2)):const Icon(Icons.notifications_active_outlined),label:Text('Báo ${selected.length} nguyên liệu'))]))),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Column(mainAxisSize:MainAxisSize.min,children:[Text('Không tải được nguyên liệu\n$error',textAlign:TextAlign.center),const SizedBox(height:12),FilledButton(onPressed:load,child:const Text('Thử lại'))])):Column(children:[
      Padding(padding:const EdgeInsets.fromLTRB(14,14,14,8),child:TextField(controller:search,decoration:InputDecoration(prefixIcon:const Icon(Icons.search),hintText:'Tìm nguyên liệu...',suffixIcon:search.text.isEmpty?null:IconButton(onPressed:search.clear,icon:const Icon(Icons.close)),border:const OutlineInputBorder()))),
      Padding(padding:const EdgeInsets.symmetric(horizontal:14),child:Row(children:[FilterChip(selected:!selectedOnly,label:const Text('Tất cả'),onSelected:(_)=>setState(()=>selectedOnly=false)),const SizedBox(width:8),FilterChip(selected:selectedOnly,label:Text('Đã chọn (${selected.length})'),onSelected:(_)=>setState(()=>selectedOnly=true)),const Spacer(),if(selected.isNotEmpty)TextButton(onPressed:()=>setState((){selected.clear();selectedOnly=false;}),child:const Text('Bỏ chọn tất cả'))])),
      const SizedBox(height:4),
      Expanded(child:rows.isEmpty?Center(child:Text(selectedOnly?'Chưa có nguyên liệu nào được chọn':'Không tìm thấy nguyên liệu')):ListView(padding:const EdgeInsets.fromLTRB(14,4,14,14),children:rows.map((e){final m=e as Map;final id=_id(m);final unit='${m['donvitinh']??'cái'}';final stock='${m['tonkho']??''}';final threshold='${m['fic_low_stock_threshold']??''}';final reported=_reported(m);final status=reported?'Đã báo sắp hết':'Đang đủ';return Card(child:CheckboxListTile(value:selected.contains(id),onChanged:reported?null:(v)=>setState((){if(v==true){selected.add(id);}else{selected.remove(id);}}),controlAffinity:ListTileControlAffinity.leading,title:Text('${m['tensanpham']??''}'),subtitle:Text('$status${stock.isNotEmpty?' · Tồn: $stock $unit':''}${threshold.isNotEmpty?' · Cảnh báo: $threshold $unit':''}'),secondary:reported?const Icon(Icons.check_circle_outline):null));}).toList()))
    ]));
  }
}

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});
  @override State<TasksPage> createState() => _TasksPageState();
}
class _TasksPageState extends State<TasksPage> {
  bool loading = true;
  Map data = {};
  @override void initState(){ super.initState(); load(); }
  Future<void> load() async { setState(()=>loading=true); final x=await ficLoadCachedModule('tasks','/tasks'); data=(x as Map?)?.cast<String,dynamic>()??{}; if(mounted)setState(()=>loading=false); }
  Future<void> done(Map m) async {
    int shift = 1;
    await showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (dc,setD) => AlertDialog(
          title: const Text('Hoàn thành công việc'),
          content: DropdownButtonFormField<int>(
            value: shift,
            decoration: const InputDecoration(labelText:'Ca làm'),
            items: const [
              DropdownMenuItem(value:1,child:Text('Ca 1')),
              DropdownMenuItem(value:2,child:Text('Ca 2')),
              DropdownMenuItem(value:3,child:Text('Ca 3')),
            ],
            onChanged:(v)=>setD(()=>shift=v??1),
          ),
          actions: [
            TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Hủy')),
            FilledButton(
              onPressed:() async {
                if(ficOfflineMode){
                  await ficQueueBusinessAction('task_done',{'task_id':m['id'],'shift':'$shift'});m['trangthai']=1;m['offline']=true;await ficCacheModule('tasks',data);if(dc.mounted)Navigator.pop(dc);if(mounted)setState((){});
                }else{await api.put('/tasks/${m['id']}',{'shift':'$shift'});if(dc.mounted)Navigator.pop(dc);await load();}
              },
              child:const Text('Xác nhận'),
            ),
          ],
        ),
      ),
    );
  }
  @override Widget build(BuildContext context){
    final rows=List.from(data['daily'] as List? ?? []);
    return Scaffold(
      appBar:AppBar(title:const Text('Công việc hằng ngày')),
      body:loading?const Center(child:CircularProgressIndicator()):ListView(
        padding:const EdgeInsets.all(14),
        children:rows.map((e){
          final m=e as Map; final donev=int.tryParse('${m['trangthai']}')==1;
          return Card(child:CheckboxListTile(value:donev,onChanged:donev?null:(_)=>done(m),title:Text('${m['tencongviec']??m['noidung']??'Công việc'}'),subtitle:Text('${m['ghichu']??''}')));
        }).toList(),
      ),
    );
  }
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key});
  @override State<SchedulePage> createState()=>_SchedulePageState();
}
class _SchedulePageState extends State<SchedulePage>{
  bool loading=true; Map data={}; final selected=<String,bool>{};
  @override void initState(){super.initState();load();}
  Future<void> load() async {setState(()=>loading=true);final r=await api.get('/schedule');data=(r['data'] as Map?)??{};if(mounted)setState(()=>loading=false);}
  Future<void> save() async {
    final shifts=List.from(data['shifts'] as List? ?? []); final payload=<String,dynamic>{};
    for(final sh in shifts){final m=sh as Map;final sid='${m['id']}';payload[sid]=<String,int>{};for(var d=0;d<7;d++){payload[sid]['day$d']=(selected['$sid-$d']??false)?1:0;}}
    await api.post('/schedule/register',{'shift':payload});
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Đã lưu đăng ký lịch')));
    await load();
  }
  @override Widget build(BuildContext context){
    final shifts=List.from(data['shifts'] as List? ?? []); final locked=data['locked']==true;
    return Scaffold(
      appBar:AppBar(title:const Text('Đăng ký lịch làm việc')),
      bottomNavigationBar:SafeArea(child:Padding(padding:const EdgeInsets.all(10),child:FilledButton(onPressed:locked?null:save,child:Text(locked?'Lịch đã chốt':'Lưu đăng ký')))),
      body:loading?const Center(child:CircularProgressIndicator()):ListView(
        padding:const EdgeInsets.all(14),
        children:[
          Text('Chế độ: ${data['mode']??''}'),
          const SizedBox(height:8),
          ...shifts.map((e){
            final m=e as Map; final sid='${m['id']}';
            return Card(child:Padding(padding:const EdgeInsets.all(10),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('${m['tencalamviec']??m['tenca']??'Ca'} ${m['thoigianlam']??''}',style:const TextStyle(fontWeight:FontWeight.bold)),
              Wrap(children:List.generate(7,(d)=>FilterChip(label:Text(['T2','T3','T4','T5','T6','T7','CN'][d]),selected:selected['$sid-$d']??false,onSelected:locked?null:(v)=>setState(()=>selected['$sid-$d']=v)))),
            ])));
          }),
        ],
      ),
    );
  }
}

class LateRequestPage extends StatefulWidget {
  const LateRequestPage({super.key});
  @override State<LateRequestPage> createState()=>_LateRequestPageState();
}
class _LateRequestPageState extends State<LateRequestPage>{
  bool loading=true,loadingMore=false,hasMore=true;int page=1; Map data={};
  @override void initState(){super.initState();load();}
  Future<void> load() async {setState((){loading=true;page=1;hasMore=true;});final r=await api.get('/late-requests?page=1&per_page=20');data=(r['data'] as Map?)??{};hasMore=((data['pagination'] as Map?)?['has_more']==true);if(mounted)setState(()=>loading=false);}
  Future<void> loadMore()async{if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/late-requests?page=$next&per_page=20');final d=(r['data'] as Map?)??{};data['requests']=[...List.from(data['requests'] as List? ?? []),...List.from(d['requests'] as List? ?? [])];data['pagination']=d['pagination'];page=next;hasMore=((d['pagination'] as Map?)?['has_more']==true);}finally{if(mounted)setState(()=>loadingMore=false);}}
  Future<void> create() async {
    final id=TextEditingController(),reason=TextEditingController(),time=TextEditingController();
    await showDialog<void>(
      context:context,
      builder:(dc)=>AlertDialog(
        title:const Text('Xin đi trễ'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:id,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'ID ca làm việc')),
          TextField(controller:time,decoration:const InputDecoration(labelText:'Giờ dự kiến đến (HH:mm)')),
          TextField(controller:reason,maxLines:2,decoration:const InputDecoration(labelText:'Lý do')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Hủy')),
          FilledButton(onPressed:() async {await api.post('/late-requests',{'schedule_id':int.tryParse(id.text),'reason':reason.text.trim(),'arrival_time':time.text.trim()});if(dc.mounted)Navigator.pop(dc);await load();},child:const Text('Gửi')),
        ],
      ),
    );
  }
  @override Widget build(BuildContext context){
    final rows=List.from(data['requests'] as List? ?? []);
    return Scaffold(
      appBar:AppBar(title:const Text('Xin đi trễ')),
      floatingActionButton:FloatingActionButton.extended(onPressed:create,icon:const Icon(Icons.add),label:const Text('Tạo yêu cầu')),
      body:loading?const Center(child:CircularProgressIndicator()):NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(padding:const EdgeInsets.all(14),children:[...rows.map((e){final m=e as Map;return Card(child:ListTile(title:Text('${m['ly_do']??m['lydo']??'Xin đi trễ'}'),subtitle:Text('${m['thoigian_den']??''} • Trạng thái: ${m['trangthai']??''}')));}),if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)))])),
    );
  }
}

class SalaryAdvancePage extends StatefulWidget {
  const SalaryAdvancePage({super.key});
  @override State<SalaryAdvancePage> createState()=>_SalaryAdvancePageState();
}
class _SalaryAdvancePageState extends State<SalaryAdvancePage>{
  bool loading=true,loadingMore=false,hasMore=true; int page=1; Map data={};
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    setState((){loading=true;page=1;hasMore=true;});
    final r=await api.get('/salary-advances?page=1&per_page=20');
    data=(r['data'] as Map?)??{};
    hasMore=((data['pagination'] as Map?)?['has_more']==true);
    if(mounted)setState(()=>loading=false);
  }
  Future<void> loadMore() async {
    if(loadingMore||!hasMore)return;
    setState(()=>loadingMore=true);
    try{
      final next=page+1;
      final r=await api.get('/salary-advances?page=$next&per_page=20');
      final d=(r['data'] as Map?)??{};
      data['requests']=[...List.from(data['requests'] as List? ?? []),...List.from(d['requests'] as List? ?? [])];
      data['pagination']=d['pagination'];
      if(d['payroll_months']!=null)data['payroll_months']=d['payroll_months'];
      page=next;
      hasMore=((d['pagination'] as Map?)?['has_more']==true);
    }finally{if(mounted)setState(()=>loadingMore=false);}
  }
  Future<void> create() async {
    final amount=TextEditingController(),note=TextEditingController(); int method=1; final now=DateTime.now(); final month=TextEditingController(text:'${now.month.toString().padLeft(2,'0')}-${now.year}');
    await showDialog<void>(
      context:context,
      builder:(dc)=>StatefulBuilder(builder:(dc,setD)=>AlertDialog(
        title:const Text('Ứng lương'),
        content:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:amount,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Số tiền ứng')),
          TextField(controller:month,decoration:const InputDecoration(labelText:'Tháng lương MM-YYYY')),
          DropdownButtonFormField<int>(value:method,decoration:const InputDecoration(labelText:'Hình thức nhận'),items:const [DropdownMenuItem(value:1,child:Text('Tiền mặt')),DropdownMenuItem(value:2,child:Text('Chuyển khoản'))],onChanged:(v)=>setD(()=>method=v??1)),
          TextField(controller:note,decoration:const InputDecoration(labelText:'Ghi chú')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Hủy')),
          FilledButton(onPressed:() async {await api.post('/salary-advances',{'amount':num.tryParse(amount.text)??0,'method':method,'month':month.text.trim(),'note':note.text.trim()});if(dc.mounted)Navigator.pop(dc);await load();},child:const Text('Gửi yêu cầu')),
        ],
      )),
    );
  }
  @override Widget build(BuildContext context){
    final rows=List.from(data['requests'] as List? ?? []);
    return Scaffold(
      appBar:AppBar(title:const Text('Ứng lương')),
      floatingActionButton:FloatingActionButton.extended(onPressed:create,icon:const Icon(Icons.add),label:const Text('Ứng lương')),
      body:loading?const Center(child:CircularProgressIndicator()):NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(padding:const EdgeInsets.all(14),children:[...rows.map((e){final m=e as Map;return Card(child:ListTile(title:Text('${money(num.tryParse('${m['sotienung']}')??0)} đ'),subtitle:Text('${m['luongthang']??''} • ${m['ghichu']??''}'),trailing:Text('TT ${m['trangthai']??''}')));}),if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)))])),
    );
  }
}

class DailyReportPage extends StatefulWidget {
  const DailyReportPage({super.key});
  @override State<DailyReportPage> createState()=>_DailyReportPageState();
}
class _DailyReportPageState extends State<DailyReportPage>{
  bool loading=true; Map data={};
  @override void initState(){super.initState();load();}
  Future<void> load() async {setState(()=>loading=true);final r=await api.get('/daily-report');data=(r['data'] as Map?)??{};if(mounted)setState(()=>loading=false);}
  Widget row(String k,dynamic v,{bool isMoney=false})=>Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[Expanded(child:Text(k)),Text(isMoney?'${money(num.tryParse('$v')??0)} đ':'$v',style:const TextStyle(fontWeight:FontWeight.w700))]));
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar:AppBar(title:const Text('Báo cáo cuối ngày')),
      body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(14),children:[Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(children:[row('Ngày',data['date']),row('Hóa đơn',data['invoices']),row('Doanh thu gốc',data['gross'],isMoney:true),row('Khuyến mãi',data['discount'],isMoney:true),row('Trả hàng',data['refund'],isMoney:true),row('Doanh thu thực thu',data['revenue'],isMoney:true),const Divider(),row('Tiền mặt bán hàng',data['cash'],isMoney:true),row('Chuyển khoản bán hàng',data['bank'],isMoney:true),row('Thu khác',data['cashbook_income'],isMoney:true),row('Chi',data['cashbook_expense'],isMoney:true),row('Dòng tiền thu chi',data['cashbook_net'],isMoney:true)])))])
    );
  }
}


class PurchaseReturnDetailPage extends StatefulWidget {
  final Map initial;
  const PurchaseReturnDetailPage({super.key, required this.initial});
  @override State<PurchaseReturnDetailPage> createState()=>_PurchaseReturnDetailPageState();
}

class _PurchaseReturnDetailPageState extends State<PurchaseReturnDetailPage>{
  bool loading=true; String? error; Map data={};
  String s(dynamic v)=>v==null?'':'$v';
  num n(dynamic v)=>num.tryParse('$v')??0;
  @override void initState(){super.initState();load();}
  Future<void> load() async {
    final id=widget.initial['id'];
    if(id==null){setState((){loading=false;error='Không tìm thấy mã phiếu trả nhập.';});return;}
    setState(()=>loading=true);
    try{final r=await api.get('/purchase-returns/$id');data=(r['data'] as Map?)??{};error=null;}
    catch(e){error=e.toString().replaceFirst('Exception: ','');}
    if(mounted)setState(()=>loading=false);
  }
  Widget kv(String a,dynamic b,{bool moneyValue=false,bool strong=false})=>Padding(
    padding:const EdgeInsets.symmetric(vertical:5),
    child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
      SizedBox(width:125,child:Text(a,style:const TextStyle(color:Colors.black54))),
      Expanded(child:Text(moneyValue?'${money(n(b))} đ':s(b),style:TextStyle(fontWeight:strong?FontWeight.w800:FontWeight.w500))),
    ]),
  );
  @override Widget build(BuildContext context){
    final h=(data['return'] as Map?)??widget.initial;
    final items=List.from(data['items'] as List? ?? const []);
    final f=(data['financials'] as Map?)??{};
    return Scaffold(
      appBar:AppBar(title:const Text('Chi tiết trả hàng nhập'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),
      body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Text(error!))):ListView(
        padding:const EdgeInsets.all(14),children:[
          Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(s(h['ma']).isEmpty?'Phiếu trả #${h['id']??''}':s(h['ma']),style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900)),
            const SizedBox(height:8),
            kv('Phiếu nhập',s(h['ma_phieunhap']).isEmpty?'#${h['id_phieunhap']??''}':h['ma_phieunhap']),
            kv('Nhà cung cấp',h['ncc']??''),
            if(s(h['ncc_dienthoai']).isNotEmpty)kv('Điện thoại',h['ncc_dienthoai']),
            kv('Ngày trả',h['ngaytra']??h['created_at']??''),
            kv('Tổng tiền trả',h['tongtien'],moneyValue:true,strong:true),
            kv('Lý do',h['lydo']??''),
            kv('Người tạo',s(h['nguoi_tao_ten']).isNotEmpty?h['nguoi_tao_ten']:'#${h['created_by']??''}'),
            if(s(h['created_at']).isNotEmpty)kv('Tạo lúc',h['created_at']),
          ]))),
          const SizedBox(height:10),
          const Text('HÀNG ĐÃ TRẢ',style:TextStyle(fontWeight:FontWeight.w900,fontSize:16)),
          const SizedBox(height:6),
          if(items.isEmpty)const Card(child:Padding(padding:EdgeInsets.all(16),child:Text('Không có chi tiết hàng trả.'))),
          ...items.map((e){final m=e as Map;final name=s(m['tensanpham']).isEmpty?'Sản phẩm #${m['id_sanpham']??''}':s(m['tensanpham']);return Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text(name,style:const TextStyle(fontWeight:FontWeight.w800)),
            if(s(m['masanpham']).isNotEmpty)Text('Mã: ${s(m['masanpham'])}',style:const TextStyle(color:Colors.black54)),
            const SizedBox(height:6),
            Row(children:[Expanded(child:Text('SL: ${s(m['soluong'])}')),Expanded(child:Text('Đơn giá: ${money(n(m['dongia']))} đ',textAlign:TextAlign.right))]),
            const SizedBox(height:4),Text('Thành tiền: ${money(n(m['thanhtien']))} đ',style:const TextStyle(fontWeight:FontWeight.w800)),
          ])));}),
          if(f.isNotEmpty)...[
            const SizedBox(height:10),
            const Text('ĐỐI SOÁT PHIẾU NHẬP',style:TextStyle(fontWeight:FontWeight.w900,fontSize:16)),
            Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(children:[
              kv('Giá trị nhập',f['original_total'],moneyValue:true),
              kv('Đã trả hàng',f['returned_total'],moneyValue:true),
              kv('Giá trị còn lại',f['net_total'],moneyValue:true,strong:true),
              kv('Đã thanh toán',f['paid_total'],moneyValue:true),
              kv('Công nợ NCC',f['debt'],moneyValue:true),
              kv('NCC phải hoàn',f['supplier_credit'],moneyValue:true),
              kv('Đã nhận hoàn',f['refund_received'],moneyValue:true),
              kv('Còn phải hoàn',f['refund_due'],moneyValue:true,strong:true),
            ]))),
          ],
        ],
      ),
    );
  }
}

class NativeModulePage extends StatefulWidget {
  final String module;
  const NativeModulePage({super.key, required this.module});
  @override State<NativeModulePage> createState() => _NativeModulePageState();
}

class _NativeModulePageState extends State<NativeModulePage> {
  bool loading = true, loadingMore=false, hasMore=false; int page=1; String? error; dynamic data;
  static const labels = <String,String>{
    'kitchen':'Báo bếp / Pha chế','returns':'Trả hàng','loyalty':'Thành viên & tích điểm',
    'purchases':'Nhập hàng','purchase_returns':'Trả hàng nhập','inventory':'Kiểm kho',
    'ingredients':'Báo nguyên liệu','recipes':'Công thức','cashbook':'Sổ thu chi',
    'daily_report':'Báo cáo cuối ngày','attendance':'Chấm công','tasks':'Công việc hằng ngày',
    'schedule':'Lịch làm việc','late_request':'Xin đi trễ / nghỉ / về sớm','salary_advance':'Ứng lương',
    'payroll':'Bảng lương của tôi','violations':'Vi phạm','notifications':'Thông báo','settings':'Thiết lập app',
  };
  static const endpoints = <String,String>{
    'kitchen':'/kitchen','returns':'/sales-returns','loyalty':'/loyalty','purchases':'/purchases',
    'purchase_returns':'/purchase-returns','inventory':'/inventory','ingredients':'/ingredients','recipes':'/recipes',
    'cashbook':'/cashbook','attendance':'/attendance','tasks':'/tasks','schedule':'/schedule',
    'late_request':'/late-requests','salary_advance':'/salary-advances','payroll':'/payroll','violations':'/violations',
    'notifications':'/notifications',
  };
  @override void initState(){super.initState();load();}
  String _pageUrl(String ep,int p)=>'$ep${ep.contains('?')?'&':'?'}page=$p&per_page=20';
  Future<void> load() async { setState((){loading=true;page=1;hasMore=false;}); try { final ep=endpoints[widget.module]; if(ep==null){data={'message': widget.module=='settings'?'Thiết lập ứng dụng được lưu trên thiết bị.':'Báo cáo cuối ngày dùng dữ liệu Ca & két và hóa đơn.'};} else {final r=await api.get(_pageUrl(ep,1)); data=r['data']??r;final d=data is Map?data as Map:{};hasMore=d['has_more']==true||((d['pagination'] as Map?)?['has_more']==true);} error=null;} catch(e){error=e.toString().replaceFirst('Exception: ','');} if(mounted)setState(()=>loading=false); }
  Future<void> loadMore() async {if(loadingMore||!hasMore)return;final ep=endpoints[widget.module];if(ep==null)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get(_pageUrl(ep,next));final d=r['data']??r;final current=_rows(data);final more=_rows(d);if(data is Map && d is Map){final mm=Map<String,dynamic>.from(data as Map);if(mm['items'] is List)mm['items']=[...current,...more];else if(mm['requests'] is List)mm['requests']=[...current,...more];else{for(final k in ['entries','customers','purchases','products','stocktakes','schedule','registrations']){if(mm[k] is List){mm[k]=[...current,...more];break;}}}mm['has_more']=d['has_more'];mm['pagination']=d['pagination'];data=mm;}else{data=[...current,...more];}page=next;final dm=d is Map?d as Map:{};hasMore=dm['has_more']==true||((dm['pagination'] as Map?)?['has_more']==true);}catch(e){toast(e.toString().replaceFirst('Exception: ',''));}finally{if(mounted)setState(()=>loadingMore=false);}}
  void toast(String x)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(x)));
  List _rows(dynamic x){ if(x is List)return x; if(x is Map){ for(final k in ['entries','customers','purchases','products','stocktakes','schedule','registrations','items']){if(x[k] is List)return x[k] as List;} final lists=x.values.whereType<List>(); if(lists.isNotEmpty)return lists.first;} return const []; }
  String summary(Map m){ final preferred=['tensanpham','ten_khachhang','tencongviec','noidung','ghichu','ma','madonhang','sotienung','thucte','trangthai','created_at']; final a=<String>[]; for(final k in preferred){final v=m[k]; if(v!=null&&'$v'.trim().isNotEmpty)a.add('$v'); if(a.length>=3)break;} if(a.isEmpty){for(final e in m.entries){if(e.value!=null&&e.value is! Map&&e.value is! List){a.add('${e.key}: ${e.value}');if(a.length>=3)break;}}} return a.join(' • '); }
  Future<void> action(String type) async {
    try{
      if(type=='checkin'||type=='checkout'){await api.post('/attendance',{'action':type});toast(type=='checkin'?'Đã chấm công vào':'Đã chấm công ra');await load();return;}
      if(type=='stocktake'){final r=await api.post('/stocktakes',{});toast('Đã tạo phiếu kiểm kho #${(r['data'] as Map?)?['id']??''}');await load();return;}
      if(type=='ingredient'){final vals=await _twoFields('Báo nguyên liệu','Tên nguyên liệu','Ghi chú');if(vals!=null){await api.post('/ingredients/report',{'name':vals[0],'note':vals[1]});toast('Đã gửi báo nguyên liệu');await load();}return;}
      if(type=='advance'){final vals=await _twoFields('Ứng lương','Số tiền','Ghi chú');if(vals!=null){final now=DateTime.now();final mm=now.month.toString().padLeft(2,'0');await api.post('/salary-advances',{'amount':num.tryParse(vals[0])??0,'method':1,'month':'$mm-${now.year}','note':vals[1]});toast('Đã gửi yêu cầu ứng lương');await load();}return;}
      if(type=='cash'){final vals=await _twoFields('Tạo thu / chi','Số tiền','Ghi chú');if(vals!=null){if(!await ficEnsureMoneyShift(context,purpose:'tạo phiếu thu / chi'))return;final d=data is Map?data as Map:{};final types=(d['types'] as List?)??[];if(types.isEmpty)throw Exception('Chưa có danh mục thu chi');final id=(types.first as Map)['id'];await api.post('/cashbook',{'danhsachthuchi':id,'giatri':num.tryParse(vals[0])??0,'phuongthuc':1,'loaithuchi':1,'ghichu':vals[1]});toast('Đã tạo phiếu thu/chi');await load();}return;}
    }catch(e){toast(e.toString().replaceFirst('Exception: ',''));}
  }
  Future<List<String>?> _twoFields(String title,String a,String b) async {final c1=TextEditingController(),c2=TextEditingController();return showDialog<List<String>>(context:context,builder:(dc)=>AlertDialog(title:Text(title),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:c1,decoration:InputDecoration(labelText:a)),TextField(controller:c2,decoration:InputDecoration(labelText:b))]),actions:[TextButton(onPressed:()=>Navigator.pop(dc),child:const Text('Hủy')),FilledButton(onPressed:()=>Navigator.pop(dc,[c1.text.trim(),c2.text.trim()]),child:const Text('Lưu'))]));}
  List<Widget> actions(){switch(widget.module){case'attendance':return[FilledButton.icon(onPressed:()=>action('checkin'),icon:const Icon(Icons.login),label:const Text('Vào ca')),OutlinedButton.icon(onPressed:()=>action('checkout'),icon:const Icon(Icons.logout),label:const Text('Ra ca'))];case'inventory':return[FilledButton.icon(onPressed:()=>action('stocktake'),icon:const Icon(Icons.add_task),label:const Text('Tạo phiếu kiểm kho'))];case'ingredients':return[FilledButton.icon(onPressed:()=>action('ingredient'),icon:const Icon(Icons.add_alert),label:const Text('Báo nguyên liệu'))];case'salary_advance':return[FilledButton.icon(onPressed:()=>action('advance'),icon:const Icon(Icons.request_quote),label:const Text('Tạo yêu cầu ứng lương'))];case'cashbook':return[FilledButton.icon(onPressed:()=>action('cash'),icon:const Icon(Icons.add),label:const Text('Tạo thu / chi'))];default:return[];}}
  @override Widget build(BuildContext context){final rows=_rows(data);return Scaffold(appBar:AppBar(title:Text(labels[widget.module]??'FIC POS'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(24),child:Text(error!))):RefreshIndicator(onRefresh:load,child:NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(padding:const EdgeInsets.all(14),children:[if(actions().isNotEmpty)Wrap(spacing:8,runSpacing:8,children:actions()),if(actions().isNotEmpty)const SizedBox(height:12),if(rows.isEmpty)Card(child:Padding(padding:const EdgeInsets.all(22),child:Text(data is Map&&data['message']!=null?'${data['message']}':'Chưa có dữ liệu.'))),...rows.map((e){final m=e is Map?e:<String,dynamic>{'value':e};final isPurchaseReturn=widget.module=='purchase_returns';final sub=isPurchaseReturn?'${m['ncc']??''}${('${m['ma_phieunhap']??''}').trim().isNotEmpty?' • Phiếu nhập ${m['ma_phieunhap']}':''}${('${m['ngaytra']??''}').trim().isNotEmpty?' • ${m['ngaytra']}':''}':(m['id']!=null?'ID: ${m['id']}':null);return Card(child:ListTile(title:Text(isPurchaseReturn?('${m['ma']??('Phiếu trả #${m['id']??''}')} • ${money(num.tryParse('${m['tongtien']}')??0)} đ'):(summary(m).isEmpty?'#${m['id']??''}':summary(m))),subtitle:sub==null?null:Text(sub),trailing:isPurchaseReturn?const Icon(Icons.chevron_right):null,onTap:isPurchaseReturn?()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>PurchaseReturnDetailPage(initial:m))):null));}),if(loadingMore)const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)))]))));}
}



class FicPrinterTransport {
  static const MethodChannel _channel = MethodChannel('fic_pos/printer');

  static String ascii(String input) {
    const a='àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
    const b='aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyydAAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    var out=input;
    for(var i=0;i<a.length && i<b.length;i++) out=out.replaceAll(a[i],b[i]);
    return out;
  }

  static Uint8List escPosText(String text, {bool cut=true}) {
    final bytes=<int>[0x1b,0x40,0x1b,0x61,0x00];
    bytes.addAll(utf8.encode(ascii(text)));
    bytes.addAll([0x0a,0x0a,0x0a]);
    if(cut) bytes.addAll([0x1d,0x56,0x00]);
    return Uint8List.fromList(bytes);
  }

  static Uint8List escPosReceipt(String text, {String qrPayload=''}) {
    final bytes=<int>[...escPosText(text, cut:false)];
    final qr=qrPayload.trim();
    if(qr.isNotEmpty) {
      final data=utf8.encode(qr);
      final len=data.length+3;
      bytes.addAll([0x1b,0x61,0x01]); // center
      bytes.addAll([0x1d,0x28,0x6b,0x04,0x00,0x31,0x41,0x32,0x00]); // QR model 2
      bytes.addAll([0x1d,0x28,0x6b,0x03,0x00,0x31,0x43,0x06]); // module size
      bytes.addAll([0x1d,0x28,0x6b,0x03,0x00,0x31,0x45,0x31]); // error correction M
      bytes.addAll([0x1d,0x28,0x6b,len & 0xff,(len >> 8) & 0xff,0x31,0x50,0x30]);
      bytes.addAll(data);
      bytes.addAll([0x1d,0x28,0x6b,0x03,0x00,0x31,0x51,0x30,0x0a,0x0a]);
    }
    bytes.addAll([0x1d,0x56,0x00]);
    return Uint8List.fromList(bytes);
  }

  static Future<List<Map<String,dynamic>>> printers({String? role}) async {
    if(api.token==null || api.baseUrl.isEmpty) return [];
    final platform=Platform.isIOS?'ios':'android';
    try {
      final r=await api.get('/printers?platform=$platform');
      final d=r['data'] is Map ? Map<String,dynamic>.from(r['data'] as Map) : r;
      final rows=List.from(d['items'] as List? ?? const []);
      return rows.where((e)=>e is Map && (role==null || '${e['loai']}'==role)).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
    } catch(_) { return []; }
  }

  static Future<Map<String,dynamic>?> preferred(String role) async {
    final rows=await printers(role:role);
    if(rows.isEmpty) return null;
    return rows.firstWhere((e)=>e['mac_dinh']==true || '${e['mac_dinh']}'=='1',orElse:()=>rows.first);
  }

  static Future<bool> directPrint(BuildContext context, String role, String text, {Map<String,dynamic>? printer, String qrPayload=''}) async {
    final p=printer ?? await preferred(role);
    if(p==null || '${p['ketnoi']}'=='pc') return false;
    final copies=(int.tryParse('${p['so_ban']??1}')??1).clamp(1,10);
    try {
      for(var i=0;i<copies;i++){
        final copyText = role=='kitchen' && copies>1
            ? 'LIEN ${i+1}/$copies - ${i==0?'BEP':'THU NGAN'}\n$text'
            : text;
        final data=role=='receipt' ? escPosReceipt(copyText, qrPayload:qrPayload) : escPosText(copyText);
        if('${p['ketnoi']}'=='lan'){
          final host='${p['ip']??''}'.trim();
          final port=int.tryParse('${p['port']??9100}')??9100;
          if(host.isEmpty) throw Exception('Máy in LAN chưa có địa chỉ IP.');
          final socket=await Socket.connect(host,port,timeout:const Duration(seconds:4));
          socket.add(data); await socket.flush(); await socket.close();
        } else if('${p['ketnoi']}'=='bluetooth'){
          if(Platform.isIOS) throw Exception('Máy in Bluetooth này chưa xác nhận tương thích iOS. Hãy dùng LAN/IP hoặc AirPrint cho iPhone/iPad.');
          final address='${p['bluetooth_address']??''}'.trim();
          if(address.isEmpty) throw Exception('Máy in Bluetooth chưa có địa chỉ thiết bị.');
          await _channel.invokeMethod('printBluetooth', {'address':address,'bytes':data});
        }
      }
      if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Đã gửi lệnh in tới ${p['ten']??'máy in'}')));
      return true;
    } catch(e) {
      if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));
      return true; // đã chọn direct printer: không tự in trùng qua system dialog
    }
  }

  static Future<List<Map<String,dynamic>>> bondedBluetooth() async {
    if(!Platform.isAndroid) return [];
    try {
      final raw=await _channel.invokeMethod<List<dynamic>>('bondedBluetooth');
      return List.from(raw??const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();
    } catch(_) { return []; }
  }

  static Future<List<Map<String,dynamic>>> scanBluetooth() async {
    if(!Platform.isAndroid) return [];
    try {
      final raw=await _channel.invokeMethod<List<dynamic>>('scanBluetooth');
      final rows=List.from(raw??const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList();
      if(rows.isNotEmpty) return rows;
    } catch(_) {}
    return bondedBluetooth();
  }
}

class PrinterSettingsPage extends StatefulWidget {
  const PrinterSettingsPage({super.key});
  @override State<PrinterSettingsPage> createState()=>_PrinterSettingsPageState();
}
class _PrinterSettingsPageState extends State<PrinterSettingsPage>{
  bool loading=true, canManage=false; List<Map<String,dynamic>> rows=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async{
    setState(()=>loading=true);
    try{
      final platform=Platform.isIOS?'ios':'android';
      final r=await api.get('/printers?platform=$platform'); final d=r['data'] is Map?Map<String,dynamic>.from(r['data'] as Map):r;
      rows=List.from(d['items'] as List? ?? const []).whereType<Map>().map((e)=>Map<String,dynamic>.from(e)).toList(); canManage=d['can_manage']==true;
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
    if(mounted)setState(()=>loading=false);
  }
  String role(Map p)=>switch('${p['loai']}'){'receipt'=>'Hóa đơn','kitchen'=>'Bếp / pha chế','label'=>'Nhãn',_=>'Máy in'};
  String conn(Map p)=>switch('${p['ketnoi']}'){'pc'=>'USB / PC','lan'=>'LAN / IP','bluetooth'=>'Bluetooth',_=>'${p['ketnoi']}'};
  String desc(Map p){final base='${role(p)} • ${conn(p)} • ${p['kho_giay']??''}';return '${p['ketnoi']}'=='lan'?'$base • ${p['ip']??''}:${p['port']??9100}':base;}
  Future<void> edit([Map<String,dynamic>? item]) async{
    final name=TextEditingController(text:'${item?['ten']??''}'); final ip=TextEditingController(text:'${item?['ip']??''}'); final port=TextEditingController(text:'${item?['port']??9100}');
    final btName=TextEditingController(text:'${item?['bluetooth_name']??''}'); final btAddr=TextEditingController(text:'${item?['bluetooth_address']??''}'); final paper=TextEditingController(text:'${item?['kho_giay']??80}'); final copies=TextEditingController(text:'${item?['so_ban']??1}');
    var type='${item?['ketnoi']??'lan'}', roleV='${item?['loai']??'receipt'}', platform='${item?['nen_tang']??'mobile'}'; var def=item?['mac_dinh']==true||'${item?['mac_dinh']}'=='1'; var active=item==null || item['trangthai']==true||'${item['trangthai']}'=='1';
    final saved=await showDialog<bool>(context:context,builder:(dc)=>StatefulBuilder(builder:(dc,setD)=>AlertDialog(title:Text(item==null?'Thêm máy in':'Sửa máy in'),content:SizedBox(width:520,child:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:name,decoration:const InputDecoration(labelText:'Tên máy in')),
      DropdownButtonFormField<String>(value:type,decoration:const InputDecoration(labelText:'Kết nối'),items:const [DropdownMenuItem(value:'pc',child:Text('USB / PC')),DropdownMenuItem(value:'lan',child:Text('LAN / IP')),DropdownMenuItem(value:'bluetooth',child:Text('Bluetooth'))],onChanged:(v)async{final next=v??'lan';setD(()=>type=next);if(next=='bluetooth'&&Platform.isAndroid){final devs=await FicPrinterTransport.scanBluetooth();if(!dc.mounted)return;final picked=await showDialog<Map<String,dynamic>>(context:dc,builder:(x)=>SimpleDialog(title:const Text('Chọn máy in Bluetooth'),children:devs.isEmpty?[const Padding(padding:EdgeInsets.all(16),child:Text('Chưa tìm thấy thiết bị Bluetooth. Hãy bật máy in và Bluetooth rồi thử lại.'))]:devs.map((d)=>SimpleDialogOption(onPressed:()=>Navigator.pop(x,d),child:Text('${d['name']??'Bluetooth'}\n${d['address']??''}'))).toList()));if(picked!=null){btName.text='${picked['name']??''}';btAddr.text='${picked['address']??''}';setD((){});}}}),
      DropdownButtonFormField<String>(value:roleV,decoration:const InputDecoration(labelText:'Dùng để in'),items:const [DropdownMenuItem(value:'receipt',child:Text('Hóa đơn')),DropdownMenuItem(value:'kitchen',child:Text('Bếp / pha chế')),DropdownMenuItem(value:'label',child:Text('Nhãn'))],onChanged:(v)=>setD(()=>roleV=v??'receipt')),
      DropdownButtonFormField<String>(value:platform,decoration:const InputDecoration(labelText:'Nền tảng'),items:const [DropdownMenuItem(value:'all',child:Text('Tất cả')),DropdownMenuItem(value:'mobile',child:Text('Android + iOS')),DropdownMenuItem(value:'android',child:Text('Android')),DropdownMenuItem(value:'ios',child:Text('iOS')),DropdownMenuItem(value:'web',child:Text('Web'))],onChanged:(v)=>setD(()=>platform=v??'mobile')),
      TextField(controller:paper,decoration:const InputDecoration(labelText:'Khổ giấy / nhãn (80, 58, 50x30...)')),
      if(type=='lan') ...[TextField(controller:ip,decoration:const InputDecoration(labelText:'IP máy in')),TextField(controller:port,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Port (thường 9100)'))],
      TextField(controller:copies,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Số bản in (1-10)')),if(type=='bluetooth') ...[TextField(controller:btName,decoration:const InputDecoration(labelText:'Tên Bluetooth')),TextField(controller:btAddr,decoration:const InputDecoration(labelText:'Địa chỉ Bluetooth / MAC')),if(Platform.isAndroid) TextButton.icon(onPressed:()async{final devs=await FicPrinterTransport.scanBluetooth();if(!dc.mounted)return;final picked=await showDialog<Map<String,dynamic>>(context:dc,builder:(x)=>SimpleDialog(title:const Text('Chọn máy in Bluetooth'),children:devs.isEmpty?[const Padding(padding:EdgeInsets.all(16),child:Text('Chưa tìm thấy thiết bị Bluetooth. Hãy bật máy in và Bluetooth rồi thử lại.'))]:devs.map((d)=>SimpleDialogOption(onPressed:()=>Navigator.pop(x,d),child:Text('${d['name']??'Bluetooth'}\n${d['address']??''}'))).toList()));if(picked!=null){btName.text='${picked['name']??''}';btAddr.text='${picked['address']??''}';setD((){});}},icon:const Icon(Icons.bluetooth_searching),label:const Text('Quét & chọn máy in'))],
      CheckboxListTile(value:def,onChanged:(v)=>setD(()=>def=v??false),title:const Text('Máy mặc định'),contentPadding:EdgeInsets.zero),CheckboxListTile(value:active,onChanged:(v)=>setD(()=>active=v??true),title:const Text('Đang sử dụng'),contentPadding:EdgeInsets.zero),
    ]))),actions:[TextButton(onPressed:()=>Navigator.pop(dc,false),child:const Text('Hủy')),FilledButton(onPressed:()=>Navigator.pop(dc,true),child:const Text('Lưu'))])));
    if(saved!=true)return;
    try{await api.post('/printers',{'id':item?['id'],'ten':name.text.trim(),'ketnoi':type,'loai':roleV,'nen_tang':platform,'kho_giay':paper.text.trim().isEmpty?'80':paper.text.trim(),'ip':ip.text.trim(),'port':int.tryParse(port.text)??9100,'bluetooth_name':btName.text.trim(),'bluetooth_address':btAddr.text.trim(),'so_ban':(int.tryParse(copies.text)??1).clamp(1,10),'mac_dinh':def,'trangthai':active});await load();}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}
  }
  Future<void> test(Map<String,dynamic> p)async{final ok=await FicPrinterTransport.directPrint(context,'${p['loai']}','FIC POS\nIN THU MAY IN\n${p['ten']}\n${DateTime.now()}\n',printer:p);if(!ok && mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('USB/PC sử dụng hộp thoại in của hệ điều hành khi in hóa đơn/nhãn.')));}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('Cài đặt máy in'),actions:[IconButton(onPressed:load,icon:const Icon(Icons.refresh))]),floatingActionButton:canManage?FloatingActionButton.extended(onPressed:()=>edit(),icon:const Icon(Icons.add),label:const Text('Thêm máy')):null,body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(14),children:[
    const Card(child:Padding(padding:EdgeInsets.all(14),child:Text('Cấu hình đồng bộ theo chi nhánh. LAN/IP hoạt động trực tiếp trên Android/iOS khi cùng mạng. Bluetooth trực tiếp hiện hỗ trợ Android với máy đã ghép đôi; iOS nên ưu tiên LAN/IP hoặc AirPrint. USB/PC giữ luồng in hệ điều hành hiện tại.'))),
    ...rows.map((p)=>Card(child:ListTile(leading:Icon('${p['ketnoi']}'=='lan'?Icons.lan:'${p['ketnoi']}'=='bluetooth'?Icons.bluetooth:Icons.print),title:Text('${p['ten']}${p['mac_dinh']==true||'${p['mac_dinh']}'=='1'?' • Mặc định':''}'),subtitle:Text(desc(p)),trailing:Row(mainAxisSize:MainAxisSize.min,children:[IconButton(tooltip:'In thử',onPressed:()=>test(p),icon:const Icon(Icons.print_outlined)),if(canManage)IconButton(tooltip:'Sửa',onPressed:()=>edit(p),icon:const Icon(Icons.edit_outlined)),if(canManage)IconButton(tooltip:'Xóa',onPressed:()async{await api.delete('/printers/${p['id']}');await load();},icon:const Icon(Icons.delete_outline))])))),
    if(rows.isEmpty)const Padding(padding:EdgeInsets.all(30),child:Center(child:Text('Chưa cấu hình máy in cho nền tảng này.')))
  ]));
}

class KitchenLabelPrintPage extends StatelessWidget {
  final String kind;
  final String orderCode;
  final String tableName;
  final List<dynamic> items;
  const KitchenLabelPrintPage({super.key, required this.kind, required this.orderCode, required this.tableName, required this.items});

  bool get kitchen => kind == 'kitchen';
  String _s(dynamic v) => v == null ? '' : '$v';
  num _n(dynamic v) => num.tryParse('$v') ?? 0;

  String _ascii(String input) {
    const a='àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ';
    const b='aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyydAAAAAAAAAAAAAAAAAEEEEEEEEEEEIIIIIOOOOOOOOOOOOOOOOOUUUUUUUUUUUYYYYYD';
    var out=input;
    for(var i=0;i<a.length && i<b.length;i++) out=out.replaceAll(a[i],b[i]);
    return out;
  }

  Widget preview() {
    if (kitchen) {
      return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children:[
        const Center(child: Text('PHIẾU BẾP', style: TextStyle(fontSize:20,fontWeight:FontWeight.w900))),
        if(tableName.isNotEmpty) Center(child:Text(tableName,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800))),
        Text('Đơn: $orderCode'),
        const Divider(),
        ...items.map((e){final m=e as Map;final action=_s(m['action']);final qty=_n(m['qty']);return Padding(padding:const EdgeInsets.symmetric(vertical:6),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('${action=='cancel'?'HỦY ':'×${qty.toString().replaceAll('.0','')} '}${_s(m['name'])}',style:const TextStyle(fontSize:17,fontWeight:FontWeight.w800)),
          if(_s(m['note']).trim().isNotEmpty) Text('Ghi chú: ${_s(m['note'])}',style:const TextStyle(fontWeight:FontWeight.w600)),
        ]));}),
      ])));
    }
    return Column(children:items.map((e){final m=e as Map;return Card(child:Padding(padding:const EdgeInsets.all(14),child:Column(children:[
      Text(_s(m['name']),textAlign:TextAlign.center,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),
      Text('SL: ${_n(m['qty']).toString().replaceAll('.0','')}'),
      if(tableName.isNotEmpty) Text(tableName),
      if(_s(m['note']).trim().isNotEmpty) Text(_s(m['note']),textAlign:TextAlign.center),
    ])));}).toList());
  }

  Future<void> printNow(BuildContext context) async {
    final doc=pw.Document();
    if(kitchen){
      doc.addPage(pw.Page(pageFormat:PdfPageFormat(80*PdfPageFormat.mm,200*PdfPageFormat.mm,marginAll:4*PdfPageFormat.mm),build:(_)=>pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
        pw.Center(child:pw.Text('PHIEU BEP',style:pw.TextStyle(fontSize:16,fontWeight:pw.FontWeight.bold))),
        if(tableName.isNotEmpty) pw.Center(child:pw.Text(_ascii(tableName),style:pw.TextStyle(fontSize:14,fontWeight:pw.FontWeight.bold))),
        pw.Text('Don: ${_ascii(orderCode)}'),pw.Divider(),
        ...items.map((e){final m=e as Map;final action=_s(m['action']);final q=_n(m['qty']).toString().replaceAll('.0','');return pw.Padding(padding:const pw.EdgeInsets.only(bottom:6),child:pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[
          pw.Text('${action=='cancel'?'HUY ':'x$q '}${_ascii(_s(m['name']))}',style:pw.TextStyle(fontSize:13,fontWeight:pw.FontWeight.bold)),
          if(_s(m['note']).trim().isNotEmpty) pw.Text('Ghi chu: ${_ascii(_s(m['note']))}',style:const pw.TextStyle(fontSize:9)),
        ]));}),
      ])));
    }else{
      for(final e in items){final m=e as Map;final count=maxInt(1,_n(m['qty']).round());for(var i=0;i<count;i++){
        doc.addPage(pw.Page(pageFormat:PdfPageFormat(50*PdfPageFormat.mm,30*PdfPageFormat.mm,marginAll:3*PdfPageFormat.mm),build:(_)=>pw.Column(mainAxisAlignment:pw.MainAxisAlignment.center,crossAxisAlignment:pw.CrossAxisAlignment.stretch,children:[
          pw.Text(_ascii(_s(m['name'])),textAlign:pw.TextAlign.center,style:pw.TextStyle(fontSize:12,fontWeight:pw.FontWeight.bold)),
          if(tableName.isNotEmpty) pw.Text(_ascii(tableName),textAlign:pw.TextAlign.center,style:const pw.TextStyle(fontSize:9)),
          if(_s(m['note']).trim().isNotEmpty) pw.Text(_ascii(_s(m['note'])),textAlign:pw.TextAlign.center,style:const pw.TextStyle(fontSize:8)),
          pw.Text(_ascii(orderCode),textAlign:pw.TextAlign.center,style:const pw.TextStyle(fontSize:7)),
        ])));
      }}
    }
    final text=StringBuffer();
    if(kitchen){text.writeln('PHIEU BEP');if(tableName.isNotEmpty)text.writeln(tableName);text.writeln('Don: $orderCode');for(final e in items){final m=e as Map;final action=_s(m['action']);final q=_n(m['qty']).toString().replaceAll('.0','');text.writeln('${action=='cancel'?'HUY ':'x$q '}${_s(m['name'])}');if(_s(m['note']).trim().isNotEmpty)text.writeln('  Ghi chu: ${_s(m['note'])}');}}else{for(final e in items){final m=e as Map;final count=maxInt(1,_n(m['qty']).round());for(var i=0;i<count;i++){text.writeln(_s(m['name']));if(tableName.isNotEmpty)text.writeln(tableName);if(_s(m['note']).trim().isNotEmpty)text.writeln(_s(m['note']));text.writeln(orderCode);text.writeln('----------------');}}}
    final direct=await FicPrinterTransport.directPrint(context,kitchen?'kitchen':'label',text.toString());
    if(!direct) await Printing.layoutPdf(onLayout:(_)=>doc.save(),name:kitchen?'FIC-POS-Phieu-Bep.pdf':'FIC-POS-Nhan-Mon.pdf');
  }

  int maxInt(int a,int b)=>a>b?a:b;
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text(kitchen?'Phiếu bếp':'In nhãn')),body:ListView(padding:const EdgeInsets.all(14),children:[preview(),const SizedBox(height:12),FilledButton.icon(onPressed:()=>printNow(context),icon:const Icon(Icons.print),label:Text(kitchen?'In phiếu bếp':'In nhãn'))]));
}

class NativePrintPage extends StatelessWidget {
  final String kind;
  final Map<String, dynamic> data;
  const NativePrintPage({super.key, required this.kind, required this.data});

  Map get root => data['data'] is Map ? data['data'] as Map : data;
  Map get bill => kind == 'temporary' ? ((root['bill'] as Map?) ?? {}) : root;
  Map get order => kind == 'temporary'
      ? ((bill['order'] as Map?) ?? {})
      : ((root['order'] as Map?) ?? {});
  Map get payment => ((root['payment'] as Map?) ?? {});
  Map get printInfo => kind == 'temporary'
      ? ((bill['print'] as Map?) ?? {})
      : ((root['print'] as Map?) ?? {});
  Map get bank => ((printInfo['bank'] as Map?) ?? {});
  Map get template => ((printInfo['template'] as Map?) ?? {});
  bool tempFlag(String key,{bool fallback=true}) => kind!='temporary' ? fallback : ('${template[key]??(fallback?'1':'0')}'=='1');
  String get receiptTitle => kind=='temporary' ? text(template['temp_title']).trim() : '';
  String get receiptFooter => kind=='temporary' ? text(template['temp_footer']).trim() : '';
  double get paperMm => kind=='temporary' && '${template['temp_paper_width']}'=='58' ? 58 : 80;
  String get paymentQr => text(printInfo['payment_qr']);
  String localQrPayload(num due) {
    final bin=text(bank['bin']).trim();
    final account=text(bank['account_no']).trim();
    if(bin.isEmpty || account.isEmpty || due<=0) return '';
    try { return VietQrPayload.build(acqId:bin, accountNo:account, amount:due, addInfo:'FIC ${text(order['madonhang'] ?? payment['madonhang'])}'); } catch(_) { return ''; }
  }
  List get items => List.from((kind == 'temporary' ? bill['items'] : root['items']) as List? ?? []);

  String text(dynamic v) => v == null ? '' : '$v';
  num n(dynamic v) => num.tryParse('$v') ?? 0;

  String method() {
    final p = text(payment['phuongthuc']);
    if (p == 'tienmat' || p == '1') return 'Tiền mặt';
    if (p == 'chuyenkhoan' || p == '2') return 'Chuyển khoản';
    return p;
  }

  Widget qrWidget(num due) {
    final local=localQrPayload(due);
    if(local.isEmpty && paymentQr.isEmpty) return const SizedBox.shrink();
    Widget image;
    if(local.isNotEmpty) {
      image=QrImageView(data:local,size:190,backgroundColor:Colors.white);
    } else if (paymentQr.startsWith('data:image')) {
      try { image=Image.memory(base64Decode(paymentQr.substring(paymentQr.indexOf(',')+1)),width:190,height:190,fit:BoxFit.contain); }
      catch (_) { image=const SizedBox.shrink(); }
    } else {
      image=Image.network(paymentQr,width:190,height:190,fit:BoxFit.contain,errorBuilder:(_,__,___)=>const Text('Không tải được QR thanh toán'));
    }
    return Column(children:[
      const Divider(),
      const Text('QUÉT QR THANH TOÁN',style:TextStyle(fontWeight:FontWeight.w800)),
      const SizedBox(height:6),image,
      Text('${money(due)} đ',style:const TextStyle(fontSize:17,fontWeight:FontWeight.w800)),
      if(text(bank['name']).isNotEmpty||text(bank['account_no']).isNotEmpty) Text('${text(bank['name'])} · ${text(bank['account_no'])}',textAlign:TextAlign.center),
      if(text(bank['holder']).isNotEmpty) Text(text(bank['holder']),textAlign:TextAlign.center,style:const TextStyle(fontSize:12)),
    ]);
  }

  Future<Uint8List?> qrBytes() async {
    // Chỉ dùng ảnh server làm fallback cho dữ liệu cũ. QR mới được dựng local bằng payload EMVCo/NAPAS.
    if(paymentQr.isEmpty) return null;
    try {
      if(paymentQr.startsWith('data:image')) return base64Decode(paymentQr.substring(paymentQr.indexOf(',')+1));
    } catch (_) {}
    return null;
  }

  Widget line(String a, String b, {bool strong = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              a,
              style: TextStyle(fontWeight: strong ? FontWeight.w700 : FontWeight.w400),
            ),
          ),
          Text(
            b,
            style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget receipt() {
    final subtotal = n(order['tongtien'] ?? payment['tongtien']);
    final discount = n(order['giamgia'] ?? payment['giamgia']);
    final due = n(order['phaitra'] ?? payment['phaitra']);
    final storeName = text(printInfo['store_name']).trim().isEmpty ? 'FIC POS' : text(printInfo['store_name']).trim();
    final branchName = text(printInfo['branch_name']).trim();
    final address = text(printInfo['address']).trim();
    final phone = text(printInfo['phone']).trim();
    final title = kind == 'temporary'
        ? (receiptTitle.isEmpty ? 'ĐƠN TẠM TÍNH' : receiptTitle)
        : (text(template['invoice_title']).trim().isEmpty ? 'HÓA ĐƠN THANH TOÁN' : text(template['invoice_title']).trim());
    final footer = kind == 'temporary'
        ? (receiptFooter.isEmpty ? 'Vui lòng kiểm tra trước khi thanh toán.' : receiptFooter)
        : (text(template['invoice_footer']).trim().isEmpty ? 'Cảm ơn quý khách!' : text(template['invoice_footer']).trim());
    final code = text(order['madonhang'] ?? payment['madonhang']);
    final table = text(order['ban'] ?? payment['tenban']);
    final time = text(order['giovao'] ?? payment['paid_at']);
    final customer = text(order['khachhang'] ?? payment['ten_khachhang']);
    final staff = text(order['nhanvien'] ?? payment['nhanvien']);

    Widget metaCell(String label, String value) => RichText(
      text: TextSpan(style: const TextStyle(color: Colors.black, fontSize: 12), children: [
        TextSpan(text: '$label: ', style: const TextStyle(fontWeight: FontWeight.w700)),
        TextSpan(text: value.isEmpty ? '-' : value),
      ]),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Text(storeName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
          if (branchName.isNotEmpty) Center(child: Text(branchName, style: const TextStyle(fontWeight: FontWeight.w700))),
          if (address.isNotEmpty) Center(child: Text(address, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black54))),
          if (phone.isNotEmpty) Center(child: Text('ĐT: $phone', style: const TextStyle(fontSize: 11, color: Colors.black54))),
          const Divider(),
          Center(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          if (kind == 'temporary') Center(child: Container(margin: const EdgeInsets.only(top: 5), padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3), decoration: BoxDecoration(border: Border.all()), child: const Text('CHƯA THANH TOÁN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800)))),
          const SizedBox(height: 8),
          if (kind == 'temporary') Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: metaCell('Mã đơn', code)), const SizedBox(width: 8), Expanded(child: metaCell('Bàn', table))]),
          if (kind == 'temporary') const SizedBox(height: 4),
          if (kind == 'temporary') Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: metaCell('Giờ vào', time)), const SizedBox(width: 8), Expanded(child: metaCell('Khách', customer.isEmpty ? 'Khách lẻ' : customer))]),
          if (kind != 'temporary') ...[
            line('Thời gian', time), line('Đơn hàng', code), line('Bàn', table.isEmpty ? 'Mang về' : table),
            line('Khách hàng', customer.isEmpty ? 'Khách lẻ' : customer),
            if (staff.isNotEmpty) line('Nhân viên', staff),
          ],
          const Divider(),
          Row(children: const [Expanded(flex: 42, child: Text('MÓN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800))), Expanded(flex: 10, child: Text('SL', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800))), Expanded(flex: 22, child: Text('ĐƠN GIÁ', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800))), Expanded(flex: 26, child: Text('THÀNH TIỀN', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)))]),
          const Divider(height: 10),
          ...items.map((e) {
            final m = e as Map; final name = text(m['ten'] ?? m['tensanpham'] ?? 'Món'); final qty = n(m['soluong']).round(); final price = n(m['dongia']); final total = n(m['thanhtien']); final tops = List.from(m['toppings'] as List? ?? []);
            return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 42, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: const TextStyle(fontWeight: FontWeight.w700)), if (text(m['ghichu']).trim().isNotEmpty) Text('Ghi chú: ${m['ghichu']}', style: const TextStyle(fontSize: 10, color: Colors.black54)), ...tops.map((t) { final x=t as Map; return Text('+ ${x['ten'] ?? ''} ×${x['soluong'] ?? 1} (${money(n(x['thanhtien']))} đ)', style: const TextStyle(fontSize: 10, color: Colors.black54)); })])),
              Expanded(flex: 10, child: Text('$qty', textAlign: TextAlign.center)),
              Expanded(flex: 22, child: Text(money(price), textAlign: TextAlign.right)),
              Expanded(flex: 26, child: Text(money(total > 0 ? total : qty * price), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
            ]));
          }),
          const Divider(),
          line(kind == 'temporary' ? 'Tạm tính' : 'Tổng tiền', '${money(subtotal)} đ'),
          if (discount > 0) line('Khuyến mãi', '-${money(discount)} đ'),
          line('PHẢI TRẢ', '${money(due)} đ', strong: true),
          if (kind != 'temporary' && method().isNotEmpty) line('Thanh toán', method()),
          if (kind != 'temporary' && n(payment['tienkhachdua'] ?? payment['tien_khach_dua']) > 0) line('Khách đưa', '${money(n(payment['tienkhachdua'] ?? payment['tien_khach_dua']))} đ'),
          if (kind != 'temporary' && n(payment['tienthua'] ?? payment['tien_thoi']) > 0) line('Tiền thối', '${money(n(payment['tienthua'] ?? payment['tien_thoi']))} đ'),
          if (kind != 'temporary' || tempFlag('temp_show_payment_qr')) qrWidget(due),
          if (kind == 'temporary' && staff.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 7), child: Text('Nhân viên: $staff', style: const TextStyle(fontSize: 11, color: Colors.black54))),
          const Divider(),
          Center(child: Text(footer, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.black54))),
          Center(child: Text(kind == 'temporary' ? 'Đơn tạm tính được tạo bởi FIC POS' : 'Hóa đơn được tạo bởi FIC POS', textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.black54))),
        ]),
      ),
    );
  }

  Future<void> printReceipt(BuildContext context) async {
    final doc = pw.Document();
    final subtotal = n(order['tongtien'] ?? payment['tongtien']);
    final discount = n(order['giamgia'] ?? payment['giamgia']);
    final due = n(order['phaitra'] ?? payment['phaitra']);
    final localQr=localQrPayload(due);
    final qr = localQr.isEmpty ? await qrBytes() : null;
    final storeName = text(printInfo['store_name']).trim().isEmpty ? 'FIC POS' : text(printInfo['store_name']).trim();
    final branchName = text(printInfo['branch_name']).trim();
    final address = text(printInfo['address']).trim();
    final phone = text(printInfo['phone']).trim();
    final title = kind == 'temporary' ? (receiptTitle.isEmpty ? 'DON TAM TINH' : receiptTitle) : 'HOA DON THANH TOAN';
    final code = text(order['madonhang'] ?? payment['madonhang']);
    final table = text(order['ban'] ?? payment['tenban']);
    final time = text(order['giovao'] ?? payment['paid_at']);
    final customer = text(order['khachhang'] ?? payment['ten_khachhang']);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          paperMm * PdfPageFormat.mm,
          200 * PdfPageFormat.mm,
          marginAll: 5 * PdfPageFormat.mm,
        ),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Center(child: pw.Text(storeName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
            if (branchName.isNotEmpty) pw.Center(child: pw.Text(branchName, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
            if (address.isNotEmpty) pw.Center(child: pw.Text(address, textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
            if (phone.isNotEmpty) pw.Center(child: pw.Text('DT: $phone', style: const pw.TextStyle(fontSize: 8))),
            pw.Divider(borderStyle: pw.BorderStyle.dashed),
            pw.Center(child: pw.Text(title, style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))),
            if (kind == 'temporary') pw.Center(child: pw.Container(margin: const pw.EdgeInsets.only(top: 3), padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 2), decoration: pw.BoxDecoration(border: pw.Border.all()), child: pw.Text('CHUA THANH TOAN', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)))),
            pw.SizedBox(height: 5),
            if (kind == 'temporary') ...[
              pw.Row(children: [pw.Expanded(child: pw.Text('Ma don: $code', style: const pw.TextStyle(fontSize: 8))), pw.Expanded(child: pw.Text('Ban: ${table.isEmpty ? '-' : table}', style: const pw.TextStyle(fontSize: 8)))]),
              pw.Row(children: [pw.Expanded(child: pw.Text('Gio vao: ${time.isEmpty ? '-' : time}', style: const pw.TextStyle(fontSize: 8))), pw.Expanded(child: pw.Text('Khach: ${customer.isEmpty ? 'Khach le' : customer}', style: const pw.TextStyle(fontSize: 8)))]),
            ] else ...[
              pw.Text('Thoi gian: $time', style: const pw.TextStyle(fontSize: 8)), pw.Text('Don hang: $code', style: const pw.TextStyle(fontSize: 8)), pw.Text('Ban: ${table.isEmpty ? 'Mang ve' : table}', style: const pw.TextStyle(fontSize: 8)), pw.Text('Khach hang: ${customer.isEmpty ? 'Khach le' : customer}', style: const pw.TextStyle(fontSize: 8)),
            ],
            pw.Divider(borderStyle: pw.BorderStyle.dashed),
            pw.Row(children: [pw.Expanded(flex: 42, child: pw.Text('MON', style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold))), pw.Expanded(flex: 10, child: pw.Text('SL', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold))), pw.Expanded(flex: 22, child: pw.Text('DON GIA', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold))), pw.Expanded(flex: 26, child: pw.Text('THANH TIEN', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold)))]),
            pw.Divider(borderStyle: pw.BorderStyle.dashed),
            ...items.map((e) { final m=e as Map; final qty=n(m['soluong']).round(); final price=n(m['dongia']); final total=n(m['thanhtien']); return pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical:2), child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children:[pw.Expanded(flex:42,child:pw.Text(text(m['ten']??m['tensanpham']??'Mon'),style:const pw.TextStyle(fontSize:8))),pw.Expanded(flex:10,child:pw.Text('$qty',textAlign:pw.TextAlign.center,style:const pw.TextStyle(fontSize:8))),pw.Expanded(flex:22,child:pw.Text(money(price),textAlign:pw.TextAlign.right,style:const pw.TextStyle(fontSize:8))),pw.Expanded(flex:26,child:pw.Text(money(total>0?total:qty*price),textAlign:pw.TextAlign.right,style:const pw.TextStyle(fontSize:8)))])); }),
            pw.Divider(borderStyle: pw.BorderStyle.dashed),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text(kind=='temporary'?'Tam tinh':'Tong tien'), pw.Text(money(subtotal))]),
            if (discount > 0) pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text('Khuyen mai'), pw.Text('-${money(discount)}')]),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text('PHAI TRA', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)), pw.Text(money(due), style: pw.TextStyle(fontWeight: pw.FontWeight.bold))]),
            if (localQr.isNotEmpty || qr != null) ...[
              pw.Divider(borderStyle: pw.BorderStyle.dashed), pw.Center(child: pw.Text('QUET QR THANH TOAN', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))), pw.SizedBox(height: 4),
              pw.Center(child: localQr.isNotEmpty ? pw.BarcodeWidget(barcode:pw.Barcode.qrCode(),data:localQr,width:38*PdfPageFormat.mm,height:38*PdfPageFormat.mm) : pw.Image(pw.MemoryImage(qr!),width:38*PdfPageFormat.mm,height:38*PdfPageFormat.mm)),
              pw.Center(child: pw.Text('${money(due)} d', style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
              if (text(bank['name']).isNotEmpty || text(bank['account_no']).isNotEmpty) pw.Center(child: pw.Text('${text(bank['name'])} - ${text(bank['account_no'])}', style: const pw.TextStyle(fontSize: 8))), if (text(bank['holder']).isNotEmpty) pw.Center(child: pw.Text(text(bank['holder']), style: const pw.TextStyle(fontSize: 8))),
            ],
            pw.Divider(borderStyle: pw.BorderStyle.dashed),
            pw.Center(child: pw.Text(kind=='temporary' ? (receiptFooter.isNotEmpty?receiptFooter:'Vui long kiem tra truoc khi thanh toan.') : 'Cam on quy khach!', textAlign: pw.TextAlign.center, style: const pw.TextStyle(fontSize: 8))),
            pw.Center(child: pw.Text(kind=='temporary'?'Don tam tinh duoc tao boi FIC POS':'Hoa don duoc tao boi FIC POS', style: const pw.TextStyle(fontSize: 7))),          ],
        ),
      ),
    );
    final out=StringBuffer();
    out.writeln(storeName.toUpperCase());
    if(branchName.isNotEmpty) out.writeln(branchName);
    if(address.isNotEmpty) out.writeln(address);
    if(phone.isNotEmpty) out.writeln('DT: $phone');
    out.writeln('----------------');
    out.writeln(title);
    if(kind=='temporary') out.writeln('CHUA THANH TOAN');
    out.writeln('Ma don: $code');
    if(table.isNotEmpty) out.writeln('Ban: $table');
    if(time.isNotEmpty) out.writeln('Thoi gian: $time');
    out.writeln('----------------');
    out.writeln('MON                 SL      THANH TIEN');
    for(final e in items){final m=e as Map;final qty=n(m['soluong']).round();final price=n(m['dongia']);final total=n(m['thanhtien']);out.writeln('${text(m['ten'] ?? m['tensanpham'] ?? 'Mon')}');out.writeln('  $qty x ${money(price)} = ${money(total>0?total:qty*price)}');if(text(m['ghichu']).trim().isNotEmpty)out.writeln('  Ghi chu: ${text(m['ghichu'])}');}
    out.writeln('----------------');
    out.writeln('PHAI TRA: ${money(due)} d');
    out.writeln(kind=='temporary'?(receiptFooter.isNotEmpty?receiptFooter:'Vui long kiem tra truoc khi thanh toan.'):'Cam on quy khach!');
    final direct=await FicPrinterTransport.directPrint(context,'receipt',out.toString(),qrPayload:localQr);
    if(!direct) await Printing.layoutPdf(onLayout: (_) => doc.save(), name: kind == 'temporary' ? 'FIC-POS-Tam-Tinh.pdf' : 'FIC-POS-Hoa-Don.pdf');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(kind == 'temporary' ? 'Tạm tính' : 'Hóa đơn')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          receipt(),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: () => printReceipt(context),
            icon: const Icon(Icons.print),
            label: Text(kind == 'temporary' ? 'In tạm tính' : 'In hóa đơn'),
          ),
        ],
      ),
    );
  }
}

class ItemConfigSheet extends StatefulWidget {
  final Map detail;
  final List toppingOptions;
  final List<Map> selectedToppings;
  final Future<void> Function(int toppingId, int quantity) onSetTopping;
  final Future<void> Function(String note, int applyQty) onAddNote;

  const ItemConfigSheet({
    super.key,
    required this.detail,
    required this.toppingOptions,
    required this.selectedToppings,
    required this.onSetTopping,
    required this.onAddNote,
  });

  @override
  State<ItemConfigSheet> createState() => _ItemConfigSheetState();
}

class _ItemConfigSheetState extends State<ItemConfigSheet> {
  late Map<int, int> quantities;
  final note = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
    quantities = {};
    for (final t in widget.selectedToppings) {
      quantities[int.parse('${t['id_sanpham']}')] = (num.tryParse('${t['soluong']}') ?? 0).round();
    }
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> setTopping(Map topping, int next) async {
    final id = int.parse('${topping['id']}');
    final previous = quantities[id] ?? 0;
    // V1.13.12: update the sheet immediately. The order state also updates
    // optimistically and the server request is debounced in OrderPage.
    if (mounted) setState(() => quantities[id] = next);
    try {
      await widget.onSetTopping(id, next);
    } catch (_) {
      if (mounted) setState(() => quantities[id] = previous);
    }
  }

  Future<void> addNote() async {
    final text = note.text.trim();
    if (text.isEmpty) return;
    setState(() => busy = true);
    try {
      await widget.onAddNote(text, 1);
      note.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Đã thêm ghi chú cho món')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sp = widget.detail['sanpham'] as Map?;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          18, 18, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${sp?['tensanpham'] ?? widget.detail['tensanpham'] ?? 'Món'}',
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                ),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
            if ('${widget.detail['ghichu'] ?? ''}'.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('Ghi chú hiện tại: ${widget.detail['ghichu']}',
                    style: const TextStyle(color: Colors.deepOrange)),
              ),
            if (widget.toppingOptions.isNotEmpty) ...[
              const Text('Topping', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              ...widget.toppingOptions.map((e) {
                final t = e as Map;
                final id = int.parse('${t['id']}');
                final q = quantities[id] ?? 0;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${t['ten']}'),
                  subtitle: Text('+${money(num.tryParse('${t['gia']}') ?? 0)} đ'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: q <= 0 ? null : () => setTopping(t, q - 1),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$q', style: const TextStyle(fontWeight: FontWeight.w700)),
                      IconButton(
                        onPressed: q >= 20 ? null : () => setTopping(t, q + 1),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                    ],
                  ),
                );
              }),
              const Divider(),
            ],
            const Text('Ghi chú món',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              maxLength: 250,
              decoration: const InputDecoration(
                hintText: 'Ví dụ: ít đá, ít đường, không hành...',
                prefixIcon: Icon(Icons.edit_note_outlined),
              ),
            ),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: ['Ít đá', 'Không đá', 'Ít đường', 'Không đường', 'Mang đi']
                  .map((x) => ActionChip(label: Text(x), onPressed: () => note.text = x))
                  .toList(),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : addNote,
                icon: const Icon(Icons.check),
                label: const Text('Lưu ghi chú'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PromotionBanner extends StatelessWidget {
  final List promotions;
  final List gifts;
  const PromotionBanner({super.key, required this.promotions, required this.gifts});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(10, 8, 10, 0),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.withValues(alpha: .25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.local_offer_outlined, size: 18, color: Colors.green),
                SizedBox(width: 6),
                Text('Khuyến mãi đang áp dụng',
                    style: TextStyle(fontWeight: FontWeight.w700, color: Colors.green)),
              ],
            ),
            ...promotions.map((p) => Text('• ${(p as Map)['name'] ?? p['ten'] ?? 'Ưu đãi'}',
                style: const TextStyle(fontSize: 12))),
            ...gifts.map((g) => Text('• Quà: ${(g as Map)['product_name'] ?? g['name'] ?? 'Sản phẩm tặng'}',
                style: const TextStyle(fontSize: 12))),
          ],
        ),
      );
}

class OrderBottomBar extends StatelessWidget {
  final int itemCount;
  final num subtotal;
  final num discount;
  final num payable;
  final VoidCallback onOpen;
  const OrderBottomBar({
    super.key,
    required this.itemCount,
    required this.subtotal,
    required this.discount,
    required this.payable,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        child: Material(
          color: Colors.white,
          elevation: 10,
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: Row(
                children: [
                  Badge(
                    label: Text('$itemCount'),
                    child: const Icon(Icons.shopping_cart_outlined, size: 30),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Xem đơn',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (discount > 0)
                        Text('Đã giảm ${money(discount)} đ',
                            style: const TextStyle(fontSize: 11, color: Colors.green)),
                    ],
                  ),
                  const Spacer(),
                  Text('${money(payable)} đ',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w800,
                          fontSize: 18)),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      );
}

class MoneyRow extends StatelessWidget {
  final String label;
  final num value;
  final bool strong;
  const MoneyRow(this.label, this.value, {super.key, this.strong = false});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text(label, style: TextStyle(fontWeight: strong ? FontWeight.w800 : FontWeight.w400)),
            const Spacer(),
            Text('${value < 0 ? '-' : ''}${money(value.abs())} đ',
                style: TextStyle(
                    fontSize: strong ? 19 : 15,
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                    color: value < 0 ? Colors.green : null)),
          ],
        ),
      );
}

class ShiftPage extends StatefulWidget {
  final bool returnAfterOpen;
  const ShiftPage({super.key, this.returnAfterOpen = false});
  @override
  State<ShiftPage> createState() => _ShiftPageState();
}

class _ShiftPageState extends State<ShiftPage> {
  Map<String, dynamic>? status;
  bool loading = true;
  bool saving = false;
  final note = TextEditingController();
  final denoms = const [500000, 200000, 100000, 50000, 20000, 10000, 5000, 2000, 1000];
  late Map<int, TextEditingController> counts;
  late Map<int, FocusNode> countFocus;
  final Map<int, String> _countBeforeEdit = {};

  @override
  void initState() {
    super.initState();
    counts = {for (final d in denoms) d: TextEditingController(text: '0')};
    countFocus = {for (final d in denoms) d: FocusNode()};
    for (final d in denoms) {
      countFocus[d]!.addListener(() => _handleCountFocus(d));
    }
    load();
  }

  void _handleCountFocus(int denomination) {
    final focus = countFocus[denomination]!;
    final controller = counts[denomination]!;
    if (focus.hasFocus) {
      _countBeforeEdit[denomination] = controller.text.trim().isEmpty ? '0' : controller.text.trim();
      controller.clear();
      if (mounted) setState(() {});
      return;
    }
    if (controller.text.trim().isEmpty) {
      controller.text = _countBeforeEdit[denomination] ?? '0';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    note.dispose();
    for (final c in counts.values) c.dispose();
    for (final f in countFocus.values) f.dispose();
    super.dispose();
  }

  Future<void> load() async {
    try {
      final s = await api.get('/shift');
      if (mounted) setState(() => status = s);
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Map<String, int> payloadCounts() => {
        for (final d in denoms) '$d': int.tryParse(counts[d]!.text.trim()) ?? 0,
      };

  num totalCash() => denoms.fold<num>(0,
      (sum, d) => sum + d * (int.tryParse(counts[d]!.text.trim()) ?? 0));

  Future<void> submit() async {
    setState(() => saving = true);
    try {
      final open = status?['open'] == true;
      if (open) {
        await api.post('/shift/close', {'counts': payloadCounts(), 'note': note.text.trim()});
        _toast('Đã kết ca thành công');
      } else {
        await api.post('/shift/open', {'counts': payloadCounts()});
        _toast('Đã mở ca thành công');
      }
      for (final c in counts.values) c.text = '0';
      note.clear();

      // Được gọi từ một màn hình đang chờ ca (Order, Sổ thu chi...).
      // Mở ca xong trả kết quả ngay để caller tiếp tục vào đúng màn hình trước đó.
      if (!open && widget.returnAfterOpen && mounted) {
        Navigator.pop(context, true);
        return;
      }

      await load();
    } catch (e) {
      _toast(e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> openWebModule(String module) async {
    Navigator.pop(context);
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ficModulePage(module)));
  }

  void _toast(String text) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(text.replaceFirst('Exception: ', ''))));

  @override
  Widget build(BuildContext context) {
    final open = status?['open'] == true;
    final summary = status?['summary'] as Map?;
    return Scaffold(
      appBar: AppBar(title: Text(open ? 'Kết ca / Két tiền' : 'Mở ca')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(open ? 'CA ĐANG MỞ' : 'CHƯA MỞ CA',
                            style: TextStyle(
                                color: open ? Colors.green : Colors.orange,
                                fontWeight: FontWeight.w800)),
                        if (open) ...[
                          const SizedBox(height: 8),
                          Text('Mở lúc: ${status?['shift']?['opened_at'] ?? ''}'),
                          Text('Người mở: ${status?['shift']?['opened_by'] ?? ''}'),
                          Text('Tiền đầu ca: ${money(num.tryParse('${status?['shift']?['opening_cash'] ?? 0}') ?? 0)} đ'),
                        ],
                      ],
                    ),
                  ),
                ),
                if (open && summary != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          MoneyRow('Doanh thu', num.tryParse('${summary['revenue']}') ?? 0, strong: true),
                          MoneyRow('Tiền mặt', num.tryParse('${summary['cash']}') ?? 0),
                          MoneyRow('Chuyển khoản', num.tryParse('${summary['bank']}') ?? 0),
                          Row(children: [const Text('Số hóa đơn'), const Spacer(), Text('${summary['invoices'] ?? 0}')]),
                        ],
                      ),
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 14, 4, 8),
                  child: Text('Kiểm đếm tiền mặt theo mệnh giá',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ),
                ...denoms.map((d) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: counts[d],
                        focusNode: countFocus[d],
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '${money(d)} đ',
                          prefixIcon: const Icon(Icons.payments_outlined),
                          suffixText: 'tờ',
                        ),
                      ),
                    )),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: MoneyRow(open ? 'Tiền đếm cuối ca' : 'Tiền đầu ca', totalCash(), strong: true),
                  ),
                ),
                if (open) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: note,
                    maxLines: 3,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Ghi chú kết ca',
                      prefixIcon: Icon(Icons.edit_note_outlined),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: saving ? null : submit,
                    icon: Icon(open ? Icons.lock_clock_outlined : Icons.play_circle_outline),
                    label: Text(open ? 'KẾT CA' : 'MỞ CA'),
                  ),
                ),
              ],
            ),
    );
  }
}

class RecentInvoicesPage extends StatefulWidget {
  const RecentInvoicesPage({super.key});
  @override
  State<RecentInvoicesPage> createState() => _RecentInvoicesPageState();
}

class _RecentInvoicesPageState extends State<RecentInvoicesPage> {
  List items = [];
  bool loading = true;
  bool loadingMore = false;
  bool hasMore = true;
  int page = 1;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() { loading = true; error = null; page=1; hasMore=true; });
    try {
      final local = await OfflineStore.recentInvoices(onlyUnsynced: !ficOfflineMode);
      List remote = [];
      if (!ficOfflineMode) {
        try {
          final r = await api.get('/orders/recent?page=1&per_page=20');
          remote = (r['items'] as List?) ?? [];
          hasMore = r['has_more']==true;
        } catch (e) {
          if (!_isNetworkError(e)) rethrow;
          ficOfflineMode = true; hasMore=false;
        }
      }
      final merged = <dynamic>[...local, ...remote];
      if (mounted) setState(() => items = merged);
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
  Future<void> loadMore() async { if(ficOfflineMode||loadingMore||!hasMore)return; setState(()=>loadingMore=true); try{final next=page+1;final r=await api.get('/orders/recent?page=$next&per_page=20');items.addAll((r['items'] as List?)??const []);page=next;hasMore=r['has_more']==true;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);} }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: IconButton(
            tooltip: 'Quay lại',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text('Hóa đơn gần đây'),
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Text(error!))
                : RefreshIndicator(
                    onRefresh: load,
                    child: NotificationListener<ScrollNotification>(
                      onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},
                      child:ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: items.length + (loadingMore?1:0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        if(i>=items.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                        final x = items[i] as Map;
                        final amount = num.tryParse('${x['phaitra'] ?? 0}') ?? 0;
                        final local = x['offline_local'] == true;
                        final syncState = '${x['sync_state'] ?? ''}';
                        return ListTile(
                          leading: CircleAvatar(child: Icon(local ? Icons.cloud_off_outlined : Icons.receipt_long_outlined, size: 20)),
                          title: Text('${x['ma_thanhtoan'] ?? x['madonhang'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${x['tenban'] ?? 'Mang về'} • ${x['ten_khachhang'] ?? 'Khách lẻ'}\n${money(amount)} đ • ${x['paid_at'] ?? ''}${local ? (syncState == 'synced' ? ' • Đã đồng bộ' : ' • Chờ đồng bộ') : ''}'),
                          isThreeLine: true,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            if (local) {
                              Navigator.push(context, MaterialPageRoute(builder: (_) => OfflineInvoiceDetailPage(invoice: Map<String, dynamic>.from(x))));
                              return;
                            }
                            Navigator.push(context, MaterialPageRoute(builder: (_) => InvoiceDetailPage(paymentId: int.tryParse('${x['id']}') ?? 0)));
                          },
                        );
                      },
                    )),
                  ),
      );
}

class OfflineInvoiceDetailPage extends StatelessWidget {
  final Map<String, dynamic> invoice;
  const OfflineInvoiceDetailPage({super.key, required this.invoice});

  @override
  Widget build(BuildContext context) {
    final payload = invoice['payload'] is Map ? Map<String, dynamic>.from(invoice['payload'] as Map) : <String, dynamic>{};
    final payment = invoice['payment'] is Map ? Map<String, dynamic>.from(invoice['payment'] as Map) : <String, dynamic>{};
    final rows = (payload['items'] as List?) ?? const [];
    final subtotal = num.tryParse('${payment['subtotal'] ?? 0}') ?? 0;
    final discount = num.tryParse('${payment['discount'] ?? 0}') ?? 0;
    final amount = num.tryParse('${payment['amount'] ?? invoice['phaitra'] ?? 0}') ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Hóa đơn ngoại tuyến')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('HÓA ĐƠN THANH TOÁN', textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text('Mã hóa đơn: ${invoice['ma_thanhtoan'] ?? invoice['local_invoice_code'] ?? ''}'),
            Text('Mã đơn: ${invoice['madonhang'] ?? ''}'),
            Text('Bàn: ${invoice['tenban'] ?? ''}'),
            Text('Thời gian: ${invoice['paid_at'] ?? ''}'),
            Text('Trạng thái: ${invoice['sync_state'] == 'synced' ? 'Đã đồng bộ' : 'Chờ đồng bộ'}'),
            const Divider(),
            ...rows.map((raw) {
              final x = raw is Map ? raw : const {};
              final name = '${x['ten'] ?? x['tensanpham'] ?? x['product_name'] ?? 'Món'}';
              final qty = num.tryParse('${x['soluong'] ?? x['quantity'] ?? 0}') ?? 0;
              final price = num.tryParse('${x['dongia'] ?? x['price'] ?? 0}') ?? 0;
              return ListTile(contentPadding: EdgeInsets.zero, dense: true, title: Text(name), subtitle: Text('${qty.toStringAsFixed(qty % 1 == 0 ? 0 : 2)} × ${money(price)} đ'), trailing: Text('${money(qty * price)} đ'));
            }),
            const Divider(),
            if (discount > 0) ...[
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Tạm tính'), Text('${money(subtotal)} đ')]),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('Khuyến mãi'), Text('-${money(discount)} đ')]),
              const SizedBox(height: 4),
            ],
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [const Text('TỔNG CỘNG', style: TextStyle(fontWeight: FontWeight.w800)), Text('${money(amount)} đ', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18))]),
          ]))),
        ],
      ),
    );
  }
}

class InvoiceDetailPage extends StatefulWidget {
  final int paymentId;
  const InvoiceDetailPage({super.key, required this.paymentId});
  @override
  State<InvoiceDetailPage> createState() => _InvoiceDetailPageState();
}

class _InvoiceDetailPageState extends State<InvoiceDetailPage> {
  Map<String, dynamic>? data;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await api.get('/invoices/${widget.paymentId}');
      if (mounted) setState(() => data = r);
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> reprint() async {
    try {
      final r = await api.post('/print-data', {'kind': 'invoice', 'ref': '${widget.paymentId}'});
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => NativePrintPage(kind: 'invoice', data: (r['data'] as Map?)?.cast<String, dynamic>() ?? r)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = (data?['payment'] as Map?) ?? const {};
    final rows = (data?['items'] as List?) ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chi tiết hóa đơn'),
        actions: [IconButton(onPressed: loading ? null : reprint, icon: const Icon(Icons.print_outlined), tooltip: 'In lại')],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
              ? Center(child: Text(error!))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text('${p['ma_thanhtoan'] ?? ''}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                    const SizedBox(height: 6),
                    Text('${p['tenban'] ?? 'Mang về'} • ${p['paid_at'] ?? ''}'),
                    Text('Khách: ${p['ten_khachhang'] ?? 'Khách lẻ'}'),
                    Text('Nhân viên: ${p['nhanvien'] ?? '—'}'),
                    const Divider(height: 28),
                    ...rows.map((raw) {
                      final x = raw as Map;
                      final qty = num.tryParse('${x['soluong'] ?? 0}') ?? 0;
                      final price = num.tryParse('${x['dongia'] ?? 0}') ?? 0;
                      final total = num.tryParse('${x['thanhtien'] ?? qty * price}') ?? 0;
                      final note = '${x['ghichu'] ?? ''}'.trim();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${x['tensanpham'] ?? 'Món'}'),
                        subtitle: Text('$qty x ${money(price)} đ${note.isNotEmpty ? ' • $note' : ''}'),
                        trailing: Text('${money(total)} đ', style: const TextStyle(fontWeight: FontWeight.w700)),
                      );
                    }),
                    const Divider(),
                    MoneyRow('Tổng tiền', num.tryParse('${p['tongtien'] ?? 0}') ?? 0),
                    MoneyRow('Giảm giá', -(num.tryParse('${p['giamgia'] ?? 0}') ?? 0)),
                    MoneyRow('Phải trả', num.tryParse('${p['phaitra'] ?? 0}') ?? 0, strong: true),
                    const SizedBox(height: 18),
                    SizedBox(height: 50, child: FilledButton.icon(onPressed: reprint, icon: const Icon(Icons.print_outlined), label: const Text('IN LẠI HÓA ĐƠN'))),
                  ],
                ),
    );
  }
}


String _paymentRequestSeenStorageKey() {
  final host = Uri.tryParse(api.baseUrl)?.host ?? api.baseUrl;
  return 'fic_payment_request_seen_${host.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}';
}

String _paymentRequestUniqueKey(Map x) {
  final id = '${x['id'] ?? x['payment_request_id'] ?? ''}'.trim();
  final tableId = '${x['id_ban'] ?? x['table_id'] ?? ''}'.trim();
  final orderCode = '${x['madonhang'] ?? x['order_code'] ?? ''}'.trim();
  final createdAt = '${x['created_at'] ?? ''}'.trim();
  return '$id|$tableId|$orderCode|$createdAt';
}

Future<Set<String>> _loadSeenPaymentRequestKeys() async {
  final prefs = await SharedPreferences.getInstance();
  return (prefs.getStringList(_paymentRequestSeenStorageKey()) ?? const <String>[]).toSet();
}

Future<bool> _markPaymentRequestSeen(Map x) async {
  final key = _paymentRequestUniqueKey(x);
  if (key == '|||') return false;
  final prefs = await SharedPreferences.getInstance();
  final storageKey = _paymentRequestSeenStorageKey();
  final values = (prefs.getStringList(storageKey) ?? const <String>[]).toList();
  final wasSeen = values.contains(key);
  values.remove(key);
  values.add(key);
  // Chỉ giữ lịch sử gần nhất để SharedPreferences không tăng vô hạn.
  final trimmed = values.length > 500 ? values.sublist(values.length - 500) : values;
  await prefs.setStringList(storageKey, trimmed);
  return !wasSeen;
}

Future<int> _countUnseenPaymentRequests(List rawItems) async {
  final seen = await _loadSeenPaymentRequestKeys();
  var count = 0;
  for (final raw in rawItems) {
    if (raw is! Map) continue;
    final key = _paymentRequestUniqueKey(raw);
    if (key == '|||' || !seen.contains(key)) count++;
  }
  return count;
}

/// Đồng bộ trạng thái đã đọc của Yêu cầu thanh toán sang Trung tâm thông báo.
/// Server notification center thường lưu ref_type=payment_request và ref_id=id yêu cầu.
/// Có fallback theo mã đơn / bàn để tương thích dữ liệu cũ.
Future<bool> _markPaymentRequestNotificationRead(Map request) async {
  try {
    final requestId = '${request['id'] ?? request['payment_request_id'] ?? ''}'.trim();
    final orderCode = '${request['madonhang'] ?? request['order_code'] ?? ''}'.trim();
    final tableId = '${request['id_ban'] ?? request['table_id'] ?? ''}'.trim();

    // Lấy đủ rộng để tìm thông báo tương ứng nhưng không tạo polling nặng.
    final r = await api.get('/notifications-center?page=1&per_page=100');
    final rows = (r['items'] as List?) ?? const [];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final n = Map<String, dynamic>.from(raw);
      if ('${n['ref_type'] ?? ''}' != 'payment_request') continue;

      final refId = '${n['ref_id'] ?? n['payment_request_id'] ?? ''}'.trim();
      final nOrderCode = '${n['madonhang'] ?? n['order_code'] ?? ''}'.trim();
      final nTableId = '${n['id_ban'] ?? n['table_id'] ?? ''}'.trim();

      final sameById = requestId.isNotEmpty && refId.isNotEmpty && requestId == refId;
      final sameByOrder = orderCode.isNotEmpty && nOrderCode.isNotEmpty && orderCode == nOrderCode;
      final sameByTable = tableId.isNotEmpty && nTableId.isNotEmpty && tableId == nTableId;
      if (!sameById && !sameByOrder && !(sameByTable && orderCode.isEmpty)) continue;

      final notificationId = int.tryParse('${n['id'] ?? 0}') ?? 0;
      final unread = '${n['trangthai'] ?? 0}' == '0';
      if (notificationId > 0 && unread) {
        await api.post('/notifications-center/read', {'id': notificationId});
      }
      return true;
    }
  } catch (_) {
    // Không chặn việc mở đơn nếu server notification-center tạm lỗi.
  }
  return false;
}

class PaymentRequestsPage extends StatefulWidget {
  final VoidCallback? onSeen;
  const PaymentRequestsPage({super.key, this.onSeen});
  @override
  State<PaymentRequestsPage> createState() => _PaymentRequestsPageState();
}

class _PaymentRequestsPageState extends State<PaymentRequestsPage> {
  List items = [];
  Set<String> seenKeys = <String>{};
  bool loading = true, loadingMore = false, hasMore = true;
  int page = 1;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() { loading = true; page=1; hasMore=true; error=null; });
    try {
      final r = await api.get('/payment-requests?page=1&per_page=20');
      final seen = await _loadSeenPaymentRequestKeys();
      if (mounted) {
        setState(() {
          items = (r['items'] as List?) ?? [];
          hasMore = r['has_more'] == true;
          seenKeys = seen;
        });
      }
    } catch(e) {
      if(mounted)setState(()=>error=e.toString().replaceFirst('Exception: ',''));
    } finally {
      if(mounted)setState(()=>loading=false);
    }
  }
  Future<void> loadMore() async {if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/payment-requests?page=$next&per_page=20');items.addAll((r['items'] as List?)??const []);page=next;hasMore=r['has_more']==true;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}

  Future<void> openRequest(Map x) async {
    try {
      final boot = await api.get('/bootstrap');
      final tables = (boot['tables'] as List?) ?? [];
      Map? table;
      for (final raw in tables) {
        if (raw is Map && '${raw['id']}' == '${x['id_ban']}') {
          table = raw;
          break;
        }
      }
      if (table == null) throw Exception('Không tìm thấy bàn của yêu cầu.');
      if (!mounted) return;

      // Người dùng đã mở đúng yêu cầu: đánh dấu đã xem ngay.
      // Badge đỏ ở menu sẽ giảm 1; khi xem hết sẽ tự biến mất.
      final newlySeen = await _markPaymentRequestSeen(x);
      if (newlySeen) {
        // Đồng bộ sang chuông: đánh dấu notification tương ứng đã đọc trên server.
        // Callback phía Home giảm badge ngay để UI phản hồi tức thì.
        await _markPaymentRequestNotificationRead(x);
        if (mounted) {
          setState(() => seenKeys.add(_paymentRequestUniqueKey(x)));
        }
        widget.onSeen?.call();
      }

      await Navigator.push(context, MaterialPageRoute(builder: (_) => OrderPage(table: Map.from(table!), bootstrap: boot, initialOrderCode: '${x['madonhang'] ?? ''}')));
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Yêu cầu thanh toán')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Text(error!))
                : RefreshIndicator(
                    onRefresh: load,
                    child: NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: items.length+(loadingMore?1:0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        if(i>=items.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                        final x = items[i] as Map;
                        final amount = num.tryParse('${x['amount'] ?? 0}') ?? 0;
                        final requestKey = _paymentRequestUniqueKey(x);
                        final isSeen = requestKey != '|||' && seenKeys.contains(requestKey);
                        return Container(
                          color: isSeen ? null : Colors.red.withValues(alpha: .055),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: isSeen
                                  ? Colors.grey.withValues(alpha: .12)
                                  : Colors.red.withValues(alpha: .12),
                              child: Icon(
                                isSeen ? Icons.done_all_rounded : Icons.notifications_active_outlined,
                                color: isSeen ? Colors.grey.shade600 : Colors.red,
                              ),
                            ),
                            title: Text(
                              '${x['tenban'] ?? 'Mang về'} • ${money(amount)} đ',
                              style: TextStyle(
                                fontWeight: isSeen ? FontWeight.w600 : FontWeight.w900,
                              ),
                            ),
                            subtitle: Text(
                              '${x['requested_by_name'] ?? 'Nhân viên'} • ${x['created_at'] ?? ''}${isSeen ? ' • Đã xem' : ''}',
                            ),
                            trailing: isSeen
                                ? const Icon(Icons.chevron_right)
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: Colors.red,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: const Text(
                                          'MỚI',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(Icons.chevron_right),
                                    ],
                                  ),
                            onTap: () => openRequest(x),
                          ),
                        );
                      },
                    )),
                  ),
      );
}


class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});
  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  List items = [];
  bool loading = true, loadingMore = false, hasMore = true;
  int page = 1;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    if (mounted) setState(() { loading = true; error = null; page=1; hasMore=true; });
    try {
      final r = await api.get('/notifications-center?page=1&per_page=20');
      hasMore=r['has_more']==true;
      final merged = List<dynamic>.from((r['items'] as List?) ?? const []);
      final existingQrRefs = <String>{};
      for (final raw in merged) {
        if (raw is Map && '${raw['ref_type'] ?? ''}' == 'qr_order') {
          existingQrRefs.add('${raw['ref_id'] ?? ''}');
        }
      }
      // Backward compatibility: nếu server cũ chưa persist QR vào notification center,
      // vẫn ghép QR pending vào chuông; server V255.7 thì ref_id sẽ dedup, không hiện 2 lần.
      try {
        final qr = await api.get('/qr-orders?page=1&per_page=20');
        final qd=qr['data']; final rows = qd is Map ? ((qd['items'] as List?)??const []) : ((qd as List?)??const []);
        for (final raw in rows) {
          if (raw is! Map || '${raw['status'] ?? ''}' != 'pending') continue;
          final x = Map<String, dynamic>.from(raw);
          final qrId = int.tryParse('${x['id'] ?? 0}') ?? 0;
          if (qrId <= 0 || existingQrRefs.contains('$qrId')) continue;
          merged.insert(0, {
            ...x,
            'id': -qrId,
            'ref_type': 'qr_order',
            'ref_id': '$qrId',
            'trangthai': 0,
            'tenthongbao': 'Đơn QR mới • ${x['tenban'] ?? x['table_name'] ?? 'Bàn'}',
            'noidungthongbao': 'Có yêu cầu gọi món đang chờ xác nhận${x['public_code'] != null ? ' • ${x['public_code']}' : ''}',
          });
        }
      } catch (_) {}
      if (mounted) setState(() => items = merged);
    } catch (e) {
      if (mounted) setState(() => error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> loadMore() async {if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/notifications-center?page=$next&per_page=20');items.addAll((r['items'] as List?)??const []);page=next;hasMore=r['has_more']==true;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}

  Future<void> markAllRead() async {
    try {
      await api.post('/notifications-center/read-all', {});
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> deleteAllNotifications() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa tất cả thông báo?'),
        content: const Text('Toàn bộ thông báo trong chuông của tài khoản này sẽ được xóa khỏi danh sách.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Hủy')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Xóa tất cả')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.post('/notifications-center/delete-all', {});
      if (!mounted) return;
      setState(() => items = []);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã xóa tất cả thông báo.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  Future<void> openNotification(Map x) async {
    final id = int.tryParse('${x['id'] ?? 0}') ?? 0;
    try {
      if (id > 0) await api.post('/notifications-center/read', {'id': id});
      final type = '${x['ref_type'] ?? ''}';
      if (type == 'qr_order') {
        if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => const QrRequestPage()));
      } else if (type == 'payment_request') {
        final tableId = int.tryParse('${x['id_ban'] ?? 0}') ?? 0;
        final code = '${x['madonhang'] ?? ''}'.trim();
        if (tableId > 0 && code.isNotEmpty) {
          final boot = await api.get('/bootstrap');
          final tables = (boot['tables'] as List?) ?? [];
          Map? table;
          for (final raw in tables) {
            if (raw is Map && '${raw['id']}' == '$tableId') { table = raw; break; }
          }
          if (table != null && mounted) {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => OrderPage(table: Map.from(table!), bootstrap: boot, initialOrderCode: code)));
          } else if (mounted) {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentRequestsPage()));
          }
        } else if (mounted) {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentRequestsPage()));
        }
      }
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Thông báo'),
          actions: [
            TextButton.icon(onPressed: markAllRead, icon: const Icon(Icons.done_all), label: const Text('Đã đọc')),
          ],
        ),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text(error!, textAlign: TextAlign.center)))
                : Column(
                    children: [
                      Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
                          title: const Text('Xóa tất cả thông báo', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
                          subtitle: const Text('Xóa toàn bộ danh sách trong chuông thông báo'),
                          onTap: items.isEmpty ? null : deleteAllNotifications,
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: load,
                          child: items.isEmpty
                              ? ListView(children: const [SizedBox(height: 160), Center(child: Text('Chưa có thông báo.'))])
                              : NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView.separated(
                                  padding: const EdgeInsets.symmetric(vertical: 8),
                                  itemCount: items.length+(loadingMore?1:0),
                                  separatorBuilder: (_, __) => const Divider(height: 1),
                                  itemBuilder: (_, i) {
                                    if(i>=items.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                                    final x = items[i] as Map;
                                    final unread = '${x['trangthai'] ?? 0}' == '0';
                                    final amount = num.tryParse('${x['amount'] ?? 0}') ?? 0;
                                    final subtitle = [
                                      '${x['noidungthongbao'] ?? ''}'.trim(),
                                      if ('${x['tenban'] ?? ''}'.trim().isNotEmpty) '${x['tenban']}',
                                      if ('${x['madonhang'] ?? ''}'.trim().isNotEmpty) '${x['madonhang']}',
                                      if (amount > 0) '${money(amount)} đ',
                                    ].where((e) => e.isNotEmpty).join(' • ');
                                    return ListTile(
                                      tileColor: unread ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .25) : null,
                                      leading: CircleAvatar(child: Icon(unread ? Icons.notifications_active : Icons.notifications_none)),
                                      title: Text('${x['tenthongbao'] ?? 'Thông báo'}', style: TextStyle(fontWeight: unread ? FontWeight.w800 : FontWeight.w600)),
                                      subtitle: Text(subtitle),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => openNotification(x),
                                    );
                                  },
                                )),
                        ),
                      ),
                    ],
                  ),
      );
}

class ApiListPage extends StatefulWidget {
  final String title;
  final String endpoint;
  final IconData icon;
  const ApiListPage({super.key, required this.title, required this.endpoint, required this.icon});
  @override
  State<ApiListPage> createState() => _ApiListPageState();
}

class _ApiListPageState extends State<ApiListPage> {
  List items = [];
  bool loading = true, loadingMore=false, hasMore=true;
  int page=1;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  String _url(int p)=>'${widget.endpoint}${widget.endpoint.contains('?')?'&':'?'}page=$p&per_page=20';
  Future<void> load() async {setState((){loading=true;error=null;page=1;hasMore=true;});try{final r=await api.get(_url(1));if(mounted)setState((){items=(r['items'] as List?)??[];hasMore=r['has_more']==true;});}catch(e){if(mounted)setState(()=>error=e.toString().replaceFirst('Exception: ',''));}finally{if(mounted)setState(()=>loading=false);}}
  Future<void> loadMore()async{if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get(_url(next));items.addAll((r['items'] as List?)??const []);page=next;hasMore=r['has_more']==true;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString().replaceFirst('Exception: ',''))));}finally{if(mounted)setState(()=>loadingMore=false);}}

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : error != null
                ? Center(child: Text(error!))
                : items.isEmpty
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(widget.icon, size: 48, color: Colors.black26), const SizedBox(height: 8), const Text('Chưa có dữ liệu')]))
                    : RefreshIndicator(
                        onRefresh: load,
                        child: NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView.separated(
                          padding: const EdgeInsets.all(10),
                          itemCount: items.length+(loadingMore?1:0),
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            if(i>=items.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                            final x = items[i] as Map;
                            final title = x['ten_khachhang'] ?? x['ten_khach'] ?? x['ma_thanhtoan'] ?? x['ma_datban'] ?? x['ma'] ?? x['madonhang'] ?? 'Dòng ${i + 1}';
                            final subtitle = _compactMap(x);
                            return ListTile(
                              leading: CircleAvatar(child: Icon(widget.icon, size: 20)),
                              title: Text('$title', style: const TextStyle(fontWeight: FontWeight.w700)),
                              subtitle: Text(subtitle, maxLines: 3, overflow: TextOverflow.ellipsis),
                            );
                          },
                        )),
                      ),
      );
}

class CustomerPage extends StatefulWidget {
  const CustomerPage({super.key});
  @override
  State<CustomerPage> createState() => _CustomerPageState();
}

class _CustomerPageState extends State<CustomerPage> {
  final search = TextEditingController();
  List items = [];
  bool loading = true, loadingMore = false, hasMore = true;
  int page = 1;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  String _customerUrl(int p){final q=Uri.encodeQueryComponent(search.text.trim());return '/customers?page=$p&per_page=20${q.isEmpty?'':'&q=$q'}';}
  Future<void> load() async {setState((){loading=true;page=1;hasMore=true;});try{final r=await api.get(_customerUrl(1));if(mounted)setState((){items=(r['items'] as List?)??[];hasMore=r['has_more']==true;});}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}finally{if(mounted)setState(()=>loading=false);}}
  Future<void> loadMore()async{if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get(_customerUrl(next));items.addAll((r['items'] as List?)??const []);page=next;hasMore=r['has_more']==true;}catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e.toString())));}finally{if(mounted)setState(()=>loadingMore=false);}}

  Future<void> addCustomer() async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final email = TextEditingController();
    final address = TextEditingController();
    await showDialog(
      context: context,
      builder: (dc) => AlertDialog(
        title: const Text('Thêm khách hàng'),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Tên khách hàng *')),
          const SizedBox(height: 8),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Số điện thoại')),
          const SizedBox(height: 8),
          TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
          const SizedBox(height: 8),
          TextField(controller: address, decoration: const InputDecoration(labelText: 'Địa chỉ')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Hủy')),
          FilledButton(onPressed: () async {
            try {
              await api.post('/customers', {'name': name.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim().isEmpty ? null : email.text.trim(), 'address': address.text.trim()});
              if (dc.mounted) Navigator.pop(dc);
              await load();
            } catch (e) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))));
            }
          }, child: const Text('Thêm')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(leading: const BackButton(), title: const Text('Khách hàng')),
        floatingActionButton: FloatingActionButton.extended(onPressed: addCustomer, icon: const Icon(Icons.person_add_alt_1), label: const Text('Thêm khách')),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: TextField(
                controller: search,
                onSubmitted: (_) => load(),
                decoration: InputDecoration(
                  hintText: 'Tên hoặc số điện thoại',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(onPressed: load, icon: const Icon(Icons.arrow_forward)),
                ),
              ),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView.separated(
                      itemCount: items.length+(loadingMore?1:0),
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        if(i>=items.length)return const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2)));
                        final x = items[i] as Map;
                        return ListTile(
                          leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                          title: Text('${x['ten_khachhang'] ?? 'Khách hàng'}'),
                          subtitle: Text('${x['sodienthoai'] ?? ''}${x['email'] != null ? ' • ${x['email']}' : ''}'),
                          trailing: x['fic_diem_khadung'] == null ? null : Text('${x['fic_diem_khadung']} điểm'),
                        );
                      },
                    )),
            ),
          ],
        ),
      );
}

class QrRequestPage extends StatefulWidget {
  const QrRequestPage({super.key});
  @override
  State<QrRequestPage> createState() => _QrRequestPageState();
}

class _QrRequestPageState extends State<QrRequestPage> {
  Map<String, dynamic>? data;
  bool loading = true, loadingMore=false, hasMore=true;
  int page=1;
  int? acceptingId;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {setState((){loading=true;page=1;hasMore=true;});try{final r=await api.get('/qr-orders?page=1&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};if(mounted)setState((){data=d;hasMore=d['has_more']==true;});}finally{if(mounted)setState(()=>loading=false);}}
  Future<void> loadMore()async{if(loadingMore||!hasMore)return;setState(()=>loadingMore=true);try{final next=page+1;final r=await api.get('/qr-orders?page=$next&per_page=20');final d=(r['data'] as Map?)?.cast<String,dynamic>()??{};final old=List.from(data?['items'] as List? ?? []);old.addAll(List.from(d['items'] as List? ?? []));data={...?data,'items':old,'has_more':d['has_more']};page=next;hasMore=d['has_more']==true;}finally{if(mounted)setState(()=>loadingMore=false);}}

  Future<void> acceptAndOpenOrder(Map x) async {
    final qrId = int.tryParse('${x['id']}');
    if (qrId == null || acceptingId != null) return;
    setState(() => acceptingId = qrId);
    try {
      final response = await api.post('/qr-orders/$qrId/accept', {});
      final accepted = (response['data'] is Map)
          ? Map<String, dynamic>.from(response['data'] as Map)
          : response;
      final tableId = int.tryParse('${accepted['table_id'] ?? x['id_ban'] ?? ''}');
      if (tableId == null) {
        throw Exception('Đã nhận đơn nhưng không xác định được bàn.');
      }

      final bootstrap = await api.get('/bootstrap');
      final tableList = (bootstrap['tables'] as List?) ?? const <dynamic>[];
      Map? table;
      for (final item in tableList) {
        if (item is Map && '${item['id']}' == '$tableId') {
          table = item;
          break;
        }
      }
      table ??= <String, dynamic>{
        'id': tableId,
        'tenban': x['tenban'] ?? 'Bàn',
        'trangthai': 2,
      };

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OrderPage(
            table: Map<String, dynamic>.from(table!),
            bootstrap: bootstrap,
          ),
        ),
      );
      if (mounted) await load();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err.toString().replaceFirst('Exception: ', ''))),
        );
      }
    } finally {
      if (mounted) setState(() => acceptingId = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(leading: const BackButton(), title: const Text('Yêu cầu gọi món QR')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: load,
                child: NotificationListener<ScrollNotification>(onNotification:(n){if(n.metrics.pixels>=n.metrics.maxScrollExtent-240)loadMore();return false;},child:ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          children: [
                            const Icon(Icons.qr_code_scanner, size: 58),
                            const SizedBox(height: 12),
                            Text('${((data?['items']) is List ? ((data?['items']) as List).where((e) => e is Map && '${e['status'] ?? 'pending'}' == 'pending').length : 0)}',
                                style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w900)),
                            const Text('đơn QR đang chờ xử lý'),
                            const SizedBox(height: 8),
                            const Text('Kéo xuống để làm mới danh sách đơn QR.', style: TextStyle(color: Colors.black45)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...(((data?['items']) is List ? (data?['items']) as List : const <dynamic>[])).map((e) {
                      final x = e is Map ? e : <String,dynamic>{};
                      final items = (x['items'] is List) ? x['items'] as List : const <dynamic>[];
                      final itemText = items.map((it) {
                        final m = it is Map ? it : <String,dynamic>{};
                        return '${m['tensanpham'] ?? 'Món'} x${m['quantity'] ?? 1}';
                      }).join(', ');
                      final status = '${x['status'] ?? 'pending'}';
                      return Card(child:ListTile(
                        title:Text('${x['tenban'] ?? 'Bàn'} • Đơn QR #${x['id'] ?? ''}'),
                        subtitle:Text([if(itemText.isNotEmpty)itemText, if('${x['note'] ?? ''}'.trim().isNotEmpty)'Ghi chú: ${x['note']}', status].join('\n')),
                        isThreeLine:itemText.isNotEmpty,
                        trailing: status=='pending' ? Row(mainAxisSize:MainAxisSize.min,children:[
                          IconButton(
                            tooltip: 'Nhận đơn và mở bàn',
                            icon: acceptingId == int.tryParse('${x['id']}')
                                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.check_circle_outline),
                            onPressed: acceptingId != null ? null : () => acceptAndOpenOrder(x),
                          ),
                          IconButton(icon:const Icon(Icons.cancel_outlined),onPressed:() async {
                            try{await api.post('/qr-orders/${x['id']}/reject',{'reason':'Từ chối từ ứng dụng'});await load();}
                            catch(err){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(err.toString().replaceFirst('Exception: ',''))));}
                          })
                        ]) : null
                      ));
                    }),
                    if(loadingMore) const Padding(padding:EdgeInsets.all(16),child:Center(child:CircularProgressIndicator(strokeWidth:2))),
                  ],
                )),
              ),
      );
}


class TableSearch extends SearchDelegate<Map?> {
  final List tables;
  TableSearch(this.tables);

  @override
  String? get searchFieldLabel => 'Tìm bàn';

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            tooltip: 'Xóa',
            onPressed: () => query = '',
            icon: const Icon(Icons.clear),
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        tooltip: 'Quay lại',
        onPressed: () => close(context, null),
        icon: const Icon(Icons.arrow_back),
      );

  @override
  Widget buildResults(BuildContext context) => _list(context);

  @override
  Widget buildSuggestions(BuildContext context) => _list(context);

  Widget _list(BuildContext context) {
    final q = query.trim().toLowerCase();
    final filtered = tables.where((e) {
      final x = e as Map;
      final name = '${x['tenban'] ?? x['ten'] ?? ''}'.toLowerCase();
      final id = '${x['id'] ?? ''}'.toLowerCase();
      final room = '${x['tenphong'] ?? x['phong'] ?? ''}'.toLowerCase();
      return q.isEmpty || name.contains(q) || id == q || room.contains(q);
    }).toList();

    if (filtered.isEmpty) {
      return const Center(child: Text('Không tìm thấy bàn phù hợp'));
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final x = filtered[i] as Map;
        final name = '${x['tenban'] ?? x['ten'] ?? 'Bàn'}';
        final busy = _tableBusyForSearch(x);
        final room = '${x['tenphong'] ?? x['phong'] ?? ''}'.trim();
        return ListTile(
          leading: CircleAvatar(
            child: Icon(busy ? Icons.restaurant : Icons.table_restaurant_outlined),
          ),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text([
            if (room.isNotEmpty) room,
            busy ? 'Đang có khách' : 'Còn trống',
          ].join(' • ')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => close(context, Map.from(x)),
        );
      },
    );
  }
}

bool _tableBusyForSearch(Map x) {
  // Prefer explicit busy flags when the API provides them.
  final explicit = x['dang_sudung'] ?? x['dang_su_dung'] ?? x['is_busy'] ?? x['busy'];
  if (explicit is bool) return explicit;
  if (explicit is num) return explicit == 1;
  if (explicit != null) {
    final s = '$explicit'.trim().toLowerCase();
    if (['1', 'true', 'busy', 'occupied', 'dang su dung', 'đang sử dụng'].contains(s)) return true;
    if (['0', 'false', 'empty', 'available', 'free', 'con trong', 'còn trống'].contains(s)) return false;
  }

  // FIC POS table status convention: 1 = available, 2 = occupied.
  final status = x['trangthai'];
  if (status is num) return status == 2;
  final statusText = '${status ?? ''}'.trim().toLowerCase();
  if (['2', 'busy', 'occupied', 'dang su dung', 'đang sử dụng'].contains(statusText)) return true;
  if (['0', '1', 'empty', 'available', 'free', 'con trong', 'còn trống'].contains(statusText)) return false;

  // Last fallback: a current order code means the table is occupied.
  final order = '${x['madonhang'] ?? x['order_code'] ?? ''}'.trim();
  return order.isNotEmpty;
}

class ProductSearch extends SearchDelegate {
  final List products;
  ProductSearch(this.products);

  @override
  List<Widget>? buildActions(BuildContext context) => [
        IconButton(onPressed: () => query = '', icon: const Icon(Icons.clear))
      ];
  @override
  Widget? buildLeading(BuildContext context) => IconButton(
      onPressed: () => close(context, null), icon: const Icon(Icons.arrow_back));
  @override
  Widget buildResults(BuildContext context) => list();
  @override
  Widget buildSuggestions(BuildContext context) => list();

  Widget list() {
    final q = query.toLowerCase();
    final filtered = products
        .where((e) => '${(e as Map)['tensanpham'] ?? ''}'.toLowerCase().contains(q))
        .toList();
    return ListView(
      children: filtered.map((e) {
        final x = e as Map;
        return ListTile(
          title: Text('${x['tensanpham'] ?? ''}'),
          subtitle: Text('${money(num.tryParse('${x['giaban'] ?? 0}') ?? 0)} đ'),
        );
      }).toList(),
    );
  }
}

String money(num n) {
  final s = n.round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return b.toString();
}

String _compactMap(Map x) {
  final parts = <String>[];
  void add(String label, dynamic value) {
    if (value != null && '$value'.trim().isNotEmpty) parts.add('$label: $value');
  }
  add('Bàn', x['tenban']);
  add('Thời gian đến', x['thoigian_den']);
  add('Số khách', x['so_khach']);
  add('SĐT', x['sodienthoai']);
  if (x['phaitra'] != null) parts.add('Tổng: ${money(num.tryParse('${x['phaitra']}') ?? 0)} đ');
  add('Thanh toán', x['phuongthuc']);
  add('Trạng thái', x['trangthai']);
  add('Thời gian', x['paid_at']);
  return parts.join(' • ');
}
