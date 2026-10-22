import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

// ─── 平台能力（哪些原生链路在本平台真的可用）───
//
// iOS 原生侧（`ios/Runner/`）现在实现了：定位、运动传感器、蓝牙心率带、
// 声卡音频（AFSK）。所以这些选项在 iOS 上**可用**，不再置灰。
//
// **仍然不可用的是 TNC / PKWDWPL**：iOS 对第三方 App 不开放经典蓝牙 SPP
// （RFCOMM）与 USB 串口（除非走 MFi 认证配件），系统层面就做不到 ——
// 这不是「还没实现」，而是「系统不允许」。所以这两个选项在 iOS 上置灰，
// 并明确说明原因（见 iosTncUnsupported）。
//
// 这里只判断「原生链路有没有实现/能不能实现」，不判断「设备/权限是否就绪」
// （那是运行时 `supported` 的职责，两者互补）。

/// 当前是否是 iOS（Web 不算）。
bool get isIOSPlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// TNC（经典蓝牙 SPP / USB 串口）在本平台是否可用。
///
/// iOS 对**非 MFi** 配件不开放 RFCOMM/USB 串口，系统层面无法实现 —— 不可用。
/// 其余平台（Android / Windows / Linux / macOS）沿用原有实现。
bool get tncPlatformSupported => !isIOSPlatform;

/// 直连 TCP 的报文链路（APRS-IS / APRSNETCN SERVER）在本平台是否可用。
///
/// Web 没有裸 TCP：主链路在 Web 上走的是 WebSocket 网关（另一回事），副链路
/// 只有 14580 明文端口，摆一个永远连不上的开关不如不摆。
bool get tcpLinkPlatformSupported => !kIsWeb;

/// 蓝牙心率带（BLE 标准心率服务）在本平台是否可用：Android / iOS 有原生实现。
bool get bleHrPlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// 运动传感器（加速度计 / 指南针）在本平台是否可用：Android / iOS 有原生实现。
bool get motionPlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// 「GPS 采样间隔」在本平台是否真的有效。
///
/// 只有 Android 能控：`LocationManager.requestLocationUpdates` 的 `minTime`
/// 就是采样间隔。iOS 的 CoreLocation 没有「定时采样」这一说（由系统按精度
/// 与移动状态自己决定），桌面走的是 IP 网络定位。摆一个改了不生效的档位
/// 比不摆更糟，所以这些平台干脆不显示。
bool get gpsSamplingPlatformSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
