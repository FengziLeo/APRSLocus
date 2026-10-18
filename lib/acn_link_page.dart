import 'dart:async';

import 'package:flutter/material.dart';

import 'acn_cards.dart';
import 'settings_widgets.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── APRSNETCN SERVER 的整页 ───
///
/// 卡本身在 [AcnCards]：「设置 → 连接设置」把它摆在 APRS-IS 那几张卡下面，
/// 两条链路形状一致。这里只是把它单独包成一页 —— 设备页那行勾选旁边的
/// 设置按钮点进来，能一次看到这台服务器公布的全部东西。
class AcnLinkPage extends StatefulWidget {
  final AppState state;
  const AcnLinkPage({super.key, required this.state});

  @override
  State<AcnLinkPage> createState() => _AcnLinkPageState();
}

class _AcnLinkPageState extends State<AcnLinkPage> {
  @override
  void initState() {
    super.initState();
    // 只读的一条公开信息：地址写错就是这张卡空着，不影响链路本身
    unawaited(widget.state.fetchAcnInfo());
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SettingsPageShell(
      title: s.acnCardTitle,
      subtitle: s.acnPageLead,
      icon: Icons.hub_rounded,
      color: C.purple,
      body: Column(children: [
        AcnCards(state: widget.state, full: true),
        const SizedBox(height: 24),
      ]),
    );
  }
}
