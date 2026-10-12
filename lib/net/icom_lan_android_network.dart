// SPDX-License-Identifier: GPL-2.0-or-later
// See LICENSING.md: this file is additionally available under GPL-2.0-or-later.

library;

import 'dart:io';
import 'package:flutter/services.dart';

/// Android 平台 IC-705 Wi-Fi 网络状态快照。
class IcomLanAndroidNetworkInfo {
  const IcomLanAndroidNetworkInfo({
    required this.status,
    this.networkHandle,
    this.ipv4Address,
  });

  final String status;
  final int? networkHandle;
  final String? ipv4Address;

  bool get isAvailable => status == 'AVAILABLE';

  @override
  String toString() =>
      'IcomLanAndroidNetworkInfo(status=$status, networkHandle=$networkHandle, ipv4=$ipv4Address)';
}

/// Android 专属网络选择与适配工具（对应 mod 的 `android/Ic705AndroidNetwork.kt`）。
///
/// ## 为什么需要它（issue #35）
///
/// IC-705 热点没有外网。若把它当默认上网通道，Android 会暂停移动数据，
/// APRS-IS 就断了。修法：Android 10+ 向系统申请一条**不含 INTERNET 能力**的
/// Wi-Fi 网络（本地网络，不抢默认路由），并把电台 UDP 套接字绑定到这条网络的
/// IPv4 上 —— 电台流量走 Wi-Fi，APRS-IS 走移动数据，两条路互不干扰。
///
/// 低版本（API < 29）没有这套语义，退回「从已连接网络里挑 Wi-Fi」。
class IcomLanAndroidNetwork {
  IcomLanAndroidNetwork._();

  static const MethodChannel channel =
      MethodChannel('com.aprslocus/ic705_network');

  /// 查找当前附着的 Wi-Fi 网络。非 Android 平台返回 null。
  static Future<IcomLanAndroidNetworkInfo?> findRadioNetwork({
    MethodChannel? overrideChannel,
  }) async {
    final activeChannel = overrideChannel ?? channel;
    if (!Platform.isAndroid && overrideChannel == null) return null;
    try {
      final res =
          await activeChannel.invokeMapMethod<String, dynamic>('findRadioNetwork');
      if (res == null) return null;
      return IcomLanAndroidNetworkInfo(
        status: res['status'] as String? ?? 'UNKNOWN',
        networkHandle: (res['networkHandle'] as num?)?.toInt(),
        ipv4Address: res['ipv4Address'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// 向系统申请一条「只连本地、不抢默认路由」的 Wi-Fi 网络（Android 10+）。
  ///
  /// 连接电台**之前**调用。它不会立刻返回可用网络（系统授权/选择可能要一会儿），
  /// 调用方随后用 [findRadioNetwork] 轮询即可。低版本是空操作。
  static Future<void> requestRadioNetwork({MethodChannel? overrideChannel}) async {
    final activeChannel = overrideChannel ?? channel;
    if (!Platform.isAndroid && overrideChannel == null) return;
    try {
      await activeChannel.invokeMethod('requestRadioNetwork');
    } catch (_) {}
  }

  /// 释放上面申请到的本地 Wi-Fi 网络（断开电台后调用，别一直占着）。
  static Future<void> releaseRadioNetwork({MethodChannel? overrideChannel}) async {
    final activeChannel = overrideChannel ?? channel;
    if (!Platform.isAndroid && overrideChannel == null) return;
    try {
      await activeChannel.invokeMethod('releaseRadioNetwork');
    } catch (_) {}
  }

  /// 诊断：电台 Wi-Fi 是否在抢默认网络（用于验证 issue #35 是否真修好）。
  static Future<Map<String, dynamic>?> status({MethodChannel? overrideChannel}) async {
    final activeChannel = overrideChannel ?? channel;
    if (!Platform.isAndroid && overrideChannel == null) return null;
    try {
      return await activeChannel.invokeMapMethod<String, dynamic>('status');
    } catch (_) {
      return null;
    }
  }
}

