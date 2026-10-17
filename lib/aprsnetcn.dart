/// APRSNETCN SERVER（国内的一台 APRS-IS 兼容服务器）在客户端这侧要知道的那几个值。
///
/// 服务器是另一个项目（github.com/dariondong/APRSNETCN-SERVER），协议上是
/// APRS-IS 的超集：标准登录行照旧可用，另外多认一对「名单账号 + 口令」
/// （`auth <账号> <口令>`，排在 `filter` 之前）和一套 HTTP 接口。
///
/// 地址写死在这里是因为它现在只有一个公网入口，没有域名；将来上了域名，
/// 改这三个常量就行，界面里引用的是 `kAcnServerHost` 而不是字面量。
library;

/// 接入点地址（APRS-IS 兼容的 TCP 端口）
const String kAcnServerHost = '8.138.199.11';

/// APRS-IS 兼容的 TCP 端口
const int kAcnServerPort = 14580;

/// HTTP 接口入口（`/api/v1/...`，见服务器仓库的 docs/API.md）
const String kAcnHttpBase = 'http://8.138.199.11:8899';

/// 预置按钮上显示的名字（服务器自己的名字，不翻译）
const String kAcnPresetLabel = 'APRSNETCN SERVER';
