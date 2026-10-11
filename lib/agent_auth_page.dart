import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'agent_allow.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── 智能体授权 / 申请页 ───
///
/// 智能体**不对普通用户开放**。用户打开智能体开关时：
///   1. 未签「智能体使用告知」→ 先弹告知页；
///   2. 签完但本机呼号**不在官网授权名单**里 → 弹到这一页。
///
/// 这一页要如实回答三件事（与 [BlacklistPage] 同一思路）：
///   * **为什么**（智能体是受限功能，需要授权）；
///   * **怎么办**（下载承诺书 → 填写 → 邮件寄到 [AgentAllow.kApplyEmail]）；
///   * **怎么生效**（申请通过后点「重新检查」；名单从官网拉取，和封禁名单同一套架构）。
///
/// 用整页而不是弹窗：这是一段"要动手去做"的流程，不是随手点掉的提示。
class AgentAuthPage extends StatefulWidget {
  final AppState state;
  const AgentAuthPage({super.key, required this.state});

  @override
  State<AgentAuthPage> createState() => _AgentAuthPageState();
}

class _AgentAuthPageState extends State<AgentAuthPage> {
  bool _opening = false;

  Future<void> _open(String url) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // 打不开（没有浏览器 / 没有邮件客户端）也不该崩：界面上还有邮箱可手抄
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String get _call => widget.state.myFullCall;

  /// 「重新检查授权」：拉一次名单重判。已授权 → 状态层会关页并启用；否则如实提示
  /// （多数情况下是"还在审核"，不要假装成功，也不要假装失败）。
  Future<void> _recheck() async {
    final s = S.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await widget.state.submitAgentAuthApplication();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok ? s.agentAuthGranted : s.agentAuthStillPending),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: ok ? C.green : C.ink,
      ),
    );
  }

  void _download() {
    // 官网静态文本，直接用系统浏览器打开（应用内读文件要把 txt 打进包里，没必要）
    _open(Uri.parse(AgentAllow.kBase).resolve(AgentAllow.kCommitmentZh).toString());
  }

  void _mailto() {
    final s = S.of(context);
    final subject = Uri.encodeComponent('${s.agentAuthMailSubject} $_call');
    final body = Uri.encodeComponent('${s.agentAuthMailBody}\n\n$_call\n');
    _open('mailto:${AgentAllow.kApplyEmail}?subject=$subject&body=$body');
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: C.pageFill,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: C.purple.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Icon(Icons.verified_user_rounded,
                                size: 20, color: C.purple),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(s.agentAuthTitle,
                                style: ts(16, w: FontWeight.w800, c: C.ink)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(s.agentAuthBody, style: ts(13, c: C.slate, h: 1.75)),
                      const SizedBox(height: 16),
                      // 本机呼号：申请时要用它，一字不改地显示（免得用户自己打错）
                      _kv(s.agentAuthCallLabel, _call),
                      const SizedBox(height: 18),
                      _step(
                        '1',
                        s.agentAuthStep1Title,
                        s.agentAuthStep1Desc,
                      ),
                      const SizedBox(height: 12),
                      _step(
                        '2',
                        s.agentAuthStep2Title,
                        '${s.agentAuthStep2Desc} ${AgentAllow.kApplyEmail}',
                      ),
                      const SizedBox(height: 12),
                      _step(
                        '3',
                        s.agentAuthStep3Title,
                        s.agentAuthStep3Desc,
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _opening ? null : _download,
                            icon: const Icon(Icons.description_outlined, size: 16),
                            label: Text(s.agentAuthDownload),
                          ),
                          OutlinedButton.icon(
                            onPressed: _opening ? null : _mailto,
                            icon: const Icon(Icons.mail_outline_rounded, size: 16),
                            label: Text(s.agentAuthEmail),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      // 邮箱也直接写出来：没有邮件客户端时，用户能手抄着发
                      SelectableText(
                        '${s.agentAuthMailTo} ${AgentAllow.kApplyEmail}',
                        style: ts(12, c: C.ink, h: 1.6)
                            .copyWith(fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: widget.state.dismissAgentAuth,
                      child: Text(s.agentAuthBack),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: C.purple),
                      onPressed: widget.state.agentAuthChecking
                          ? null
                          : _recheck,
                      icon: widget.state.agentAuthChecking
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.refresh_rounded, size: 16),
                      label: Text(widget.state.agentAuthChecking
                          ? s.agentAuthChecking
                          : s.agentAuthRecheck),
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

  Widget _kv(String k, String v) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: ts(11, c: C.grey, w: FontWeight.w700)),
          const SizedBox(height: 3),
          SelectableText(v,
              style: ts(13, c: C.ink, h: 1.5)
                  .copyWith(fontFamily: 'monospace')),
        ],
      );

  Widget _step(String n, String title, String desc) => Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
        decoration: BoxDecoration(
          color: C.surfaceFill,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.border, width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: C.purple.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Text(n,
                  style: ts(12, c: C.purple, w: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ts(13, c: C.ink, w: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(desc, style: ts(12, c: C.slate, h: 1.6)),
                ],
              ),
            ),
          ],
        ),
      );
}
