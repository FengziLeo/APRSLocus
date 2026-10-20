/// 版本比较：支持 `1.2.5` / `1.2.5.b` / `v1.0.0`。
///
/// 与「检查更新」页保持同一套规则：字母后缀视为修复版
/// （`1.2.5.b > 1.2.5`），数字段 > 字母段（`1.2.6 > 1.2.5.b`）。
/// 返回 >0 表示 a 更新。
///
/// 单独成文件是为了让**不依赖界面的地方**也能用它（最低版本闸门
/// `lib/min_version.dart` 就是这样一个地方：它只比对版本号，不画界面）。
int compareVersions(String a, String b) {
  final sa = a.replaceAll(RegExp('^v'), '').split(RegExp(r'[._-]'));
  final sb = b.replaceAll(RegExp('^v'), '').split(RegExp(r'[._-]'));
  const letters = 'abcdefghijklmnopqrstuvwxyz';
  final len = sa.length > sb.length ? sa.length : sb.length;
  for (var i = 0; i < len; i++) {
    final hasA = i < sa.length;
    final hasB = i < sb.length;
    if (!hasA && hasB) return -1;
    if (hasA && !hasB) return 1;
    final x = sa[i];
    final y = sb[i];
    final xv = int.tryParse(x);
    final yv = int.tryParse(y);
    if (xv != null && yv != null) {
      if (xv != yv) return xv - yv;
    } else if (xv != null && yv == null) {
      return 1;
    } else if (xv == null && yv != null) {
      return -1;
    } else {
      final xl = x.isNotEmpty ? letters.indexOf(x[0]) : -1;
      final yl = y.isNotEmpty ? letters.indexOf(y[0]) : -1;
      if (xl != yl) return xl - yl;
    }
  }
  return 0;
}
