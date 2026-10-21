// SPDX-License-Identifier: GPL-2.0-or-later
/// ─── 操作证书查询（CRAC 公开查询接口）───
///
/// 用途：按「姓名 + 完整证书编号」查一次操作证书。查到的记录留在本机，
/// 显示在电台页的「认证信息」那块。
///
/// 接口事实（照抄会踩的坑都记在这里）：
///   * 地址只有 `/CRAC/app/...` 这个前缀能用，`/CRAC/a/...` 会 302 到登录页；
///   * 请求体必须是**嵌套** JSON `{"req":{...}}`；网页里看到的 `req=<json串>`
///     是它自己的前端拼法，照抄会被后端判 400/415；
///   * `code: 10000` 成功，`10010` 查无此人，其余按失败处理；
///   * 返回三张表：内地（prcList）/ 香港（hkList）/ 外国来访者临时（fgList），
///     字段各不相同，这里统一成 [CracCertRecord]；
///   * 内地表的证书类别在 `type` 里只是 `A`/`B`/`C` 一个字符，界面拼「类」。
///
/// 这是**开发人员自测**用的查询：它会把你填的姓名与证件号发到第三方接口，
/// 页面里必须把这件事写出来。查询结果只留在本机偏好里，不上传。
library;

import 'dart:convert';

import 'net/http_send.dart';

/// 查询接口。
const String cracCertEndpoint =
    'https://zhipu.allspectrum.cn:9528/CRAC/app/businessSupport/'
    'cracOperationCert/getOperCertByParamWeb';

/// 一张表里的一条记录（三张表的字段已经摊平成同一形状，空值就是空串）。
class CracCertRecord {
  const CracCertRecord({
    required this.table,
    required this.name,
    this.type = '',
    this.certNo = '',
    this.call = '',
    this.passDate = '',
    this.issueDate = '',
    this.region = '',
    this.validThrough = '',
    this.idMasked = '',
  });

  /// 表名（内地操作证书 / 香港操作证书 / 外国来访者临时操作证书）。
  final String table;
  final String name;

  /// 操作类别：内地表里是 `A`/`B`/`C`，香港与外国表里没有。
  final String type;
  final String certNo;

  /// 证书记录里登记的呼号（内地表多数为空）。
  final String call;
  final String passDate;
  final String issueDate;
  final String region;

  /// 有效期（香港 / 外国来访者表）。
  final String validThrough;

  /// 后端自己打过码的证件号，例如 `440******10`。
  final String idMasked;

  /// 证书类别的中文写法（`A 类`）；没有类别就是空串。
  String get typeLabel => type.isEmpty ? '' : '$type 类';

  Map<String, dynamic> toJson() => {
        'table': table,
        'name': name,
        'type': type,
        'certNo': certNo,
        'call': call,
        'passDate': passDate,
        'issueDate': issueDate,
        'region': region,
        'validThrough': validThrough,
        'idMasked': idMasked,
      };

  static CracCertRecord fromJson(Map<String, dynamic> json) => CracCertRecord(
        table: json['table']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
        certNo: json['certNo']?.toString() ?? '',
        call: json['call']?.toString() ?? '',
        passDate: json['passDate']?.toString() ?? '',
        issueDate: json['issueDate']?.toString() ?? '',
        region: json['region']?.toString() ?? '',
        validThrough: json['validThrough']?.toString() ?? '',
        idMasked: json['idMasked']?.toString() ?? '',
      );
}

/// 本机保存的验证结果：哪个呼号、查到的姓名、证书类别与编号、查的时间。
///
/// 一张证书只认一个呼号：呼号改了或换了人，徽章就不该再挂在那里，
/// 所以呼号跟记录一起存，显示前先对一遍。
class CracCertInfo {
  const CracCertInfo({
    required this.call,
    required this.name,
    this.type = '',
    this.certNo = '',
    this.at = '',
  });

  final String call;
  final String name;

  /// `A`/`B`/`C`；香港与外国表没有类别，存空串。
  final String type;
  final String certNo;

  /// 查询时间（`yyyy-MM-dd HH:mm`）。
  final String at;

  String get typeLabel => type.isEmpty ? '' : '$type 类';

  Map<String, dynamic> toJson() => {
        'call': call,
        'name': name,
        'type': type,
        'certNo': certNo,
        'at': at,
      };

  String encode() => jsonEncode(toJson());

  /// 解析失败（旧版本、手改坏了）一律当「没有验证过」，不抛异常。
  static CracCertInfo? fromJson(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final call = (decoded['call'] ?? '').toString().trim();
      if (call.isEmpty) return null;
      return CracCertInfo(
        call: call.toUpperCase(),
        name: (decoded['name'] ?? '').toString(),
        type: (decoded['type'] ?? '').toString(),
        certNo: (decoded['certNo'] ?? '').toString(),
        at: (decoded['at'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// 把姓名打码：留第一个字，其余每个字换成 `*`。
///
/// 设置页那一小块「已认证」要在别人看得见的地方出现（截图、给别人看屏幕），
/// 姓名与证书编号都只留一点点，够认就行。
String maskCracName(String name) {
  final t = name.trim();
  if (t.isEmpty) return '';
  if (t.length == 1) return t;
  return t[0] + '*' * (t.length - 1);
}

/// 把证书编号打码：长度够就前后各留几位，中间一律 `*`。
String maskCracCertNo(String no) {
  final t = no.trim();
  if (t.isEmpty) return '';
  if (t.length <= 4) return t[0] + '*' * (t.length - 1);
  if (t.length <= 8) {
    return t.substring(0, 2) + '*' * (t.length - 4) + t.substring(t.length - 2);
  }
  return t.substring(0, 4) + '*' * (t.length - 8) + t.substring(t.length - 4);
}

/// 一次查询的结果。
class CracCertResult {
  const CracCertResult({
    required this.status,
    this.records = const [],
    this.message = '',
  });

  final CracCertStatus status;
  final List<CracCertRecord> records;

  /// 失败时的后端原话（不翻译，只用来排查）。
  final String message;

  bool get ok => status == CracCertStatus.found;
}

enum CracCertStatus {
  /// 查到记录。
  found,

  /// 后端明确回答查无此人（code 10010）。
  notFound,

  /// 网络不通 / 接口报错 / 返回体不是 JSON。
  failed,
}

/// 发一次查询：只认「姓名 + 完整证书编号」这一种。
///
/// 后端还支持用身份证件号查，但**本应用不提供这条路**：证件号是比操作证
/// 敏感得多的东西，为了给呼号挂一枚徽章去填它，不值得。`idCarNumber` 仍然
/// 按接口形状发空串。
Future<CracCertResult> queryCracCert({
  required String name,
  required String certNo,
  Duration timeout = const Duration(seconds: 25),
}) async {
  final body = jsonEncode({
    'req': {
      'page_no': '1',
      'page_size': '100',
      'name': name.trim(),
      'certificateNo': certNo.trim(),
      'idCarNumber': '',
    },
  });

  String text;
  try {
    text = await httpSend(
      'POST',
      Uri.parse(cracCertEndpoint),
      headers: {
        'Content-Type': 'application/json',
        'X-Requested-With': 'XMLHttpRequest',
        'Origin': 'https://zhipu.allspectrum.cn:9528',
        'Referer':
            'https://zhipu.allspectrum.cn:9528/CRAC/crac/pages/list_cert.html',
      },
      body: body,
      timeout: timeout,
    );
  } catch (error) {
    return CracCertResult(
      status: CracCertStatus.failed,
      message: '$error',
    );
  }

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return CracCertResult(
      status: CracCertStatus.failed,
      message: '返回内容不是 JSON',
    );
  }
  if (decoded is! Map) {
    return const CracCertResult(
      status: CracCertStatus.failed,
      message: '返回内容格式不对',
    );
  }

  final code = int.tryParse('${decoded['code']}') ?? 0;
  if (code == 10010) {
    return const CracCertResult(status: CracCertStatus.notFound);
  }
  if (code != 10000) {
    return CracCertResult(
      status: CracCertStatus.failed,
      message: '${decoded['msg'] ?? '未知原因'}（code=$code）',
    );
  }

  final records = parseCracRecords(decoded);
  if (records.isEmpty) {
    return const CracCertResult(status: CracCertStatus.notFound);
  }
  return CracCertResult(status: CracCertStatus.found, records: records);
}

/// 把三张表摊平成记录列表（顺序：内地 → 香港 → 外国来访者）。
List<CracCertRecord> parseCracRecords(Map decoded) {
  final res = decoded['res'];
  if (res is! Map) return const [];
  final out = <CracCertRecord>[];

  String s(Map row, String key) => (row[key] ?? '').toString().trim();

  for (final row in (res['prcList'] as List? ?? const [])) {
    if (row is! Map) continue;
    out.add(CracCertRecord(
      table: '内地操作证书',
      name: s(row, 'name'),
      type: s(row, 'type'),
      certNo: s(row, 'certificateNo'),
      call: s(row, 'homeCall'),
      passDate: s(row, 'passDate'),
      issueDate: s(row, 'issueDate'),
      region: s(row, 'passAddr'),
      idMasked: s(row, 'idCarNumber'),
    ));
  }
  for (final row in (res['hkList'] as List? ?? const [])) {
    if (row is! Map) continue;
    out.add(CracCertRecord(
      table: '香港操作证书',
      name: s(row, 'name'),
      certNo: s(row, 'certNo'),
      call: s(row, 'homeCall'),
      issueDate: s(row, 'issueDate'),
      validThrough: s(row, 'certValidityDate'),
      idMasked: s(row, 'idCard'),
    ));
  }
  for (final row in (res['fgList'] as List? ?? const [])) {
    if (row is! Map) continue;
    out.add(CracCertRecord(
      table: '外国来访者临时操作证书',
      name: s(row, 'name'),
      certNo: s(row, 'certificateNo'),
      call: s(row, 'homeCall'),
      region: s(row, 'origin'),
      validThrough: s(row, 'validThrough'),
    ));
  }
  return out;
}
