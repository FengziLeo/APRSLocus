import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:shared_preferences/shared_preferences.dart';

/// ─── 启动体检：只查当前权限，不申请 ───
///
/// 权限有个很难自查的失败模式：用户在系统设置里把它关掉之后，**应用里什么都
/// 看不出来**，只会在用到的那一刻失败。最坏的一处是定位：前台服务的类型声明
/// 拿不到权限时会抛异常、服务直接结束（见 `LocationService.declareForeground`），
/// 表现是「一打开就闪退」或者「后台永远不会上报」。
///
/// 所以每次启动只问一次「现在缺哪一项」。
///
/// **只查不申请**：申请是各功能自己的事（连接蓝牙时、开录音时、首次定位时）。
/// 启动时再弹系统权限框，用户还没操作就先被拦一道，只会更差。
///
/// **只对「以前到手过、现在没了」的项提示**（[revoked]）：第一次就拒绝是用户的
/// 选择 —— 定位与通知是在同一个系统弹窗序列里问的，他完全可能只准一个，每次
/// 冷启都拿这件事拦他一道只会让人烦。真正要说的那种是「本来好好的，被关掉了」：
/// 那时界面上看不出任何异常，但功能已经废了一半。
///
/// 只盯**核心功能**的两项（与原生 `permissionReport` 一一对应）：定位、通知。
/// 蓝牙 / 录音 / 计步是按功能要的，各自在用到时申请并提示；放进启动体检只会在
/// 用户根本没开那个功能时乱报「缺权限」。
class PermissionCheck {
  PermissionCheck._();

  /// 与原生共用的定位通道（`checkPermissions` / `requestPermissions` 也在上面）
  static const _channel = MethodChannel('com.aprslocus/location');

  /// 体检盯着的两项，顺序即提示里的顺序
  static const List<String> watched = ['location', 'notifications'];

  /// 见过「已到手」的项。与应用里的偏好无关（用户可能换机、可能重装），
  /// 所以不跟着备份走 —— 它描述的是**本机系统设置**的历史。
  static const _kSeen = 'permGrantedV1';

  /// 原生报回来的授予情况；查不到（非 Android、通道缺席、调用失败）时返回 null，
  /// 体检是**锦上添花**，它自己出问题绝不能让启动流程跟着出问题。
  static Future<Map<String, bool>?> _report() async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'permissionReport',
      );
      if (r == null) return null;
      return {
        for (final k in watched)
          // 原生没报的键（版本更低、系统没有这一项）不算缺失
          if (r[k] is bool) k: r[k] == true,
      };
    } catch (_) {
      return null;
    }
  }

  /// 这次启动该提示的项：以前到手过、现在没了的那几项（按 [watched] 排序）。
  ///
  /// 同时把「这一轮确实到手」的项记进 `permGrantedV1` —— 下次它们消失才算
  /// 「被关掉」。
  static Future<List<String>> revoked() async {
    final report = await _report();
    if (report == null) return const [];
    final prefs = await SharedPreferences.getInstance();
    final seen = <String>{...?prefs.getStringList(_kSeen)};
    final gone = [
      for (final k in watched)
        if (report[k] == false && seen.contains(k)) k,
    ];
    // 名单只**加**，不减：这次缺的项留在名单里，下次启动还会提 —— 直到用户
    // 把它打开（重新到手），或者明确说一句「知道了」（见 [stopReminding]）。
    final grantedNow = <String>{
      ...seen,
      ...watched.where((k) => report[k] == true),
    };
    if (grantedNow.length != seen.length) {
      await prefs.setStringList(_kSeen, grantedNow.toList()..sort());
    }
    return gone;
  }

  /// 用户明确说「知道了」：不再为这几项提醒。
  ///
  /// 从「到手过」的名单里划掉，所以下次它们**重新到手再被关掉**时还会提 ——
  /// 划掉的语义是「这次别再说了」，不是「以后都别说」。
  static Future<void> stopReminding(Iterable<String> ids) async {
    try {
      final drop = ids.toSet();
      if (drop.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      final left = <String>{
        ...?prefs.getStringList(_kSeen),
      }..removeAll(drop);
      await prefs.setStringList(_kSeen, left.toList()..sort());
    } catch (_) {}
  }

  /// 打开本应用的系统设置页（提示里那个「去设置」）。
  ///
  /// 不去申请权限：用户在系统设置里手动打开的那一档**不会被系统再拦**
  /// （「拒绝后不再询问」也拦不住手动打开），比再弹一次系统框稳。
  static Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<bool>('openAppSettings');
    } catch (_) {}
  }
}
