import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 上传/发射的「单独同意」范围 —— 与用户协议 V2.0 附件一的三项一一对应。
///
/// 为什么要独立成一个文件、而不是并进 `AppState`：
///   * 协议 5.4 要求留下**可举证**的记录（同意时间、所同意的功能项、告知
///     文本的版本标识），这组事实与业务状态不是一回事，测试也该能直接构造；
///   * 它同时被状态层（闸门）、协议页（告知文本）和设置页（撤回入口）用到，
///     放中间一个中立的地方最省事。
enum ConsentScope {
  /// APRS-IS 信标上传：经互联网链路把信标发到公开网络。
  ///
  /// 这里包含同为互联网链路的 APRSNETCN SERVER：它跑的是 APRS-IS 协议、
  /// 同样把信标送进公开网络，附件一那一项说的就是这件事。
  internet('internet'),

  /// 射频信标发射：经 TNC / 声卡等射频链路真正在空中发射。
  rf('rf'),

  /// iGate 转发：把一侧收到的报文转给另一侧。往射频转就是代表他人发射，
  /// 所以开启它同时需要 [rf]。
  igate('igate');

  const ConsentScope(this.id);

  /// 落盘用的稳定标识。**不要**跟着枚举名改 —— 存过的同意要能读回来。
  final String id;

  static ConsentScope? byId(String id) {
    for (final s in ConsentScope.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// 一条同意事件。
///
/// [granted] 为 false 表示撤回。撤回也记，因为「什么时候撤的」同样是
/// 争议时要拿出来的事实（协议 5.5：撤回后立即停止发送）。
class ConsentEvent {
  const ConsentEvent({
    required this.scope,
    required this.granted,
    required this.at,
    required this.version,
  });

  final ConsentScope scope;
  final bool granted;
  final DateTime at;

  /// 告知文本的版本标识（`kTermsVersion`）。用户当时同意的是哪一版，写清楚。
  final String version;

  Map<String, Object?> toJson() => {
        'scope': scope.id,
        'granted': granted,
        'at': at.toIso8601String(),
        'version': version,
      };

  static ConsentEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final scope = ConsentScope.byId('${raw['scope'] ?? ''}');
    final at = DateTime.tryParse('${raw['at'] ?? ''}');
    if (scope == null || at == null) return null;
    return ConsentEvent(
      scope: scope,
      granted: raw['granted'] == true,
      at: at,
      version: '${raw['version'] ?? ''}',
    );
  }

  /// 「2026-10-20 14:03」—— 日志行的时间部分。
  String get stamp {
    String two(int v) => v < 10 ? '0$v' : '$v';
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}

/// 单独同意的本地存储。
///
/// 为什么放 prefs、且**不进备份**：
///   * 协议 5.4 要求「不因业务数据的清除而自动删除」——`AppState.clearAllData`
///     只清内容（台站/消息/日志/轨迹），不动 prefs，放这里天然满足；
///   * 同意是**在这台设备上**作出的，跟着备份搬到另一台设备没有意义
///     （与 `dataNoticeAccepted` 同一口径）；
///   * 恢复出厂等于重装，`p.clear()` 会连它一起清掉 —— 这也符合预期。
class ConsentStore {
  static const _kGranted = 'consentGranted';
  static const _kLog = 'consentLog';

  /// 日志保留条数。同意/撤回一年也就几十条，200 条足够回溯。
  static const _kLogMax = 200;

  final Set<ConsentScope> _granted = {};
  final List<ConsentEvent> _events = [];

  Set<ConsentScope> get granted => {..._granted};

  /// 新的在前（界面直接按这个顺序列）。
  List<ConsentEvent> get events => List.unmodifiable(_events.reversed);

  bool has(ConsentScope scope) => _granted.contains(scope);

  /// 测试口子：直接当作已同意（不写日志、不碰磁盘）。
  void debugGrant(Iterable<ConsentScope> scopes) => _granted.addAll(scopes);

  bool hasAll(Iterable<ConsentScope> scopes) =>
      scopes.every((s) => _granted.contains(s));

  bool get any => _granted.isNotEmpty;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _granted
      ..clear()
      ..addAll((p.getStringList(_kGranted) ?? const [])
          .map(ConsentScope.byId)
          .whereType<ConsentScope>());
    _events
      ..clear()
      ..addAll((p.getStringList(_kLog) ?? const [])
          .map(_decode)
          .whereType<ConsentEvent>());
  }

  static ConsentEvent? _decode(String raw) {
    try {
      return ConsentEvent.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 记一次同意。重复同意不重复写日志（只有状态真的变了才算一次）。
  Future<void> grant(Iterable<ConsentScope> scopes, String version,
      {DateTime? now}) async {
    final add = scopes.where((s) => !_granted.contains(s)).toList();
    if (add.isEmpty) return;
    final at = now ?? DateTime.now();
    _granted.addAll(add);
    for (final s in add) {
      _events.add(ConsentEvent(
          scope: s, granted: true, at: at, version: version));
    }
    await _save();
  }

  /// 撤回一项。协议 5.5：撤回后立即停止通过该功能发送新的数据 ——
  /// 状态层读 [has]，所以这里落盘之后闸门自然就关上了。
  Future<void> revoke(ConsentScope scope, String version,
      {DateTime? now}) async {
    if (!_granted.remove(scope)) return;
    _events.add(ConsentEvent(
        scope: scope, granted: false, at: now ?? DateTime.now(), version: version));
    await _save();
  }

  /// 只清日志：已作出的同意不动（协议 5.4 允许单独清除日志，
  /// 且说明「清除不影响清除前已完成的处理行为的合法性」）。
  Future<void> clearLog() async {
    if (_events.isEmpty) return;
    _events.clear();
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLog);
  }

  /// 恢复出厂：内存态也要清。磁盘上的两个键由 `p.clear()` 一并抹掉。
  /// 只清磁盘不清内存，就会在「恢复出厂 → 回到首次引导」这段里
  /// 还带着上一次安装的同意，等于替新用户签了字。
  void reset() {
    _granted.clear();
    _events.clear();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
        _kGranted, _granted.map((s) => s.id).toList()..sort());
    if (_events.length > _kLogMax) {
      _events.removeRange(0, _events.length - _kLogMax);
    }
    await p.setStringList(
        _kLog, _events.map((e) => jsonEncode(e.toJson())).toList());
  }
}
