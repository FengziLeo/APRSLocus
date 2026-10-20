import 'dart:async';

import 'package:flutter/material.dart';

import 'net/tnc.dart';
import 'nmea.dart';
import 'nmea_gps.dart';
import 'settings_widgets.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── 外接 GPS 设备页（设备页的子页）───
///
/// 与 [PkwdwplDevicePage] **同构**（扫设备 → 绑定 → 连接 → 断开 → 重启），
/// 生命周期完全是同一套，所以只保留这条链路真有的东西：
///   ① 设备绑定 / 连接 / 重启（蓝牙已配对 + USB 串口）
///   ② 定位接收统计（收了多少条、还没定上多少、校验不符多少）
///   ③ 校验严格度与自动重连
///
/// 刻意**没有** KISS 参数、初始化串、中继路径、射频信标、发射自检 ——
/// GPS 模组只单向输出 NMEA（收指令只认厂商私有语句），摆上这些控件只会
/// 让用户去调一个永远不生效的参数。
///
/// 与 PKWDWPL 的**区别只有语义**：那条收的是别人的位置（电台自报的航点），
/// 这条供的是**本机位置** —— 接上后它会参与 [AppState.positionSourceNow]
/// 的优先级（见页面顶部的那句说明与 [AppState.positionSourceNow] 的注释）。
/// 所以这一页要多说两句位置相关的话：现在有没有定位、几颗星、精度多少。
class ExtGpsDevicePage extends StatefulWidget {
  final AppState state;
  const ExtGpsDevicePage({super.key, required this.state});

  @override
  State<ExtGpsDevicePage> createState() => _ExtGpsDevicePageState();
}

class _ExtGpsDevicePageState extends State<ExtGpsDevicePage> {
  bool _scanning = false;
  bool _supported = true;
  bool _busy = false;

  /// 「当前定位」卡里那句「N 秒前」自己走秒用的 —— 除了它什么都不做。
  ///
  /// 模组正常吐数据时上层每秒都会 notify（定位上抛按秒节流），界面本来就在重建；
  /// 但一旦断流就再也没人 notify 了 —— 而「已经好几分钟没有新定位」恰恰是
  /// 那时最该看见的一件事。所以只在这个页面上补一个只读的秒 tick。
  Timer? _ageTimer;

  AppState get st => widget.state;
  NmeaGpsLink get link => widget.state.nmeaGps;

  @override
  void initState() {
    super.initState();
    unawaited(_probe());
    _ageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !link.connected || link.lastFix == null) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    final ok = await link.supported();
    if (mounted) setState(() => _supported = ok);
  }

  void _toast(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color ?? C.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _scan() async {
    // 先把界面文案取好：await 之后再用 context 会被 lint 拦
    final S s = S.of(context);
    setState(() => _scanning = true);
    // Android 12+ 需要运行时蓝牙权限，先请求再扫描，否则列表恒为空
    if (!await link.requestPermissions()) {
      if (mounted) {
        setState(() => _scanning = false);
        _toast(s.tncNeedPermission, color: C.red);
      }
      return;
    }
    await link.scan();
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _toggleLink() async {
    final S s = S.of(context);
    setState(() => _busy = true);
    if (link.connected) {
      await link.disconnect();
      st.adoptDeviceLink(AppState.srcNmeaGps, false);
    } else {
      if (link.device == null) {
        setState(() => _busy = false);
        _toast(s.linkNotBound, color: C.orange);
        return;
      }
      if (!await link.requestPermissions()) {
        setState(() => _busy = false);
        _toast(s.tncNeedPermission, color: C.red);
        return;
      }
      // 设备冲突守卫必须在 connect **之前**：设备页绕过 AppState 直接连，
      // 只把守卫放在 _connectNmeaGps 里对这里无效。
      // 外接 GPS 是只读链路、且优先级最低 —— 冲突时不让别人让路（自己拒绝）。
      final conflict = await st.guardDeviceConnect(AppState.srcNmeaGps);
      if (conflict != null) {
        setState(() => _busy = false);
        _toast(s.deviceConflictTitle, color: C.red);
        return;
      }
      final ok = await link.connect();
      // 记回 AppState（_linkUp 表 + 来源启用）—— 否则会出现
      // 「已连上但界面全说未连接」（「当前链路」卡不渲染、横幅说未连接）。
      st.adoptDeviceLink(AppState.srcNmeaGps, ok);
      if (!ok) {
        if (link.status == NmeaGpsStatus.openFailed) {
          _toast(s.tncOpenFailedHint, color: C.red);
        } else if (link.status == NmeaGpsStatus.unsupported) {
          _toast(s.tncSupportedNo, color: C.orange);
        } else {
          _toast('${s.connectFailedCheckConfig} ${link.lastDetail}',
              color: C.red);
        }
      }
    }
    st.reloadUi();
    if (mounted) setState(() => _busy = false);
  }

  String _statusText(S s) {
    switch (link.status) {
      case NmeaGpsStatus.connected:
        return s.connected;
      case NmeaGpsStatus.connecting:
        return s.connecting;
      // 「连着但没收到语句」**不改说成「已断开」**：链路确实连着，
      // 问题在数据源那一侧 —— 由 _liveHint 单独说清（查供电 / 是否被占用）。
      // 写成「已断开」会把人引去重连，而重连并不解决问题。
      case NmeaGpsStatus.silent:
        return s.connected;
      case NmeaGpsStatus.noDevice:
        return s.linkNotBound;
      case NmeaGpsStatus.unsupported:
        return s.tncSupportedNo;
      case NmeaGpsStatus.openFailed:
        return s.tncOpenFailedHint;
      case NmeaGpsStatus.closed:
        return s.disconnected;
      case NmeaGpsStatus.error:
        return s.connectFailedCheckConfig;
      default:
        return s.disconnected;
    }
  }

  /// 这条链路**现在到底在干什么** —— 三档必须分开说，否则用户只能靠猜：
  ///   * 连着却没收到任何语句 → 供电 / 被别的 App 占着（接线问题）；
  ///   * 收到语句但还没定上 → 模组在搜星（等一会儿就好）；
  ///   * 有定位 → 正常，不提示（下面那张卡里全是数）。
  Widget? _liveHint(S s) {
    if (!link.connected) return null;
    if (link.silent) return SettingsHint(s.extGpsSilent, color: C.orange);
    if (link.waitingFix) return SettingsHint(s.extGpsWaitingFix, color: C.blue);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => SettingsPageShell(
        state: widget.state,
        title: s.extGpsDeviceTitle,
        subtitle: s.extGpsDeviceDesc,
        icon: Icons.gps_fixed_rounded,
        color: C.blue,
        body: Column(children: [
          _bindCard(s),
          const SizedBox(height: 16),
          // 「当前定位」只在连着时出现：断开后 lastFix 已被清掉
          // （见 [NmeaGpsLink._resetData]），摆一张全是「—」的卡只会让人
          // 以为定位坏了。
          if (link.connected) ...[
            _fixCard(s),
            const SizedBox(height: 16),
          ],
          _statCard(s),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  /// ① 设备绑定与状态
  Widget _bindCard(S s) {
    final statusValue = link.connected
        ? '${_statusText(s)} · ${s.extGpsStats('${link.fixes}')}'
        : _statusText(s);
    return SettingsSectionCard(
      title: s.extGpsBindTitle,
      subtitle: s.extGpsBindSubtitle,
      icon: Icons.bluetooth_rounded,
      color: C.blue,
      children: [
        SettingsRow2(
          s.linkBoundDevice,
          link.device?.label ?? s.linkNotBound,
          valueColor: link.device == null ? C.grey : C.ink,
        ),
        SettingsRow2(
          s.connection,
          statusValue,
          valueColor: link.connected
              ? C.green
              : (link.connecting ? C.blue : C.slate),
        ),
        // 「只收不发」必须写在明面上：这是它与 TNC 最大的区别
        SettingsRow2(
          s.dataSourceNmeaGps,
          s.extGpsReadOnly,
          valueColor: C.orange,
        ),
        if (!_supported) SettingsHint(s.tncSupportedNo, color: C.orange),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _scanning || !_supported ? null : _scan,
                icon: _scanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded, size: 16),
                label: Text(s.linkScanAction),
                style: OutlinedButton.styleFrom(
                  foregroundColor: C.blue,
                  side: BorderSide(color: C.blue.withValues(alpha: 0.5)),
                  textStyle: ts(12, w: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _busy || !_supported ? null : _toggleLink,
                icon: Icon(
                  link.connected
                      ? Icons.link_off_rounded
                      : Icons.link_rounded,
                  size: 16,
                ),
                label: Text(link.connected ? s.disconnect : s.linkConnectAction),
                style: FilledButton.styleFrom(
                  backgroundColor: link.connected ? C.red : C.blue,
                  textStyle: ts(12, c: Colors.white, w: FontWeight.w600),
                ),
              ),
            ),
          ]),
        ),
        if (link.device != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
            child: Row(children: [
              TextButton.icon(
                onPressed: () async {
                  link.bind(null);
                  setState(() {});
                },
                icon: const Icon(Icons.delete_outline_rounded, size: 15),
                label: Text(s.tncUnbind, style: ts(12)),
                style: TextButton.styleFrom(foregroundColor: C.grey),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  setState(() => _busy = true);
                  await link.restart();
                  st.adoptDeviceLink(AppState.srcNmeaGps, link.connected);
                  st.reloadUi();
                  if (mounted) setState(() => _busy = false);
                },
                icon: const Icon(Icons.restart_alt_rounded, size: 15),
                label: Text(s.tncRestart, style: ts(12)),
                style: TextButton.styleFrom(foregroundColor: C.orange),
              ),
            ]),
          ),
        if (link.devices.isNotEmpty) ...[
          Divider(height: 1, color: C.border),
          for (final d in link.devices) _deviceTile(d),
        ] else if (!_scanning)
          SettingsHint(s.linkNoPaired, icon: Icons.bluetooth_disabled_rounded),
      ],
    );
  }

  Widget _deviceTile(TncDevice d) {
    final s = S.of(context);
    final selected = link.device?.id == d.id;
    // 该设备已被别的链路（TNC / PKWDWPL / 盒子）绑定？两条链路连同一台设备
    // 会把**接收**字节流瓜分（串口两个句柄各读一部分 / 蓝牙第二条 RFCOMM
    // 顶掉第一条），所以这里直接不允许重复绑定 —— 与 PKWDWPL 页同一条判据。
    final owner = selected ? null : st.deviceBoundBy(d.id);
    final usedByOther = owner != null && owner != AppState.srcNmeaGps;
    return InkWell(
      onTap: usedByOther
          ? null
          : () async {
              link.bind(d);
              if (mounted) setState(() {});
            },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? C.blue.withValues(alpha: 0.10) : Colors.transparent,
          border: Border(bottom: BorderSide(color: C.border, width: 0.4)),
        ),
        child: Row(children: [
          Icon(
            d.isBluetooth ? Icons.bluetooth_rounded : Icons.usb_rounded,
            size: 16,
            color: usedByOther ? C.greyLight : (selected ? C.blue : C.grey),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d.label,
                    style: ts(12,
                        w: selected ? FontWeight.w700 : FontWeight.w500,
                        c: usedByOther ? C.grey : null),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (usedByOther)
                  Text(s.deviceInUseByOther, style: ts(10, c: C.orange)),
              ],
            ),
          ),
          if (selected) Icon(Icons.check_circle_rounded, size: 16, color: C.blue),
        ]),
      ),
    );
  }

  /// ② 当前定位：模组最近报上来的那一条（用户 2026-10-14：「加更详细的显示」）
  ///
  /// 与下面那张统计卡的分工：统计卡是「这条链路收得好不好」（收了多少条、
  /// 丢了多少），这张是「现在这个点是什么」—— 一个是链路台账，一个是定位本身。
  /// 之前只有 `定位接收 · N` 那一行时，用户看不到当前坐标/星数/精度到底是多少。
  Widget _fixCard(S s) {
    final fix = link.lastFix;
    final hint = _liveHint(s);
    return SettingsSectionCard(
      title: s.extGpsFixTitle,
      subtitle: s.extGpsFixSubtitle,
      icon: Icons.my_location_rounded,
      color: C.green,
      children: fix == null
          ? [hint ?? SettingsHint(s.extGpsWaitingFix, color: C.blue)]
          : [
              // 龄期放第一行：它是「这条定位还能不能用」的唯一判据 ——
              // 30 秒没有新点，位置来源就交回手机 GPS（[NmeaGpsLink.kFixFresh]）。
              SettingsRow2(
                s.extGpsFixAge,
                _ageText(s),
                valueColor: link.fresh ? C.green : C.orange,
              ),
              SettingsRow2(s.latitude, fix.lat.toStringAsFixed(6)),
              SettingsRow2(s.longitude, fix.lng.toStringAsFixed(6)),
              SettingsRow2(
                s.altitude,
                fix.altM == null ? '—' : '${fix.altM!.toStringAsFixed(1)} m',
                valueColor: fix.altM == null ? C.grey : C.ink,
              ),
              SettingsRow2(
                s.speed,
                fix.speedKmh == null
                    ? '—'
                    : '${fix.speedKmh!.toStringAsFixed(1)} km/h',
                valueColor: fix.speedKmh == null ? C.grey : C.ink,
              ),
              SettingsRow2(
                s.course,
                fix.courseDeg == null
                    ? '—'
                    : '${fix.courseDeg!.toStringAsFixed(0)}°',
                valueColor: fix.courseDeg == null ? C.grey : C.ink,
              ),
              SettingsRow2(
                s.extGpsSatellites,
                fix.satellites == null ? '—' : '${fix.satellites}',
                valueColor: (fix.satellites ?? 0) > 0 ? C.green : C.grey,
              ),
              SettingsRow2(
                s.extGpsAccuracy,
                _accuracyText(fix),
                valueColor: fix.accuracyM == null ? C.grey : C.ink,
              ),
              SettingsRow2(
                s.extGpsFixType,
                _fixTypeText(s),
                valueColor: link.fixType.isEmpty ? C.grey : C.ink,
              ),
              SettingsRow2(
                s.extGpsFixUtc,
                _utcText(fix),
                valueColor: fix.utc == null ? C.grey : C.ink,
              ),
              // 触发语句与原始语句：模组在发什么，比任何统计都直接 ——
              // 同一个模组换固件后「发 RMC 还是 GGA、有没有 GSA」是会变的，
              // 而这几件事决定了上面几行有没有值。
              SettingsRow2(s.extGpsFixSource, fix.source),
              _rawSentence(s, fix.raw),
            ],
    );
  }

  /// 「N 秒前 / N 分前 / N 小时前」：复用已有的相对时间键，不另造一套格式。
  String _ageText(S s) {
    final at = link.lastFix?.at;
    if (at == null) return '—';
    final sec = DateTime.now().difference(at).inSeconds;
    if (sec < 60) return s.secondsAgo(sec < 0 ? 0 : sec);
    final min = sec ~/ 60;
    if (min < 60) return s.minutesAgo(min);
    return s.hoursAgo(min ~/ 60);
  }

  /// 精度行：HDOP 估算值 + 模组报的原始 HDOP（两者都没有就一个「—」）。
  ///
  /// 两个都写出来是因为它们不是一回事：`±N m` 是给人看的估算
  /// （[NmeaFix.accuracyM] = HDOP × 5 m），`HDOP` 是模组原值 ——
  /// 拿它才能跟别的软件对上。
  String _accuracyText(NmeaFix fix) {
    final parts = <String>[];
    if (fix.accuracyM != null) {
      parts.add('±${fix.accuracyM!.toStringAsFixed(0)} m');
    }
    if (fix.hdop != null) parts.add('HDOP ${fix.hdop!.toStringAsFixed(1)}');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// GSA 报的定位类型；`''` = 这个模组不发 GSA（只发 RMC/GGA 的很常见）。
  String _fixTypeText(S s) {
    switch (link.fixType) {
      case '3':
        return s.extGpsFixType3d;
      case '2':
        return s.extGpsFixType2d;
      case '1':
        return s.extGpsFixTypeNoFix;
      default:
        return s.extGpsFixTypeNone;
    }
  }

  /// 模组时间（UTC）：来自卫星，可能还没同步上（没电池的模组会回到 2000 年）。
  ///
  /// 所以它只是参考值 —— 「这条定位新不新鲜」一律按**本机时钟**判断
  /// （见 [NmeaFix.at] 与 [_ageText]），用模组时间会得出荒唐的结论。
  String _utcText(NmeaFix fix) {
    final t = fix.utc;
    if (t == null) return '—';
    return '${t.toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';
  }

  /// 最近一条原始语句（等宽）。GGA 一条就有 70 多个字符，交给 Text 自己换行。
  Widget _rawSentence(S s, String raw) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.extGpsFixRaw, style: ts(11, c: C.slate)),
          const SizedBox(height: 4),
          Text(
            raw,
            style: ts(10, c: C.slate, h: 1.35)
                .copyWith(fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  /// ③ 定位接收统计 + 校验严格度
  ///
  /// 为什么要分开计数「还没定上 / 校验不符 / 其它 NMEA」：这条链路收不到定位
  /// 只有三种可能（语句有效但模组还没定上、校验不符被丢、压根不是 NMEA），
  /// 三个计数能把它们分开 —— 否则用户只能靠猜。
  ///
  /// 星数与精度不在这里：它们是「当前定位」的属性，摆在上面那张卡里 ——
  /// 同一个数在两张卡上各出现一次，用户会以为哪个才是准的。
  Widget _statCard(S s) {
    return SettingsSectionCard(
      title: s.extGpsStatTitle,
      subtitle: s.extGpsDeviceDesc,
      icon: Icons.insights_rounded,
      color: C.cyan,
      children: [
        SettingsRow2(s.extGpsStats('${link.fixes}'), '${link.rxBytes} B'),
        SettingsRow2(
          s.extGpsStatNoFix,
          '${link.noFixYet}',
          valueColor: link.noFixYet > 0 ? C.slate : C.grey,
        ),
        SettingsRow2(
          s.extGpsStatMismatch,
          '${link.checksumMismatches}',
          valueColor: link.checksumMismatches > 0 ? C.orange : C.grey,
        ),
        SettingsRow2(
          s.extGpsStatRejected,
          '${link.rejected}',
          valueColor: link.rejected > 0 ? C.orange : C.grey,
        ),
        SettingsRow2(
          s.extGpsStatIgnored,
          '${link.ignored}',
          valueColor: C.slate,
        ),
        SettingsSwitch(
          s.extGpsStrictChecksum,
          value: link.config.strictChecksum,
          color: C.cyan,
          onChanged: (v) async {
            link.config.strictChecksum = v;
            await link.persistConfig();
            if (mounted) setState(() {});
          },
        ),
        SettingsHint(s.extGpsStrictChecksumTip),
        SettingsSwitch(
          s.kissAutoReconnect,
          value: link.config.autoReconnect,
          color: C.blue,
          onChanged: (v) async {
            link.config.autoReconnect = v;
            await link.persistConfig();
            if (mounted) setState(() {});
          },
        ),
        if (link.logs.isEmpty)
          SettingsHint(s.extGpsLogEmpty)
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final l in link.logs.take(12))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      l,
                      style: ts(10, c: C.slate, h: 1.35)
                          .copyWith(fontFamily: 'monospace'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
