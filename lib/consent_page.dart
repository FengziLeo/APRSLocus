import 'dart:async';

import 'package:flutter/material.dart';

import 'consent.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── 上传/发射前的「单独同意」（用户协议 V2.0 附件一）───
///
/// 为什么是一整页而不是随手点掉的弹窗：协议 5.3 要求把**三件事**单独讲清楚
/// （信息性质 / 必要性 / 对个人权益的影响），5.4 还要求把「同意时间、所同意的
/// 功能项、告知文本的版本标识」记进本地日志。一段两行的 toast 做不到这两件事。
///
/// 页面上有两层勾选：
///   * 「我同意」——对应附件一那句「本人自愿、明确地单独同意」，默认不勾；
///   * 三个功能项——勾哪项才签哪项。用户故意漏勾的那一项**不会**被打开，
///     开关读的是同一份同意状态（[AppState.consent]）。
class ConsentPage extends StatefulWidget {
  final AppState state;
  const ConsentPage({super.key, required this.state});

  @override
  State<ConsentPage> createState() => _ConsentPageState();
}

class _ConsentPageState extends State<ConsentPage> {
  bool _agree = false;
  final Set<ConsentScope> _picked = {};
  String? _error;

  AppState get st => widget.state;

  // 所有方框默认**不勾**（附件一：「请主动勾选，默认不勾选」）。
  // 连「刚才点的那一项」也不预勾 —— 预勾等于替他做了那个决定。

  void _submit() {
    final s = S.of(context);
    if (!_agree) {
      setState(() => _error = s.consentPickAgree);
      return;
    }
    if (_picked.isEmpty) {
      setState(() => _error = s.consentPickOne);
      return;
    }
    unawaited(st.acceptConsent({..._picked}));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final granted = st.consent.granted;
    return Scaffold(
      backgroundColor: C.pageFill,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 24, 22, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: C.blue.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(Icons.shield_outlined,
                              size: 20, color: C.blue),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.consentTitle,
                            style: ts(16, w: FontWeight.w800, c: C.ink),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(s.consentLead, style: ts(13, c: C.slate, h: 1.7)),
                    _point(s.consentNatureTitle, s.consentNatureBody),
                    _point(s.consentNeedTitle, s.consentNeedBody),
                    _point(s.consentImpactTitle, s.consentImpactBody),
                    const SizedBox(height: 6),
                    Divider(height: 20, color: C.border),
                    _check(
                      label: s.consentAgree,
                      value: _agree,
                      onChanged: (v) => setState(() {
                        _agree = v;
                        _error = null;
                      }),
                      strong: true,
                    ),
                    const SizedBox(height: 4),
                    for (final scope in ConsentScope.values)
                      _check(
                        label: _scopeLabel(s, scope),
                        value: granted.contains(scope) || _picked.contains(scope),
                        onChanged: granted.contains(scope)
                            ? null
                            : (v) => setState(() {
                                  if (v) {
                                    _picked.add(scope);
                                  } else {
                                    _picked.remove(scope);
                                  }
                                  _error = null;
                                }),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(_error!, style: ts(12, c: C.orange)),
                      ),
                  ],
                ),
              ),
            ),
            // 两个按钮都能离开这一页 —— 不同意不是死路：软件本来就默认不连接、
            // 不上传，本地功能照常可用。
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: st.declineConsent,
                      child: Text(s.consentCancel),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _submit,
                      style: FilledButton.styleFrom(backgroundColor: C.blue),
                      child: Text(s.consentAccept),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _scopeLabel(S s, ConsentScope scope) {
    switch (scope) {
      case ConsentScope.internet:
        return s.consentScopeInternet;
      case ConsentScope.rf:
        return s.consentScopeRf;
      case ConsentScope.igate:
        return s.consentScopeIgate;
    }
  }

  Widget _point(String title, String body) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: ts(13, w: FontWeight.w700, c: C.ink)),
          const SizedBox(height: 4),
          Text(body, style: ts(13, c: C.slate, h: 1.75)),
        ],
      ),
    );
  }

  Widget _check({
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
    bool strong = false,
  }) {
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: onChanged == null ? null : (v) => onChanged(v ?? false),
              activeColor: C.blue,
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Text(
                label,
                style: strong
                    ? ts(13, w: FontWeight.w700, c: C.ink)
                    : ts(13, c: onChanged == null ? C.grey : C.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
