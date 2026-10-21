// SPDX-License-Identifier: GPL-2.0-or-later
/// 操作证书查询页（设置 → 高级 → 开发人员）。
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
        title: s.cracCertTitle,
        icon: Icons.verified_user_rounded,
        color: C.green,
        body: Column(children: [
          SettingsSectionCard(
            title: s.cracCertTitle,
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
            ],
          ),
          const SizedBox(height: 16),
          _resultCard(s),
        ]),
      ),
    );
  }

  Widget _resultCard(S s) {
    final result = _result;
    final children = <Widget>[];
    if (result != null) {
      switch (result.status) {
        case CracCertStatus.found:
          for (final rec in result.records) {
            children.addAll(_recordRows(s, rec));
          }
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

  List<Widget> _recordRows(S s, CracCertRecord rec) {
    final rows = <Widget>[_line(rec.table, C.green)];
    void add(String label, String value) {
      if (value.trim().isEmpty) return;
      rows.add(SettingsRow2(label, value));
    }

    add(s.cracCertName, rec.name);
    add(s.cracCertNumber, rec.certNo);
    if (rec.type.isNotEmpty) add(s.cracCertType, rec.typeLabel);
    add(s.cracCertCall, rec.call);
    add(s.cracCertPassDate, rec.passDate);
    add(s.cracCertIssueDate, rec.issueDate);
    add(s.cracCertRegion, rec.region);
    add(s.cracCertValid, rec.validThrough);
    add(s.cracCertId, rec.idMasked);
    return rows;
  }

  Widget _line(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        alignment: Alignment.centerLeft,
        child: Text(text, style: ts(12, c: color, w: FontWeight.w600)),
      );
}
