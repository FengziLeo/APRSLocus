//
//  APRSLocusActivityAttributes.swift
//  APRSLocus
//
//  灵动岛（Live Activity）的数据契约。
//
//  这个文件同时编到主应用与 LiveActivityWidget 扩展两个 target 里 —— 它们必须
//  是**同一份类型**，否则 ActivityKit 匹配不到（扩展里的 attributes 类型与主应用
//  启动活动时的类型不是同一个符号，活动就不会出现在灵动岛上）。
//
//  内容全部来自 Dart 侧（已经本地化过）：`call` 是呼号，`line` 是常驻通知那行
//  完整文字，`short` 是状态栏里那行超短文本，`endsAt` 非空时画系统倒计时。
//

import ActivityKit
import Foundation

@available(iOS 16.1, *)
public struct APRSLocusActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    /// 当前呼号（含 SSID），例如 `BG7LZQ-7`。
    public var call: String
    /// 完整状态行，与常驻通知同一句。
    public var line: String
    /// 超短文本（`32km/h` / `✉3` / `--`），倒计时优先。
    public var short: String
    /// 倒计时的结束时刻；为 nil 表示这条活动不画计时器。
    public var endsAt: Date?

    public init(call: String, line: String, short: String, endsAt: Date?) {
      self.call = call
      self.line = line
      self.short = short
      self.endsAt = endsAt
    }
  }

  public init() {}
}
