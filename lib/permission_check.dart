import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart' show MethodChannel;

/// ─── 启动体检：只查当前权限，不申请 ───
///
/// 权限有个很难自查的失败模式：用户在系统设置里把它关掉之后，**应用里什么都
/// 看不出来**，只会在用到的那一刻失败。最坏的一处是定位：前台服务的类型声明
/// 拿不到权限时会抛异常、服务直接结束（见 `LocationService.declareForeground`），
/// 表现是「一打开就闪退」或者「后台永远不会上报」。
///
/// 所以每次启动只问一次「现在缺哪一项」，缺了就如实说「缺哪项、什么用不了」，
/// 并给一个直达系统设置的入口。
///
/// **只查不申请**：申请是各功能自己的事（连接蓝牙时、开录音时、首次定位时）。
/// 启动时再弹系统权限框，用户还没操作就先被拦一道，只会更差。
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

  /// 当前缺哪几项。非 Android、通道缺席、按钮查询失败时一律返回空表 ——
  /// 体检是**锦上添花**，它自己出问题绝不能让启动流程跟着出问题。
  ///
  /// 原生没报的键（版本更低、系统没有这一项）不算缺失。
  static Future<Set<String>> missing() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const {};
    try {
      final r = await _channel.invokeMapMethod<String, Object?>(
        'permissionReport',
      );
      if (r == null) return const {};
      return {
        for (final k in watched)
          if (r[k] == false) k,
      };
    } catch (_) {
      return const {};
    }
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
