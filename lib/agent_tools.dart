/// ─── 智能体工具（把 AppState 暴露成模型可调用的函数）───
///
/// [agent.dart] 只认「工具 schema + 执行器」两块数据，具体的工具都在这里实现。
/// 之所以单独一个文件：工具要 import `state.dart`，而 `state.dart` 反过来又要
/// import `agent.dart`（读配置、把 Key 纳入出厂清理）—— 两者若合在一起就循环导入。
///
/// ## 设计取舍
///
/// * 工具集**刻意不含**连接/断开、重启、清空数据这类「一刀切且可能把用户挡在
///   门外」的操作。智能体的价值是「动动嘴就把常用设置调好」，不是替代遥控。
/// * 每个工具都做**参数校验**（枚举值、范围），非法参数直接把错误文本回给模型，
///   让模型自己纠正 —— 比抛异常中断整轮对话好。
/// * 展示给用户的 `note` 保持简洁（工具名 + 关键参数），给用户看的自然语言解释
///   由模型回复给出，避免为几十个工具各配一套本地化文案。
library;

import 'dart:convert';

import 'agent.dart';
import 'garmin.dart';
import 'group_chat.dart';
import 'map_math.dart';
import 'models.dart';
import 'state.dart';

/// 工具定义：名称、说明（给模型看）、参数 schema、是否有副作用。
class AgentToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// 有副作用、需要用户确认（发送/改设置=true；只读=false）
  final bool mutating;

  const AgentToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    this.mutating = false,
  });

  Map<String, dynamic> toSchema() => {
        'type': 'function',
        'function': {
          'name': name,
          'description': description,
          'parameters': parameters,
        },
      };
}

const _str = {'type': 'string'};
const _bool = {'type': 'boolean'};

/// 工具 schema 列表（发给模型的 tools 字段）
final List<AgentToolSpec> kAgentTools = [
  const AgentToolSpec(
    name: 'get_app_state',
    description:
        'Read the current app state: my callsign, connection status, tracking '
        '(beacon) settings, preference values, counts of stations/messages/'
        'groups, and the allowed value ranges for settings. Call this before '
        'changing settings or sending messages.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'list_groups',
    description: 'List chat groups the user has joined (name + group call).',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'search_stations',
    description:
        'Search recently heard APRS stations by callsign substring. Returns '
        'callsign, position and how long ago it was heard.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'Callsign or substring to search for.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Max results (default 20, max 50).',
        },
      },
      'required': ['query'],
    },
  ),
  const AgentToolSpec(
    name: 'list_stations',
    description:
        'List the most recently heard APRS stations (no query). Use this to get '
        'an overview of what is on the air.',
    parameters: {
      'type': 'object',
      'properties': {
        'limit': {
          'type': 'integer',
          'description': 'Max results (default 20, max 50).',
        },
      },
    },
  ),
  const AgentToolSpec(
    name: 'station_detail',
    description:
        'Get full detail for one station by exact callsign (or nearest match): '
        'position, symbol, comment, last heard, and how many track points.',
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Station callsign.'},
      },
      'required': ['call'],
    },
  ),
  const AgentToolSpec(
    name: 'read_messages',
    description:
        'Read recent chat messages (private and group). Optionally filter by a '
        'peer callsign or a group call. Never send anything: this is read-only. '
        'Use it to summarize conversations or answer "did anyone message me".',
    parameters: {
      'type': 'object',
      'properties': {
        'with': {
          'type': 'string',
          'description': 'Only messages to/from this callsign or group call.',
        },
        'limit': {
          'type': 'integer',
          'description': 'Max messages (default 20, max 50).',
        },
      },
    },
  ),
  const AgentToolSpec(
    name: 'send_message',
    description:
        'Send an APRS text message to a callsign, or to a group by its group '
        'call. Requires the "allow sending messages" permission.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'to': {'type': 'string', 'description': 'Destination callsign.'},
        'text': {'type': 'string', 'description': 'Message body.'},
      },
      'required': ['to', 'text'],
    },
  ),
  const AgentToolSpec(
    name: 'send_beacon_now',
    description: 'Immediately send one position beacon.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'set_tracking',
    description:
        'Enable/disable and configure automatic position reporting (beacon). '
        'Only the provided fields are changed. This enables or disables '
        'tracking directly; it is unrelated to "beacon auto-start on launch".',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'beacon_enabled': {
          'type': 'boolean',
          'description': 'true = enable tracking now, false = stop tracking.',
        },
        'beacon_interval_sec': {'type': 'integer', 'description': '5..3600'},
        'beacon_net_interval_sec': {
          'type': 'integer',
          'description': '30..3600 (network-only mode)',
        },
        'smart_beacon': _bool,
        'include_speed': _bool,
        'include_course': _bool,
        'include_battery': _bool,
        'include_hr': _bool,
        'include_steps': _bool,
        'include_trip_mileage': _bool,
        'include_total_mileage': _bool,
      },
    },
  ),
  const AgentToolSpec(
    name: 'set_station_filters',
    description: 'Change which stations are displayed and how many are kept.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'receive_others': _bool,
        'max_stations': {'type': 'integer', 'description': '0..5000'},
        'max_packets': {'type': 'integer', 'description': '0..20000'},
        'max_track_points': {'type': 'integer', 'description': '0..5000'},
        'retention_days': {'type': 'integer', 'description': '0..3650'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'set_preferences',
    description:
        'Change general preferences: language, dark mode, UI layout, UI '
        'scale, map type, interface material, weather, sensor assist, heat '
        'level. Only the provided fields change.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'language': {
          'type': 'string',
          'description': 'One of: zh, zh_TW, en, ja, es, id.',
        },
        'dark_mode': _bool,
        'ui_layout': {
          'type': 'string',
          'description': 'classic or sheet (2.0).',
        },
        'ui_scale': {'type': 'number', 'description': '0.85..1.3'},
        'map_type': _str,
        'ui_material': {
          'type': 'string',
          'description': 'none, glass, mica or glass_full.',
        },
        'weather': _bool,
        'sensor_assist': _bool,
        'heat_level': {'type': 'integer', 'description': '0..2'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'set_nickname',
    description: "Change the user's own callsign, SSID, symbol or comment.",
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'callsign': _str,
        'ssid': {'type': 'integer', 'description': '0..15'},
        'symbol': _str,
        'comment': _str,
      },
    },
  ),
  const AgentToolSpec(
    name: 'navigate',
    description:
        'Switch the app to a screen and optionally focus a station on the '
        'map: screen = map/stations/messages/data/settings; or pass focus_call '
        'to center the map on that station.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'screen': {
          'type': 'string',
          'description': 'map, stations, messages, data or settings.',
        },
        'focus_call': {
          'type': 'string',
          'description': 'Callsign to focus on the map.',
        },
      },
    },
  ),
  const AgentToolSpec(
    name: 'create_task',
    description:
        'Create a task that runs without the user present. "prompt" is what to '
        'do (written as if the user said it). "trigger" = "timer" (default) runs '
        'on a schedule: "interval_minutes" > 0 repeats it every N minutes, 0 runs '
        'it once. "trigger" = "message" runs the instruction each time a new APRS '
        'message arrives (and may run a burst of them back to back, so avoid '
        'long tasks). Use "list_tasks" first to avoid duplicates.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'The instruction to run at that time.',
        },
        'trigger': {
          'type': 'string',
          'enum': ['timer', 'message'],
          'description':
              '"timer" = on a schedule (default); "message" = on each new message.',
        },
        'interval_minutes': {
          'type': 'integer',
          'description':
              'timer trigger only: 0 = once, otherwise repeat every N minutes '
              '(min 1). Ignored for the message trigger.',
        },
      },
      'required': ['prompt'],
    },
  ),
  const AgentToolSpec(
    name: 'list_tasks',
    description: 'List the currently scheduled agent tasks.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'cancel_task',
    description: 'Cancel a scheduled task by its id (see "list_tasks").',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id from list_tasks.'},
      },
      'required': ['id'],
    },
  ),
  const AgentToolSpec(
    name: 'set_connection_server',
    description:
        'Change the APRS-IS server used for the internet link. Only the '
        'provided fields are changed. Setting a server does NOT connect — call '
        '"connect" afterwards if the user wants to go online. NOTE: the app '
        'does not provide or recommend any server; only use an address the user '
        'explicitly gave you.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'server': {
          'type': 'string',
          'description': 'Hostname, e.g. "rotate.aprs2.net".',
        },
        'port': {'type': 'integer', 'description': 'TCP port, usually 14580.'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'set_connection_source',
    description:
        'Enable or disable a data link source. "source" is one of: aprsis '
        '(internet), tnc, audio, pkwdwpl. Enabling a source makes it eligible; '
        'call "connect" to actually bring links up. Use get_app_state to see the '
        'current "sources" map.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'source': {
          'type': 'string',
          'description': 'aprsis, tnc, audio or pkwdwpl.',
        },
        'enabled': {
          'type': 'boolean',
          'description': 'true = enable this source, false = disable it.',
        },
      },
      'required': ['source', 'enabled'],
    },
  ),
  const AgentToolSpec(
    name: 'connect',
    description:
        'Bring up the connection to the APRS-IS server and/or the radio link '
        '(all currently enabled sources). Requires that the user has accepted '
        'the data & network usage notice; if not, this returns an error asking '
        'the user to accept it manually first.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'disconnect',
    description:
        'Tear down the current connection and stop automatic reconnects until '
        'the next explicit connect.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'nearby_stations',
    description:
        'List the stations currently nearest to the user (by distance from '
        'their position), nearest first. Use this for "who is near me / around '
        'me" — no need to search by callsign. Read-only, never needs confirmation.',
    parameters: {
      'type': 'object',
      'properties': {
        'radius_km': {
          'type': 'number',
          'description': 'Only stations within this many km (default: current filter).',
        },
        'limit': {'type': 'integer', 'description': 'How many to return (default 5).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'reply_message',
    description:
        'Reply to the person who sent you the latest message in a conversation. '
        'This is the natural tool for answering an incoming message — you do not '
        'need to know the callsign, just pass the sender it came from. Requires '
        'the "allow sending" permission and the user\'s confirmation.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'string',
          'description': 'Call sign (or group call) the incoming message came from.',
        },
        'text': {'type': 'string', 'description': 'The reply text.'},
      },
      'required': ['to', 'text'],
    },
  ),
  const AgentToolSpec(
    name: 'send_group_message',
    description:
        'Send a message to a chat group by its name or group call (see '
        '"list_groups"). Use "send_message" for a single person. Requires the '
        '"allow sending" permission and the user\'s confirmation.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group name or group call.'},
        'text': {'type': 'string', 'description': 'The message text.'},
      },
      'required': ['group', 'text'],
    },
  ),
  const AgentToolSpec(
    name: 'create_group',
    description:
        'Create a new chat group with the given members. Requires the '
        '"allow settings" permission and the user\'s confirmation.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Display name of the group.'},
        'members': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Call signs to invite (the owner is added automatically).',
        },
      },
      'required': ['name'],
    },
  ),
  const AgentToolSpec(
    name: 'set_task_enabled',
    description:
        'Pause or resume a scheduled task by its id (see "list_tasks"). '
        'Pausing keeps it but stops it from running.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id from list_tasks.'},
        'enabled': {'type': 'boolean', 'description': 'true = resume, false = pause.'},
      },
      'required': ['id', 'enabled'],
    },
  ),
  const AgentToolSpec(
    name: 'update_task',
    description:
        'Edit an existing task in place (see "list_tasks"). Only the provided '
        'fields change; use this instead of cancel + create. Changing "trigger" '
        'resets the schedule.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id from list_tasks.'},
        'prompt': {'type': 'string', 'description': 'New instruction text.'},
        'trigger': {
          'type': 'string',
          'enum': ['timer', 'message'],
          'description': 'timer = on a schedule; message = on each new message.',
        },
        'interval_minutes': {
          'type': 'integer',
          'description': 'timer trigger: 0 = once, otherwise every N min.',
        },
        'run_at': {
          'type': 'string',
          'description':
              'timer trigger: run once at an absolute time (ISO-8601, e.g. '
              '2026-10-03T20:00 local). Overrides interval_minutes.',
        },
      },
      'required': ['id'],
    },
  ),
  const AgentToolSpec(
    name: 'list_task_runs',
    description:
        'Recent execution history of scheduled/message tasks: when each ran and '
        'what happened. Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id; omit for all tasks.'},
        'limit': {'type': 'integer', 'description': 'Max rows (default 20).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'clear_task_runs',
    description: 'Clear task execution history (one task, or all when id is omitted).',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id; omit to clear all.'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'list_contacts',
    description:
        'List the user\'s contacts / favourite stations (callsigns kept on the '
        'map even when they go quiet). Read-only.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'update_group',
    description:
        'Change an existing group: rename it and/or add or remove members. '
        'A group is found by name or group call.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group name or group call.'},
        'name': {'type': 'string', 'description': 'New display name.'},
        'add': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Callsigns to add as members.',
        },
        'remove': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Callsigns to remove from the member list.',
        },
      },
      'required': ['group'],
    },
  ),
  const AgentToolSpec(
    name: 'join_group',
    description:
        'Join a group chat by its group call (or a group already in the list).',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
      },
      'required': ['group'],
    },
  ),
  const AgentToolSpec(
    name: 'leave_group',
    description: 'Leave a group chat (the group stays in the list, you stop taking part).',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group name or group call.'},
      },
      'required': ['group'],
    },
  ),
  const AgentToolSpec(
    name: 'dismiss_group',
    description:
        'Delete a group chat you own. This removes it from this device.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group name or group call.'},
      },
      'required': ['group'],
    },
  ),
  const AgentToolSpec(
    name: 'set_favorite',
    description:
        'Follow or unfollow a station. Followed stations are kept on the map. '
        'Adding a call that is not heard yet creates a manual contact.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Callsign.'},
        'favorite': {'type': 'boolean', 'description': 'true = follow, false = unfollow.'},
      },
      'required': ['call', 'favorite'],
    },
  ),
  const AgentToolSpec(
    name: 'set_station_ignored',
    description:
        'Block or unblock a station from the map/station list. Packets are '
        'still received and shown on the packets page; this only hides it.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Callsign.'},
        'ignored': {'type': 'boolean', 'description': 'true = hide, false = show again.'},
      },
      'required': ['call', 'ignored'],
    },
  ),
  const AgentToolSpec(
    name: 'set_status_text',
    description:
        'Set the station status text (the APRS "status" report, separate from '
        'the position comment). Stored only; it is sent with the next status '
        'report, not immediately.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'New status text (may be empty).'},
      },
      'required': ['text'],
    },
  ),
  const AgentToolSpec(
    name: 'broadcast_message',
    description:
        'Send the same message to several callsigns at once (one APRS message '
        'per recipient). Radio mode limits each message to 67 characters.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Recipient callsigns.',
        },
        'text': {'type': 'string', 'description': 'Message body.'},
      },
      'required': ['to', 'text'],
    },
  ),
  const AgentToolSpec(
    name: 'get_sensors',
    description:
        'Read the current on-device sensor values: heart rate, steps today, '
        'battery, speed, course, and trip/total mileage. Read-only.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'get_station_packets',
    description:
        'Recent raw APRS packets, optionally only those from one callsign. '
        'Includes the raw frame and the digipeater path. Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Optional callsign filter.'},
        'limit': {'type': 'integer', 'description': 'Max rows (default 20, max 50).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'get_track',
    description:
        'The position track of a station (or of yourself with "my call" / '
        'callsign). Read-only. Use "export_track_gpx" to get it as GPX.',
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Callsign, or "me".'},
        'limit': {'type': 'integer', 'description': 'Max points from the newest end.'},
      },
      'required': ['call'],
    },
  ),
  const AgentToolSpec(
    name: 'export_track_gpx',
    description:
        'Export a station track as a GPX document (returned as text; nothing '
        'is written to disk). Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'call': {'type': 'string', 'description': 'Callsign, or "me".'},
      },
      'required': ['call'],
    },
  ),
  const AgentToolSpec(
    name: 'distance_between',
    description:
        'Great-circle distance and initial bearing between two stations (or '
        'points). Use "me" for the user\'s own position. Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'from': {'type': 'string', 'description': 'Callsign or "me".'},
        'to': {'type': 'string', 'description': 'Callsign or "me".'},
      },
      'required': ['from', 'to'],
    },
  ),
  const AgentToolSpec(
    name: 'set_my_position',
    description:
        'Set the user\'s position manually (simulated position), e.g. for '
        'testing or when there is no location service. Overrides real GPS until '
        'cleared. Requires the data notice to be accepted.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'lat': {'type': 'number', 'description': '-90..90'},
        'lng': {'type': 'number', 'description': '-180..180'},
        'alt': {'type': 'number', 'description': 'Optional altitude in metres.'},
      },
      'required': ['lat', 'lng'],
    },
  ),
  const AgentToolSpec(
    name: 'clear_my_position',
    description: 'Stop using a manually set position and go back to real GPS.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
];

/// 名称 → spec
final Map<String, AgentToolSpec> _byName = {
  for (final t in kAgentTools) t.name: t,
};

/// 允许的底图名（来自 [MapType]，避免两处漂移）
final List<String> _mapTypeNames =
    MapType.values.map((e) => e.name).toList(growable: false);

/// 允许切换的页签名 → 页签编号（两套外壳一致）
const Map<String, int> _screens = {
  'map': 0,
  'stations': 1,
  'messages': 2,
  'data': 3,
  'settings': 4,
};

/// 发给模型的 schema 列表。
///
/// 未开启发送权限时连会发消息的工具都不给 —— 既有明确的权限边界，
/// 也避免模型反复尝试一个注定被拒的操作。定时任务**不再**单独设开关：
/// 任务只是「到点自动跑一句话」，真正能不能做仍由发送/改设置权限与确认决定，
/// 所以没有理由再挡一道（旧版的「允许定时任务」开关已移除）。
List<Map<String, dynamic>> agentToolSchemas({required bool allowSend}) => [
      for (final t in kAgentTools)
        if (allowSend || !_isSendingTool(t.name)) t.toSchema(),
    ];

/// 会发出 APRS 消息的工具（受「允许发送」开关约束）。
/// `reply_message` 不以 `send_` 开头，但同样是发送，必须一并纳入；
/// `broadcast_message` 发多条单播，同样受此闸门约束。
bool _isSendingTool(String name) =>
    name.startsWith('send_') ||
    name == 'reply_message' ||
    name == 'broadcast_message';

/// 免确认白名单：这些工具无副作用，执行前不问用户。
///
/// 关键修正（旧版硬编码漏了 `list_groups` 之外的只读工具、且把 navigate 也算成
/// 需要确认）：现在按 [AgentToolSpec.mutating] 判断 —— 只读工具一律免确认，
/// 有副作用的工具默认要确认，`navigate` 只切页面故豁免。新增工具时不必再改这里，
/// 只要正确标注 [AgentToolSpec.mutating] 即可。
bool agentNeedsConfirm(String name) {
  final spec = _byName[name];
  if (spec == null) return true; // 未知工具宁可先问
  if (!spec.mutating) return false;
  return name != 'navigate';
}

String _val(Map<String, dynamic> a, String k) {
  final v = a[k];
  // 注意：不能用 '$v' 直接插值 —— 缺省/显式 null 会变成字符串 "null"，
  // 让「没传 focus_call」被当成呼号 "NULL" 去搜索。这里统一归一为 ''。
  if (v == null) return '';
  return '$v';
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? _asDouble(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

bool? _asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    switch (v.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
      case 'on':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
        return false;
    }
  }
  return null;
}

AgentToolOutcome _err(String msg) => AgentToolOutcome('ERROR: $msg');

/// 执行一个工具调用。
///
/// [allowedSend] / [allowedSettings] 来自配置的权限开关；未授权时返回错误文本
/// （模型会据此告知用户去打开权限）。
Future<AgentToolOutcome> executeAgentTool(
  AppState st,
  String name,
  Map<String, dynamic> args, {
  required bool allowedSend,
  required bool allowedSettings,
}) async {
  final spec = _byName[name];
  if (spec == null) return _err('Unknown tool: $name');

  // 权限闸门（schema 层已隐藏发送类工具，但模型仍可能凭空调用）
  if (_isSendingTool(name) && !allowedSend) {
    return _err('Permission denied: sending messages is disabled in settings.');
  }
  if (spec.mutating && name != 'navigate' && !allowedSettings) {
    return _err('Permission denied: changing settings is disabled.');
  }

  switch (name) {
    case 'get_app_state':
      return AgentToolOutcome(jsonEncode({
        'my_callsign': st.myFullCall,
        'my_symbol': st.mySymbol,
        'my_comment': st.myComment,
        'my_status_text': st.aprsStatusText,
        // 自身位置：以前只给「有多少台站」，坐标反而拿不到 —— 但后台明明有
        // （nearby_stations 就靠它算距离）。这里如实给出，并带上「新不新鲜」。
        'my_lat': st.myLat,
        'my_lng': st.myLng,
        'my_alt_m': st.myAlt,
        'my_has_fix': st.myHasFix,
        'my_position_reportable': st.myPositionReportable,
        'my_fix_min_ago':
            st.myFixAt == null ? null : DateTime.now().difference(st.myFixAt!).inMinutes,
        'connected': st.connected,
        'using_rf': st.usingRf,
        // 权限可见性：模型不必再「撞错才知道」。只读，供其判断能做什么。
        'permissions': {
          'agent_enabled': AgentService.instance.config.enabled,
          'allow_send': AgentService.instance.config.allowSend,
          'allow_settings': AgentService.instance.config.allowSettings,
          'agent_notice_accepted': st.agentNoticeAccepted,
          'data_notice_accepted': st.dataNoticeAccepted,
        },
        'connections': {
          'connected': st.anyLinkUp,
          'user_disconnected': st.userDisconnected,
          'server': st.aprs.server,
          'port': st.aprs.port,
          'sources': {
            'aprsis': st.aprsIsOn,
            'tnc': st.tncOn,
            'audio': st.audioOn,
            'pkwdwpl': st.pkwdwplOn,
          },
          'data_notice_accepted': st.dataNoticeAccepted,
        },
        'stations': st.stations.length,
        'messages': st.messages.length,
        'unread_messages': st.unreadMessages,
        'groups': st.chatGroups.length,
        'scheduled_tasks': AgentService.instance.tasks.length,
        'tracking': {
          'beacon_enabled': st.beaconEnabled,
          'beacon_interval_sec': st.beaconInterval,
          'beacon_net_interval_sec': st.beaconNetInterval,
          'smart_beacon': st.smartBeaconEnabled,
          'include_speed': st.beaconIncludeSpeed,
          'include_course': st.beaconIncludeCourse,
          'include_battery': st.beaconIncludeBattery,
          'include_hr': st.beaconIncludeHr,
        },
        'preferences': {
          'language': st.locale,
          'dark_mode': st.darkMode,
          'ui_layout': st.uiLayout,
          'ui_scale': st.uiScale,
          'map_type': st.mapType,
          'ui_material': st.uiMaterial,
          'weather': st.weatherEnabled,
          'sensor_assist': st.sensorAssist,
        },
        'allowed_values': {
          'language': const ['zh', 'zh_TW', 'en', 'ja', 'es', 'id'],
          'ui_layout': const ['classic', 'sheet'],
          'ui_material': const ['none', 'glass', 'mica', 'glass_full'],
          'map_type': _mapTypeNames,
          'screen': _screens.keys.toList(),
        },
      }));

    case 'list_groups':
      return AgentToolOutcome(jsonEncode([
        for (final g in st.chatGroups)
          {
            'name': g.name,
            'call': g.groupCall,
            'owner': g.owner,
            'is_owner': g.isOwner(st.myFullCall),
            // 以前只给群名 + 群呼，模型连「群里都有谁」都看不到，没法做任何成员运维。
            'members': [
              for (final m in g.allMemberCalls.toList()..sort())
                {
                  'call': m,
                  'status': g.activeMembers.contains(m)
                      ? 'active'
                      : (g.memberStatus[m.toUpperCase()]?.name ?? 'unknown'),
                  'blocked': g.blockedMembers.contains(m),
                },
            ],
          },
      ]));

    case 'list_contacts':
      return AgentToolOutcome(jsonEncode([
        for (final s in st.stations.where((s) => s.favorite || s.manual))
          {..._stationBrief(s), 'manual': s.manual},
      ]));

    case 'search_stations':
      {
        final q = _val(args, 'query').trim().toUpperCase();
        if (q.isEmpty) return _err('query is required');
        final lim = _limit(args['limit']);
        final hits = st.stations
            .where((s) => s.call.toUpperCase().contains(q))
            .take(lim);
        final list = [for (final s in hits) _stationBrief(s)];
        return AgentToolOutcome(jsonEncode(list),
            note: 'search_stations "$q" → ${list.length}');
      }

    case 'list_stations':
      {
        final lim = _limit(args['limit']);
        final sorted = [...st.stations]
          ..sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
        final list = [for (final s in sorted.take(lim)) _stationBrief(s)];
        return AgentToolOutcome(jsonEncode(list),
            note: 'list_stations → ${list.length}');
      }

    case 'nearby_stations':
      {
        if (!st.myHasFix || st.myLat == null || st.myLng == null) {
          return _err('No position fix yet; cannot compute nearby stations.');
        }
        final radiusKm =
            _asDouble(args['radius_km']) ?? st.filterRadius.toDouble();
        if (radiusKm <= 0) return _err('radius_km must be > 0');
        final lim = _asInt(args['limit']) ?? 5;
        final hits = st.nearbyStations(radiusKm, limit: lim.clamp(1, 50));
        final list = [for (final s in hits) _stationBrief(s)];
        return AgentToolOutcome(jsonEncode(list),
            note: 'nearby_stations ${radiusKm.round()}km → ${list.length}');
      }

    case 'station_detail':
      {
        final q = _val(args, 'call').trim().toUpperCase();
        if (q.isEmpty) return _err('call is required');
        final s = st.stations
                .where((x) => x.call.toUpperCase() == q)
                .firstOrNull ??
            st.stations
                .where((x) => x.call.toUpperCase().contains(q))
                .firstOrNull;
        if (s == null) return _err('Station $q not found.');
        return AgentToolOutcome(
          jsonEncode({
            ..._stationBrief(s),
            'symbol': s.symbol,
            'alt_m': s.alt,
            'speed_kmh': s.speed,
            'course': s.course,
            'status_text': s.statusText,
            'device': s.deviceName,
            'path': s.path,
            'track_points': s.track.length,
          }),
          note: 'station_detail ${s.call}',
        );
      }

    case 'read_messages':
      {
        final who = _val(args, 'with').trim().toUpperCase();
        final kw = _val(args, 'query').trim().toLowerCase();
        final since = _asEpoch(args['since']);
        final until = _asEpoch(args['until']);
        final lim = (() {
          final n = _asInt(args['limit']) ?? 20;
          return n.clamp(1, 200);
        })();
        final groupCalls = st.chatGroups.map((g) => g.groupCall.toUpperCase());
        // st.messages 是倒序（最新在前）：过滤后取最新 lim 条，再翻回时间正序给模型。
        // 注意 take(lim) 必须在 reversed 前 —— 否则截的是最旧的 lim 条。
        final filtered = st.messages.where((m) {
          if (since != null && m.time.isBefore(since)) return false;
          if (until != null && m.time.isAfter(until)) return false;
          if (kw.isNotEmpty && !m.text.toLowerCase().contains(kw)) return false;
          if (who.isEmpty) return true;
          final from = m.from.toUpperCase();
          final to = m.to.toUpperCase();
          return from.contains(who) ||
              to.contains(who) ||
              groupCalls.contains(to);
        }).take(lim).toList().reversed;
        final list = [
          for (final m in filtered)
            {
              'time': m.time.toIso8601String(),
              'from': m.from,
              'to': m.to,
              'text': m.text,
              'sent': m.sent,
              // 送达回执：只有本机发出的单播才有 ack 语义（群发刻意不做 ack，见
              // sendGroupMessage 的注释）。null = 不适用，false = 已发未确认。
              'acked': m.sent && m.id != null ? m.acked : null,
              'group': m.groupId != null,
              'system': m.system,
            },
        ];
        // 只有「完整读某个会话」时才顺带标记已读；关键字/时间过滤只关心结果，
        // 不代表该会话已看完 —— 不能因此清掉未读小红点。
        var markedRead = false;
        if (who.isNotEmpty &&
            kw.isEmpty &&
            since == null &&
            until == null &&
            list.isNotEmpty) {
          final g = st.findGroup(who);
          if (g != null) {
            st.markGroupRead(g.id);
          } else {
            st.markConversationRead(who);
          }
          markedRead = true;
        }
        return AgentToolOutcome(jsonEncode({
          'messages': list,
          'marked_read': markedRead,
        }), note: 'read_messages${who.isEmpty ? '' : ' "$who"'} → ${list.length}');
      }

    case 'send_message':
      {
        final to = _val(args, 'to').trim().toUpperCase();
        final text = _val(args, 'text').trim();
        if (to.isEmpty || text.isEmpty) {
          return _err('"to" and "text" are required');
        }
        if (st.usingRf && text.length > 67) {
          return _err('Radio mode limits a message to 67 characters.');
        }
        st.sendMessage(to, text);
        return AgentToolOutcome('Message queued to $to: $text',
            note: 'send_message → $to');
      }

    case 'reply_message':
      {
        final to = _val(args, 'to').trim().toUpperCase();
        final text = _val(args, 'text').trim();
        if (to.isEmpty || text.isEmpty) {
          return _err('"to" and "text" are required');
        }
        if (st.usingRf && text.length > 67) {
          return _err('Radio mode limits a message to 67 characters.');
        }
        // 若目标其实是某个群（群名/群呼号），走群发，否则按单播回。
        final g = st.chatGroups
            .where((g) =>
                g.groupCall.toUpperCase() == to ||
                g.name.toUpperCase() == to)
            .firstOrNull;
        if (g != null) {
          st.sendGroupMessage(g.groupCall, text, groupId: g.id);
          return AgentToolOutcome('Reply sent to group ${g.name}: $text',
              note: 'reply_message → group ${g.name}');
        }
        st.sendMessage(to, text);
        return AgentToolOutcome('Reply sent to $to: $text',
            note: 'reply_message → $to');
      }

    case 'send_group_message':
      {
        final q = _val(args, 'group').trim().toUpperCase();
        final text = _val(args, 'text').trim();
        if (q.isEmpty || text.isEmpty) {
          return _err('"group" and "text" are required');
        }
        final g = st.chatGroups
            .where((g) =>
                g.groupCall.toUpperCase() == q || g.name.toUpperCase() == q)
            .firstOrNull;
        if (g == null) return _err('No group named "$q".');
        if (st.usingRf && text.length > 67) {
          return _err('Radio mode limits a message to 67 characters.');
        }
        st.sendGroupMessage(g.groupCall, text, groupId: g.id);
        return AgentToolOutcome('Group message sent to ${g.name}: $text',
            note: 'send_group_message → ${g.name}');
      }

    case 'create_group':
      {
        final groupName = _val(args, 'name').trim();
        if (groupName.isEmpty) return _err('name is required');
        final raw = args['members'];
        final members = <String>{};
        if (raw is List) {
          for (final m in raw) {
            final s = '$m'.trim().toUpperCase();
            if (s.isNotEmpty) members.add(s);
          }
        }
        final g = st.createGroup(groupName, members);
        return AgentToolOutcome(
          'Created group ${g.name} (${g.groupCall}) with '
          '${g.recipients.length} member(s).',
          note: 'create_group ${g.name}',
        );
      }

    case 'send_beacon_now':
      if (!st.myPositionReportable) {
        return _err('No usable GPS fix yet; beacon not sent.');
      }
      st.sendBeacon();
      return AgentToolOutcome('Beacon sent.', note: 'send_beacon_now');

    case 'set_tracking':
      {
        final changed = <String>[];
        if (args.containsKey('beacon_enabled')) {
          final b = _asBool(args['beacon_enabled']);
          if (b == null) return _err('beacon_enabled must be a boolean');
          st.setBeaconEnabled(b);
          changed.add('beacon_enabled');
        }
        if (args.containsKey('beacon_interval_sec')) {
          final n = _asInt(args['beacon_interval_sec']);
          if (n == null || n < 5 || n > 3600) {
            return _err('beacon_interval_sec must be 5..3600');
          }
          st.setBeaconInterval(n);
          changed.add('beacon_interval_sec');
        }
        if (args.containsKey('beacon_net_interval_sec')) {
          final n = _asInt(args['beacon_net_interval_sec']);
          if (n == null || n < 30 || n > 3600) {
            return _err('beacon_net_interval_sec must be 30..3600');
          }
          st.setBeaconNetInterval(n);
          changed.add('beacon_net_interval_sec');
        }
        final bools = <String, void Function(bool)>{
          'smart_beacon': st.setSmartBeaconOn,
          'include_speed': st.setBeaconIncludeSpeed,
          'include_course': st.setBeaconIncludeCourse,
          'include_battery': st.setBeaconIncludeBattery,
          'include_hr': st.setBeaconIncludeHr,
          'include_steps': st.setBeaconIncludeSteps,
          'include_trip_mileage': st.setBeaconIncludeTripMileage,
          'include_total_mileage': st.setBeaconIncludeTotalMileage,
        };
        for (final e in bools.entries) {
          if (!args.containsKey(e.key)) continue;
          final b = _asBool(args[e.key]);
          if (b == null) return _err('${e.key} must be a boolean');
          e.value(b);
          changed.add(e.key);
        }
        if (changed.isEmpty) return _err('No tracked fields provided.');
        return AgentToolOutcome('Updated tracking: ${changed.join(', ')}',
            note: 'set_tracking ${changed.join(', ')}');
      }

    case 'set_station_filters':
      {
        final changed = <String>[];
        if (args.containsKey('receive_others')) {
          final b = _asBool(args['receive_others']);
          if (b == null) return _err('receive_others must be a boolean');
          st.setReceiveOthers(b);
          changed.add('receive_others');
        }
        if (args.containsKey('max_stations')) {
          final n = _asInt(args['max_stations']);
          if (n == null || n < 0 || n > 5000) {
            return _err('max_stations must be 0..5000');
          }
          st.setMaxStations(n);
          changed.add('max_stations');
        }
        if (args.containsKey('max_packets')) {
          final n = _asInt(args['max_packets']);
          if (n == null || n < 0 || n > 20000) {
            return _err('max_packets must be 0..20000');
          }
          st.setMaxPackets(n);
          changed.add('max_packets');
        }
        if (args.containsKey('max_track_points')) {
          final n = _asInt(args['max_track_points']);
          if (n == null || n < 0 || n > 5000) {
            return _err('max_track_points must be 0..5000');
          }
          st.setMaxTrackPts(n);
          changed.add('max_track_points');
        }
        if (args.containsKey('retention_days')) {
          final n = _asInt(args['retention_days']);
          if (n == null || n < 0 || n > 3650) {
            return _err('retention_days must be 0..3650');
          }
          st.setStationRetentionDays(n);
          changed.add('retention_days');
        }
        if (changed.isEmpty) return _err('No fields provided.');
        return AgentToolOutcome('Updated filters: ${changed.join(', ')}',
            note: 'set_station_filters ${changed.join(', ')}');
      }

    case 'set_preferences':
      {
        final changed = <String>[];
        if (args.containsKey('language')) {
          final v = _val(args, 'language');
          if (!const ['zh', 'zh_TW', 'en', 'ja', 'es', 'id'].contains(v)) {
            return _err('language must be one of zh, zh_TW, en, ja, es, id');
          }
          st.setLocale(v);
          changed.add('language=$v');
        }
        if (args.containsKey('dark_mode')) {
          final b = _asBool(args['dark_mode']);
          if (b == null) return _err('dark_mode must be a boolean');
          st.setDarkMode(b);
          changed.add('dark_mode=$b');
        }
        if (args.containsKey('ui_layout')) {
          final v = _val(args, 'ui_layout');
          if (v != 'classic' && v != 'sheet') {
            return _err('ui_layout must be classic or sheet');
          }
          st.setUiLayout(v);
          changed.add('ui_layout=$v');
        }
        if (args.containsKey('ui_scale')) {
          final d = _asDouble(args['ui_scale']);
          if (d == null || d < 0.85 || d > 1.3) {
            return _err('ui_scale must be 0.85..1.3');
          }
          st.setUiScale(d);
          changed.add('ui_scale=$d');
        }
        if (args.containsKey('map_type')) {
          final v = _val(args, 'map_type');
          if (!_mapTypeNames.contains(v)) {
            return _err('map_type must be one of ${_mapTypeNames.join(', ')}');
          }
          st.setMapType(v);
          changed.add('map_type=$v');
        }
        if (args.containsKey('ui_material')) {
          final v = _val(args, 'ui_material');
          if (!const ['none', 'glass', 'mica', 'glass_full'].contains(v)) {
            return _err('ui_material must be none, glass, mica or glass_full');
          }
          st.setUiMaterial(v);
          changed.add('ui_material=$v');
        }
        if (args.containsKey('weather')) {
          final b = _asBool(args['weather']);
          if (b == null) return _err('weather must be a boolean');
          st.setWeatherEnabled(b);
          changed.add('weather=$b');
        }
        if (args.containsKey('sensor_assist')) {
          final b = _asBool(args['sensor_assist']);
          if (b == null) return _err('sensor_assist must be a boolean');
          st.setSensorAssist(b);
          changed.add('sensor_assist=$b');
        }
        if (args.containsKey('heat_level')) {
          final n = _asInt(args['heat_level']);
          if (n == null || n < 0 || n > 2) {
            return _err('heat_level must be 0..2');
          }
          st.setHeatLevel(n);
          changed.add('heat_level=$n');
        }
        if (changed.isEmpty) return _err('No fields provided.');
        return AgentToolOutcome(
            'Updated preferences: ${changed.join(', ')}',
            note: 'set_preferences ${changed.join(', ')}');
      }

    case 'set_nickname':
      {
        final changed = <String>[];
        if (args.containsKey('callsign')) {
          final v = _val(args, 'callsign').trim().toUpperCase();
          if (v.isEmpty || v.length > 10 || v.contains(RegExp(r'\s'))) {
            return _err('callsign must be 1..10 non-space characters');
          }
          st.myCall = v;
          changed.add('callsign=$v');
        }
        if (args.containsKey('ssid')) {
          final n = _asInt(args['ssid']);
          if (n == null || n < 0 || n > 15) return _err('ssid must be 0..15');
          st.mySsid = n;
          changed.add('ssid=$n');
        }
        if (args.containsKey('symbol')) {
          final v = _val(args, 'symbol');
          if (v.isEmpty || v.length > 2) {
            return _err('symbol must be 1..2 characters');
          }
          st.mySymbol = v;
          changed.add('symbol=$v');
        }
        if (args.containsKey('comment')) {
          st.myComment = _val(args, 'comment').trim();
          changed.add('comment');
        }
        if (changed.isEmpty) return _err('No fields provided.');
        st.persist();
        return AgentToolOutcome(
            'Updated station identity: ${changed.join(', ')}',
            note: 'set_nickname ${changed.join(', ')}');
      }

    case 'navigate':
      {
        final focus = _val(args, 'focus_call').trim().toUpperCase();
        if (focus.isNotEmpty) {
          // 精确匹配优先，退而求其次按包含匹配
          final exact =
              st.stations.where((s) => s.call.toUpperCase() == focus).toList();
          final matches = exact.isEmpty
              ? st.stations
                  .where((s) => s.call.toUpperCase().contains(focus))
                  .toList()
              : exact;
          if (matches.isEmpty) return _err('Station $focus not found.');
          st.focusOnMap(matches.first);
          st.requestTab(0);
          return AgentToolOutcome(
              'Centered map on ${matches.first.call}.',
              note: 'navigate → map (${matches.first.call})');
        }
        final screen = _val(args, 'screen').trim().toLowerCase();
        final idx = _screens[screen];
        if (idx == null) {
          return _err('screen must be one of ${_screens.keys.join(', ')}');
        }
        st.requestTab(idx);
        return AgentToolOutcome('Switched to $screen screen.',
            note: 'navigate → $screen');
      }

    case 'create_task':
      {
        final prompt = _val(args, 'prompt').trim();
        if (prompt.isEmpty) return _err('prompt is required');
        final trigger = _val(args, 'trigger').toLowerCase() == 'message'
            ? AgentTaskTrigger.message
            : AgentTaskTrigger.timer;
        var mins = _asInt(args['interval_minutes']) ?? 0;
        if (mins < 0) mins = 0;
        // 消息触发型没有间隔；定时型循环间隔没有额外下限（轮询本身 60 秒一次）。
        final isMessage = trigger == AgentTaskTrigger.message;
        final t = await AgentService.instance.addTask(
          prompt,
          trigger: trigger,
          intervalMinutes: isMessage ? 0 : mins,
        );
        final desc = isMessage
            ? 'on each new message'
            : (mins == 0 ? 'once' : 'every $mins min');
        return AgentToolOutcome(
          'Task ${t.id} created ($desc): $prompt',
          note: 'create_task ${t.id}',
        );
      }

    case 'list_tasks':
      {
        final list = [
          for (final t in AgentService.instance.tasks)
            {
              'id': t.id,
              'prompt': t.prompt,
              'trigger': t.trigger.name,
              'every_min': t.intervalMinutes,
              'enabled': t.enabled,
              'next_run': t.nextRun?.toIso8601String(),
              'last_run': t.lastRun?.toIso8601String(),
            },
        ];
        return AgentToolOutcome(jsonEncode(list), note: 'list_tasks → ${list.length}');
      }

    case 'cancel_task':
      {
        final id = _val(args, 'id').trim();
        if (id.isEmpty) return _err('id is required');
        final hit = AgentService.instance.tasks.where((t) => t.id == id).toList();
        if (hit.isEmpty) return _err('No task with id $id.');
        await AgentService.instance.removeTask(id);
        return AgentToolOutcome('Task $id canceled.', note: 'cancel_task $id');
      }

    case 'set_task_enabled':
      {
        final id = _val(args, 'id').trim();
        if (id.isEmpty) return _err('id is required');
        final on = _asBool(args['enabled']);
        if (on == null) return _err('"enabled" must be true or false.');
        final hit = AgentService.instance.tasks.where((t) => t.id == id).toList();
        if (hit.isEmpty) return _err('No task with id $id.');
        await AgentService.instance.setTaskEnabled(id, on);
        return AgentToolOutcome('Task $id ${on ? 'resumed' : 'paused'}.',
            note: 'set_task_enabled $id → $on');
      }

    case 'update_task':
      {
        final id = _val(args, 'id').trim();
        if (id.isEmpty) return _err('id is required');
        final svc = AgentService.instance;
        if (svc.tasks.where((t) => t.id == id).isEmpty) {
          return _err('No task with id $id.');
        }
        AgentTaskTrigger? trigger;
        if (args.containsKey('trigger')) {
          final v = _val(args, 'trigger').trim().toLowerCase();
          if (v != 'timer' && v != 'message') {
            return _err('trigger must be "timer" or "message".');
          }
          trigger = v == 'message' ? AgentTaskTrigger.message : AgentTaskTrigger.timer;
        }
        DateTime? runAt;
        if (args.containsKey('run_at') && _val(args, 'run_at').trim().isNotEmpty) {
          runAt = DateTime.tryParse(_val(args, 'run_at').trim());
          if (runAt == null) {
            return _err('run_at must be an ISO-8601 date/time.');
          }
        }
        int? interval;
        if (args.containsKey('interval_minutes')) {
          interval = _asInt(args['interval_minutes']);
          if (interval == null || interval < 0) {
            return _err('interval_minutes must be >= 0.');
          }
        }
        if (_val(args, 'prompt').trim().isEmpty &&
            trigger == null &&
            runAt == null &&
            interval == null) {
          return _err('Nothing to update: give prompt, trigger, run_at or '
              'interval_minutes.');
        }
        final ok = await svc.updateTask(
          id,
          prompt: _val(args, 'prompt').trim().isEmpty ? null : _val(args, 'prompt'),
          trigger: trigger,
          runAt: runAt,
          intervalMinutes: interval,
          clearRunAt: trigger == AgentTaskTrigger.message,
        );
        if (!ok) return _err('No task with id $id.');
        final t = svc.tasks.where((t) => t.id == id).first;
        return AgentToolOutcome(
            'Task $id updated (trigger=${t.trigger.name}, '
            'every=${t.intervalMinutes} min, run_at=${t.runAt?.toIso8601String()}).',
            note: 'update_task $id');
      }

    case 'list_task_runs':
      {
        final id = _val(args, 'id').trim();
        final lim = (() {
          final n = _asInt(args['limit']) ?? 20;
          return n.clamp(1, 100);
        })();
        final runs = AgentService.instance.taskRunsFor(id).take(lim);
        final list = [
          for (final r in runs)
            {
              'task_id': r.taskId,
              'at': r.at.toIso8601String(),
              'ok': r.ok,
              'summary': r.summary,
            },
        ];
        return AgentToolOutcome(jsonEncode(list),
            note: 'list_task_runs${id.isEmpty ? '' : ' $id'} → ${list.length}');
      }

    case 'clear_task_runs':
      {
        final id = _val(args, 'id').trim();
        await AgentService.instance.clearTaskRuns(id);
        return AgentToolOutcome(
            id.isEmpty ? 'Cleared all task run history.' : 'Cleared runs for $id.',
            note: 'clear_task_runs${id.isEmpty ? '' : ' $id'}');
      }

    // ─── 群管理（成员运维 / 加入 / 退出 / 解散）───

    case 'update_group':
      {
        final q = _val(args, 'group').trim();
        if (q.isEmpty) return _err('group is required');
        final g = st.findGroup(q);
        if (g == null) return _err('No group named "$q".');
        final name = _val(args, 'name').trim();
        if (name.isNotEmpty && GroupProto.validateName(name) != null) {
          return _err('Invalid group name.');
        }
        final add = _strSet(args['add']);
        final remove = _strSet(args['remove']);
        if (name.isEmpty && add.isEmpty && remove.isEmpty) {
          return _err('Nothing to update: give name, add or remove.');
        }
        // 自己不能被从成员表里踢掉（否则群聊收件人里就没自己了）。
        remove.remove(st.myCall.toUpperCase());
        st.updateGroup(
          g.id,
          name: name.isEmpty ? null : name,
          members: add.isEmpty ? null : add,
          remove: remove.isEmpty ? null : remove,
        );
        return AgentToolOutcome(
            'Updated ${g.name}: ${[
              if (name.isNotEmpty) 'renamed to $name',
              if (add.isNotEmpty) 'added ${add.join(', ')}',
              if (remove.isNotEmpty) 'removed ${remove.join(', ')}',
            ].join('; ')}.',
            note: 'update_group ${g.name}');
      }

    case 'join_group':
      {
        final q = _val(args, 'group').trim();
        if (q.isEmpty) return _err('group is required');
        final g = st.findGroup(q);
        if (g == null) return _err('No group named "$q".');
        final name = st.setMyGroupMembership(g.id, true);
        return AgentToolOutcome('Joined ${name ?? g.name}.',
            note: 'join_group ${g.name}');
      }

    case 'leave_group':
      {
        final q = _val(args, 'group').trim();
        if (q.isEmpty) return _err('group is required');
        final g = st.findGroup(q);
        if (g == null) return _err('No group named "$q".');
        final name = st.setMyGroupMembership(g.id, false);
        return AgentToolOutcome('Left ${name ?? g.name}.',
            note: 'leave_group ${g.name}');
      }

    case 'dismiss_group':
      {
        final q = _val(args, 'group').trim();
        if (q.isEmpty) return _err('group is required');
        final g = st.findGroup(q);
        if (g == null) return _err('No group named "$q".');
        st.deleteGroup(g.id);
        return AgentToolOutcome('Dismissed ${g.name} (${g.groupCall}).',
            note: 'dismiss_group ${g.name}');
      }

    // ─── 台站：收藏 / 屏蔽 ───

    case 'set_favorite':
      {
        final call = _val(args, 'call').trim().toUpperCase();
        final fav = _asBool(args['favorite']);
        if (call.isEmpty) return _err('call is required');
        if (fav == null) return _err('"favorite" must be true or false.');
        st.setFavorite(call, fav);
        return AgentToolOutcome(
            fav ? 'Following $call.' : 'Unfollowed $call.',
            note: 'set_favorite $call → $fav');
      }

    case 'set_station_ignored':
      {
        final call = _val(args, 'call').trim().toUpperCase();
        final ign = _asBool(args['ignored']);
        if (call.isEmpty) return _err('call is required');
        if (ign == null) return _err('"ignored" must be true or false.');
        st.setStationIgnored(call, ign);
        return AgentToolOutcome(
            ign
                ? '$call is now hidden from the map (packets still received).'
                : '$call is shown again.',
            note: 'set_station_ignored $call → $ign');
      }

    // ─── 发送：状态文本 / 群发 ───

    case 'set_status_text':
      {
        if (!args.containsKey('text')) return _err('text is required');
        final v = _val(args, 'text').trim();
        st.setAprsStatusText(v);
        return AgentToolOutcome(
            v.isEmpty
                ? 'Status text cleared.'
                : 'Status text set to "$v" (sent with the next status report).',
            note: 'set_status_text');
      }

    case 'broadcast_message':
      {
        final raw = args['to'];
        final text = _val(args, 'text').trim();
        if (text.isEmpty) return _err('text is required');
        final dests = <String>{};
        if (raw is List) {
          for (final m in raw) {
            final s = _val({'x': m}, 'x').trim().toUpperCase();
            if (s.isNotEmpty) dests.add(s);
          }
        }
        if (dests.isEmpty) return _err('"to" needs at least one callsign.');
        if (st.usingRf && text.length > 67) {
          return _err('Radio mode limits a message to 67 characters.');
        }
        for (final d in dests) {
          st.sendMessage(d, text);
        }
        return AgentToolOutcome(
            'Sent to ${dests.length} recipient(s): ${dests.join(', ')}.',
            note: 'broadcast_message → ${dests.length}');
      }

    // ─── 传感器 / 台站数据 / 轨迹 / 距离 ───

    case 'get_sensors':
      return AgentToolOutcome(jsonEncode({
        'heart_rate_bpm': st.myHr,
        'heart_rate_min_ago': st.myHrAt == null
            ? null
            : DateTime.now().difference(st.myHrAt!).inMinutes,
        'steps_today': st.stepsToday,
        'steps_status': st.stepsStatus.name,
        'battery_percent': st.battery < 0 ? null : st.battery,
        'battery_min_ago': st.batteryAt == null
            ? null
            : DateTime.now().difference(st.batteryAt!).inMinutes,
        'speed_kmh': st.mySpeed,
        'course_deg': st.myCourse,
        'trip_km': st.tripMileageKm,
        'total_km': st.totalMileageKm,
      }));

    case 'get_station_packets':
      {
        final call = _val(args, 'call').trim().toUpperCase();
        final lim = (() {
          final n = _asInt(args['limit']) ?? 20;
          return n.clamp(1, 50);
        })();
        final filtered = st.packets
            .where((p) =>
                call.isEmpty ||
                p.src.toUpperCase().contains(call) ||
                p.dest.toUpperCase().contains(call))
            .take(lim)
            .toList();
        final list = [
          for (final p in filtered)
            {
              'time': p.time.toIso8601String(),
              'from': p.src,
              'to': p.dest,
              'type': p.type,
              'source': p.source,
              'raw': p.raw,
            },
        ];
        return AgentToolOutcome(jsonEncode(list),
            note: 'get_station_packets${call.isEmpty ? '' : ' "$call"'} → ${list.length}');
      }

    case 'get_track':
      return _trackOutcome(st, _val(args, 'call'), asGpx: false,
          limit: _asInt(args['limit']));

    case 'export_track_gpx':
      return _trackOutcome(st, _val(args, 'call'), asGpx: true, limit: null);

    case 'distance_between':
      {
        final a = _pointOf(st, _val(args, 'from'));
        if (a == null) return _err('"from" is neither "me" nor a known station.');
        final b = _pointOf(st, _val(args, 'to'));
        if (b == null) return _err('"to" is neither "me" nor a known station.');
        final m = haversine(a.$1, a.$2, b.$1, b.$2) * 1000;
        final brg = bearingDeg(a.$1, a.$2, b.$1, b.$2);
        return AgentToolOutcome(jsonEncode({
          'from': {'lat': a.$1, 'lng': a.$2},
          'to': {'lat': b.$1, 'lng': b.$2},
          'distance_m': m.round(),
          'distance_km': double.parse((m / 1000).toStringAsFixed(3)),
          'initial_bearing_deg': brg == null ? null : brg.round(),
        }), note: 'distance_between');
      }

    case 'set_my_position':
      {
        if (!st.dataNoticeAccepted) {
          return _err('The data & network usage notice must be accepted first.');
        }
        final lat = _asDouble(args['lat']);
        final lng = _asDouble(args['lng']);
        if (lat == null || lng == null) {
          return _err('lat and lng are required numbers.');
        }
        if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
          return _err('lat must be -90..90, lng -180..180.');
        }
        final alt = _asDouble(args['alt']);
        st.setMyPosition(lat, lng, alt: alt);
        return AgentToolOutcome('Position set to $lat, $lng (simulated).',
            note: 'set_my_position');
      }

    case 'clear_my_position':
      {
        if (!st.useSimLocation) {
          return AgentToolOutcome('No simulated position is set.',
              note: 'clear_my_position (none)');
        }
        st.setUseSimLocation(false);
        return AgentToolOutcome(
            'Simulated position cleared; back to real location.',
            note: 'clear_my_position');
      }

    case 'set_connection_server':
      {
        final server = _val(args, 'server').trim();
        final port = _asInt(args['port']);
        if (server.isEmpty && port == null) {
          return _err('Provide "server" and/or "port".');
        }
        if (server.isNotEmpty) st.aprs.server = server;
        if (port != null) {
          if (port < 1 || port > 65535) {
            return _err('port must be between 1 and 65535.');
          }
          st.aprs.port = port;
        }
        st.persist();
        return AgentToolOutcome(
          'Server set to ${st.aprs.server}:${st.aprs.port} (not connected yet).',
          note: 'set_connection_server ${st.aprs.server}:${st.aprs.port}',
        );
      }

    case 'set_connection_source':
      {
        final src = _val(args, 'source').trim().toLowerCase();
        final on = _asBool(args['enabled']);
        if (on == null) return _err('"enabled" must be true or false.');
        const valid = {'aprsis', 'tnc', 'audio', 'pkwdwpl'};
        if (!valid.contains(src)) {
          return _err('source must be one of ${valid.join(', ')}.');
        }
        if (!on && st.enabledSources.length <= 1 &&
            st.enabledSources.contains(src)) {
          return _err('At least one data source must stay enabled.');
        }
        await st.toggleSource(src, on);
        return AgentToolOutcome(
          '$src source ${on ? 'enabled' : 'disabled'}.',
          note: 'set_connection_source $src=$on',
        );
      }

    case 'connect':
      {
        if (st.anyLinkUp) {
          return AgentToolOutcome('Already connected.',
              note: 'connect (already up)');
        }
        if (!st.dataNoticeAccepted) {
          return _err(
              'The data & network usage notice has not been accepted; ask the '
              'user to accept it in the app before connecting.');
        }
        await st.toggleConnect();
        return AgentToolOutcome(
          st.anyLinkUp ? 'Connecting…' : 'Connection attempt started.',
          note: 'connect',
        );
      }

    case 'disconnect':
      {
        if (!st.anyLinkUp) {
          return AgentToolOutcome('Already disconnected.',
              note: 'disconnect (already down)');
        }
        await st.toggleConnect();
        return AgentToolOutcome('Disconnected.', note: 'disconnect');
      }
  }
  return _err('Unhandled tool: $name');
}

/// limit 参数归一：默认 20，夹在 1..50。
int _limit(Object? v) {
  final n = _asInt(v) ?? 20;
  return n.clamp(1, 50);
}

/// 把 JSON 数组参数归一成大写呼号集合（忽略非字符串/空值）。
Set<String> _strSet(Object? v) {
  final out = <String>{};
  if (v is List) {
    for (final m in v) {
      final s = _val({'x': m}, 'x').trim().toUpperCase();
      if (s.isNotEmpty) out.add(s);
    }
  }
  return out;
}

/// 把时间参数（ISO-8601 字符串或 epoch 毫秒/秒）归一成 [DateTime]。
/// 解析失败返回 null（调用方视作「未提供」）。
DateTime? _asEpoch(Object? v) {
  if (v == null) return null;
  if (v is int) {
    // 10 位当秒、13 位当毫秒（13 位是 Flutter 的惯例）。
    return DateTime.fromMillisecondsSinceEpoch(v < 100000000000 ? v * 1000 : v);
  }
  final s = '$v'.trim();
  if (s.isEmpty) return null;
  final n = int.tryParse(s);
  if (n != null) {
    return DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n);
  }
  return DateTime.tryParse(s);
}

/// 把 "me"/"我" 或某个呼号解析成坐标。找不到返回 null。
(double, double)? _pointOf(AppState st, String who) {
  final q = who.trim().toUpperCase();
  if (q.isEmpty) return null;
  if (q == 'ME' || q == '我' || q == st.myFullCall.toUpperCase()) {
    final la = st.myLat, ln = st.myLng;
    return (la == null || ln == null) ? null : (la, ln);
  }
  final s = st.stations
      .where((s) => s.call.toUpperCase() == q)
      .firstOrNull;
  if (s == null) return null;
  return (s.lat, s.lng);
}

/// 轨迹取点：`me` = 自身轨迹，否则查台站。返回 GPX 文本或 JSON 列表。
AgentToolOutcome _trackOutcome(AppState st, String who,
    {required bool asGpx, int? limit}) {
  final q = who.trim().toUpperCase();
  if (q.isEmpty) {
    return AgentToolOutcome('"call" is required (use "me" for your own track).');
  }
  final isMe = q == 'ME' || q == '我' || q == st.myFullCall.toUpperCase();
  final List<TrackPt> pts;
  final String label;
  if (isMe) {
    pts = st.myTrack;
    label = 'my track';
  } else {
    final s = st.stations.where((s) => s.call.toUpperCase() == q).firstOrNull;
    if (s == null) return AgentToolOutcome('Station $q not found.');
    pts = s.track;
    label = q;
  }
  if (pts.isEmpty) {
    return AgentToolOutcome('No track points for $label.');
  }
  // limit：从**最新**一端取（跟用户问「最近走过哪」的直觉一致）。
  final sel = (limit != null && limit > 0 && pts.length > limit)
      ? pts.sublist(pts.length - limit)
      : pts;
  if (asGpx) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="APRSLocus">')
      ..writeln('  <trk><name>${_xmlEscape(label)}</name><trkseg>');
    for (final p in sel) {
      b.write('    <trkpt lat="${p.lat}" lon="${p.lng}">');
      b.write('<time>${p.time.toUtc().toIso8601String()}</time>');
      b.writeln('</trkpt>');
    }
    b
      ..writeln('  </trkseg></trk>')
      ..writeln('</gpx>');
    return AgentToolOutcome(b.toString(), note: 'export_track_gpx $label');
  }
  final list = [
    for (final p in sel)
      {
        'time': p.time.toIso8601String(),
        'lat': p.lat,
        'lng': p.lng,
      },
  ];
  return AgentToolOutcome(jsonEncode(list),
      note: 'get_track $label → ${list.length}');
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 台站摘要（多个只读工具共用，避免各写一份字段集）。
Map<String, dynamic> _stationBrief(Station s) => {
      'call': s.call,
      'lat': s.lat,
      'lng': s.lng,
      'comment': s.comment,
      'heard_min_ago': DateTime.now().difference(s.lastHeard).inMinutes,
    };
