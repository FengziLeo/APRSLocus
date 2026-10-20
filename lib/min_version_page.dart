import 'package:flutter/material.dart';

import 'check_update_page.dart';
import 'exit_app.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── 版本低于官网要求时的拦截页 ───
///
/// 用**整页**而不是弹窗：既然低于最低版本就不能继续用，界面上就不该留一半
/// 能点的东西（那些按钮点下去只会出错）。这一页只有一个出口：去更新页。
///
/// 更新回来后自动重新判一次（见 [_openUpdate]）：装上了新版本、回到这一页，
/// 页面会自己消失；没装上就还停在这里。返回键不返回上一页，直接退出应用 ——
/// 这正是"不更新就不让用"的落点（[_quit]）。
class MinVersionPage extends StatefulWidget {
  final AppState state;
  const MinVersionPage({super.key, required this.state});

  @override
  State<MinVersionPage> createState() => _MinVersionPageState();
}

class _MinVersionPageState extends State<MinVersionPage> {
  bool _busy = false;

  String get _min => widget.state.minVersionLimit?.minVersion ?? '';

  /// 去更新页。回来后重新拉一次下限：更新装上了，这一页就自己消失。
  Future<void> _openUpdate() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CheckUpdatePage(state: widget.state)),
    );
    if (!mounted) return;
    setState(() => _busy = true);
    await widget.state.recheckMinVersion(force: true);
    if (mounted) setState(() => _busy = false);
  }

  /// 不更新 → 退出应用（先按正常退出流程收尾：存设置、停定位、断链路）。
  Future<void> _quit() async {
    await widget.state.shutdownForExit();
    if (!mounted) return;
    await exitApplication();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final reason = widget.state.minVersionLimit?.reason ?? '';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _quit();
      },
      child: Scaffold(
        backgroundColor: C.pageFill,
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
                decoration: BoxDecoration(
                  color: C.surfaceFill,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: C.border, width: 0.5),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: C.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: Icon(Icons.system_update_rounded,
                            size: 20, color: C.blue),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(s.mvTitle,
                            style: ts(16, w: FontWeight.w800, c: C.ink)),
                      ),
                    ]),
                    const SizedBox(height: 14),
                    Text(s.mvBody(_min), style: ts(13, c: C.slate, h: 1.7)),
                    const SizedBox(height: 14),
                    Row(children: [
                      Expanded(
                        child: _kv(s.mvCurrent, AppState.appVersion),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _kv(s.mvRequired, _min)),
                    ]),
                    if (reason.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text(s.mvReason,
                          style: ts(11, c: C.grey, w: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(reason, style: ts(13, c: C.ink, h: 1.6)),
                    ],
                    const SizedBox(height: 16),
                    Row(children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : _openUpdate,
                        icon: _busy
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.system_update_rounded,
                                size: 16),
                        label: Text(_busy ? s.mvChecking : s.mvUpdate),
                        style: FilledButton.styleFrom(
                          backgroundColor: C.blue,
                          textStyle:
                              ts(12, c: Colors.white, w: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: _busy ? null : _quit,
                        child: Text(s.mvExit, style: ts(12, c: C.slate)),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 一行"标签 + 等宽读数"（版本号用等宽字体才好对位）
  Widget _kv(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: ts(11, c: C.grey, w: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(value,
              style: ts(13, c: C.ink, h: 1.5)
                  .copyWith(fontFamily: 'monospace')),
        ],
      );
}
