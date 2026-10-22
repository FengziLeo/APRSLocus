// SPDX-License-Identifier: GPL-2.0-or-later
/// 操作证验证页（电台页的入口，也可从设置 → 高级 → 开发人员 进）。
///
/// 两段：先一页说明，用户点「我同意」才看到表单 —— 用户 2026-10-22：
/// 「点击操作证验证之后，将会单独跳转一页进行操作证验证，进行同意」。
/// 同意不落盘，每次进来重新问一遍；拒绝就直接退回去，什么都不发。
///
/// 查到了就把「呼号 + 证书类别」记在本机，电台页的「认证信息」那块
/// 显示的就是这条记录（见 `_StationSettingsPageState._certCard`）。
/// 查不到、网络不通都只在那行结果里说，不改动任何已有记录 ——
/// 一次失败的查询不该把已验过的记录抹掉。
library;

import 'package:flutter/material.dart';

import 'crac_cert.dart';
import 'settings_widgets.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

class CracCertPage extends StatefulWidget {
  final AppState state;
  const CracCertPage({super.key, required this.state});

  @override
  State<CracCertPage> createState() => _CracCertPageState();
}

class _CracCertPageState extends State<CracCertPage> {
  // 不预填任何值：姓名与证件号都是要用户自己填的。
  final _name = TextEditingController();
  final _cert = TextEditingController();

  bool _busy = false;
  CracCertResult? _result;

  /// 这一次进来是否已经同意。**不持久化**：每次进这一页都要重新同意一次
  /// （用户要的是「跳转一页……进行同意」这个动作本身，而不是一次性开关）。
  bool _agreed = false;

  /// 结果行下方那句「已记到呼号 X / 这条登记的是 Y」。
  String _note = '';

  AppState get st => widget.state;

  @override
  void dispose() {
    _name.dispose();
    _cert.dispose();
    super.dispose();
  }

  Future<void> _query() async {
    final s = S.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast(s.cracCertNeedName);
      return;
    }
    if (_cert.text.trim().isEmpty) {
      _toast(s.cracCertNeedKey);
      return;
    }
    setState(() {
      _busy = true;
      _note = '';
    });
    final result = await queryCracCert(name: name, certNo: _cert.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = result;
    });
    if (!result.ok) return;

    // 记到本机：证书记录里登记了呼号就按它对，没登记就按当前呼号。
    final rec = result.records.first;
    final call = rec.call.trim().isEmpty
        ? st.myBaseCall
        : rec.call.trim().toUpperCase();
    if (rec.call.trim().isNotEmpty && call != st.myBaseCall) {
      setState(() => _note = s.cracCertOtherCall(call));
      return;
    }
    if (call.isEmpty) return;
    st.setCracCert(CracCertInfo(
      call: call,
      name: rec.name,
      type: rec.type,
      certNo: rec.certNo,
      at: _stamp(),
    ));
    if (mounted) setState(() => _note = s.cracCertSaved(call));
  }

  /// 查询时间（本机时区，`yyyy-MM-dd HH:mm`）—— 只给人看，不参与判断。
  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)} '
        '${two(now.hour)}:${two(now.minute)}';
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.ink,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => SettingsPageShell(
        title: s.cracCertEntry,
        icon: Icons.verified_user_rounded,
        color: C.green,
        body: _agreed ? _form(s) : _consent(s),
      ),
    );
  }

  /// 第一段：先把事情说清楚，用户点「我同意」才看得到表单。
  ///
  /// 四条说明按「数据去哪、怎么检、是不是必须做、为什么要有这一步」排。
  Widget _consent(S s) {
    return Column(children: [
      SettingsSectionCard(
        title: s.cracCertEntry,
        icon: Icons.policy_rounded,
        color: C.green,
        children: [
          SettingsHint(s.cracCertPrivacy),
          SettingsHint(s.cracCertLocal, icon: Icons.rule_rounded),
          SettingsHint(s.cracCertVoluntary,
              icon: Icons.volunteer_activism_rounded),
          SettingsHint(s.cracCertWhyRequired, icon: Icons.gavel_rounded),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Row(children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => setState(() => _agreed = true),
                  style: FilledButton.styleFrom(
                    backgroundColor: C.green,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(s.consentAgree,
                      style: ts(12, c: Colors.white, w: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              // 不同意就直接退回去：什么都不填、什么都不发。
              TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(s.cancel, style: ts(12, c: C.slate)),
              ),
            ]),
          ),
        ],
      ),
    ]);
  }

  /// 第二段：表单 + 查询。
  Widget _form(S s) {
    return Column(children: [
      SettingsSectionCard(
        title: s.cracCertEntry,
        icon: Icons.manage_search_rounded,
        color: C.green,
        children: [
          SettingsInput(s.cracCertName, _name,
              onEditingComplete: () => _query()),
          SettingsInput(s.cracCertNumber, _cert,
              onEditingComplete: () => _query()),
          SettingsHint(s.cracCertPrivacy),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _query,
                style: FilledButton.styleFrom(
                  backgroundColor: C.green,
                  disabledBackgroundColor: C.greyBg,
                  disabledForegroundColor: C.slate,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  _busy ? s.cracCertQuerying : s.cracCertQuery,
                  style: ts(12, c: Colors.white, w: FontWeight.w700),
                ),
              ),
            ),
          ),
          SettingsHint(s.cracCertWhyRequired, icon: Icons.gavel_rounded),
          const SizedBox(height: 6),
        ],
      ),
      const SizedBox(height: 16),
      _resultCard(s),
    ]);
  }

  Widget _resultCard(S s) {
    final result = _result;
    final children = <Widget>[];
    if (result != null) {
      switch (result.status) {
        case CracCertStatus.found:
          // 只回「通过 + 证书类别」（用户 2026-10-22：只返回验证成功与 A/B/C 证）。
          // 接口其实带了姓名/证号/发证日期这些字段，这里一律不展 —— 多列一行
          // 就多一种「拿别人的记录当自己的」异议，也不该把人家的证件号留在屏幕上。
          final rec = result.records.first;
          children.add(_line(
            rec.typeLabel.isEmpty
                ? s.cracCertVerified
                : '${s.cracCertVerified} · ${rec.typeLabel}',
            C.green,
          ));
          break;
        case CracCertStatus.notFound:
          children.add(_line(s.cracCertNotFound, C.orange));
          break;
        case CracCertStatus.failed:
          children.add(_line('${s.cracCertFailed}${result.message}', C.red));
          break;
      }
    }
    if (_note.isNotEmpty) children.add(_line(_note, C.green));
    if (children.isEmpty) return const SizedBox.shrink();
    return SettingsSectionCard(
      title: s.cracCertResult,
      icon: Icons.fact_check_rounded,
      color: C.green,
      children: children,
    );
  }

  Widget _line(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        alignment: Alignment.centerLeft,
        child: Text(text, style: ts(12, c: color, w: FontWeight.w600)),
      );
}
