// HTTP 发送工厂（条件导入）
//   - io 平台：dart:io HttpClient
//   - Web：明确不支持（自定义翻译接口受 CORS 限制）
import 'dart:typed_data';

import 'http_send_io.dart'
    if (dart.library.html) 'http_send_web.dart' as impl;

export 'http_send_io.dart'
    if (dart.library.html) 'http_send_web.dart'
    show HttpStatusError, httpAvailable;

Future<String> httpSend(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  String? body,
  Duration timeout = const Duration(seconds: 20),
}) =>
    impl.httpSend(method, uri, headers: headers, body: body, timeout: timeout);

/// 流式（按行）发送：智能体「逐字回复」用。Web 上抛 UnsupportedError。
///
/// 与 [httpSend] 的区别见 `http_send_io.dart`：不等整段收完，收到一行吐一行。
Stream<String> httpSendLines(
  String method,
  Uri uri, {
  Map<String, String>? headers,
  String? body,
  Duration timeout = const Duration(seconds: 30),
}) =>
    impl.httpSendLines(method, uri,
        headers: headers, body: body, timeout: timeout);

/// 二进制 GET（地图瓦片下载）。Web 上抛 UnsupportedError。
Future<Uint8List> httpGetBytes(
  Uri uri, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 20),
}) =>
    impl.httpGetBytes(uri, headers: headers, timeout: timeout);

Future<bool> isHttpAvailable() => impl.httpAvailable();
