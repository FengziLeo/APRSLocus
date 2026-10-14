/// ─── 外接 GPS 链路：蓝牙 SPP 上的 NMEA 0183 明文行 ───
///
/// 与 TNC / PKWDWPL / 盒子并列的**又一条只读链路**：外面接一个 GPS/北斗模组
/// （常见的是带蓝牙 SPP 的模块，也有 USB-TTL 的），它按固定频率吐 ASCII 语句，
/// 每行 `$` 开头、`\r\n` 结尾。拿到的坐标直接当「我」的位置来源。
///
/// 为什么单独一条链路（而不是复用 PKWDWPL）：
/// ```text
///                   PKWDWPL 链路                外接 GPS 链路
///   设备            电台的 GPS / PC 输出口      外面的 GPS 模组
///   内容            $PKWDWPL（带呼号/图标）     标准 NMEA（RMC/GGA/GLL…）
///   语义            别人的位置（电台自报）      **我的位置**
///   频率            一分钟几条                 一秒 1~10 条
/// ```
/// 两者连的是**两台不同设备**、产出的是**两种东西**，共用一条链路只能二选一
/// （原生的 socket 一次只连一个设备）。所以从传输层（`createGpsTransport()`）
/// 到解析（`nmea.dart`）都是独立的一条。
///
/// 解析全在 `nmea.dart`（纯函数 + 单测），本文件只做**链路的四件事**：
/// 字节流 → 行（[NmeaLineSplitter]）→ 语句 → 定位（[NmeaAssembler]）、
/// 统计、状态、持久化。与 [PkwdwplLink] 的生命周期完全对齐
/// （`scan` → `bind` → `connect` → `disconnect` → `restart`），UI 才能复用同一套交互。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'nmea.dart';
import 'net/tnc.dart';

/// 链路状态码（UI 负责本地化）
class NmeaGpsStatus {
  static const String idle = 'idle';
  static const String connecting = 'connecting';
  static const String connected = 'connected';

  /// 连着，但 [NmeaGpsLink.kSilentAfter] 内一个字节都没收到。
  ///
  /// 必须与 [connected] 分开：模组「配对上了但没在吐数据」是最常见的失败形态
  /// （接在充电线上没通电、被别的 App 占着、模组还在冷启动），
  /// 界面若只显示「已连接」，用户会以为一切正常却永远等不到定位。
  static const String silent = 'silent';

  static const String noDevice = 'no-device';
  static const String unsupported = 'unsupported';
  static const String openFailed = 'open-failed';
  static const String closed = 'closed';
  static const String error = 'error';
}

/// 外接 GPS 链路的可配置项。
///
/// 刻意没有 KISS 参数、中继路径、射频信标这些发射相关项：这条链路是**只读**的
/// （模组只说位置，不接受任何指令），留着那些开关只会让人以为「配好了就能发」。
class NmeaGpsConfig {
  /// 校验和不符时是否丢弃该条（默认丢弃，理由见 [NmeaAssembler.strictChecksum]）。
  ///
  /// 与 `PkwdwplConfig.strictChecksum` 的默认刻意相反，两处的注释都写了原因：
  /// 那个是电台→手机的本地线缆（固件常与手册有出入，丢光会让界面全空），
  /// 这个是按标准发语句的模组（不符基本只有线路噪声一种解释）。
  /// 少数杂牌模组确实会发错校验和 —— 那时可以在设备页关掉它（丢弃条数一直显示）。
  bool strictChecksum;

  /// 断开后自动重连（蓝牙偶发掉链是常态，尤其是省电模式下）
  bool autoReconnect;

  NmeaGpsConfig({
    this.strictChecksum = true,
    this.autoReconnect = true,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'strictChecksum': strictChecksum,
        'autoReconnect': autoReconnect,
      };

  static NmeaGpsConfig fromJson(Object? j) {
    final c = NmeaGpsConfig();
    if (j is! Map) return c;
    if (j['strictChecksum'] is bool) {
      c.strictChecksum = j['strictChecksum'] as bool;
    }
    if (j['autoReconnect'] is bool) c.autoReconnect = j['autoReconnect'] as bool;
    return c;
  }
}

/// 外接 GPS 链路（只收不发）。
///
/// [transport] 与 [clock] 仅测试注入用；生产环境走条件导入的平台实现
/// （移动端蓝牙 SPP，桌面端串口）与系统时钟。
///
/// 为什么连时钟也要能注入：[fresh]/[silent] 与上抛节流全是**时间行为**，
/// 拿真实时钟写的测试只能靠 `sleep` 把秒数熬过去（慢且不稳），
/// 能拨表才能把它们变成纯函数式的断言。
class NmeaGpsLink {
  NmeaGpsLink({TncTransport? transport, DateTime Function()? clock})
      : _t = transport ?? createGpsTransport(),
        _now = clock ?? DateTime.now {
    _t.onBytes = _onBytes;
    _t.onClosed = _onClosed;
    _t.onStatus = (s) => lastDetail = s;
    _asm.strictChecksum = config.strictChecksum;
  }

  final TncTransport _t;

  /// 时钟（可注入，见构造函数注释）
  final DateTime Function() _now;

  final NmeaGpsConfig config = NmeaGpsConfig();

  /// 已绑定的设备（下次启动自动带出）
  TncDevice? device;

  /// 最近一次扫描到的设备列表
  List<TncDevice> devices = const [];

  bool connecting = false;
  bool connected = false;

  /// 连接成功的时刻（[silent] 在还没收到任何语句时从它起算）
  DateTime? connectedAt;

  String status = NmeaGpsStatus.idle;
  String lastDetail = '';
  String lastError = '';

  /// 收到的字节数与行数
  int rxBytes = 0;
  int rxFrames = 0;

  /// 产出过的定位数
  int fixes = 0;

  /// 被丢弃的语句数（校验不符 / 字段非法）
  int rejected = 0;

  /// 校验不符的语句数（**不区分丢不丢**：关了严格校验时照样计数并显示）
  int checksumMismatches = 0;

  /// 解析成功但不带定位信息的语句数（GSV 星历 / 厂商私有语句 …）
  ///
  /// 单独一个计数而不是并进 [rejected]：这些是**正常流量**
  /// （GSV 是每条最长的语句，一次要好几条才发得完），算成错误会让统计一片红，
  /// 真正的校验不符反而淹在里面看不出来。
  int ignored = 0;

  /// 语句本身说「还没定上」的条数（RMC 状态 V / GGA 质量为 0）
  ///
  /// 冷启动、进隧道、天线被遮住时都是这个状态，**不是错误**，
  /// 但必须与「压根没收到语句」区分开 —— 前者是等一会儿就好，后者是接线问题。
  int noFixYet = 0;

  DateTime? lastLineAt;
  DateTime? lastFixAt;

  /// 最近一次可用的定位（界面显示卫星数/精度用，[fresh] 也看它）
  NmeaFix? lastFix;

  /// 分帧缓冲溢出次数（线路噪声的指标）
  int get frameOverflows => _splitter.overflows;

  final NmeaLineSplitter _splitter = NmeaLineSplitter();
  final NmeaAssembler _asm = NmeaAssembler();

  /// 链路日志（环形，最多 100 条）
  final List<String> log = [];

  /// 收到一条可用定位
  void Function(NmeaFix fix)? onFix;

  /// 被动断开
  void Function()? onClosed;

  /// 状态变化
  void Function()? onStateChanged;

  bool get up => connected;

  /// 连着但 [kSilentAfter] 没有收到任何字节（含「连上后一直没动静」）
  static const Duration kSilentAfter = Duration(seconds: 10);

  /// 定位的新鲜期：超过它就不再算「外接 GPS 在供位」，手机定位接回来。
  ///
  /// 30 秒这个数字与模块的频率无关（常见 1~10 Hz），而是留给**偶发的语句断流**
  /// （过隧道、模组短暂失锁）的余量：太短会在路口就来回切换来源，
  /// 太长会让「模组已经拔了」还一直占着位置。
  static const Duration kFixFresh = Duration(seconds: 30);

  /// 上抛定位的最小间隔。
  ///
  /// 模组每秒能给 1~10 条带坐标的语句（GGA 最常见是 5~10 Hz），
  /// 每条都上抛会让上层每秒重建十次页面树、写十次同一个位置。
  /// 中间那些**没有丢**：卫星数/精度照样更新进 [lastFix]，
  /// 只是「一次位置更新」按秒节流 —— 30 m/s 也就 30 米，抽稀本来就按距离做。
  static const Duration kEmitInterval = Duration(seconds: 1);

  DateTime? _lastEmitAt;

  /// 定位是否还新鲜（[kFixFresh] 内收到过）
  bool get fresh {
    final t = lastFixAt;
    return t != null && _now().difference(t) < kFixFresh;
  }

  /// 连上了但久久没有字节
  bool get silent {
    if (!connected) return false;
    final t = lastLineAt ?? connectedAt;
    return t != null && _now().difference(t) > kSilentAfter;
  }

  /// 连上了、也有语句，但还没有一次可用定位（模组在搜星）
  bool get waitingFix => connected && lastFix == null;

  int? get satellites => lastFix?.satellites;
  double? get hdop => lastFix?.hdop;
  double? get accuracyM => lastFix?.accuracyM;

  /// 最近一次 GSA 的定位类型（1 未定位 / 2 二维 / 3 三维），空 = 模组不发 GSA
  String get fixType => _asm.fixType;

  /// 秒级心跳（**由 `AppState` 的 tick 调用**，本类刻意不自起 Timer）。
  ///
  /// 为什么要一个显式心跳而不是自己起 `Timer.periodic`：
  /// 应用里本来就有一个每秒的 tick，再起一个只会在 dispose 时多一处漏掉的机会
  /// （漏掉的计时器会一直持有本对象与它的 EventChannel 订阅）。
  void heartbeat() {
    if (!connected) return;
    final want = silent ? NmeaGpsStatus.silent : NmeaGpsStatus.connected;
    if (status != want) {
      status = want;
      if (want == NmeaGpsStatus.silent) {
        _log('已连接但 ${kSilentAfter.inSeconds}s 没有收到任何语句'
            '（${lastLineAt == null ? '尚未收到数据' : '数据已断流'}）');
      }
      onStateChanged?.call();
    }
  }

  void _log(String s) {
    final ts = _now().toIso8601String().substring(11, 19);
    log.insert(0, '$ts  $s');
    if (log.length > 100) log.removeRange(100, log.length);
  }

  List<String> get logs => List.unmodifiable(log);

  // ─── 生命周期 ───

  Future<bool> supported() => _t.supported;

  Future<bool> requestPermissions() => _t.requestPermissions();

  Future<List<TncDevice>> scan() async {
    devices = await _t.listDevices();
    _log('扫描到 ${devices.length} 个设备');
    onStateChanged?.call();
    return devices;
  }

  void bind(TncDevice? d) {
    device = d;
    lastError = '';
    _log(d == null ? '解除绑定' : '绑定 ${d.label}');
    unawaited(_persistDevice());
    onStateChanged?.call();
  }

  Future<bool> connect([TncDevice? d]) async {
    final target = d ?? device;
    if (connecting) {
      lastError = 'busy';
      _log('已在连接中，忽略本次连接请求');
      return false;
    }
    if (connected && target != null && device?.id == target.id) return true;
    if (target == null) {
      status = NmeaGpsStatus.noDevice;
      lastError = 'no-device';
      onStateChanged?.call();
      return false;
    }
    if (!await supported()) {
      status = NmeaGpsStatus.unsupported;
      lastError = 'unsupported';
      _log('平台不支持外接 GPS 链路');
      onStateChanged?.call();
      return false;
    }
    device = target;
    unawaited(_persistDevice());
    connecting = true;
    status = NmeaGpsStatus.connecting;
    lastError = '';
    _resetData();
    onStateChanged?.call();
    _log('连接 ${target.label} …');
    final err = await _t.connect(target);
    connecting = false;
    if (err != null) {
      connected = false;
      lastError = err;
      lastDetail = err;
      status =
          err.startsWith('open-') ? NmeaGpsStatus.openFailed : NmeaGpsStatus.error;
      _log('连接失败：$err');
      onStateChanged?.call();
      return false;
    }
    connected = true;
    connectedAt = _now();
    status = NmeaGpsStatus.connected;
    lastError = '';
    _log('已连接 ${target.label}（等待 NMEA 语句）');
    onStateChanged?.call();
    return true;
  }

  Future<void> disconnect({bool manual = true}) async {
    // 先置 false 再拆传输层：拆卸过程中会异步抛 closed 事件，
    // 若此时仍为 true 会被当成「链路意外丢失」而触发上层自动重连
    // （症状就是「用户点了断开，几秒后自己又连上」）。
    connected = false;
    connecting = false;
    status = NmeaGpsStatus.idle;
    _resetData();
    await _t.disconnect();
    if (manual) _log('已断开');
    onStateChanged?.call();
  }

  Future<bool> restart() async {
    _log('重启链路…');
    await disconnect(manual: false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return connect();
  }

  void _onClosed() {
    if (!connected) return; // 预期内的拆卸，不上报
    connected = false;
    status = NmeaGpsStatus.closed;
    _log('链路断开');
    onStateChanged?.call();
    onClosed?.call();
  }

  /// 断开/重连时清空收集到的数据与装配缓存。
  ///
  /// 装配缓存必须清：跨链路残留的日期/海拔会把新链路的头几条定位拼成一条
  /// 「跨设备」的怪数据（见 [NmeaAssembler.reset]）。
  void _resetData() {
    _splitter.reset();
    _asm.reset();
    _asm.strictChecksum = config.strictChecksum;
    lastFix = null;
    lastFixAt = null;
    lastLineAt = null;
    connectedAt = connected ? _now() : null;
    _lastEmitAt = null;
    // 统计**不清零**：它们是「这条链路到现在为止的表现」，
    // 断开重连时归零会让用户永远看不到「它在反复重连」这件事。
  }

  // ─── 收 ───

  void _onBytes(List<int> bytes) {
    rxBytes += bytes.length;
    final now = _now();
    lastLineAt = now;
    for (final line in _splitter.feed(bytes)) {
      _handleLine(line, now: now);
    }
    // 断流后又来数据：状态立刻回到 connected（不必等下一秒的心跳）
    if (connected && status == NmeaGpsStatus.silent) {
      status = NmeaGpsStatus.connected;
      _log('数据恢复');
    }
    onStateChanged?.call();
  }

  /// 一行 → 一条定位（公开可见是为了让测试直接喂句子，不必造字节流）。
  void _handleLine(String line, {DateTime? now}) {
    final at = now ?? _now();
    final fix = _asm.feed(line, now: at);
    if (fix != null) {
      rxFrames++;
      fixes++;
      lastFix = fix;
      lastFixAt = at;
      if (!fix.checksumValid) {
        // 宽松模式下照用，但必须计数（严格模式下这条根本走不到这里）
        checksumMismatches++;
      }
      final last = _lastEmitAt;
      if (last == null || at.difference(last) >= kEmitInterval) {
        _lastEmitAt = at;
        onFix?.call(fix);
      }
      return;
    }
    // 没产出定位：按原因分别计数 —— 混在一起会让「还没定上」（正常）
    // 和「校验不符」（线路有问题）看起来一样。
    switch (_asm.lastError) {
      case NmeaErrorCode.noFix:
        rxFrames++;
        noFixYet++;
      case NmeaErrorCode.checksumMismatch:
        rxFrames++;
        checksumMismatches++;
        rejected++;
        _log('丢弃语句（校验不符 ${_asm.lastDetail}）');
      case NmeaErrorCode.unknownSentence:
        // 厂商私有语句（$PMTK… 之类）：模组常发，不是问题
        ignored++;
      case NmeaErrorCode.notNmea:
        ignored++;
      case null:
        // 语句本身没问题，只是不带定位信息（GSV 星历 …）
        ignored++;
      default:
        rejected++;
        _log('丢弃语句（${_asm.lastError!.name} ${_asm.lastDetail}）');
    }
  }

  // ─── 只读守卫 ───

  /// 这条链路**不能发射**（GPS 模组只单向输出位置，收指令只认厂商私有语句）。
  ///
  /// 显式提供而不是省略：省略的话上层调用 `send` 会编译不过，
  /// 有人就会在别处偷偷绕过；这里明确返回错误码，让「发不出去」有据可查。
  String? send(String raw) {
    lastError = 'read-only';
    _log('外接 GPS 链路为只读，已拒绝发送：$raw');
    return lastError;
  }

  // ─── 持久化 ───

  static const _kConfig = 'gpsConfigJson';
  static const _kDevice = 'gpsDeviceJson';

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getString(_kConfig);
      if (c != null && c.isNotEmpty) {
        final parsed = NmeaGpsConfig.fromJson(jsonDecode(c));
        config
          ..strictChecksum = parsed.strictChecksum
          ..autoReconnect = parsed.autoReconnect;
        _asm.strictChecksum = config.strictChecksum;
      }
      final d = p.getString(_kDevice);
      if (d != null && d.isNotEmpty) device = TncDevice.fromJson(jsonDecode(d));
    } catch (_) {}
  }

  Future<void> persistConfig() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kConfig, jsonEncode(config.toJson()));
    } catch (_) {}
  }

  Future<void> _persistDevice() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (device == null) {
        await p.remove(_kDevice);
      } else {
        await p.setString(_kDevice, jsonEncode(device!.toJson()));
      }
    } catch (_) {}
  }

  void dispose() {
    _t.onBytes = null;
    _t.onClosed = null;
    _t.onStatus = null;
    unawaited(_t.disconnect());
  }
}
