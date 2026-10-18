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
import 'net/http_send.dart';
import 'state.dart';
import 'strategy_map.dart';

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
        'Read the current app state: callsign, connection, tracking (beacon) '
        'settings, preferences, counts, and the allowed value ranges. Call this '
        'before changing settings or sending anything.',
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
        'Search recently heard stations by callsign substring; returns call, '
        'position and age.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Callsign or substring.'},
        'limit': {'type': 'integer', 'description': 'Max results (default 20, max 50).'},
      },
      'required': ['query'],
    },
  ),
  const AgentToolSpec(
    name: 'list_stations',
    description: 'List the most recently heard stations, to see what is on the air.',
    parameters: {
      'type': 'object',
      'properties': {
        'limit': {'type': 'integer', 'description': 'Max results (default 20, max 50).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'station_detail',
    description:
        'Full detail for one station (exact call or nearest match): position, '
        'symbol, comment, last heard, track point count.',
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
        'Read recent chat messages (private and group), optionally filtered by '
        'a peer or group call. Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'with': {
          'type': 'string',
          'description': 'Only messages to/from this call or group.',
        },
        'limit': {'type': 'integer', 'description': 'Max messages (default 20, max 50).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'send_message',
    description:
        'Send an APRS text message to a callsign, or to a group by its group '
        'call. Needs "allow sending".',
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
    description: 'Send one position beacon now.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'set_tracking',
    description:
        'Configure automatic position reporting (beacon); only the given fields '
        'change. Unrelated to "beacon auto-start on launch".',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'beacon_enabled': {
          'type': 'boolean',
          'description': 'true = start tracking now, false = stop.',
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
    description: 'Change which stations are shown and how many are kept.',
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
        'Change general preferences (language, dark mode, layout, scale, map '
        'type, material, weather, sensor assist, heat). Only given fields change.',
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
        'Open a screen and optionally centre the map on a station.',
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
          'description': 'Callsign to centre on the map.',
        },
      },
    },
  ),
  const AgentToolSpec(
    name: 'create_task',
    description:
        'Create a task that runs with no user present. "prompt" is the '
        'instruction. trigger "timer" runs on a schedule (interval_minutes 0 = '
        'once, N = every N minutes); trigger "message" runs on each new incoming '
        'message. List tasks first to avoid duplicates.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {'type': 'string', 'description': 'Instruction to run.'},
        'trigger': {
          'type': 'string',
          'enum': ['timer', 'message'],
          'description': '"timer" = schedule (default); "message" = each new message.',
        },
        'interval_minutes': {
          'type': 'integer',
          'description': 'timer only: 0 = once, else every N minutes (min 1).',
        },
      },
      'required': ['prompt'],
    },
  ),
  const AgentToolSpec(
    name: 'list_tasks',
    description: 'List the scheduled agent tasks.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'cancel_task',
    description: 'Cancel a task by its id (see list_tasks).',
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
        'Change the APRS-IS server; only given fields change. Does NOT connect '
        'by itself — call "connect" afterwards. Use only an address the user '
        'gave you.',
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
        'Enable or disable a link source (aprsis, tnc, audio, pkwdwpl, spp); call '
        '"connect" to actually bring links up.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'source': {
          'type': 'string',
          'description': 'aprsis, tnc, audio, pkwdwpl or spp.',
        },
        'enabled': {
          'type': 'boolean',
          'description': 'true = enable, false = disable.',
        },
      },
      'required': ['source', 'enabled'],
    },
  ),
  const AgentToolSpec(
    name: 'connect',
    description:
        'Connect all enabled sources (APRS-IS and/or radio). Refused until the '
        'user has accepted the data & network usage notice.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'disconnect',
    description: 'Disconnect and stop automatic reconnects until the next connect.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'nearby_stations',
    description:
        'List the stations currently nearest the user, nearest first (no search '
        'needed). Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'radius_km': {
          'type': 'number',
          'description': 'Only within this many km (default: current filter).',
        },
        'limit': {'type': 'integer', 'description': 'How many (default 5).'},
      },
    },
  ),
  const AgentToolSpec(
    name: 'reply_message',
    description:
        'Reply to the sender of the latest message in a conversation (no need '
        'to know the callsign). Needs "allow sending".',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'to': {
          'type': 'string',
          'description': 'Call (or group) the incoming message came from.',
        },
        'text': {'type': 'string', 'description': 'The reply text.'},
      },
      'required': ['to', 'text'],
    },
  ),
  const AgentToolSpec(
    name: 'send_group_message',
    description:
        'Send a message to a group by its name or group call (see list_groups). '
        'Needs "allow sending".',
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
    description: 'Create a chat group with the given members. Needs "allow settings".',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'name': {'type': 'string', 'description': 'Group display name.'},
        'members': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Call signs to invite (owner is added automatically).',
        },
      },
      'required': ['name'],
    },
  ),
  const AgentToolSpec(
    name: 'set_task_enabled',
    description: 'Pause or resume a task by its id (see list_tasks).',
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
        'Edit a task in place (see list_tasks); only given fields change. '
        'Changing "trigger" resets the schedule.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': 'Task id from list_tasks.'},
        'prompt': {'type': 'string', 'description': 'New instruction text.'},
        'trigger': {
          'type': 'string',
          'enum': ['timer', 'message'],
          'description': 'timer = schedule; message = each new message.',
        },
        'interval_minutes': {
          'type': 'integer',
          'description': 'timer: 0 = once, else every N min.',
        },
        'run_at': {
          'type': 'string',
          'description': 'timer: run once at this ISO-8601 time (overrides interval).',
        },
      },
      'required': ['id'],
    },
  ),
  const AgentToolSpec(
    name: 'list_task_runs',
    description: 'Recent task run history: when each ran and what happened. Read-only.',
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
    description: 'Clear task run history (one task, or all if id is omitted).',
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
    description: "List the user's followed / favourite stations. Read-only.",
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'update_group',
    description: 'Rename a group and/or add or remove its members.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group name or group call.'},
        'name': {'type': 'string', 'description': 'New display name.'},
        'add': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Callsigns to add.',
        },
        'remove': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Callsigns to remove.',
        },
      },
      'required': ['group'],
    },
  ),
  const AgentToolSpec(
    name: 'join_group',
    description: 'Join a group chat by its group call or name.',
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
    description: 'Leave a group chat (it stays listed, you no longer take part).',
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
    description: 'Delete a group you own from this device.',
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
        'Follow or unfollow a station (followed stations stay on the map); an '
        'unheard call creates a manual contact.',
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
        'Hide a station from the map/list (packets are still received and shown '
        'on the packets page).',
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
        'Set the station status text (the APRS status report, separate from the '
        'position comment). Stored; sent with the next status report.',
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
        'Send the same message to several callsigns (one APRS message each; '
        'radio mode limits each to 67 characters).',
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
        'Read on-device sensors: heart rate, steps today, battery, speed, '
        'course, trip/total mileage. Read-only.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'get_station_packets',
    description:
        'Recent raw APRS packets (optionally from one callsign), with the '
        'digipeater path. Read-only.',
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
        "A station's position track (or \"me\"). Read-only; see "
        'export_track_gpx for GPX.',
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
        'Export a station track as GPX text (nothing is written to disk). Read-only.',
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
        'Distance and initial bearing between two stations or points ("me" for '
        'the user). Read-only.',
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
        'Set a manual (simulated) position, overriding GPS until cleared. Needs '
        'the data notice accepted.',
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
    description: 'Drop the manual position and use real GPS again.',
    mutating: true,
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'http_request',
    description:
        'Make an HTTP request and return the (truncated) response body. Needs '
        '"allow network requests".',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string', 'description': 'Full URL (http/https).'},
        'method': {
          'type': 'string',
          'description': 'HTTP method. Default GET.',
          'enum': ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'HEAD'],
        },
        'headers': {
          'type': 'object',
          'description': 'Optional request headers.',
        },
        'body': {
          'type': 'string',
          'description': 'Optional request body (e.g. JSON string).',
        },
      },
      'required': ['url'],
    },
  ),
  const AgentToolSpec(
    name: 'save_memory',
    description:
        'Remember a durable fact about the user across conversations (name, '
        'callsign, preferences, routines, places). No secrets or transient details.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'The fact to remember, one short sentence.',
        },
      },
      'required': ['text'],
    },
  ),
  const AgentToolSpec(
    name: 'list_memories',
    description: 'List the stored long-term memories. Read-only.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  const AgentToolSpec(
    name: 'forget_memory',
    description:
        'Delete long-term memories matching an id or a text substring. Read the '
        'list first.',
    parameters: {
      'type': 'object',
      'properties': {
        'key': {
          'type': 'string',
          'description': 'A memory id, or a substring of its text.',
        },
      },
      'required': ['key'],
    },
  ),

  // ─── 策略地图：与队友共享标点 / 划线 / 圈 / 集合点 ───
  // 写工具会真的广播 APRS 帧（射频下占时隙），故按 `strategy_` 前缀纳入
  // [_isSendingTool]，受「允许发送」闸门与逐次确认约束。`group` 传群呼号或群名。
  const AgentToolSpec(
    name: 'list_strategy',
    description:
        'List a group\'s shared strategy elements (points, lines, circles, rally '
        'points) with id, kind, owner, label, coordinates, radius, point count. '
        'Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'group': {
          'type': 'string',
          'description':
              'Group call (e.g. BD4TYW-G1) or name. Omit to list every group.',
        },
      },
    },
  ),
  const AgentToolSpec(
    name: 'strategy_add_point',
    description:
        "Add a marker point to a group's shared strategy map and broadcast it to "
        'the group.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'lat': {'type': 'number', 'description': '-90..90'},
        'lng': {'type': 'number', 'description': '-180..180'},
        'label': {
          'type': 'string',
          'description': 'Optional short name (at most 8 characters).',
        },
      },
      'required': ['group', 'lat', 'lng'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_add_rally',
    description:
        "Add a rally (meeting) point to a group's shared strategy map and "
        'broadcast it.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'lat': {'type': 'number', 'description': '-90..90'},
        'lng': {'type': 'number', 'description': '-180..180'},
        'label': {'type': 'string', 'description': 'Optional short name (≤8 characters).'},
      },
      'required': ['group', 'lat', 'lng'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_add_circle',
    description:
        "Add a circle (radius in metres) to a group's shared strategy map and "
        'broadcast it.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'lat': {'type': 'number', 'description': 'Centre latitude, -90..90'},
        'lng': {'type': 'number', 'description': 'Centre longitude, -180..180'},
        'radius_m': {'type': 'number', 'description': 'Radius in metres (1..50000).'},
        'label': {'type': 'string', 'description': 'Optional short name (≤8 characters).'},
        'color': {
          'type': 'integer',
          'description': 'Palette 0..5 (0 red 1 blue 2 green 3 orange 4 purple 5 cyan).',
        },
      },
      'required': ['group', 'lat', 'lng', 'radius_m'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_add_line',
    description:
        "Add a polyline to a group's shared strategy map and broadcast it. "
        'Points: a "lat,lng;lat,lng" string, or a list of [lat,lng] pairs '
        '(up to about 80 points).',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'points': {
          'description':
              'The path: a "lat,lng;lat,lng" string, or a list of [lat,lng] '
              'arrays or {lat,lng} objects.',
        },
        'label': {'type': 'string', 'description': 'Optional short name (≤8 characters).'},
        'color': {
          'type': 'integer',
          'description': 'Palette index 0..5.',
        },
      },
      'required': ['group', 'points'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_update',
    description:
        'Edit a strategy element (by "id") and broadcast the change; only given '
        'fields change. Get the id from list_strategy first.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'id': {'type': 'string', 'description': 'Element id from list_strategy.'},
        'lat': {'type': 'number', 'description': 'New latitude.'},
        'lng': {'type': 'number', 'description': 'New longitude.'},
        'radius_m': {'type': 'number', 'description': 'New radius in metres (circle).'},
        'label': {'type': 'string', 'description': 'New short name (≤8 characters).'},
        'color': {'type': 'integer', 'description': 'New palette index 0..5.'},
        'points': {
          'description': 'New path for a line (same format as strategy_add_line).',
        },
      },
      'required': ['group', 'id'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_delete',
    description:
        "Remove a strategy element (by id) from a group's shared map and "
        'broadcast the deletion. Get the id from list_strategy.',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
        'id': {'type': 'string', 'description': 'Element id from list_strategy.'},
      },
      'required': ['group', 'id'],
    },
  ),
  const AgentToolSpec(
    name: 'strategy_clear',
    description:
        "Delete every strategy element of a group (mine and received) and "
        'broadcast a clear. Use with care.',
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
    name: 'strategy_request_snapshot',
    description:
        'Ask every member of a group to re-send their strategy elements, to '
        'rebuild the shared layer (e.g. after joining).',
    mutating: true,
    parameters: {
      'type': 'object',
      'properties': {
        'group': {'type': 'string', 'description': 'Group call or name.'},
      },
      'required': ['group'],
    },
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
List<Map<String, dynamic>> agentToolSchemas({
  required bool allowSend,
  bool allowNetwork = false,
}) =>
    [
      for (final t in kAgentTools)
        if ((allowSend || !_isSendingTool(t.name)) &&
            (allowNetwork || !_isNetworkTool(t.name)))
          t.toSchema(),
    ];

/// 需要联网权限的工具（`http_request` 可向任意地址发请求）。
bool _isNetworkTool(String name) => name == 'http_request';

/// 会发出 APRS 消息的工具（受「允许发送」开关约束）。
/// `reply_message` 不以 `send_` 开头，但同样是发送，必须一并纳入；
/// `broadcast_message` 发多条单播，同样受此闸门约束。
/// 策略地图的写工具（`strategy_add_*` / `strategy_update` / `strategy_delete` /
/// `strategy_clear` / `strategy_request_snapshot`）会往群里广播 APRS 帧，射频下
/// 占用时隙，同样算「发送」；只读的 `list_strategy` 不在此列。
bool _isSendingTool(String name) =>
    name.startsWith('send_') ||
    name == 'reply_message' ||
    name == 'broadcast_message' ||
    (name.startsWith('strategy_') && name != 'list_strategy');

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
  bool allowedNetwork = false,
}) async {
  final spec = _byName[name];
  if (spec == null) return _err('Unknown tool: $name');

  // 权限闸门（schema 层已隐藏发送类工具，但模型仍可能凭空调用）
  if (_isSendingTool(name) && !allowedSend) {
    return _err('Permission denied: sending messages is disabled in settings.');
  }
  if (_isNetworkTool(name) && !allowedNetwork) {
    return _err(
        'Permission denied: network requests are disabled in settings.');
  }
  if (spec.mutating && name != 'navigate' && !allowedSettings) {
    return _err('Permission denied: changing settings is disabled.');
  }

  // 工具执行期间进入「静默」：智能体的动作不进日志页（见 [AppState.agentQuiet]）。
  // 用 try/finally 包住整个分派，无论工具从哪个分支 return 都会复位。
  st.agentQuiet = true;
  try {
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
          'agent_authorized': st.agentAllowed,
          'data_notice_accepted': st.dataNoticeAccepted,
        },
        'connections': {
          'connected': st.anyLinkUp,
          'user_disconnected': st.userDisconnected,
          'server': st.aprs.server,
          'port': st.aprs.port,
          // 第二条链路不是可选的数据来源（它只是往同一个网络里多发一份），
          // 所以不进下面的 sources，只报它开没开、连没连上。
          'acn_on': st.acnOn,
          'acn_connected': st.acnConnected,
          'sources': {
            'aprsis': st.aprsIsOn,
            'tnc': st.tncOn,
            'audio': st.audioOn,
            'pkwdwpl': st.pkwdwplOn,
            'spp': st.nmeaGpsOn,
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
          'include_sats': st.beaconIncludeSats,
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
        const valid = {'aprsis', 'tnc', 'audio', 'pkwdwpl', 'spp'};
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

    // ─── 联网 ───
    // 真正发出请求前已经过确认层（mutating=true → agentNeedsConfirm），
    // 再加上「联网」权限闸门，双重把关。
    case 'http_request':
      {
        final url = _val(args, 'url').trim();
        if (url.isEmpty) return _err('"url" is required.');
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !(uri.isScheme('http') || uri.isScheme('https'))) {
          return _err('"url" must be an http(s) URL.');
        }
        final method = _val(args, 'method').trim().toUpperCase();
        final headers = <String, String>{};
        final rawHeaders = args['headers'];
        if (rawHeaders is Map) {
          rawHeaders.forEach((k, v) {
            if (v != null) headers['$k'] = '$v';
          });
        }
        final body = _val(args, 'body');
        try {
          final r = await httpSend(
            method.isEmpty ? 'GET' : method,
            uri,
            headers: headers.isEmpty ? null : headers,
            body: body.isEmpty ? null : body,
            timeout: const Duration(seconds: 30),
          );
          final clipped =
              r.length > 4000 ? '${r.substring(0, 4000)}…(truncated)' : r;
          return AgentToolOutcome(clipped,
              note: 'http_request ${method.isEmpty ? 'GET' : method} $url');
        } catch (e) {
          return _err('Request failed: $e');
        }
      }

    // ─── 长期记忆 ───
    // 本地写入、无外部副作用，故不设确认（用户说「记住…」即应立刻生效）。
    // 仍受权限层约束：只读工具的闸门放行，写入前要「允许改设置」。
    case 'save_memory':
      {
        if (!allowedSettings) {
          return _err('Permission denied: changing settings is disabled.');
        }
        final text = _val(args, 'text').trim();
        if (text.isEmpty) return _err('"text" is required.');
        final added = await AgentService.instance.addMemory(text);
        return AgentToolOutcome(
            added ? 'Memory saved.' : 'Already remembered (refreshed).',
            note: 'save_memory');
      }

    case 'list_memories':
      {
        final list = [
          for (final m in AgentService.instance.memories)
            {'id': m.id, 'text': m.text, 'at': m.at.toIso8601String()},
        ];
        return AgentToolOutcome(jsonEncode(list),
            note: 'list_memories → ${list.length}');
      }

    case 'forget_memory':
      {
        if (!allowedSettings) {
          return _err('Permission denied: changing settings is disabled.');
        }
        final key = _val(args, 'key').trim();
        if (key.isEmpty) return _err('"key" is required.');
        final n = await AgentService.instance.forgetMemory(key);
        return AgentToolOutcome(
            n == 0 ? 'No matching memory found.' : 'Forgot $n memory(ies).',
            note: 'forget_memory $key');
      }

    // ─── 策略地图（与队友共享标点 / 划线 / 圈 / 集合点）───
    //
    // 落图/广播/群聊提示全部复用 [AppState.putStrategy] 等既有入口，工具层只做
    // 参数校验 + 群解析，不重复实现协议。

    case 'list_strategy':
      {
        final q = _val(args, 'group');
        final groups = q.trim().isEmpty
            ? st.chatGroups.toList()
            : st.chatGroups.where((g) => _sameGroup(g, q)).toList();
        if (q.trim().isNotEmpty && groups.isEmpty) {
          return _err('No group named "$q".');
        }
        final out = <Map<String, dynamic>>[];
        final me = _bareCall(st.myCall);
        for (final g in groups) {
          for (final it in st.strategyOf(g.groupCall)) {
            out.add({
              'group': g.name,
              'group_call': g.groupCall,
              'id': it.id,
              'kind': it.kind.name,
              'owner': it.owner,
              'mine': it.owner == me,
              'label': it.label,
              'lat': it.lat,
              'lng': it.lng,
              if (it.kind == StrategyKind.circle) 'radius_m': it.radiusM,
              if (it.kind == StrategyKind.line) 'points': it.path.length,
              if (it.colorIndex >= 0) 'color': it.colorIndex,
            });
          }
        }
        return AgentToolOutcome(jsonEncode(out),
            note: 'list_strategy → ${out.length}');
      }

    case 'strategy_add_point':
    case 'strategy_add_rally':
    case 'strategy_add_circle':
    case 'strategy_add_line':
      {
        final g = _resolveGroup(st, _val(args, 'group'));
        if (g == null) return _err('No group "${_val(args, 'group')}".');
        final kind = switch (name) {
          'strategy_add_rally' => StrategyKind.rally,
          'strategy_add_circle' => StrategyKind.circle,
          'strategy_add_line' => StrategyKind.line,
          _ => StrategyKind.point,
        };
        final label = _strategyLabel(args['label']);
        final color = _strategyColor(args['color']);
        if (color == null) return _err('"color" must be an integer 0..5.');

        if (kind == StrategyKind.line) {
          final pts = _parsePath(args['points']);
          if (pts == null || pts.isEmpty) {
            return _err('"points" must be "lat,lng;lat,lng" or a list of pairs.');
          }
          if (pts.length > _maxStrategyLinePts) {
            return _err('Too many points (max $_maxStrategyLinePts).');
          }
          final ok = st.putStrategy(g.groupCall, StrategyKind.line,
              lat: pts.first.$1,
              lng: pts.first.$2,
              path: pts,
              label: label,
              colorIndex: color);
          if (!ok) {
            return _err('The line cannot fit into APRS frames (too long?).');
          }
          return AgentToolOutcome(
              'Line with ${pts.length} point(s) added to ${g.name}.',
              note: 'strategy_add_line → ${g.name} (${pts.length} pts)');
        }

        final lat = _asDouble(args['lat']);
        final lng = _asDouble(args['lng']);
        if (lat == null || lng == null || !_validLatLng(lat, lng)) {
          return _err('"lat"/"lng" are required and must be in range.');
        }
        var radius = 0;
        if (kind == StrategyKind.circle) {
          final r = _asInt(args['radius_m']);
          if (r == null || r <= 0 || r > StrategyProto.maxRadiusM) {
            return _err('"radius_m" must be 1..${StrategyProto.maxRadiusM}.');
          }
          radius = r;
        }
        final ok = st.putStrategy(g.groupCall, kind,
            lat: lat, lng: lng, radiusM: radius,
            label: label, colorIndex: color);
        if (!ok) return _err('The element cannot fit into an APRS frame.');
        return AgentToolOutcome('${_strategyKindNoun(kind)} added to ${g.name}.',
            note: '$name → ${g.name}');
      }

    case 'strategy_update':
      {
        final g = _resolveGroup(st, _val(args, 'group'));
        if (g == null) return _err('No group "${_val(args, 'group')}".');
        final id = _val(args, 'id').trim().toUpperCase();
        if (id.isEmpty) return _err('"id" is required.');
        final prev = st.strategyItems['${g.groupCall.toUpperCase()}|$id'];
        if (prev == null) {
          return _err('No element "$id" in ${g.name} (use list_strategy).');
        }
        final lat = args['lat'] == null ? prev.lat : _asDouble(args['lat']);
        final lng = args['lng'] == null ? prev.lng : _asDouble(args['lng']);
        if (lat == null || lng == null || !_validLatLng(lat, lng)) {
          return _err('"lat"/"lng" must be in range.');
        }
        var radius = prev.radiusM;
        if (args['radius_m'] != null) {
          final r = _asInt(args['radius_m']);
          if (r == null || r <= 0 || r > StrategyProto.maxRadiusM) {
            return _err('"radius_m" must be 1..${StrategyProto.maxRadiusM}.');
          }
          radius = r;
        }
        final label = args['label'] == null
            ? prev.label
            : _strategyLabel(args['label']);
        final color = args['color'] == null
            ? prev.colorIndex
            : _strategyColor(args['color']);
        if (color == null) return _err('"color" must be an integer 0..5.');
        var path = prev.path;
        if (args['points'] != null) {
          final pts = _parsePath(args['points']);
          if (pts == null || pts.isEmpty) {
            return _err('"points" must be "lat,lng;lat,lng" or a list of pairs.');
          }
          if (pts.length > _maxStrategyLinePts) {
            return _err('Too many points (max $_maxStrategyLinePts).');
          }
          path = pts;
        }
        final ok = st.putStrategy(g.groupCall, prev.kind,
            id: id,
            lat: lat,
            lng: lng,
            radiusM: radius,
            path: path,
            label: label,
            colorIndex: color);
        if (!ok) return _err('The change cannot fit into APRS frames.');
        return AgentToolOutcome('Updated "${id}" in ${g.name}.',
            note: 'strategy_update → ${g.name} $id');
      }

    case 'strategy_delete':
      {
        final g = _resolveGroup(st, _val(args, 'group'));
        if (g == null) return _err('No group "${_val(args, 'group')}".');
        final id = _val(args, 'id').trim().toUpperCase();
        if (id.isEmpty) return _err('"id" is required.');
        if (!st.strategyItems.containsKey('${g.groupCall.toUpperCase()}|$id')) {
          return _err('No element "$id" in ${g.name} (use list_strategy).');
        }
        st.deleteStrategy(g.groupCall, id);
        return AgentToolOutcome('Deleted "$id" from ${g.name}.',
            note: 'strategy_delete → ${g.name} $id');
      }

    case 'strategy_clear':
      {
        final g = _resolveGroup(st, _val(args, 'group'));
        if (g == null) return _err('No group "${_val(args, 'group')}".');
        final n = st.strategyOf(g.groupCall).length;
        if (n == 0) {
          return AgentToolOutcome('${g.name} already has no strategy elements.',
              note: 'strategy_clear (empty)');
        }
        st.clearStrategy(g.groupCall);
        return AgentToolOutcome('Cleared $n element(s) from ${g.name}.',
            note: 'strategy_clear → ${g.name}');
      }

    case 'strategy_request_snapshot':
      {
        final g = _resolveGroup(st, _val(args, 'group'));
        if (g == null) return _err('No group "${_val(args, 'group')}".');
        st.requestStrategySnapshot(g.groupCall);
        return AgentToolOutcome(
            'Asked ${g.name} members to re-send their strategy elements.',
            note: 'strategy_request_snapshot → ${g.name}');
      }
    }
  } finally {
    st.agentQuiet = false;
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

// ─── 策略地图工具的辅助函数 ───
//
// 工具层只做「参数校验 + 群解析 + 调用 AppState 入口」，协议细节一律留给
// [AppState.putStrategy] / [StrategyProto]，这些函数是它们之间的粘合层。

/// 一条线的最大点数。与 [StrategyProto.maxParts] 对应（每片约 2 个点），
/// 超过这个规模先在这里挡下，别让模型构造出几十条广播把时隙刷爆。
const int _maxStrategyLinePts = StrategyProto.maxParts * 2;

/// 经纬度是否在合法范围（并挡掉 NaN/Infinity）。
bool _validLatLng(double lat, double lng) =>
    lat.isFinite &&
    lng.isFinite &&
    lat >= -90 &&
    lat <= 90 &&
    lng >= -180 &&
    lng <= 180;

/// 去掉呼号的 `-SSID`，得到基呼号（大写）。与 [AppState._baseCall] 同一语义
/// —— 策略元素里存的 owner 就是这个形态，比较「是不是我建的」时必须一致。
String _bareCall(String call) {
  final s = call.trim().toUpperCase();
  final i = s.indexOf('-');
  return i <= 0 ? s : s.substring(0, i);
}

/// 群名 / 群呼号（大小写不敏感）是否匹配。用于 list_strategy 的过滤。
bool _sameGroup(ChatGroup g, String q) {
  final key = q.trim().toUpperCase();
  if (key.isEmpty) return false;
  return g.groupCall.toUpperCase() == key || g.name.toUpperCase() == key;
}

/// 把一个群名或群呼号解析成 [ChatGroup]；找不到返回 null。
ChatGroup? _resolveGroup(AppState st, String q) {
  final key = q.trim().toUpperCase();
  if (key.isEmpty) return null;
  for (final g in st.chatGroups) {
    if (g.groupCall.toUpperCase() == key || g.name.toUpperCase() == key) {
      return g;
    }
  }
  return null;
}

/// 策略元素的类型名词（工具回执里用，跟随协议而非界面语言）。
String _strategyKindNoun(StrategyKind k) => switch (k) {
  StrategyKind.point => 'Point',
  StrategyKind.rally => 'Rally point',
  StrategyKind.circle => 'Circle',
  StrategyKind.line => 'Line',
};

/// 标签归一：去首尾空白，按**字符**（不是字节）截断到
/// [StrategyProto.maxLabelLen]。超长直接截断而不是报错 —— 模型给个长名字也
/// 照样能出图，没必要为名字把整个操作打回。
String _strategyLabel(Object? v) {
  final raw = _val({'x': v}, 'x').trim();
  if (raw.isEmpty) return '';
  final cs = raw.runes.toList();
  if (cs.length <= StrategyProto.maxLabelLen) return raw;
  return String.fromCharCodes(cs.take(StrategyProto.maxLabelLen));
}

/// 颜色下标归一：`null` / `-1` 表示「用默认色」；其余必须是
/// `0..palette.length-1`。非法返回 null（调用方据此报错）。
int? _strategyColor(Object? v) {
  if (v == null) return -1;
  final n = _asInt(v);
  if (n == null) return null;
  if (n == -1) return -1;
  if (n < 0 || n >= StrategyProto.palette.length) return null;
  return n;
}

/// 解析一条线的路径。接受三种写法：
///   - `"lat,lng;lat,lng"` 字符串；
///   - `[[lat,lng], [lat,lng]]`；
///   - `[{"lat":..,"lng":..}, ...]`。
/// 返回点列；格式非法或全部越界时返回 null。
List<(double, double)>? _parsePath(Object? v) {
  final out = <(double, double)>[];
  bool add(Object? latO, Object? lngO) {
    final la = _asDouble(latO);
    final ln = _asDouble(lngO);
    if (la == null || ln == null || !_validLatLng(la, ln)) return false;
    out.add((la, ln));
    return true;
  }

  if (v is String) {
    for (final seg in v.split(';')) {
      final t = seg.trim();
      if (t.isEmpty) continue;
      final parts = t.split(',');
      if (parts.length < 2 || !add(parts[0], parts[1])) return null;
    }
    return out.isEmpty ? null : out;
  }
  if (v is List) {
    for (final e in v) {
      if (e is List && e.length >= 2) {
        if (!add(e[0], e[1])) return null;
      } else if (e is Map) {
        if (!add(e['lat'], e['lng'])) return null;
      } else {
        return null;
      }
    }
    return out.isEmpty ? null : out;
  }
  return null;
}
