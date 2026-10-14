import 'dart:typed_data';

import 'package:aprslocus/nmea.dart';
import 'package:aprslocus/nmea_gps.dart';
import 'package:aprslocus/net/tnc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 外接 GPS 链路（蓝牙 SPP 上的 NMEA 0183）回归测试。
///
/// 解析本身由 `test/nmea_test.dart` 钉住，**这份测的是链路那一层**：
/// 字节流分帧、语句 → 定位的上抛、各种丢弃/忽略**分别**计数、
/// 静默与新鲜期（时间行为，靠注入时钟拨表）、配置持久化、只读守卫。
///
/// 权威期望值来自 NMEA 0183 文档的标准示例（`$GPRMC…*6A` / `$GPGGA…*47`）；
/// 自己拼的语句（GGA 质量 0、GSV）校验和按同一套 XOR 算出来 ——
/// 算法本身由那条权威示例保证，这里只用它来构造「校验和正确但内容不同」的样本。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  const rmc = r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A';
  const gga = r'$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47';

  /// 给任意 body 配上正确的校验和（`$` 必须转义，否则被当成插值）
  String withSum(String body) =>
      '\$$body*${NmeaChecksum.format(NmeaChecksum.compute(body))}';

  /// 一条（或几条）语句 → 一段字节流。
  ///
  /// ⚠ 终止符不是装饰：[NmeaLineSplitter] 只在 `\r\n` 处切行，不带终止符的
  /// 语句会一直留在缓冲里 —— 断言拿到的永远是空列表（第一版就是这么错的：
  /// 分帧逻辑本身没问题，是测试没把行尾发出去）。
  List<int> bytes(String sentences) => '$sentences\r\n'.codeUnits;

  /// 注入时钟：新鲜期/静默/节流全是时间行为，拨表比 sleep 稳
  late DateTime now;
  NmeaGpsLink newLink(_FakeTransport t) {
    now = DateTime(2026, 10, 14, 12, 0, 0);
    return NmeaGpsLink(transport: t, clock: () => now);
  }

  group('只读守卫', () {
    test('这条链路不能发射（模组只单向吐位置）', () {
      final link = newLink(_FakeTransport());
      expect(link.send(r'BG7LZQ>APALOC:>test'), 'read-only');
    });
  });

  group('字节流 → 定位', () {
    test('逐行喂入 GGA + RMC：合并成一条带海拔/速度的定位', () {
      // 喂**字节**而不是直接调解析：分帧（\r\n 切分、噪声丢弃）也在被验证。
      // 顺序刻意是「先 GGA 后 RMC」：定位信息分散在多条语句里，
      // 本条到达时只能用**已经见过**的配角字段 —— 这正是 NmeaAssembler 要解决的问题。
      final t = _FakeTransport();
      final link = newLink(t);
      final got = <NmeaFix>[];
      link.onFix = got.add;
      t.onBytes!(bytes('$gga\r\n$rmc'));

      expect(got, hasLength(1), reason: '同一秒内按 kEmitInterval 节流');
      // 断言取链路最后合成的那条（= RMC 到达时补齐了 GGA 的海拔/精度）
      final f = link.lastFix!;
      expect(f.lat, closeTo(48.1173, 1e-6));
      expect(f.lng, closeTo(11.5166667, 1e-6));
      expect(f.altM, closeTo(545.4, 1e-6), reason: '海拔来自 GGA');
      expect(f.hdop, closeTo(0.9, 1e-6));
      expect(f.satellites, 8);
      expect(f.speedKmh!, closeTo(22.4 * 1.852, 1e-6), reason: '速度来自 RMC');
      expect(f.accuracyM, closeTo(0.9 * 5.0, 1e-6), reason: 'HDOP × UERE');
      expect(f.utc, DateTime.utc(1994, 3, 23, 12, 35, 19));
      // 两条语句都带坐标 → 两次定位；上抛被节流成一次
      expect(link.fixes, 2);
      expect(link.rejected, 0);
      expect(link.checksumMismatches, 0);
    });

    test('节流过了就再上抛一次（拨表 2 秒）', () {
      final t = _FakeTransport();
      final link = newLink(t);
      final got = <NmeaFix>[];
      link.onFix = got.add;
      t.onBytes!(bytes(rmc));
      now = now.add(const Duration(seconds: 2));
      t.onBytes!(bytes(rmc));
      expect(got, hasLength(2));
      expect(link.fixes, 2);
    });

    test('GSV / 私有语句是「认识但不用」，计入 ignored 而不是 rejected', () {
      final t = _FakeTransport();
      final link = newLink(t);
      final got = <NmeaFix>[];
      link.onFix = got.add;
      t.onBytes!(bytes(withSum(
          'GPGSV,3,1,11,01,05,000,00,02,10,000,00,03,15,000,00,04,20,000,00')));
      t.onBytes!(bytes(withSum('PMTK001,314,3')));
      expect(got, isEmpty);
      expect(link.ignored, 2);
      expect(link.rejected, 0);
      expect(link.fixes, 0);
    });

    test('「还没定上」（GGA 质量 0）单独计数，不算错误', () async {
      final t = _FakeTransport();
      final link = newLink(t);
      final dev = TncDevice(id: 'aa:bb', name: 'GPS 模组');
      expect(await link.connect(dev), isTrue);
      t.onBytes!(bytes(withSum(
          'GPGGA,123519,4807.038,N,01131.000,E,0,08,0.9,545.4,M,46.9,M,')));
      expect(link.noFixYet, 1);
      expect(link.rejected, 0);
      expect(link.lastFix, isNull);
      expect(link.waitingFix, isTrue, reason: '连上了但还没有定位 = 正在搜星');
      expect(link.silent, isFalse, reason: '有语句在流，只是还没定上');
    });

    test('默认严格：校验不符的语句被丢弃并计数', () {
      final t = _FakeTransport();
      final link = newLink(t);
      final got = <NmeaFix>[];
      link.onFix = got.add;
      // 标准 RMC 的校验和故意写错一个字符
      t.onBytes!(bytes(
          r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6B'));
      expect(got, isEmpty);
      expect(link.rejected, 1);
      expect(link.checksumMismatches, 1);
      expect(link.fixes, 0);
    });

    test('关掉严格校验：坐标照用，但计数与 checksumValid 都要如实', () {
      final t = _FakeTransport();
      final link = newLink(t);
      link.config.strictChecksum = false;
      final got = <NmeaFix>[];
      link.onFix = got.add;
      t.onBytes!(bytes(
          r'$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6B'));
      expect(got, hasLength(1));
      expect(link.fixes, 1);
      expect(link.checksumMismatches, 1);
      expect(link.rejected, 0);
      expect(link.lastFix!.checksumValid, isFalse);
    });

    test('断开重连后装配缓存被清空（不拿上一条链路的日期拼新点）', () async {
      final t = _FakeTransport();
      final link = newLink(t);
      t.onBytes!(bytes(rmc));
      expect(link.lastFix!.utc, isNotNull);
      await link.disconnect();
      expect(link.lastFix, isNull);
      expect(link.lastFixAt, isNull);
    });
  });

  group('静默与新鲜期（时间行为）', () {
    test('连上 10 秒没有字节 → silent；来数据立刻回到 connected', () async {
      final t = _FakeTransport();
      final link = newLink(t);
      final dev = TncDevice(id: 'aa:bb', name: 'GPS 模组');
      expect(await link.connect(dev), isTrue);
      expect(link.status, NmeaGpsStatus.connected);
      expect(link.silent, isFalse, reason: '刚连上，静默期还没走完');

      now = now.add(const Duration(seconds: 11));
      link.heartbeat();
      expect(link.silent, isTrue);
      expect(link.status, NmeaGpsStatus.silent);

      t.onBytes!(bytes(rmc));
      expect(link.status, NmeaGpsStatus.connected);
      expect(link.silent, isFalse);
    });

    test('定位超过 30 秒没更新 → 不再算「外接 GPS 在供位」', () {
      final t = _FakeTransport();
      final link = newLink(t);
      t.onBytes!(bytes(rmc));
      expect(link.fresh, isTrue);
      now = now.add(const Duration(seconds: 31));
      expect(link.fresh, isFalse);
      expect(link.lastFix, isNotNull, reason: '点还在，只是不新鲜了');
    });
  });

  group('配置与设备持久化', () {
    test('严格校验 / 自动重连能落盘并读回', () async {
      final link = newLink(_FakeTransport());
      link.config
        ..strictChecksum = false
        ..autoReconnect = false;
      await link.persistConfig();

      final link2 = newLink(_FakeTransport());
      await link2.load();
      expect(link2.config.strictChecksum, isFalse);
      expect(link2.config.autoReconnect, isFalse);
    });

    test('绑定的设备下次启动能带出（换机/重启不必重扫）', () async {
      final link = newLink(_FakeTransport());
      link.bind(TncDevice(id: 'aa:bb', name: 'GPS 模组'));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final link2 = newLink(_FakeTransport());
      await link2.load();
      expect(link2.device?.id, 'aa:bb');
      expect(link2.device?.name, 'GPS 模组');
      expect(link2.device?.label, 'GPS 模组 · aa:bb');
    });
  });
}

class _FakeTransport implements TncTransport {
  @override
  bool connected = false;

  @override
  void Function(List<int> bytes)? onBytes;

  @override
  void Function(String status)? onStatus;

  @override
  void Function()? onClosed;

  @override
  void Function(String reason)? onTxFailed;

  @override
  void Function(int size)? onTxAck;

  @override
  Future<bool> get supported async => true;

  @override
  Future<List<TncDevice>> listDevices() async => const [];

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<String?> connect(TncDevice device) async {
    connected = true;
    return null;
  }

  @override
  Future<void> disconnect() async => connected = false;

  @override
  void send(Uint8List bytes) {}
}
