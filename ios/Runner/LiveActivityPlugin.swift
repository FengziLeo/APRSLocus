//
//  LiveActivityPlugin.swift
//  APRSLocus
//
//  灵动岛 / 锁屏实时活动的原生实现（iOS 16.1+）。
//
//  与 Android 16 的实时更新（状态栏胶囊）是同一件事的两个平台实现：Dart 侧
//  在 `lib/state.dart` 的 `_updateNotification` 里拼好一行状态，Android 走
//  常驻通知的提升，iOS 走这里的 Live Activity。
//
//  方法通道 `com.aprslocus/live_activity`
//    - `available` → Bool：这台机器能不能用（系统版本 + 用户在设置里关没关）
//    - `update`    → 参数 `{call, line, short, endsAtMs}`：没有活动就开一条，
//                    有就原地更新（只改内容，不重开 —— 重开会闪一下）
//    - `end`       → 结束并清掉这条活动
//
//  失败一律不抛给 Dart：灵动岛是「有就更好」的展示面，不能因为它让定位、
//  上报主流程受影响。
//

import ActivityKit
import Flutter
import UIKit

@available(iOS 16.1, *)
final class LiveActivityPlugin {
  static let channelName = "com.aprslocus/live_activity"

  private var activity: Activity<APRSLocusActivityAttributes>?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = LiveActivityPlugin()
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(ActivityAuthorizationInfo().areActivitiesEnabled)
    case "update":
      let args = call.arguments as? [String: Any] ?? [:]
      update(
        call: args["call"] as? String ?? "",
        line: args["line"] as? String ?? "",
        short: args["short"] as? String ?? "",
        endsAtMs: (args["endsAtMs"] as? NSNumber)?.doubleValue)
      result(nil)
    case "end":
      endAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 结束时刻用毫秒时间戳传：Dart 的 DateTime 与 Swift 的 Date 之间只有这个
  /// 形状不会因为时区/格式解析翻车。
  private func update(call: String, line: String, short: String, endsAtMs: Double?) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let endsAt = endsAtMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
    let state = APRSLocusActivityAttributes.ContentState(
      call: call, line: line, short: short, endsAt: endsAt)

    if let activity = activity {
      Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
      return
    }

    // 上一条活动可能是上一次运行留下的（被系统回收后仍在锁屏）：先接回来。
    if let existing = Activity<APRSLocusActivityAttributes>.activities.first {
      activity = existing
      Task { await existing.update(ActivityContent(state: state, staleDate: nil)) }
      return
    }

    do {
      activity = try Activity.request(
        attributes: APRSLocusActivityAttributes(),
        content: ActivityContent(state: state, staleDate: nil))
    } catch {
      // 用户关掉实时活动 / 系统不允许时走到这里，安静放弃。
      activity = nil
    }
  }

  private func endAll() {
    let running = Activity<APRSLocusActivityAttributes>.activities
    activity = nil
    Task {
      for item in running {
        await item.end(nil, dismissalPolicy: .immediate)
      }
    }
  }
}
