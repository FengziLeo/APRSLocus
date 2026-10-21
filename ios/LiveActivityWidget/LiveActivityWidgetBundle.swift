//
//  LiveActivityWidgetBundle.swift
//  LiveActivityWidget
//
//  灵动岛扩展的入口。只挂一条实时活动（APRSlocus 的常驻状态），
//  没有桌面小组件 —— 这里就不要再加别的 Widget。
//

import SwiftUI
import WidgetKit

@main
struct LiveActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    APRSLocusLiveActivity()
  }
}
