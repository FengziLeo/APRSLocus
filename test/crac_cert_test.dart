// 操作证书查询的解析与本地记录回归。
//
// 现场看不到的东西全在这里：三张表的字段各不相同（内地是 certificateNo/type，
// 香港是 certNo/certValidityDate，外国来访者是 certificateNo/validThrough），
// 解析写错不会编译失败，只会表现成「查到了但一片空白」；本地记录解析写错，
// 表现成「徽章指向一个已经不是本人的呼号」。所以钉在 CI。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aprslocus/crac_cert.dart';

Map decoded(String json) => jsonDecode(json) as Map;

void main() {
  test('内地表：类别、证书编号、通过地点都摊平出来', () {
    final records = parseCracRecords(decoded('''
{
 "res": {
  "prcList": [
   {"name": "董俊志", "type": "A", "certificateNo": "A4500000570",
    "homeCall": "", "passDate": "2025-02-13", "passAddr": "广西壮族自治区",
    "issueDate": "2025.08.20", "idCarNumber": "440******10"}
  ],
  "hkList": [], "fgList": []
 }
}'''));
    expect(records.length, 1);
    final r = records.first;
    expect(r.name, '董俊志');
    expect(r.type, 'A');
    expect(r.typeLabel, 'A 类');
    expect(r.certNo, 'A4500000570');
    expect(r.passDate, '2025-02-13');
    expect(r.region, '广西壮族自治区');
    expect(r.issueDate, '2025.08.20');
    expect(r.idMasked, '440******10');
    expect(r.call, '');
  });

  test('香港表与外国来访者表用各自的字段名', () {
    final records = parseCracRecords(decoded('''
{
 "res": {
  "prcList": [],
  "hkList": [
   {"name": "陳大文", "homeCall": "VR2AAA", "certNo": "HK123",
    "issueDate": "2020-01-02", "certValidityDate": "2030-01-01", "idCard": "A1****9"}
  ],
  "fgList": [
   {"name": "John", "homeCall": "JA1XYZ", "certificateNo": "FG7",
    "origin": "Japan", "validThrough": "2026-12-31"}
  ]
 }
}'''));
    expect(records.length, 2);
    final hk = records[0];
    expect(hk.call, 'VR2AAA');
    expect(hk.certNo, 'HK123');
    expect(hk.validThrough, '2030-01-01');
    expect(hk.typeLabel, '', reason: '香港证书没有 A/B/C 类别');
    final fg = records[1];
    expect(fg.call, 'JA1XYZ');
    expect(fg.certNo, 'FG7');
    expect(fg.region, 'Japan');
    expect(fg.validThrough, '2026-12-31');
  });

  test('空表与缺字段都不炸', () {
    expect(parseCracRecords(decoded('{}')), isEmpty);
    expect(parseCracRecords(decoded('{"res": {"prcList": []}}')), isEmpty);
    final records = parseCracRecords(decoded('{"res": {"prcList": [{}]}}'));
    expect(records.length, 1);
    expect(records.first.name, '');
    expect(records.first.typeLabel, '');
  });

  test('本地记录能存能读，呼号大写', () {
    const info = CracCertInfo(
      call: 'bg7lzq',
      name: '董俊志',
      type: 'A',
      certNo: 'A4500000570',
      at: '2026-10-21 08:00',
    );
    final back = CracCertInfo.fromJson(info.encode());
    expect(back, isNotNull);
    expect(back!.call, 'BG7LZQ');
    expect(back.type, 'A');
    expect(back.typeLabel, 'A 类');
    expect(back.certNo, 'A4500000570');
    expect(back.at, '2026-10-21 08:00');
  });

  test('记录坏了就当没查过，不抛异常', () {
    expect(CracCertInfo.fromJson(''), isNull);
    expect(CracCertInfo.fromJson('不是 JSON'), isNull);
    expect(CracCertInfo.fromJson('[]'), isNull);
    expect(CracCertInfo.fromJson('{"name": "没有呼号"}'), isNull,
        reason: '没有呼号的记录不能挂到任何呼号上');
  });

  test('设置页那一小块：姓名与证书编号都打码', () {
    // 姓名只留第一个字
    expect(maskCracName('董俊志'), '董**');
    expect(maskCracName('张三'), '张*');
    expect(maskCracName('李'), '李');
    expect(maskCracName('  '), '');
    // 证书编号前后各留几位，中间一律星号；长度不同留的位数不同
    expect(maskCracCertNo('A4500000570'), 'A450***0570');
    expect(maskCracCertNo('12345678'), '12****78');
    expect(maskCracCertNo('123456'), '12**56');
    expect(maskCracCertNo('1234'), '1***');
    expect(maskCracCertNo(''), '');
  });
}
