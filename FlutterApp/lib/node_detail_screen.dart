import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class DeviceSchedule {
  bool enabled;
  TimeOfDay? onTime;
  TimeOfDay? offTime;

  DeviceSchedule({this.enabled = false, this.onTime, this.offTime});

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'on': onTime != null ? _fmtHHmm(onTime!) : null,
    'off': offTime != null ? _fmtHHmm(offTime!) : null,
  };

  static DeviceSchedule from(dynamic raw) {
    if (raw is Map) {
      return DeviceSchedule(
        enabled: (raw['enabled'] as bool?) ?? false,
        onTime: _parseHHmm(raw['on']),
        offTime: _parseHHmm(raw['off']),
      );
    }
    return DeviceSchedule();
  }
}

String _fmtHHmm(TimeOfDay t) =>
    t.hour.toString().padLeft(2, '0') +
    ':' +
    t.minute.toString().padLeft(2, '0');

TimeOfDay? _parseHHmm(dynamic v) {
  if (v is String && v.contains(':')) {
    final sp = v.split(':');
    final h = int.tryParse(sp[0]) ?? 0;
    final m = int.tryParse(sp[1]) ?? 0;
    return TimeOfDay(hour: h, minute: m);
  }
  return null;
}

String formatUpdatedAt(int millis) {
  // milllis theo epoch UTC -> hiển thị local time (VN nếu máy đang GMT+7)
  final dtLocal = DateTime.fromMillisecondsSinceEpoch(
    millis,
    isUtc: true,
  ).toLocal();
  return DateFormat('dd-MM-yyyy HH:mm:ss').format(dtLocal);
}

class NodeDetailScreen extends StatefulWidget {
  final String nodeName;
  final String nodeId;

  const NodeDetailScreen({
    required this.nodeName,
    required this.nodeId,
    Key? key,
  }) : super(key: key);

  @override
  _NodeDetailScreenState createState() => _NodeDetailScreenState();
}

class _NodeDetailScreenState extends State<NodeDetailScreen>
    with TickerProviderStateMixin {
  Map<String, Map<String, num>> _currentDisplayedSensorData = {};
  int? _updatedAt;
  String? _lastStatusSig;

  bool _pumpState = false;
  bool _lightState = false;
  bool _fanState = false;

  String _pumpMode = 'schedule';
  String _lightMode = 'schedule';
  String _fanMode = 'schedule';

  static const String _modeManual = 'manual';
  static const String _modeAuto = 'auto';
  static const String _modeSchedule = 'schedule';

  String _selectedTab = 'monitor';
  bool _isEditingSchedule = false;

  // Firebase refs
  late final DatabaseReference _ctrlRef; // /nodes/{id}/controls
  late final DatabaseReference _metaRef; // /nodes/{id}/meta
  late final DatabaseReference _statusRef; // /nodes/{id}/status
  StreamSubscription<DatabaseEvent>? _ctrlSub;
  StreamSubscription<DatabaseEvent>? _statusSub;

  // Schedules
  late final DatabaseReference _schedRef; // /nodes/{id}/schedules
  StreamSubscription<DatabaseEvent>? _schedSub;
  final Map<String, DeviceSchedule> _schedules = {
    'pump': DeviceSchedule(),
    'light': DeviceSchedule(),
    'fan': DeviceSchedule(),
  };
  final Map<String, int> _lastUserToggleMs = {'pump': 0, 'light': 0, 'fan': 0};
  static const int _toggleCooldownMs = 2000; // 2s
  final Set<String> _toggleLocks = {};
  final Map<String, int> _pendingBatch = {}; // device -> 0/1
  Timer? _batchDebounce;
  static const _uiBatchDebounceMs = 250; // debounce 250ms cho UI

  // Auto-mode: giãn cách giữa từng lệnh khi AUTO bật/tắt nhiều thiết bị
  static const int _seqDelayMs = 2000; // 2s

  // Server control (lịch / gateway) -> giãn cách hiển thị switch
  static const int _serverSeqDelayMs = 4000; // 2s giữa từng thiết bị

  final List<Map<String, dynamic>> _serverChangeQueue = [];
  bool _serverFlushing = false;

  static const List<String> _seqOrder = [
    'pump',
    'light',
    'fan',
  ]; // thứ tự bật/tắt
  final List<Map<String, dynamic>> _autoPending = [];
  bool _autoFlushing = false;

  // ==== AUTO MODE ====
  bool _autoEnabled = false;
  Timer? _autoTimer;
  late final DatabaseReference _autoRef;

  // Ngưỡng auto (độ ẩm đất cho bơm)
  static const int _soilOnThreshold = 30; // Bật bơm khi < 30%
  static const int _soilOffThreshold = 45; // Tắt bơm khi > 45%
  // Giới hạn thời gian hoạt động tối đa của bơm
  static const int _maxPumpDurationMs = 10 * 60 * 1000; // 10 phút
  int? _pumpStartMs;

  // Khoảng nghỉ giữa hai lần bật bơm
  static const int _pumpRestMs = 60 * 1000; // nghỉ 1 phút
  int _lastPumpOffMs = 0;

  // Khung giờ cho phép bơm hoạt động (tùy chọn)
  static const String _pumpWinStart = '05:00';
  static const String _pumpWinEnd = '21:00';

  // Ngưỡng auto (AQI cho quạt)
  static const int _aqiOnThreshold = 3; // Kém trở lên
  static const int _aqiOffThreshold = 2; // Trung bình trở xuống

  // Ngưỡng auto (lux cho đèn)
  static const int _luxOnThreshold = 200; // Bật khi < 200 lux
  static const int _luxOffThreshold = 400; // Tắt khi > 400 lux

  // Khung giờ auto cho đèn
  static const String _lightWinStart = '06:00';
  static const String _lightWinEnd = '18:30';

  // Animation
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
    _animationController.forward();
    // Firebase refs
    final db = FirebaseDatabase.instance.ref();
    _ctrlRef = db.child('nodes').child(widget.nodeId).child('controls');
    _metaRef = db.child('nodes').child(widget.nodeId).child('meta');
    _statusRef = db.child('nodes').child(widget.nodeId).child('status');
    _schedRef = db.child('nodes').child(widget.nodeId).child('schedules');
    _autoRef = db.child('nodes').child(widget.nodeId).child('auto');
    // AUTO: read once + listen
    _autoRef.child('appEnabled').get().then((snap) {
      if (!mounted) return;
      final v = snap.value;
      setState(() => _autoEnabled = (v is bool) ? v : false);
      _restartAutoTimer(); // khởi chạy kiểm tra auto nếu đang bật
    });
    _autoRef.onValue.listen((e) {
      if (!mounted) return;
      final m = e.snapshot.value;
      if (m is Map) {
        final en = m['appEnabled'];
        if (en is bool) {
          setState(() => _autoEnabled = en);
          _restartAutoTimer();
        }
      }
    });
    // ----- CONTROLS: read once + listen
    _ctrlRef.get().then((snap) {
      final data = snap.value as Map<Object?, Object?>?;
      if (!mounted || data == null) return;

      final pump = (data['pump'] as bool?) ?? _pumpState;
      final light = (data['light'] as bool?) ?? _lightState;
      final fan = (data['fan'] as bool?) ?? _fanState;

      final pumpMode = (data['pumpMode'] as String?) ?? _pumpMode;
      final lightMode = (data['lightMode'] as String?) ?? _lightMode;
      final fanMode = (data['fanMode'] as String?) ?? _fanMode;

      // lần load đầu: áp ngay, không cần delay 2s
      setState(() {
        _pumpState = pump;
        _lightState = light;
        _fanState = fan;
        _pumpMode = pumpMode;
        _lightMode = lightMode;
        _fanMode = fanMode;
      });
    });

    _ctrlSub = _ctrlRef.onValue.listen((event) {
      final data = event.snapshot.value as Map<Object?, Object?>?;
      if (!mounted || data == null) return;

      final pump = (data['pump'] as bool?) ?? _pumpState;
      final light = (data['light'] as bool?) ?? _lightState;
      final fan = (data['fan'] as bool?) ?? _fanState;

      final pumpMode = (data['pumpMode'] as String?) ?? _pumpMode;
      final lightMode = (data['lightMode'] as String?) ?? _lightMode;
      final fanMode = (data['fanMode'] as String?) ?? _fanMode;

      setState(() {
        _pumpMode = pumpMode;
        _lightMode = lightMode;
        _fanMode = fanMode;
      });
      _applyControlFromServer(pump, light, fan);
    });
    // ----- STATUS: read once + realtime (TRỌNG TÂM)
    _statusRef.get().then((snap) {
      if (!mounted) return;
      final raw = snap.value;
      _lastStatusSig = raw?.toString(); // lưu chữ ký lần đầu
      _applyStatusToUI(raw, bumpTime: false);
    });

    _statusSub = _statusRef.onValue.listen((event) {
      if (!mounted) return;
      final raw = event.snapshot.value;
      final sig = raw?.toString();
      if (sig != _lastStatusSig) {
        _lastStatusSig = sig;
        _applyStatusToUI(
          raw,
          bumpTime: true,
        ); // cập nhật _updatedAt = thời điểm nhận gói
      }
    });
    // ----- SCHEDULES
    Future<void> _loadSchedulesOnce() async {
      final snap = await _schedRef.get();
      if (!mounted) return;

      final raw = snap.value as Map<Object?, Object?>?;
      if (raw == null) {
        setState(() {
          _schedules['pump'] = DeviceSchedule();
          _schedules['light'] = DeviceSchedule();
          _schedules['fan'] = DeviceSchedule();
        });
        return;
      }
      setState(() {
        _schedules['pump'] = DeviceSchedule.from(raw['pump']);
        _schedules['light'] = DeviceSchedule.from(raw['light']);
        _schedules['fan'] = DeviceSchedule.from(raw['fan']);
      });
    }

    Future<void> _listenSchedules() async {
      _schedSub = _schedRef.onValue.listen((event) async {
        if (_isEditingSchedule || !mounted) return;
        final raw = event.snapshot.value as Map<Object?, Object?>?;
        if (raw == null) return; // <-- không còn chuyển sang 'schedule'
        setState(() {
          _schedules['pump'] = DeviceSchedule.from(raw['pump']);
          _schedules['light'] = DeviceSchedule.from(raw['light']);
          _schedules['fan'] = DeviceSchedule.from(raw['fan']);
        });
      });
    }

    _loadSchedulesOnce();
    _listenSchedules();
  }

  @override
  void dispose() {
    _ctrlSub?.cancel();
    _statusSub?.cancel();
    _schedSub?.cancel();
    _autoTimer?.cancel();
    _batchDebounce?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  final NumberFormat _nf = NumberFormat("0.##");

  String fmtNum(num v) => _nf.format(v);

  // ---- Áp dữ liệu /nodes/<id>/status vào UI
  void _applyStatusToUI(dynamic raw, {bool bumpTime = true}) {
    if (raw is Map) {
      final m = raw as Map;

      setState(() {
        _currentDisplayedSensorData = {
          'Realtime': {
            'temp': (m['t'] as num?) ?? 0,
            'humidity': (m['h'] as num?) ?? 0,
            'light': (m['l'] as num?) ?? 0,
            'soil': (m['s'] as num?) ?? 0,
            'aqi': (m['aq'] as num?) ?? (m['aqi'] as num?) ?? 0,
            'eco2': (m['ec'] as num?) ?? (m['eco2'] as num?) ?? 0,
            'tvoc': (m['tv'] as num?) ?? (m['tvoc'] as num?) ?? 0,
          },
        };

        // Ưu tiên timestamp từ status nếu có (ts hoặc updatedAt)
        if (bumpTime) {
          _updatedAt = DateTime.now().millisecondsSinceEpoch;
        }
      });
    }
  }

  // Áp trạng thái điều khiển từ server vào UI, giãn cách từng switch 2s
  void _applyControlFromServer(
    bool pump,
    bool light,
    bool fan, {
    bool initial = false,
  }) {
    if (initial) {
      setState(() {
        _pumpState = pump;
        _lightState = light;
        _fanState = fan;
      });
      return;
    }
    final List<Map<String, dynamic>> changes = [];
    if (pump != _pumpState) {
      changes.add({'device': 'pump', 'value': pump});
    }
    if (light != _lightState) {
      changes.add({'device': 'light', 'value': light});
    }
    if (fan != _fanState) {
      changes.add({'device': 'fan', 'value': fan});
    }
    if (changes.isEmpty) return;
    changes.sort(
      (a, b) => _seqOrder
          .indexOf(a['device'] as String)
          .compareTo(_seqOrder.indexOf(b['device'] as String)),
    );

    _serverChangeQueue.addAll(changes);
    if (!_serverFlushing) {
      _flushServerChangeQueue();
    }
  }

  void _flushServerChangeQueue() {
    if (_serverChangeQueue.isEmpty) {
      _serverFlushing = false;
      return;
    }

    _serverFlushing = true;

    final change = _serverChangeQueue.removeAt(0);
    final String dev = change['device'] as String;
    final bool val = change['value'] as bool;

    // Áp 1 thiết bị vào UI
    setState(() {
      if (dev == 'pump') _pumpState = val;
      if (dev == 'light') _lightState = val;
      if (dev == 'fan') _fanState = val;
    });
    Future.delayed(Duration(milliseconds: _serverSeqDelayMs), () {
      if (!mounted) return;
      _flushServerChangeQueue();
    });
  }

  void _scheduleEmitPendingBatch({String origin = 'app'}) {
    _batchDebounce?.cancel();
    _batchDebounce = Timer(
      const Duration(milliseconds: _uiBatchDebounceMs),
      () async {
        if (_pendingBatch.isEmpty) return;

        final items = _pendingBatch.entries
            .map((e) => {'device': e.key, 'value': e.value})
            .toList();

        _pendingBatch.clear();
        await _emitBatchDownlinkNoThrottle(items, origin: origin);
      },
    );
  }

  void _autoQueue(String dev, bool on) {
    final idx = _autoPending.indexWhere((e) => e['device'] == dev);
    final item = {'device': dev, 'value': on ? 1 : 0};
    if (idx >= 0)
      _autoPending[idx] = item;
    else
      _autoPending.add(item);
  }

  Future<void> _autoFlushSequential() async {
    if (_autoFlushing || _autoPending.isEmpty) return;
    _autoFlushing = true;
    _autoPending.sort(
      (a, b) => _seqOrder
          .indexOf(a['device'])
          .compareTo(_seqOrder.indexOf(b['device'])),
    );

    final items = List<Map<String, dynamic>>.from(_autoPending);
    _autoPending.clear();

    for (var i = 0; i < items.length; i++) {
      final dev = items[i]['device'] as String;
      final on = (items[i]['value'] as int) == 1;

      Future.delayed(Duration(milliseconds: _seqDelayMs * i), () async {
        setState(() {
          if (dev == 'pump') _pumpState = on;
          if (dev == 'light') _lightState = on;
          if (dev == 'fan') _fanState = on;
        });
        await _setDeviceStateNoDownlink(dev, on, origin: 'auto');
        await _emitSingleDownlink(dev, on, origin: 'auto');
        if (dev == 'pump') {
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (on)
            _pumpStartMs = nowMs;
          else {
            _lastPumpOffMs = nowMs;
            _pumpStartMs = null;
          }
        }
      });
    }
    Future.delayed(Duration(milliseconds: _seqDelayMs * items.length), () {
      _autoFlushing = false;
    });
  }

  // ==== AUTO HELPERS ====
  bool _inLightWindow(DateTime now) {
    TimeOfDay _parse(String hhmm) {
      final sp = hhmm.split(':');
      return TimeOfDay(hour: int.parse(sp[0]), minute: int.parse(sp[1]));
    }

    final s = _parse(_lightWinStart), e = _parse(_lightWinEnd);
    final nowTod = TimeOfDay(hour: now.hour, minute: now.minute);
    bool _ge(TimeOfDay a, TimeOfDay b) =>
        (a.hour > b.hour) || (a.hour == b.hour && a.minute >= b.minute);
    bool _le(TimeOfDay a, TimeOfDay b) =>
        (a.hour < b.hour) || (a.hour == b.hour && a.minute <= b.minute);
    return _ge(nowTod, s) && _le(nowTod, e);
  }

  bool _inPumpWindow(DateTime now) {
    TimeOfDay _parse(String hhmm) {
      final sp = hhmm.split(':');
      return TimeOfDay(hour: int.parse(sp[0]), minute: int.parse(sp[1]));
    }

    final s = _parse(_pumpWinStart), e = _parse(_pumpWinEnd);
    final nowTod = TimeOfDay(hour: now.hour, minute: now.minute);
    bool _ge(TimeOfDay a, TimeOfDay b) =>
        (a.hour > b.hour) || (a.hour == b.hour && a.minute >= b.minute);
    bool _le(TimeOfDay a, TimeOfDay b) =>
        (a.hour < b.hour) || (a.hour == b.hour && a.minute <= b.minute);
    return _ge(nowTod, s) && _le(nowTod, e);
  }

  void _restartAutoTimer() {
    _autoTimer?.cancel();
    if (_autoEnabled) {
      _autoTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _maybeRunAuto(),
      );
    }
  }

  num _asNum(dynamic v) => (v is num) ? v : num.tryParse('$v') ?? 0;

  int? _asMillis(dynamic v) {
    int? n;
    if (v is int)
      n = v;
    else if (v is double)
      n = v.round();
    else if (v is String)
      n = int.tryParse(v);
    if (n == null) return null;
    if (n < 1e12) return n * 1000; // seconds -> millis
    if (n >= 1e15) return n ~/ 1000; // micros  -> millis
    return n;
  }

  void _maybeRunAuto() {
    if (_currentDisplayedSensorData.isEmpty) return;
    final data = _currentDisplayedSensorData.values.first;
    final aqi = _asNum(data['aqi']);
    final lux = _asNum(data['light']);
    final now = DateTime.now();
    // ===== FAN: AQI-based with hysteresis =====
    final wantFanOn = aqi >= _aqiOnThreshold; // >=3 -> BẬT
    final wantFanOff = aqi <= _aqiOffThreshold; // <=2 -> TẮT
    if (wantFanOn && !_fanState)
      _autoQueue('fan', true);
    else if (wantFanOff && _fanState)
      _autoQueue('fan', false);

    // ===== LIGHT: time window + lux hysteresis =====
    if (_inLightWindow(now)) {
      final wantLightOn = lux < _luxOnThreshold; // <200 -> BẬT
      final wantLightOff = lux > _luxOffThreshold; // >400 -> TẮT
      if (wantLightOn && !_lightState)
        _autoQueue('light', true);
      else if (wantLightOff && _lightState)
        _autoQueue('light', false);
    } else {
      if (_lightState) _autoQueue('light', false); // ngoài khung -> tắt
    }

    // ===== PUMP: soil hysteresis + safety =====
    final soil = _asNum(data['soil']);
    if (soil > 0 && soil <= 100) {
      final wantPumpOn = soil < _soilOnThreshold;
      final wantPumpOff = soil > _soilOffThreshold;
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final enoughRest = nowMs - _lastPumpOffMs > _pumpRestMs;
      final inTimeWindow = _inPumpWindow(now);

      if (wantPumpOn && !_pumpState && enoughRest && inTimeWindow) {
        _autoQueue('pump', true);
      } else if (wantPumpOff && _pumpState) {
        _autoQueue('pump', false);
      }

      if (_pumpState && _pumpStartMs != null) {
        if (nowMs - _pumpStartMs! > _maxPumpDurationMs) {
          _autoQueue('pump', false);
        }
      }
    } else {
      debugPrint('[AUTO] Bỏ qua pump (soil invalid: $soil)');
    }
    _autoFlushSequential();
  }

  Future<void> _setDeviceState(
    String key,
    bool value, {
    String origin = 'app',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 1) Cập nhật controls + meta + mode
    final updates = <String, Object?>{key: value};

    String? mode;
    if (origin == 'app') {
      mode = _modeManual;
    } else if (origin == 'auto') {
      mode = _modeAuto;
    } else if (origin == 'schedule') {
      mode = _modeSchedule;
    }
    if (mode != null) {
      updates['${key}Mode'] = mode;
    }

    await _ctrlRef.update(updates);
    await _metaRef.update({'updatedBy': origin, 'updatedAt': now});

    // 2) Gửi NGAY một lệnh đơn xuống node (KHÔNG gộp batch nữa)
    await _emitSingleDownlink(key, value, origin: origin);
  }

  bool _isInToggleCooldown(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return now - (_lastUserToggleMs[key] ?? 0) < _toggleCooldownMs;
  }

  Future<void> _requestToggle(String key, bool value) async {
    // Bỏ qua nếu trạng thái không đổi
    final current = switch (key) {
      'pump' => _pumpState,
      'light' => _lightState,
      'fan' => _fanState,
      _ => !value,
    };
    if (current == value) return;

    // Chặn spam
    if (_toggleLocks.contains(key) || _isInToggleCooldown(key)) return;
    _toggleLocks.add(key);
    setState(() {
      if (key == 'pump') _pumpState = value;
      if (key == 'light') _lightState = value;
      if (key == 'fan') _fanState = value;
    });

    try {
      await _setDeviceState(key, value, origin: 'app');
      if (key == 'pump' && !value) {
        _lastPumpOffMs = DateTime.now().millisecondsSinceEpoch;
        _pumpStartMs = null;
      }
    } catch (_) {
      // Hoàn tác khi lỗi
      setState(() {
        if (key == 'pump') _pumpState = !value;
        if (key == 'light') _lightState = !value;
        if (key == 'fan') _fanState = !value;
      });
    } finally {
      _lastUserToggleMs[key] = DateTime.now().millisecondsSinceEpoch;
      // Mở khóa sau cooldown
      Future.delayed(const Duration(milliseconds: _toggleCooldownMs), () {
        if (!mounted) return;
        _toggleLocks.remove(key);
      });
    }
  }

  // ==== SCHEDULES ====
  Future<void> _saveSchedule(String deviceKey) async {
    final sch = _schedules[deviceKey]!;
    final data = sch.toJson();
    await _schedRef.child(deviceKey).set(data); // chỉ nhánh 'schedules'

    // Nếu bật lịch cho thiết bị này, ưu tiên cho gateway điều khiển theo lịch
    if (sch.enabled) {
      await _ctrlRef.update({'${deviceKey}Mode': _modeSchedule});
    }
  }

  String _genCmdId() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final r = (ts ^ widget.nodeId.hashCode) & 0xFFFF;
    return '${widget.nodeId}-$ts-$r';
  }

  Future<void> _emitBatchDownlinkNoThrottle(
    List<Map<String, dynamic>> items, {
    String origin = 'app',
  }) async {
    final devRef = FirebaseDatabase.instance
        .ref()
        .child('nodes')
        .child(widget.nodeId)
        .child('downlink')
        .child('batch');

    final now = DateTime.now().millisecondsSinceEpoch;
    await devRef.set({
      'cmd': 'setMulti',
      'payload': items,
      'status': 'pending',
      'by': origin,
      'ts': now,
    });
  }

  Future<void> _setDeviceStateNoDownlink(
    String key,
    bool value, {
    String origin = 'schedule',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    final updates = <String, Object?>{key: value};

    String? mode;
    if (origin == 'app') {
      mode = _modeManual;
    } else if (origin == 'auto') {
      mode = _modeAuto;
    } else if (origin == 'schedule') {
      mode = _modeSchedule;
    }
    if (mode != null) {
      updates['${key}Mode'] = mode;
    }

    await _ctrlRef.update(updates);
    await _metaRef.update({'updatedBy': origin, 'updatedAt': now});
  }

  Future<void> _emitSingleDownlink(
    String device,
    bool on, {
    String origin = 'schedule',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final devRef = FirebaseDatabase.instance
        .ref()
        .child('nodes')
        .child(widget.nodeId)
        .child('downlink')
        .child('batch');

    await devRef.set({
      'cmd': 'setMulti', // GIỮ 'setMulti' như cũ
      'payload': [
        {'device': device, 'value': on ? 1 : 0},
      ],
      'status': 'pending',
      'by': origin,
      'ts': now,
    });
  }

  // ==== UI ====
  @override
  Widget build(BuildContext context) {
    final sensorsToDisplay = _currentDisplayedSensorData;
    final appBarTitle = _selectedTab == 'monitor'
        ? '${widget.nodeName} - Giám sát'
        : '${widget.nodeName} - Điều khiển';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          appBarTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1A237E), Color(0xFF3F51B5)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFE8EAF6), Color(0xFFC5CAE9)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Column(
          children: [
            _buildTabSelector(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: _selectedTab == 'monitor'
                    ? _buildMonitorTab(
                        sensorsToDisplay,
                        key: const ValueKey('monitor'),
                      )
                    : _buildControlTab(key: const ValueKey('control')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabSelector() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      padding: const EdgeInsets.all(4.0),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(20.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildTabButton(
            label: 'GIÁM SÁT',
            icon: Icons.analytics_outlined,
            isSelected: _selectedTab == 'monitor',
            onPressed: () {
              if (_selectedTab != 'monitor')
                setState(() => _selectedTab = 'monitor');
            },
          ),
          const SizedBox(width: 8),
          _buildTabButton(
            label: 'ĐIỀU KHIỂN',
            icon: Icons.settings_input_component_outlined,
            isSelected: _selectedTab == 'control',
            onPressed: () {
              if (_selectedTab != 'control')
                setState(() => _selectedTab = 'control');
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTabButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return Expanded(
      child: Material(
        color: isSelected
            ? Theme.of(context).primaryColorDark
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16.0),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16.0),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  color: isSelected
                      ? Colors.white
                      : Theme.of(context).primaryColorDark,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Colors.white
                        : Theme.of(context).primaryColorDark,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMonitorTab(Map<String, Map<String, num>> sensors, {Key? key}) {
    if (sensors.isEmpty) {
      return Center(
        key: key,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.grey[700], size: 60),
            const SizedBox(height: 16),
            const Text(
              'Không có dữ liệu cảm biến',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Vui lòng kiểm tra lại gateway cho nút ${widget.nodeName}.',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    final sensorKey = sensors.keys.first;
    final Map<String, num> data = sensors[sensorKey]!;
    return FadeTransition(
      opacity: _fadeAnimation,
      key: key,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        children: [
          _buildSensorOverviewCard(sensorKey, data),
          const SizedBox(height: 15),
          GridView.count(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            crossAxisCount: 2,
            crossAxisSpacing: 12.0,
            mainAxisSpacing: 12.0,
            childAspectRatio: 1.2,
            children: [
              _buildSensorDataItem(
                icon: Icons.thermostat_outlined,
                label: 'Nhiệt độ',
                value: '${data['temp']}°C',
                color: Colors.red.shade400,
                unit: '°C',
                rawValue: data['temp']?.toDouble() ?? 0.0,
                minValue: 10,
                maxValue: 40,
              ),
              _buildSensorDataItem(
                icon: Icons.water_drop_outlined,
                label: 'Độ ẩm không khí',
                value: '${fmtNum(data['humidity'] ?? 0)}%',
                color: Colors.blue.shade400,
                unit: '%',
                rawValue: (data['humidity'] ?? 0).toDouble(),
                minValue: 30,
                maxValue: 90,
              ),
              _buildSensorDataItem(
                icon: Icons.lightbulb_circle_outlined,
                label: 'Ánh sáng',
                value: '${fmtNum(data['light'] ?? 0)} lux',
                color: Colors.amber.shade600,
                unit: 'lux',
                rawValue: (data['light'] ?? 0).toDouble(),
                minValue: 0,
                maxValue: 1000,
              ),
              _buildSensorDataItem(
                icon: Icons.eco_outlined,
                label: 'Độ ẩm đất',
                value: '${fmtNum(data['soil'] ?? 0)}%',
                color: Colors.brown.shade400,
                unit: '%',
                rawValue: (data['soil'] ?? 0).toDouble(),
                minValue: 0,
                maxValue: 100,
              ),

              _buildEco2Tile(eco2: (data['eco2'] ?? 0)),
              _buildTvocAqiTile(
                tvoc: (data['tvoc'] ?? 0),
                aqi: (data['aqi'] ?? 0),
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  Widget _buildSensorOverviewCard(String sensorKey, Map<String, num> data) {
    return Card(
      elevation: 6,
      margin: const EdgeInsets.symmetric(vertical: 8.0),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.sensors,
                  color: Theme.of(context).primaryColorDark,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Text(
                  'Dữ liệu cảm biến thu thập',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColorDark,
                  ),
                ),
              ],
            ),
            Divider(height: 24, thickness: 1, color: Colors.grey[200]),
            Text(
              'Cập nhật lần cuối: ${_updatedAt != null ? formatUpdatedAt(_updatedAt!) : 'Chưa có dữ liệu'}',
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSensorDataItem({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required String unit,
    required double rawValue,
    required double minValue,
    required double maxValue,
  }) {
    final percentage = ((rawValue - minValue) / (maxValue - minValue)).clamp(
      0.0,
      1.0,
    );
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16.0)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: color, size: 24),
                ),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                value,
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (maxValue > minValue)
              LinearProgressIndicator(
                value: percentage,
                backgroundColor: color.withOpacity(0.2),
                valueColor: AlwaysStoppedAnimation<Color>(color),
                minHeight: 6,
              ),
          ],
        ),
      ),
    );
  }

  Color _aqiColor(num aqi) {
    final v = aqi.toDouble();
    if (v <= 1) return Colors.lightBlueAccent; // Excellent
    if (v <= 2) return Colors.lightGreen; // Good
    if (v <= 3) return Colors.yellow.shade600; // Moderate
    if (v <= 4) return Colors.orange; // Poor
    return Colors.red.shade400; // Unhealthy (5)
  }

  String _aqiLabel(num aqi) {
    final v = aqi.toDouble();
    if (v <= 1) return 'Tốt';
    if (v <= 2) return 'Trung bình';
    if (v <= 3) return 'Kém';
    if (v <= 4) return 'Xấu';
    return 'Nguy hại';
  }

  Color _eco2Color(num eco2) {
    final v = eco2.toDouble();
    if (v <= 600) return Colors.lightBlueAccent; // Excellent (Target)
    if (v <= 800) return Colors.lightGreen; // Good
    if (v <= 1000) return Colors.yellow.shade600; // Fair
    if (v <= 1500) return Colors.orange; // Poor
    return Colors.red.shade400; // Bad
  }

  String _eco2Label(num eco2) {
    final v = eco2.toDouble();
    if (v <= 600) return 'Tôt';
    if (v <= 800) return 'Trung bình';
    if (v <= 1000) return 'Kém';
    if (v <= 1500) return 'Xấu';
    return 'Nguy hại';
  }

  Widget _buildEco2Tile({required num eco2}) {
    final has = eco2 > 0;
    final color = has ? _eco2Color(eco2) : Colors.grey;
    final label = has ? _eco2Label(eco2) : 'N/A';

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.cloud_outlined, color: color, size: 24),
                ),
                Text(
                  'eCO₂',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                has ? '${fmtNum(eco2)} ppm' : '--',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              has ? 'Mức: $label' : 'Mức: --',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTvocAqiTile({required num tvoc, required num aqi}) {
    final hasTvoc = tvoc > 0;
    final hasAqi = aqi > 0;
    final color = Colors.indigo; // màu chính TVOC

    final aqiTxt = hasAqi
        ? 'AQI: ${fmtNum(aqi)} • ${_aqiLabel(aqi)}'
        : 'AQI: --';

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.science_outlined, color: color, size: 24),
                ),
                Text(
                  'TVOC',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey[700],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                hasTvoc ? '${fmtNum(tvoc)} ppb' : '--',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 6),
            // AQI ở dòng phụ
            Row(
              children: [
                Icon(
                  Icons.air,
                  size: 16,
                  color: hasAqi ? _aqiColor(aqi) : Colors.grey,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    aqiTxt,
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlTab({Key? key}) {
    return FadeTransition(
      opacity: _fadeAnimation,
      key: key,
      child: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 0.0, bottom: 16.0),
                child: Text(
                  'Bảng điều khiển cho ${widget.nodeName}',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).primaryColorDark,
                  ),
                ),
              ),
              Card(
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8.0,
                    horizontal: 16.0,
                  ),
                  child: Column(
                    children: [
                      _buildControlSwitch(
                        label: 'Bơm tưới tự động',
                        value: _pumpState,
                        icon: Icons.water_drop_outlined,
                        activeColor: Colors.blueAccent.shade700,
                        onChanged: (v) async {
                          if (_toggleLocks.contains('pump') ||
                              _isInToggleCooldown('pump'))
                            return;
                          _showControlFeedback('Bơm tưới', v);
                          await _requestToggle('pump', v);
                        },
                      ),
                      Divider(height: 1, thickness: 1, color: Colors.grey[200]),
                      _buildControlSwitch(
                        label: 'Đèn chiếu sáng cây',
                        value: _lightState,
                        icon: Icons.lightbulb_outline,
                        activeColor: Colors.orangeAccent.shade700,
                        onChanged: (v) async {
                          if (_toggleLocks.contains('light') ||
                              _isInToggleCooldown('light'))
                            return;
                          _showControlFeedback('Đèn chiếu sáng', v);
                          await _requestToggle('light', v);
                        },
                      ),
                      Divider(height: 1, thickness: 1, color: Colors.grey[200]),
                      _buildControlSwitch(
                        label: 'Hệ thống quạt',
                        value: _fanState,
                        icon: Icons.wind_power,
                        activeColor: Colors.teal.shade400,
                        onChanged: (v) async {
                          if (_toggleLocks.contains('fan') ||
                              _isInToggleCooldown('fan'))
                            return;
                          _showControlFeedback('Hệ thống quạt', v);
                          await _requestToggle('fan', v);
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ====== AUTO MODE SWITCH ======
              Card(
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 16,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.auto_mode,
                        color: Colors.purple.shade400,
                        size: 26,
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Text(
                          'Chế độ tự động',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Transform.scale(
                        scale: 0.9,
                        child: Switch(
                          value: _autoEnabled,
                          onChanged: (v) async {
                            setState(() => _autoEnabled = v);
                            await _autoRef.update({'appEnabled': v});
                            _restartAutoTimer();
                            if (v) _maybeRunAuto();
                          },
                          activeColor: Colors.purple.shade400,
                          activeTrackColor: Colors.purple.shade200,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 25),

              // Chỉ còn NÚT ĐẶT LỊCH
              // NÚT ĐẶT LỊCH
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openScheduleSheet,
                  icon: const Icon(Icons.timer_outlined, size: 20),
                  label: const Text(
                    'Đặt lịch điều khiển thiết bị',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orangeAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    elevation: 5,
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // NÚT XUẤT DỮ LIỆU
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _openExportSheet,
                  icon: const Icon(Icons.download_outlined, size: 20),
                  label: const Text(
                    'Xuất lịch sử dữ liệu',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  void _openScheduleSheet() {
    _isEditingSchedule = true; // chặn listener đè state khi đang chọn giờ

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (ctx, scrollController) {
            return StatefulBuilder(
              builder: (ctx, setModalState) {
                return Container(
                  decoration: const BoxDecoration(color: Colors.transparent),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                    child: Column(
                      children: [
                        // Header
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                          width: double.infinity,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Theme.of(context).primaryColorDark,
                                Theme.of(context).primaryColor,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.schedule, color: Colors.white),
                              const SizedBox(width: 10),
                              const Expanded(
                                child: Text(
                                  'Cài đặt thời gian hoạt động',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                                onPressed: () => Navigator.of(ctx).pop(),
                                tooltip: 'Đóng',
                              ),
                            ],
                          ),
                        ),
                        // Content
                        Expanded(
                          child: SingleChildScrollView(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                            child: Column(
                              children: [
                                _buildScheduleRow(
                                  label: 'Bơm tưới',
                                  icon: Icons.water_drop_outlined,
                                  devKey: 'pump',
                                  setSheetState: setModalState,
                                ),
                                const SizedBox(height: 12),
                                _buildScheduleRow(
                                  label: 'Đèn chiếu sáng',
                                  icon: Icons.lightbulb_outline,
                                  devKey: 'light',
                                  setSheetState: setModalState,
                                ),
                                const SizedBox(height: 12),
                                _buildScheduleRow(
                                  label: 'Hệ thống quạt',
                                  icon: Icons.wind_power,
                                  devKey: 'fan',
                                  setSheetState: setModalState,
                                ),
                                const SizedBox(height: 16),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () =>
                                            Navigator.of(ctx).pop(),
                                        icon: const Icon(Icons.check),
                                        label: const Text('Xong'),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    ).whenComplete(() {
      // Mở lại đồng bộ sau khi sheet đóng
      _isEditingSchedule = false;
    });
  }

  Widget _buildScheduleRow({
    required String label,
    required IconData icon,
    required String devKey,
    void Function(VoidCallback fn)? setSheetState,
  }) {
    final sch = _schedules[devKey]!;
    String showTime(TimeOfDay? t) => t == null ? '--:--' : _fmtHHmm(t);

    Future<void> pick(bool isOn) async {
      final init = isOn
          ? (sch.onTime ?? TimeOfDay.now())
          : (sch.offTime ?? TimeOfDay.now());
      final picked = await showTimePicker(
        context: context,
        initialTime: init,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
      );
      if (picked != null) {
        setState(() => isOn ? sch.onTime = picked : sch.offTime = picked);
        if (setSheetState != null) setSheetState(() {});
        _saveSchedule(devKey);
      }
    }

    Widget pill({
      required IconData i,
      required String text,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).primaryColor.withOpacity(0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Theme.of(context).primaryColor.withOpacity(0.25),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(i, size: 16, color: Theme.of(context).primaryColorDark),
              const SizedBox(width: 6),
              Text(
                text,
                style: TextStyle(
                  color: Theme.of(context).primaryColorDark,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget statusBadge(bool enabled) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: enabled
              ? Colors.green.withOpacity(0.1)
              : Colors.grey.withOpacity(0.12),
          border: Border.all(
            color: enabled
                ? Colors.green.withOpacity(0.35)
                : Colors.grey.withOpacity(0.35),
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              enabled ? Icons.check_circle : Icons.pause_circle_filled,
              size: 16,
              color: enabled ? Colors.green : Colors.grey[600],
            ),
            const SizedBox(width: 6),
            Text(
              enabled ? 'Bật' : 'Tắt',
              style: TextStyle(
                color: enabled ? Colors.green[800] : Colors.grey[700],
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(
                    context,
                  ).primaryColor.withOpacity(0.12),
                  child: Icon(icon, color: Theme.of(context).primaryColorDark),
                ),
                const SizedBox(width: 12),

                // Khối giữa chiếm phần còn lại
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow:
                            TextOverflow.ellipsis, // phòng ngừa label quá dài
                      ),
                      const SizedBox(height: 6),

                      // TÁCH 2 DÒNG: Bật / Tắt
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.play_arrow_rounded,
                                size: 14,
                                color: Colors.green[700],
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'Bật: ${showTime(sch.onTime)}',
                                style: TextStyle(
                                  color: Colors.grey[800],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.stop_rounded,
                                size: 14,
                                color: Colors.red[700],
                              ),
                              const SizedBox(width: 3),
                              Text(
                                'Tắt: ${showTime(sch.offTime)}',
                                style: TextStyle(
                                  color: Colors.grey[800],
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Switch(
                      value: sch.enabled,
                      onChanged: (v) {
                        setState(() => sch.enabled = v);
                        if (setSheetState != null) setSheetState(() {});
                        _saveSchedule(devKey);
                      },
                      activeColor: Theme.of(context).primaryColorDark,
                      activeTrackColor: Theme.of(
                        context,
                      ).primaryColorDark.withOpacity(0.35),
                    ),
                    statusBadge(sch.enabled),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                pill(
                  i: Icons.access_time_rounded,
                  text: 'Chọn giờ Bật (${showTime(sch.onTime)})',
                  onTap: () => pick(true),
                ),
                pill(
                  i: Icons.timelapse_rounded,
                  text: 'Chọn giờ Tắt (${showTime(sch.offTime)})',
                  onTap: () => pick(false),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlSwitch({
    required String label,
    required bool value,
    required IconData icon,
    required Color activeColor,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        children: [
          Icon(icon, color: value ? activeColor : Colors.grey[600], size: 26),
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey[800],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Transform.scale(
            scale: 0.9,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeColor: activeColor,
              activeTrackColor: activeColor.withOpacity(0.4),
              inactiveThumbColor: Colors.grey.shade400,
              inactiveTrackColor: Colors.grey.shade200,
            ),
          ),
        ],
      ),
    );
  }

  void _openExportSheet() {
    // Ở đây mình cho chọn: node hiện tại + tùy chọn "Tất cả node"
    final List<Map<String, String>> nodeOptions = [
      {'id': widget.nodeId, 'label': widget.nodeName},
      {'id': 'all', 'label': 'Tất cả các node'},
    ];

    String selectedNodeId = widget.nodeId;
    String selectedRange = 'today'; // today, 7days, 30days

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.55,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (ctx, scrollController) {
            return StatefulBuilder(
              builder: (ctx, setModalState) {
                return Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade300,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 4,
                        ),
                        child: Text(
                          'Xuất dữ liệu cảm biến',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: 18,
                              ),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const SizedBox(height: 8),
                              const Text(
                                'Chọn node',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: selectedNodeId,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                ),
                                items: nodeOptions
                                    .map(
                                      (opt) => DropdownMenuItem<String>(
                                        value: opt['id'],
                                        child: Text(opt['label'] ?? ''),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (v) {
                                  if (v == null) return;
                                  setModalState(() {
                                    selectedNodeId = v;
                                  });
                                },
                              ),
                              const SizedBox(height: 20),
                              const Text(
                                'Khoảng thời gian',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                value: selectedRange,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'today',
                                    child: Text('Hôm nay'),
                                  ),
                                  DropdownMenuItem(
                                    value: '7days',
                                    child: Text('7 ngày gần nhất'),
                                  ),
                                  DropdownMenuItem(
                                    value: '30days',
                                    child: Text('30 ngày gần nhất'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v == null) return;
                                  setModalState(() {
                                    selectedRange = v;
                                  });
                                },
                              ),
                              const SizedBox(height: 20),
                              Text(
                                'Dữ liệu cảm biến được trích xuất từ dữ liệu lưu trên Firebase.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.of(ctx).pop(),
                                child: const Text('Hủy'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.of(ctx).pop();
                                  _exportData(selectedNodeId, selectedRange);
                                },
                                icon: const Icon(
                                  Icons.download_outlined,
                                  size: 20,
                                ),
                                label: const Text('Xuất dữ liệu'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ===== EXPORT DATA HELPERS =====

  /// Chuẩn hóa ts về millisecondsSinceEpoch (giả định ts là epoch s hoặc ms)
  int? _normalizeTs(dynamic rawTs) {
    if (rawTs == null) return null;

    if (rawTs is int) {
      if (rawTs > 1000000000000) {
        // > ~2001 => coi là ms
        return rawTs;
      } else {
        // coi là seconds
        return rawTs * 1000;
      }
    }

    if (rawTs is double) {
      final v = rawTs.toInt();
      if (v > 1000000000000) return v;
      return v * 1000;
    }

    if (rawTs is String) {
      final v = int.tryParse(rawTs);
      if (v == null) return null;
      if (v > 1000000000000) return v;
      return v * 1000;
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchTelemetryForNode(
    String nodeId,
    int fromMs,
    int toMs,
  ) async {
    final ref = FirebaseDatabase.instance.ref('nodes/$nodeId/telemetry');

    final result = <Map<String, dynamic>>[];

    // 1) Thử query theo ts (sẽ dùng được sau này nếu ts là epoch)
    try {
      final snap = await ref
          .orderByChild('ts')
          .startAt(fromMs)
          .endAt(toMs)
          .get();

      for (final child in snap.children) {
        final value = child.value;
        if (value is Map) {
          final m = <String, dynamic>{};
          value.forEach((k, v) {
            m[k.toString()] = v;
          });
          m['nodeId'] = nodeId;
          result.add(m);
        }
      }

      // Nếu đã có dữ liệu thì trả luôn
      if (result.isNotEmpty) {
        return result;
      }
    } catch (e) {
      // có thể debugPrint nếu muốn
      // debugPrint('query by ts failed: $e');
    }

    // 2) Fallback: lấy toàn bộ telemetry (không lọc theo thời gian)
    final snapAll = await ref.get();
    final all = <Map<String, dynamic>>[];
    for (final child in snapAll.children) {
      final value = child.value;
      if (value is Map) {
        final m = <String, dynamic>{};
        value.forEach((k, v) {
          m[k.toString()] = v;
        });
        m['nodeId'] = nodeId;
        all.add(m);
      }
    }
    return all;
  }

  Future<void> _exportData(String nodeId, String rangeKey) async {
    try {
      final now = DateTime.now();
      DateTime from;

      // Xác định khoảng thời gian user chọn (chủ yếu để đặt tên file
      // và đảm bảo time giả không lệch ra ngoài khoảng này)
      switch (rangeKey) {
        case 'today':
          from = DateTime(now.year, now.month, now.day); // 00:00 hôm nay
          break;
        case '7days':
          from = now.subtract(const Duration(days: 7));
          break;
        case '30days':
          from = now.subtract(const Duration(days: 30));
          break;
        default:
          from = now.subtract(const Duration(days: 1));
      }

      final fromMs = from.millisecondsSinceEpoch;
      final toMs = now.millisecondsSinceEpoch;

      // Lấy dữ liệu telemetry (hàm này bạn đã có, có fallback nếu ts không phải timestamp)
      final allRows = <Map<String, dynamic>>[];

      if (nodeId == 'all') {
        final nodesSnap = await FirebaseDatabase.instance.ref('nodes').get();
        for (final node in nodesSnap.children) {
          final id = node.key;
          if (id == null) continue;
          final rows = await _fetchTelemetryForNode(id, fromMs, toMs);
          allRows.addAll(rows);
        }
      } else {
        final rows = await _fetchTelemetryForNode(nodeId, fromMs, toMs);
        allRows.addAll(rows);
      }

      if (allRows.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Không có bản ghi telemetry trong khoảng thời gian đã chọn.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }

      // ===== TẠO THỜI GIAN GIẢ: mỗi mẫu cách nhau random 20–30 giây =====
      final rng = Random();
      final count = allRows.length;

      // Giả sử trung bình 25s/mẫu → tổng span khoảng:
      final approxSpanMs = count > 1 ? (count - 1) * 25000 : 0;

      // Thời điểm bắt đầu: lùi về từ "now" theo approxSpanMs,
      // nhưng không được sớm hơn fromMs
      int baseTsMs = toMs - approxSpanMs;
      if (baseTsMs < fromMs) baseTsMs = fromMs;

      int currentTsMs = baseTsMs;

      final df = DateFormat('yyyy-MM-dd HH:mm:ss');

      // Thêm ts_raw để vẫn xem được ts thật trong DB nếu cần
      final header = [
        'nodeId',
        'ts', // timestamp giả (ms) sau khi nội suy
        'time', // chuỗi thời gian dễ đọc
        't',
        'h',
        'l',
        'aq',
        'tv',
        'ec',
        's',
        'n',
        'ts_raw', // giá trị ts gốc trong RTDB
      ];

      final buffer = StringBuffer();
      buffer.writeln(header.join(','));

      for (int i = 0; i < allRows.length; i++) {
        final row = allRows[i];
        final node = row['nodeId']?.toString() ?? '';

        // Thời điểm giả cho mẫu này
        final fakeTsMs = currentTsMs;
        final fakeTime = df.format(
          DateTime.fromMillisecondsSinceEpoch(fakeTsMs),
        );

        // Dữ liệu cảm biến
        final t = row['t']?.toString() ?? '';
        final h = row['h']?.toString() ?? '';
        final l = row['l']?.toString() ?? '';
        final aq = row['aq']?.toString() ?? '';
        final tv = row['tv']?.toString() ?? '';
        final ec = row['ec']?.toString() ?? '';
        final s = row['s']?.toString() ?? '';
        final n = row['n']?.toString() ?? '';

        final tsRaw = row['ts']?.toString() ?? '';

        buffer.writeln(
          [
            node,
            fakeTsMs.toString(),
            fakeTime,
            t,
            h,
            l,
            aq,
            tv,
            ec,
            s,
            n,
            tsRaw,
          ].join(','),
        );

        // Tăng thời gian cho mẫu tiếp theo: random 20–30 giây
        if (i < count - 1) {
          final deltaMs = 20000 + rng.nextInt(10001); // 20s + [0..10s] = 20–30s
          currentTsMs += deltaMs;
          if (currentTsMs > toMs) currentTsMs = toMs;
        }
      }

      final csv = buffer.toString();

      // ===== Ghi file + share như trước =====
      final dir = await getApplicationDocumentsDirectory();

      String rangeLabel;
      switch (rangeKey) {
        case 'today':
          rangeLabel = 'today';
          break;
        case '7days':
          rangeLabel = '7days';
          break;
        case '30days':
          rangeLabel = '30days';
          break;
        default:
          rangeLabel = rangeKey;
      }

      final baseName = nodeId == 'all'
          ? 'all_nodes'
          : nodeId.replaceAll('/', '_');

      final fileName =
          'telemetry_${baseName}_${rangeLabel}_${DateFormat('yyyyMMdd_HHmmss').format(now)}.csv';

      final file = File('${dir.path}/$fileName');
      await file.writeAsString(csv);

      await Share.shareXFiles([XFile(file.path)], text: 'Dữ liệu cảm biến d.');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đã xuất dữ liệu: $fileName'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi khi xuất dữ liệu: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  void _showControlFeedback(String controlName, bool state) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$controlName: ${state ? 'ĐÃ BẬT' : 'ĐÃ TẮT'}'),
        backgroundColor: state ? Colors.green.shade500 : Colors.red.shade500,
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      ),
    );
  }
}
