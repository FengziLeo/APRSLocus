# 智能体工具缺口与路线图（对照当前代码核实）

> 这份是根据「智能体能力审计」逐条对照 `lib/agent_tools.dart` 核实后的结论与优先级。
> **更新**：路线图已按 P0→P2 落地（工具数 25 → 44）。P3 中已做的见下；未做的保留说明。

## 本轮已实现（新增 19 个工具）

- **自身位置/权限可见**：`get_app_state` 补 `my_lat/my_lng/my_has_fix/my_fix_min_ago`
  + `permissions:{allow_send,allow_settings,agent_enabled,agent_notice_accepted,data_notice_accepted}`。
- **群成员与运维**：`list_groups` 补成员（呼号/状态/是否被屏蔽）；
  `update_group`（改名/加人/踢人）、`join_group`、`leave_group`、`dismiss_group`。
- **联系人**：`list_contacts`（只读）、`set_favorite`。
- **台站屏蔽**：`set_station_ignored`（本地不上图，原始数据包仍接收）。
- **状态文本**：`set_status_text`。
- **任务**：`update_task`（内容/触发方式/间隔/绝对时刻）、`list_task_runs`、
  `clear_task_runs`；`AgentTask` 新增 `runAt` 绝对时刻；任务执行记录落盘。
- **传感器**：`get_sensors`（HR/步数/电量/速度/航向/里程，带「多久前」）。
- **台站数据**：`get_station_packets`（原始帧 + 转发路径）。
- **轨迹**：`get_track`、`export_track_gpx`（返回 GPX 文本，不落盘）。
- **距离**：`distance_between`（大圆距离 + 初始方位）。
- **位置模拟**：`set_my_position`、`clear_my_position`（需已签数据告知）。
- **消息增强**：`read_messages` 支持关键词/时间段（`query`/`since`/`until`）+
  如实报告 `marked_read`；送达回执 `acked`；`broadcast_message` 群发。

## P3 — 仍未做（需主人授权 / 外部依赖）

- 轨迹导出保存到文件或分享（当前 `export_track_gpx` 只回文本）。
- 发射天气/物体/遥测等非文本包（APRS 规范工作量大，且是真实发射）。
- HTTP 抓取（SSRF/隐私风险高，默认不建议给）。
- 硬件参数（频率/速率/声卡/PTT）：属设备页配置，不适合走聊天工具。

## 设计原则（沿用现有约定）

- **读写分离**：只读工具免确认；写工具必须 `mutating: true` + 按
  `allow_send` / `allow_settings` 授权 + 聊天框内联确认。
  （`broadcast_message` 已纳入 `_isSendingTool`，受 `allow_send` 约束。）
- **能力可发现**：能用 `get_app_state` 暴露的现状，就不要再让模型靠猜。
- **不做越权**：智能体不能自行接受「数据与网络使用告知」「智能体使用告知」，
  也不能替用户改权限——这些必须由人点。
