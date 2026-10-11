import 'package:flutter/material.dart';

import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── 启用智能体前必须签署的「智能体使用告知」───
///
/// 为什么单独一份（而不是并进「数据与网络使用告知」）：两者风险不同。
/// 连接服务器是「把位置/消息送上电波」，而智能体是「把对话内容发给第三方
/// 大模型，并可读取本机数据、在授权后改动设置与发消息」。用户可能只想连服务
/// 器、不想用智能体，或反之，所以各签各的。
///
/// 用**整页**而不是小弹窗：这是要读的内容，不是"随手点掉"的提示。不签也完全
/// 可用 —— 软件其余功能（含手动连接服务器）都在，只是智能体开关保持关闭。
class AgentNoticePage extends StatelessWidget {
  final AppState state;
  const AgentNoticePage({super.key, required this.state});

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
                            color: C.purple.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(13),
                          ),
                          child: Icon(Icons.smart_toy_rounded,
                              size: 20, color: C.purple),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.agentNoticeTitle,
                            style: ts(16, w: FontWeight.w800, c: C.ink),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(s.agentNoticeBody, style: ts(13, c: C.slate, h: 1.7)),
                  ],
                ),
              ),
            ),
            // 同意才启用；暂不启用则保持关闭（两个按钮都能离开这一页 —— 不签不是死路）
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 18),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: state.declineAgentNotice,
                      child: Text(s.agentNoticeDecline),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: state.acceptAgentNotice,
                      style: FilledButton.styleFrom(backgroundColor: C.purple),
                      child: Text(s.agentNoticeAccept),
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
}
