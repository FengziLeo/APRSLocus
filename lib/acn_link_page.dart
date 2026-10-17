import 'dart:async';

import 'package:flutter/material.dart';

import 'settings_widgets.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─── APRSNETCN SERVER 的配置页 ───
///
/// 这条链路原先挤在「连接设置」那一页里当一张卡，和主链路、过滤器、缓存三张
/// 卡排在一起。它有自己的服务器、自己的账号口令、自己的同步按钮，摆在那里
/// 既挤又把两件事混成一件：主链路是**收发**，它只**收**。
///
/// 所以单开一页，形状照主链路那张「APRS-IS 连接」卡：地址 → 端口 → 账号口令
/// → 状态，改完给一个「重新连接」。服务器地址是**填进去的**，不写死在代码里：
/// 同一套协议可以指到别的机器上，换机器、走反代、自己搭一台试，都只改这两格。
class AcnLinkPage extends StatefulWidget {
  final AppState state;
  const AcnLinkPage({super.key, required this.state});

  @override
  State<AcnLinkPage> createState() => _AcnLinkPageState();
}

class _AcnLinkPageState extends State<AcnLinkPage> {
  late final TextEditingController _server;
  late final TextEditingController _port;
  late final TextEditingController _account;
  late final TextEditingController _password;
  bool _passwordHidden = true;

  /// 保存进页面时的值：只用来判断「改过了、要重连」，不参与连接
  late final String _origServer;
  late final int _origPort;
  late final String _origAccount;
  late final String _origPassword;
  bool _dirty = false;

  AppState get st => widget.state;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: st.acnServer);
    _port = TextEditingController(text: '${st.acnPort}');
    _account = TextEditingController(text: st.acnAccount);
    _password = TextEditingController(text: st.acnPassword);
    _origServer = st.acnServer;
    _origPort = st.acnPort;
    _origAccount = st.acnAccount;
    _origPassword = st.acnPassword;
  }

  @override
  void dispose() {
    _server.dispose();
    _port.dispose();
    _account.dispose();
    _password.dispose();
    super.dispose();
  }

  /// 改了一项就落盘，但只在「脏」翻转的那一次写：逐字 persist 会把整份偏好
  /// 反复刷进磁盘，而地址往往是一个字一个字敲出来的。
  void _touched() {
    final dirty = st.acnServer != _origServer ||
        st.acnPort != _origPort ||
        st.acnAccount != _origAccount ||
        st.acnPassword != _origPassword;
    if (dirty == _dirty) return;
    if (dirty) st.persist();
    setState(() => _dirty = dirty);
  }

  Future<void> _reconnect() async {
    setState(() => _dirty = false);
    await st.reconnectAcn();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => SettingsPageShell(
        title: s.acnCardTitle,
        subtitle: s.acnPageLead,
        icon: Icons.hub_rounded,
        color: C.purple,
        body: Column(children: [
          _linkCard(s),
          const SizedBox(height: 16),
          _syncCard(s),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  /// ① 这条链路本身：开关、地址、端口、账号口令、状态
  Widget _linkCard(S s) {
    return SettingsSectionCard(
      title: s.connection,
      icon: Icons.hub_rounded,
      color: C.purple,
      children: [
        SettingsSwitch(s.acnLinkSwitch,
            value: st.acnOn,
            color: C.purple,
            onChanged: (v) => st.setAcnOn(v)),
        SettingsRow2(
          s.acnLinkStatus,
          st.acnConnected ? s.connected : s.disconnected,
          valueColor: st.acnConnected ? C.green : C.grey,
        ),
        // 服务器认不认这个登录：口令填错时链路会连着又断开，只有这一行
        // 说得出原因（服务器回 `not authorized (auth-failed)`）。
        if (st.acnLogin != null)
          SettingsRow2(
            s.acnLoginTitle,
            st.acnLogin == ''
                ? s.acnLoginOk
                : (st.acnLogin == 'unverified'
                    ? s.unverified
                    : s.acnLoginRejected),
            valueColor: st.acnLogin == '' ? C.slate : C.orange,
          ),
        _serverInput(s),
        SettingsInput(s.port, _port,
            onChanged: (v) {
          final n = int.tryParse(v.trim());
          if (n != null && n > 0 && n <= 65535) st.acnPort = n;
          _touched();
        }),
        _accountInputs(s),
        if (_dirty) _reconnectRow(s),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Text(s.acnLinkNote, style: ts(10, c: C.grey)),
        ),
      ],
    );
  }

  /// 地址这一格：空了就说清楚「连不上」，与主链路那张卡一个口径。
  Widget _serverInput(S s) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _server,
      builder: (_, v, _) {
        final missing = v.text.trim().isEmpty;
        return SettingsInput(
          s.server,
          _server,
          badge: missing ? s.serverMissing : null,
          onChanged: (x) {
            st.acnServer = x.trim();
            _touched();
          },
        );
      },
    );
  }

  /// 账号 + 口令：只写进这条链路的登录行。
  ///
  /// 主链路永远不带 `auth`：那几个词发给 rotate.aprs2.net 有可能被当成非法
  /// 登录词。两项都非空才发，留空就按 passcode 只收。
  Widget _accountInputs(S s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: C.border, width: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.serverAccountTitle, style: ts(12, c: C.slate)),
        const SizedBox(height: 6),
        TextField(
          controller: _account,
          autocorrect: false,
          style: ts(13, w: FontWeight.w600),
          onChanged: (v) {
            st.acnAccount = v.trim();
            _touched();
          },
          decoration: InputDecoration(
            hintText: s.serverAccountHint,
            hintStyle: ts(13, c: C.greyLight),
            isDense: true,
            filled: true,
            fillColor: C.bgSoft,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _password,
          obscureText: _passwordHidden,
          autocorrect: false,
          enableSuggestions: false,
          style: ts(13, w: FontWeight.w600),
          onChanged: (v) {
            st.acnPassword = v;
            _touched();
          },
          decoration: InputDecoration(
            hintText: s.serverPasswordHint,
            hintStyle: ts(13, c: C.greyLight),
            isDense: true,
            filled: true,
            fillColor: C.bgSoft,
            suffixIcon: IconButton(
              icon: Icon(
                _passwordHidden
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 18,
                color: C.grey,
              ),
              tooltip: s.serverPasswordTitle,
              onPressed: () => setState(() => _passwordHidden = !_passwordHidden),
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(s.acnAccountNote, style: ts(10, c: C.grey)),
      ]),
    );
  }

  /// 地址/端口/账号口令改过、链路还连着：给一个「重新连接」。
  Widget _reconnectRow(S s) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, color: C.orange, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.configChanged,
                style: ts(13, c: C.orange, w: FontWeight.w700)),
            Text(s.reconnectToApply,
                style: ts(11, c: C.orange.withValues(alpha: 0.8))),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: Icon(Icons.refresh_rounded, color: C.orange, size: 22),
          tooltip: s.reconnect,
          onPressed: _reconnect,
        ),
      ]),
    );
  }

  /// ② 24 小时台站：只有用户按下去才拉
  Widget _syncCard(S s) {
    final last = st.acnLast;
    final busy = st.acnSyncing;
    return SettingsSectionCard(
      title: s.acnSyncTitle,
      icon: Icons.sync_rounded,
      color: C.purple,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          child: Row(children: [
            Expanded(
              child: Text(s.acnSyncHint, style: ts(11, c: C.slate, h: 1.4)),
            ),
            TextButton.icon(
              onPressed: busy ? null : () => unawaited(st.syncAcnStations()),
              icon: Icon(Icons.cloud_download_rounded,
                  size: 15, color: busy ? C.greyLight : C.purple),
              label: Text(busy ? s.acnSyncing : s.acnSyncNow,
                  style: ts(11,
                      w: FontWeight.w700, c: busy ? C.greyLight : C.purple)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
        ),
        if (last != null)
          SettingsRow2(
            s.acnSyncLast,
            last.ok
                ? s.acnSyncDone('${last.total}', '${last.added}')
                : (last.error == 'no-account'
                    ? s.acnSyncNoAccount
                    : last.error!),
            valueColor: last.ok ? C.slate : C.orange,
          ),
      ],
    );
  }
}
