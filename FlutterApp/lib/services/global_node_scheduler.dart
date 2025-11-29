// lib/services/global_node_scheduler.dart
import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';

/// Cấu trúc schedule đơn giản như lưu ở /nodes/<id>/schedules/<device>
class _SimpleSchedule {
  final bool enabled;
  final String? on; // "HH:mm"
  final String? off; // "HH:mm"

  const _SimpleSchedule({this.enabled = false, this.on, this.off});

  factory _SimpleSchedule.from(dynamic raw) {
    if (raw is Map) {
      return _SimpleSchedule(
        enabled: (raw['enabled'] as bool?) ?? false,
        on: raw['on'] as String?,
        off: raw['off'] as String?,
      );
    }
    return const _SimpleSchedule();
  }
}

/// Runtime scheduler cho 1 node (ví dụ "N01")
class _NodeSchedulerRuntime {
  final String nodeId;

  final DatabaseReference _schedRef;
  final DatabaseReference _ctrlRef;
  final DatabaseReference _metaRef;
  final DatabaseReference _downRef;

  // schedules['pump'|'light'|'fan'] -> _SimpleSchedule
  Map<String, _SimpleSchedule> _schedules = {
    'pump': const _SimpleSchedule(),
    'light': const _SimpleSchedule(),
    'fan': const _SimpleSchedule(),
  };

  StreamSubscription<DatabaseEvent>? _schedSub;

  // Để tránh bắn trùng lệnh trong cùng 1 phút (theo ngày)
  final Set<String> _firedKeysToday = {};
  String? _lastDay; // "yyyy-MM-dd"

  // Thứ tự ưu tiên trong batch
  static const List<String> _seqOrder = ['pump', 'light', 'fan'];

  _NodeSchedulerRuntime(this.nodeId)
    : _schedRef = FirebaseDatabase.instance
          .ref()
          .child('nodes')
          .child(nodeId)
          .child('schedules'),
      _ctrlRef = FirebaseDatabase.instance
          .ref()
          .child('nodes')
          .child(nodeId)
          .child('controls'),
      _metaRef = FirebaseDatabase.instance
          .ref()
          .child('nodes')
          .child(nodeId)
          .child('meta'),
      _downRef = FirebaseDatabase.instance
          .ref()
          .child('nodes')
          .child(nodeId)
          .child('downlink')
          .child('batch');

  /// Lắng nghe /nodes/<id>/schedules realtime
  void attach() {
    _schedSub = _schedRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is Map) {
        _schedules = {
          'pump': _SimpleSchedule.from(raw['pump']),
          'light': _SimpleSchedule.from(raw['light']),
          'fan': _SimpleSchedule.from(raw['fan']),
        };
      } else {
        _schedules = {
          'pump': const _SimpleSchedule(),
          'light': const _SimpleSchedule(),
          'fan': const _SimpleSchedule(),
        };
      }
    });
  }

  void dispose() {
    _schedSub?.cancel();
  }

  /// Được GlobalNodeScheduler gọi mỗi 30s
  void tick(DateTime now) {
    final today = DateFormat('yyyy-MM-dd').format(now);

    // Sang ngày mới thì reset history
    if (_lastDay != today) {
      _lastDay = today;
      _firedKeysToday.clear();
    }

    final hmNow =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final List<Map<String, dynamic>> actions = [];

    void enqueue(String devKey, bool turnOn) {
      // Key có cả nodeId để phân biệt (dù mỗi runtime đã riêng node)
      final firedKey = '$today|$nodeId|$devKey|${turnOn ? 'on' : 'off'}|$hmNow';
      if (_firedKeysToday.contains(firedKey)) return;
      _firedKeysToday.add(firedKey);

      actions.add({'device': devKey, 'value': turnOn ? 1 : 0});
    }

    void checkOne(String devKey) {
      final sch = _schedules[devKey];
      if (sch == null || !sch.enabled) return;

      if (sch.on != null && sch.on == hmNow) {
        enqueue(devKey, true);
      }
      if (sch.off != null && sch.off == hmNow) {
        enqueue(devKey, false);
      }
    }

    // Kiểm tra 3 thiết bị
    checkOne('pump');
    checkOne('light');
    checkOne('fan');

    if (actions.isEmpty) return;

    // Sắp xếp thứ tự: pump -> light -> fan
    actions.sort(
      (a, b) => _seqOrder
          .indexOf(a['device'] as String)
          .compareTo(_seqOrder.indexOf(b['device'] as String)),
    );

    final nowMs = now.millisecondsSinceEpoch;

    // 1) Cập nhật /controls
    final Map<String, Object?> ctrlUpdate = {};
    for (final a in actions) {
      final dev = a['device'] as String;
      final on = (a['value'] as int) == 1;
      ctrlUpdate[dev] = on;
    }
    _ctrlRef.update(ctrlUpdate);

    // 2) Cập nhật /meta
    _metaRef.update({'updatedBy': 'schedule', 'updatedAt': nowMs});

    // 3) Gửi batch xuống gateway: gateway sẽ xử lý payload từng thiết bị
    _downRef.set({
      'cmd': 'setMulti',
      'payload': actions, // [{device:'pump',value:1}, ...]
      'status': 'pending',
      'by': 'schedule',
      'ts': nowMs,
    });
  }
}

/// Scheduler dùng chung toàn app
class GlobalNodeScheduler {
  GlobalNodeScheduler._();

  static final GlobalNodeScheduler I = GlobalNodeScheduler._();

  final Map<String, _NodeSchedulerRuntime> _nodes = {};
  Timer? _timer;

  /// Đăng ký 1 node (ví dụ "N01")
  void registerNode(String nodeId) {
    if (_nodes.containsKey(nodeId)) return;
    final runtime = _NodeSchedulerRuntime(nodeId);
    runtime.attach();
    _nodes[nodeId] = runtime;
    _ensureTimer();
  }

  /// Đăng ký nhiều node cùng lúc
  void registerNodes(List<String> nodeIds) {
    for (final id in nodeIds) {
      registerNode(id);
    }
  }

  void _ensureTimer() {
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      final now = DateTime.now();
      for (final r in _nodes.values) {
        r.tick(now);
      }
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    for (final r in _nodes.values) {
      r.dispose();
    }
    _nodes.clear();
  }
}
