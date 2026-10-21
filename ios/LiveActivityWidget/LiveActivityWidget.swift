//
//  LiveActivityWidget.swift
//  LiveActivityWidget
//
//  灵动岛与锁屏上那条活动的外观。
//
//  设计上有两条规矩：
//   1. 文字全部来自 Dart（已经按界面语言本地化过），这里不写死任何一句话；
//   2. 颜色只用系统给的两档（主/次），深浅色外观由系统自己决定。
//
//  倒计时用 `Text(timerInterval:countsDown:)`，交给系统画：每秒重开一次活动
//  只为了改一个字，既费电又会被系统限流。
//

import ActivityKit
import SwiftUI
import WidgetKit

struct APRSLocusLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: APRSLocusActivityAttributes.self) { context in
      // 锁屏 / 通知中心那条
      LockScreenView(state: context.state)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 3) {
            Image(systemName: "dot.radiowaves.left.and.right")
              .font(.caption2)
            Text(context.state.call.isEmpty ? "APRSLocus" : context.state.call)
              .font(.caption2.weight(.semibold))
              .lineLimit(1)
          }
          .foregroundStyle(.secondary)
        }
        DynamicIslandExpandedRegion(.trailing) {
          TrailingValue(state: context.state)
            .font(.caption.monospacedDigit().weight(.semibold))
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.line)
            .font(.caption2)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.caption2)
      } compactTrailing: {
        CompactValue(state: context.state)
          .font(.caption2.monospacedDigit())
      } minimal: {
        Image(systemName: "dot.radiowaves.left.and.right")
          .font(.caption2)
      }
      .keylineTint(.cyan)
    }
  }
}

private struct LockScreenView: View {
  let state: APRSLocusActivityAttributes.ContentState

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "dot.radiowaves.left.and.right")
        .font(.title3)
        .foregroundStyle(.cyan)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.call.isEmpty ? "APRSLocus" : state.call)
          .font(.footnote.weight(.semibold))
        Text(state.line)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      TrailingValue(state: state)
        .font(.footnote.monospacedDigit().weight(.semibold))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

/// 有结束时刻就画系统倒计时，否则画那行超短文本。
private struct TrailingValue: View {
  let state: APRSLocusActivityAttributes.ContentState

  var body: some View {
    if let endsAt = state.endsAt {
      Text(timerInterval: Date()...endsAt, countsDown: true)
        .multilineTextAlignment(.trailing)
    } else {
      Text(state.short.isEmpty ? "--" : state.short)
    }
  }
}

/// 胶囊右端空间很小：倒计时只留 `m:ss` 的形状，其余照旧。
private struct CompactValue: View {
  let state: APRSLocusActivityAttributes.ContentState

  var body: some View {
    if let endsAt = state.endsAt {
      Text(timerInterval: Date()...endsAt, countsDown: true)
    } else {
      Text(state.short.isEmpty ? "--" : state.short)
        .lineLimit(1)
    }
  }
}
