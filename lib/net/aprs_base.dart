/// APRS-IS 连接器抽象
abstract class AprsConnector {
  bool connected = false;
  // 不给任何默认服务器地址：软件不预置、也不推荐连到哪台服务器（用户协议 2.4）。
  String server = '';
  int port = 14580;
  String? wsUrl;
  String callsign = 'BV2AAA';
  String passcode = '-1';

  /// 名单账号与口令（只有支持账号登录的服务器才用得上，例如 APRSNETCN）。
  ///
  /// 标准 APRS-IS 认的是 passcode，账号没有意义；APRSNETCN 在 passcode 之外
  /// 还认一对账号口令（`auth <账号> <口令>`），用来放行白名单里的呼号。
  /// 两项都非空才写进登录行，留空则完全按标准 APRS-IS 登录。
  String account = '';
  String password = '';

  String filter = 'r/39.90/116.40/300';

  /// 这行链路是否支持「账号 + 口令」登录。界面上据此决定要不要显示那两格。
  ///
  /// 不按服务器域名猜（自定义域名谁都能设），而是让连接器自己表态：
  /// TCP 直连的 AprsIo 支持；WebSocket 网关不认识这些字段，不支持。
  bool get supportsAccountLogin => false;

  /// 登录行里 `auth <账号> <口令>` 那一段（不支持或没填时为空）。
  ///
  /// 必须排在 `filter` **之前**：APRS-IS 的 `filter` 会吞掉该行剩下的全部
  /// 词，写在它后面的 `auth` 永远不会被解析。
  String get authSegment {
    if (!supportsAccountLogin) return '';
    final a = account.trim();
    if (a.isEmpty || password.isEmpty) return '';
    return ' auth $a $password';
  }
  int rxCount = 0;
  void Function(String line)? onLine;
  void Function()? onDisconnected;

  Future<bool> connect();
  /// 发送一行 TNC2。返回 false = 这帧**没写进链路**（socket 没了 / 写异常）。
  ///
  /// 回传成败是给「状态帧自愈」用的：状态报文是一对（内置 CONNECT + 自定义
  /// 状态），第二帧被吞掉就会让用户自定义状态永远显示不出来。上层据此决定
  /// 要不要重发，而不是像以前那样一律当成发出去了。
  bool send(String raw);
  void disconnect();
}
