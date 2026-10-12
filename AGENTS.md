# AGENTS.md — APRSLocus

Flutter/Dart APRS app (`github.com/dariondong/APRSLocus`, default branch `main`).

## 本机环境（重要）

- 本机**不能跑 Android 构建**（无 Android SDK）；`flutter build apk/bundle` 会
  在 `build_hooks` 阶段报 `Android SDK could not be found`。要验证编译，用
  `flutter test` / `flutter build web`，别指望 APK。
- Flutter SDK 在 `/tmp/flutter/bin/flutter`（不在默认 PATH）。
- `flutter analyze` 有一条**已知可容忍**的假阳性：
  `lib/vector_map.dart:295` `argument_type_not_assignable`。CI 用脚本过滤它，
  本地判断「有没有新 error」时同样忽略这一条即可。

## 提交前必跑（与 CI 对齐）

```bash
export PATH=/tmp/flutter/bin:$PATH
python3 tool/check_*.py            # 全部静态检查；注意 check_site / check_apk_resources
                                   # 需要额外参数或联网，属预期「失败」
flutter analyze                    # 除 vector_map 外不应有 error
flutter test $(grep -oE 'flutter test [^ ]+\.dart' .github/workflows/ci-test.yml | awk '{print $3}')
```

`tool/check_*.py` 是本仓库的核心防线：这些检查覆盖的都是「能编译、能过 analyze、
只在真机/特定语言/深色模式下才暴露」的坑（跨层漏 import、写死颜色、l10n 不同步、
未用成员……）。**新增 UI 代码后务必跑一遍。**

## 文案本地化（l10n）铁律

- 真源 arb：`lib/l10n/app_zh.arb`（模板），6 语言：zh / zh_TW / en / ja / es / id。
  输出物 `lib/l10n/app_localizations*.dart` **已入库**，改 arb 后必须
  `flutter gen-l10n` 重生成并一起提交；`tool/check_l10n_sync.py` 会拦不同步。
- 同页文案若某处已本地化、某处仍写死中文，就是 bug。net 层（`net/icom_lan_io.dart`
  的 `phaseLabel`、枚举 `WlanRadioModel.description`）的中文基准值，一律经
  `lib/settings_widgets.dart` 的 `icomPhaseLabel / icomModelName / icomModelTab /
  icomModelDesc` 转成当前语言再外显，不要直接贴。
- 判颜色/逻辑用**原始中文串**（如 `_phaseColor` 按中文关键字匹配），展示才用译文。

## 暗色模式（dark mode）铁律

- 表面底色走主题 token（`C.white` / `C.surfaceFillStrong` / `C.bg` / `C.mapBg`…），
  不要 `Colors.white`；`Colors.white.withValues(alpha: …)` 用于彩色横幅上的按钮，
  不算表面。
- `surfaceTint(Colors.white)` / `surfaceTint(const Color(0xFF…))` 在材质关闭时
  **原样返回常量**，深色下就是一块白板 —— 已由 `tool/check_dark_mode.py` 拦。

## 测试与 CI

- CI 只跑 `ci-test.yml` 里显式列出的测试文件（见上面那条 `grep`）。**新增测试后
  要手动把 `flutter test test/xxx_test.dart` 加进该文件**，否则永远不会跑。
- `main` 上存在若干**与本仓库特性无关的历史失败测试**
  （`widget_test.dart`/`unread_badge_test.dart`/`station_filter_test.dart` 等，
  部分因生成物不同步或测试落后于实现）。判断回归时，先 `git stash` 对比基线，
  别把这些算到自己的改动头上。

## 远程名单：封禁（黑）与授权（白）

两个名单是**同一套架构、方向相反**，改一个时对照另一个：

|  | 封禁 `lib/blacklist.dart` | 授权 `lib/agent_allow.dart` |
|---|---|---|
| 数据 | `docs/assets/blacklist.json` | `docs/assets/agent_allow.json` |
| 方向 | 命中**就拦** | 命中**才放** |
| 拉不到 | 失败**放行**（安全底线：不误封） | 默认**拒绝**（安全底线：不误开） |
| 键 | `blacklistCacheJson` / `…CheckedAt` | `agentAllowCacheJson` / `…CheckedAt` |

- 两端都往 `https://aprslocus.theez.top/assets/…` 取，本地缓存 + 6 小时节流；
  **只要曾成功拉到过名单，断网仍按缓存判定**（否则离线会把已授权/正常用户误伤）。
- 白名单条目 `call` 必须含**至少一个非通配符字符**，否则整条作废（防手滑写 `*`
  把智能体对所有人开放）；裸呼号 = 授权该人及其所有 SSID。
- 申请：下载承诺书（`docs/assets/agent_commitment_{zh,en}.txt`）→ 发送到
  `mc081208@163.com`（写在 `AgentAllow.kApplyEmail`）→ 审核后加入 JSON。
- 静态检查：`tool/check_blacklist.py` 与 `tool/check_agent_allow.py`（后者额外核对
  取址、申请邮箱、"默认拒绝"说明）。名单新键须加进 `tool/check_backup_keys.py`
  的 EXCLUDE（缓存不该随备份搬走）。
- 智能开关的两道闸：先签 `agent_notice`（`pendingAgentNotice`），再查授权
  （`pendingAgentAuth` → `AgentAuthPage`）。授权页在 `AppState.recheckAgentAllow`
  确认未授权后会**强制关闭**已开的智能体（防备份/旧版本绕过）。

## WLAN 电台热点不抢默认路由（issue #35）

连上 IC-705 等电台的 Wi-Fi 热点后，若系统把这条**无外网**的热点当成默认上网
通道，会暂停移动数据 → APRS-IS 断线（表现为「一连电台，APRS-IS 就掉」）。修法：

- `Ic705NetworkManager.kt`：Android 10+ 用 `ConnectivityManager.requestNetwork`
  申请一条**不含 `NET_CAPABILITY_INTERNET`** 的 Wi-Fi 网络（`WifiNetworkRequest`
  思路），系统便不把它当默认路由；个别机型仍抢默认时，兜底把**本进程**绑到一条
  有外网的网络（`bindProcessToNetwork`）保证 APRS-IS。低版本（API<29）退回
  「从已连接网络里挑 Wi-Fi」。
- Dart：`IcomLanAndroidNetwork.requestRadioNetwork/findRadioNetwork/…`；
  `IcomLanLinkIo.startCapture` 先解析电台 Wi-Fi 的 IPv4，再交给
  `IcomLanRxSession(bindLocalAddress:)`，由 `IcomLanUdpChannel` 在
  `RawDatagramSocket.bind` 时**按该地址绑定** → 电台流量走 Wi-Fi、APRS-IS 走
  移动数据。`_teardown` 里 `releaseRadioNetwork`。
- 通道方法：`findRadioNetwork` / `requestRadioNetwork` / `releaseRadioNetwork` /
  `status`（诊断 `defaultIsWifi`/`defaultHasInternet`/`splitRouting`）。
- 测试 `test/icom_lan_android_network_test.dart` + `test/icom_lan_udp_channel_test.dart`
  已进 CI（真机才暴露，编译/analyze 全绿）。

## WLAN 直连的射频中继路径（issue #35 的另一半）

「WLAN 电台直连」子页（`lib/ic705_device_page.dart`）**没有**独立的中继路径配置：
WLAN 直连本身就是**音频来源**的一个变体（`audio.config.source == AudioSource.icomLan`），
发射路径来自共享的 `audio.config.path`（见 `AppState.rfPathOf` / `txPath`）。
因此改中继路径 = 改 `audio.config.path`，与声卡音频页**同一个键**。

- 页面上的输入框「射频中继路径」用现成 l10n 键 `s.kissRfPath` / `s.kissRfPathTip`
  （语义通用，TNC 页 / 音频页同款），无需新增 ARB。
- 存回 `c.path`（`_saveConfig`），失焦/回车落定（`_focuses` 里已含 `_pathFocus`）。
- 回归测试 `test/beacon_format_test.dart`「音频/WLAN 来源：txPath 跟随 audio.config.path」。
- 手册 `tool/manual_bodies2.py` 的 SETTINGS_INTRO['WLAN 电台直连'] 与
  `docs/{,zh-TW/,en/}manual/settings.html` 已同步该设置项。
  ⚠️ 不要直接跑 `gen_manual_pages.py` 全量重生成：脚本产出的资源版本仍是
  `?v=6`，而仓库要求 `?v=7`（check_site 会拦），会连带回退一堆无关改动；
  手改对应的 settings.html 段落后用 `python3 tool/check_site.py` 校验即可。


