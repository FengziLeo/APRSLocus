// IC-705 WLAN 发射后置延迟（Post TX Delay）回归。
//
// 现场症状：WLAN 直连发报文时，电台在报文还没发完就松 PTT，对方收到的帧
// 缺尾、校验不过；手动按 PTT 把整条报文发完就正常。原因是音频包按实时节奏
// 送进电台、电台自己的抖动缓冲还压着最后一段，最后一个包刚发出就松 PTT，
// 缓冲里剩下的报尾没机会上空中。
//
// 修法是把「松 PTT」的时刻往后推：尾部静音 = 固定 60 ms + 用户配的延迟。
// 这几条都是纯逻辑（多几个包 / 数值夹取 / 序列化），错了不会编译失败，
// 只会表现成「延迟填了没用」或「旧配置一读就丢」，所以钉在 CI。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:aprslocus/net/icom_lan_pcm16.dart';
import 'package:aprslocus/net/icom_lan_protocol.dart';
import 'package:aprslocus/net/icom_lan_settings.dart';
import 'package:aprslocus/net/icom_lan_tx_audio_packetizer.dart';

IcomLanConfig config({int postTxDelayMs = 0}) => IcomLanConfig(
      host: '192.168.59.1',
      username: 'ic705',
      password: 'password',
      postTxDelayMs: postTxDelayMs,
    );

/// 12 kHz / 每包 240 样本 = 20 ms 一包。
int packetCount({required int trailingSilenceMs}) {
  final packetizer = IcomLanTxAudioPacketizer(senderId: 1, receiverId: 2);
  final datagrams = packetizer.packetize(
    Int16List(240)..fillRange(0, 240, 1000),
    trailingSilenceMs: trailingSilenceMs,
  );
  return datagrams.length;
}

void main() {
  test('默认后置延迟 200 ms', () {
    expect(IcomLanConfig.defaultPostTxDelayMs, 200);
    expect(config().postTxDelayMs, 200);
  });

  test('后置延迟按整包换成尾部静音，200 ms = 多 10 个包', () {
    // 240 样本音频 + 60 ms 前导 + (60 + 后置) ms 尾部，凑成整包。
    final base = packetCount(
        trailingSilenceMs: IcomLanTxAudioPacketizer.defaultTrailingSilenceMs);
    final delayed = packetCount(
        trailingSilenceMs: IcomLanTxAudioPacketizer.defaultTrailingSilenceMs +
            IcomLanConfig.defaultPostTxDelayMs);
    expect(base, 7);
    expect(delayed, 17);
    expect(delayed - base, 10, reason: '200 ms / 20 ms 一包 = 10 包');
  });

  test('后置延迟 0 时只剩固定的 60 ms 尾部静音', () {
    expect(
      packetCount(
          trailingSilenceMs: IcomLanTxAudioPacketizer.defaultTrailingSilenceMs +
              0),
      7,
    );
  });

  test('尾部静音那几包真是静音', () {
    final packetizer = IcomLanTxAudioPacketizer(senderId: 1, receiverId: 2);
    final datagrams = packetizer.packetize(
      Int16List(240)..fillRange(0, 240, 1000),
      trailingSilenceMs: 260,
    );
    for (final datagram in datagrams.skip(datagrams.length - 10)) {
      final packet = IcomLanAudioCodec.decode(datagram);
      expect(packet.pcmPayload.every((byte) => byte == 0), isTrue);
      expect(decodePcm16LittleEndian(packet.pcmPayload).every((v) => v == 0),
          isTrue);
    }
  });

  test('序列化带走后置延迟，读回来不丢', () {
    final json = config(postTxDelayMs: 600).toJson();
    expect(json['postTxDelayMs'], 600);
    expect(IcomLanConfig.fromJson(json).postTxDelayMs, 600);
  });

  test('旧配置（没有这个字段）读回默认值', () {
    final json = config().toJson()..remove('postTxDelayMs');
    expect(IcomLanConfig.fromJson(json).postTxDelayMs,
        IcomLanConfig.defaultPostTxDelayMs);
  });

  test('越界值夹到 0..2000', () {
    expect(
      IcomLanConfig.fromJson(config().toJson()..['postTxDelayMs'] = -50)
          .postTxDelayMs,
      0,
    );
    expect(
      IcomLanConfig.fromJson(config().toJson()..['postTxDelayMs'] = 99999)
          .postTxDelayMs,
      IcomLanConfig.maxPostTxDelayMs,
    );
  });

  test('copyWith 能单独改后置延迟', () {
    final next = config(postTxDelayMs: 100).copyWith(postTxDelayMs: 450);
    expect(next.postTxDelayMs, 450);
    expect(next.host, '192.168.59.1');
  });
}
