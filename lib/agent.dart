/// ─── 智能体模式（AI Agent）───
///
/// 实验功能：用户自行配置一个 **OpenAI 兼容** 的接口（Base URL + Key + 模型），
/// 打开后屏幕上出现一个 AI 聊天框；智能体可以**调用工具**帮用户改设置、发消息、
/// 查台站。
///
/// ## 分层（为什么这样切）
///
/// * 本文件（`agent.dart`）：配置、对话历史、LLM 调用与**工具调用循环**。
///   它**不 import `state.dart`** —— 否则 `state.dart` 要引用本文件的配置时就会
///   循环导入。工具由上层通过回调注入：`send()` 只认「工具表 + 执行器 + 确认器」
///   三个回调，不知道 AppState 的存在。
/// * [agent_tools.dart]：把 AppState 包装成上面那三个回调（真正的工具实现）。
/// * [agent_ui.dart]：浮动聊天框 + 设置页。
///
/// ## 安全
///
/// Key 只存在本机 `SharedPreferences`，**不写日志、不进任何网络请求之外的用途**。
/// 改动设置 / 发送消息这类有副作用且不可撤销的操作，走 [AgentService.send] 的
/// `confirm` 回调 → 由界面弹确认框，用户点了「允许」才真正执行。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'net/http_send.dart';

/// 一条工具调用（来自模型的 tool_calls）
class AgentToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  static AgentToolCall fromJson(Map j) {
    final fn = (j['function'] as Map?) ?? const {};
    Map<String, dynamic> args = const {};
    final raw = fn['arguments'];
    if (raw is Map) {
      args = raw.map((k, v) => MapEntry('$k', v));
    } else if (raw is String && raw.trim().isNotEmpty) {
      // 不少兼容接口把 arguments 作为 JSON 字符串返回
      try {
        final d = jsonDecode(raw);
        if (d is Map) args = d.map((k, v) => MapEntry('$k', v));
      } catch (_) {}
    }
    return AgentToolCall(
      id: '${j['id'] ?? ''}',
      name: '${fn['name'] ?? ''}',
      arguments: args,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      };
}

/// 聊天消息（role 直接用 OpenAI 的写法，便于序列化）
class AgentMessage {
  final String role; // system / user / assistant / tool
  String content;
  List<AgentToolCall> toolCalls;
  String? toolCallId; // role=tool 时对应哪次调用
  String? name; // role=tool 时的工具名

  AgentMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const [],
    this.toolCallId,
    this.name,
  });

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isTool => role == 'tool';

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (toolCalls.isNotEmpty)
          'tool_calls': toolCalls.map((c) => c.toJson()).toList(),
        if (toolCallId != null) 'tool_call_id': toolCallId,
        if (name != null) 'name': name,
      };

  static AgentMessage fromJson(Map j) => AgentMessage(
        role: '${j['role'] ?? 'assistant'}',
        content: '${j['content'] ?? ''}',
        toolCalls: [
          for (final c in (j['tool_calls'] as List? ?? const []))
            if (c is Map) AgentToolCall.fromJson(c),
        ],
        toolCallId: j['tool_call_id']?.toString(),
        name: j['name']?.toString(),
      );
}

/// 智能体配置（全部由用户填写）
class AgentConfig {
  bool enabled;
  String baseUrl;
  String apiKey;
  String model;
  String systemPrompt;

  /// 允许智能体发送消息（私信 / 群消息 / 信标）
  bool allowSend;

  /// 允许智能体修改设置（关闭后只能查看）
  bool allowSettings;

  /// 免确认白名单：这些工具被执行时不再逐次弹确认（用户点过「始终允许」）。
  ///
  /// 与 [allowSettings] 的分工：后者是「能不能做」，这里只是「要不要每次问」。
  /// 敏感工具（发消息）默认不进这个名单，需要用户显式点「始终允许」才会加。
  Set<String> alwaysAllow;

  /// 收到别人发来的消息时，自动让智能体代拟一条回复（默认关，属实验能力）。
  ///
  /// 安全阀：只回复**私聊**（[replyGroups] 打开才含群聊）、受安静时段与冷却限制、
  /// 且仅当用户在最近一段时间内活跃过（避免后台无人值守时乱回复）。
  bool autoReply;

  /// 自动回复是否也覆盖群聊（默认关：群里自动说话风险更大）。
  bool replyGroups;

  /// 自动回复冷却：同一会话在这么多秒内不重复自动回复（防止双方机器人互刷）。
  int autoReplyCooldownSec;

  /// 安静时段，格式 `HH:MM-HH:MM`（可为空 = 不限）。跨零点（如 23:00-07:00）也支持。
  String quietHours;

  AgentConfig({
    this.enabled = false,
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.systemPrompt = '',
    this.allowSend = false,
    this.allowSettings = false,
    Set<String>? alwaysAllow,
    this.autoReply = false,
    this.replyGroups = false,
    this.autoReplyCooldownSec = 60,
    this.quietHours = '',
  }) : alwaysAllow = alwaysAllow ?? <String>{};

  /// 配置是否已填写到「可发起请求」的程度
  bool get ready =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  /// 实际的 chat/completions 地址：用户既可填到 `/v1`，也可直接填带
  /// `/chat/completions` 的完整地址。
  String get endpoint {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    if (u.endsWith('/chat/completions')) return u;
    return '$u/chat/completions';
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'systemPrompt': systemPrompt,
        'allowSend': allowSend,
        'allowSettings': allowSettings,
        'alwaysAllow': alwaysAllow.toList(),
        'autoReply': autoReply,
        'replyGroups': replyGroups,
        'autoReplyCooldownSec': autoReplyCooldownSec,
        'quietHours': quietHours,
      };

  static AgentConfig fromJson(Object? j) {
    final c = AgentConfig();
    if (j is! Map) return c;
    String s(String k, String fb) => j[k]?.toString() ?? fb;
    return AgentConfig(
      enabled: j['enabled'] == true,
      baseUrl: s('baseUrl', c.baseUrl),
      apiKey: s('apiKey', c.apiKey),
      model: s('model', c.model),
      systemPrompt: s('systemPrompt', c.systemPrompt),
      allowSend: j['allowSend'] == true,
      allowSettings: j['allowSettings'] == true,
      alwaysAllow: {
        for (final v in (j['alwaysAllow'] as List? ?? const [])) '$v',
      },
      autoReply: j['autoReply'] == true,
      replyGroups: j['replyGroups'] == true,
      autoReplyCooldownSec:
          int.tryParse('${j['autoReplyCooldownSec']}') ?? c.autoReplyCooldownSec,
      quietHours: s('quietHours', c.quietHours),
    );
  }
}

/// 一个由智能体「到点」或「收到消息」触发的任务，触发后以 [prompt] 作为用户
/// 指令跑一轮智能体。
///
/// 设计上**只存「做什么」不存「怎么发」**：真正执行走的是和手动聊天完全相同的
/// [AgentService.send] 路径（因此权限闸门、确认、工具链全部一致），定时器 / 消息
/// 回调只负责触发。这样「改了一处」不会出现「手动能用、触发不能用」的分叉。
///
/// [trigger] 区分两种触发源：定时（[AgentTaskTrigger.timer]）与收到消息
/// （[AgentTaskTrigger.message]）。二者的「做什么」是同一套，只是被谁唤醒不同。
enum AgentTaskTrigger { timer, message }

class AgentTask {
  final String id;
  String prompt;
  final DateTime createdAt;
  DateTime? lastRun;

  /// 触发源。默认定时（兼容旧数据）。
  AgentTaskTrigger trigger;

  /// 循环间隔（分钟）。0 = 只跑一次。[trigger] 为 message 时不使用。
  int intervalMinutes;

  bool enabled;

  AgentTask({
    required this.id,
    required this.prompt,
    DateTime? createdAt,
    this.lastRun,
    this.trigger = AgentTaskTrigger.timer,
    this.intervalMinutes = 0,
    this.enabled = true,
  }) : createdAt = createdAt ?? DateTime.now();

  bool get recurring => intervalMinutes > 0;

  /// 下一次该跑的时刻（只跑一次的任务跑完即视为不再触发）。
  ///
  /// 消息触发型**没有「时刻」**（由 [AppState.onNewMessage] 唤醒），返回 null，
  /// 于是 [dueTasks] 天然不会把它当定时任务轮询到。
  DateTime? get nextRun {
    if (!enabled) return null;
    if (trigger == AgentTaskTrigger.message) return null;
    if (!recurring) {
      return lastRun == null ? createdAt : null;
    }
    final base = lastRun ?? createdAt;
    return base.add(Duration(minutes: intervalMinutes));
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'prompt': prompt,
        'createdAt': createdAt.toIso8601String(),
        'lastRun': lastRun?.toIso8601String(),
        'trigger': trigger.name,
        'intervalMinutes': intervalMinutes,
        'enabled': enabled,
      };

  static AgentTask? fromJson(Object? j) {
    if (j is! Map) return null;
    final prompt = '${j['prompt'] ?? ''}'.trim();
    if (prompt.isEmpty) return null;
    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.tryParse('$v');
    return AgentTask(
      id: '${j['id'] ?? ''}',
      prompt: prompt,
      createdAt: dt(j['createdAt']),
      lastRun: dt(j['lastRun']),
      trigger: '${j['trigger']}' == AgentTaskTrigger.message.name
          ? AgentTaskTrigger.message
          : AgentTaskTrigger.timer,
      intervalMinutes:
          int.tryParse('${j['intervalMinutes']}') ?? 0,
      enabled: j['enabled'] != false,
    );
  }
}

/// 用户没自定义系统提示时用的默认提示。
///
/// 用英文写：各家用模型对英文系统提示的遵循度最稳；但明确要求它**用用户的语言
/// 回复**，否则中文用户会收到英文回答。提醒它只依据工具返回值作答、不要编造
/// 台站/消息数据，也不要夸大自己的能力。
const String kDefaultSystemPrompt = '''
You are the in-app assistant of APRSLocus, an APRS client. Help the user
understand and operate the app: answer questions and, when needed, call the
provided tools to read state, change settings, send messages or jump to a
screen.

Rules:
- Always reply in the SAME language the user writes in.
- BE PROACTIVE WITH TOOLS. Whenever an answer depends on current data (what is
  on the air, the user's settings, their chats, connectivity) or the user asks
  you to DO something, CALL THE TOOLS instead of answering from memory, guessing
  or asking the user to look it up themselves. Do not say "I cannot" or "I don't
  know" before you have tried the relevant tool — chain several tool calls when
  needed (read -> decide -> act), then summarise what you did.
- Before changing settings or sending anything, call `get_app_state` first to
  see the current values. Respect the allowed value ranges it returns.
- Never invent stations, messages or settings. Only state facts that came from
  a tool result; if you did not read it, say you do not know.
- Tools that change settings or send messages require the user's confirmation;
  explain briefly what you are about to do before calling them.
- Use `read_messages` to read the user's conversations and `list_stations` /
  `search_stations` / `nearby_stations` / `station_detail` to inspect what is on
  the air. These are read-only and never need confirmation.
- To answer an incoming message use `reply_message`; to talk to a whole group use
  `send_group_message` (find it with `list_groups`). `create_group` makes a new
  group. All of these need the "allow sending"/"allow settings" permission and
  the user's confirmation.
- You can create work that runs without the user watching, with `create_task`.
  `trigger` = "timer" (default) runs on a schedule (interval_minutes = 0 runs
  once); `trigger` = "message" runs the instruction each time a new APRS message
  arrives. A background run happens WITHOUT the user watching: only use it for
  things that are already permitted (e.g. reading and reporting), never for a
  one-off action that still needs a confirmation — that will just be denied.
  List existing tasks before creating one so you do not duplicate it.
- You can help with connectivity: `set_connection_server` changes the APRS-IS
  server, `set_connection_source` enables/disables a link, and `connect` /
  `disconnect` bring the link up or down. Setting a server does NOT connect by
  itself. Only use a server address the user actually gave you — never make one
  up. If the user has not accepted the data & network usage notice, `connect`
  is refused; tell them to accept it in the app first.
- Keep answers short and concrete.
''';

/// 智能体调用失败（消息已是可读文本）
class AgentException implements Exception {
  final String message;
  AgentException(this.message);
  @override
  String toString() => message;
}

/// 工具执行结果
class AgentToolOutcome {
  /// 回给模型的文本（成功或失败的说明）
  final String text;

  /// 界面上展示的一行摘要（可空）
  final String? note;

  const AgentToolOutcome(this.text, {this.note});
}

/// 执行一次工具调用。上层（[agent_tools.dart]）负责实现。
typedef AgentToolExecutor = Future<AgentToolOutcome> Function(
    String name, Map<String, dynamic> args);

/// 有副作用的工具执行前的确认结果。
enum AgentConfirmResult { deny, allowOnce, allowAlways }

/// 有副作用的工具执行前的确认。返回 [AgentConfirmResult]（deny / 仅此次 / 始终允许）。
typedef AgentToolConfirmer = Future<AgentConfirmResult> Function(
    String name, Map<String, dynamic> args);

/// 判断某个工具是否需要用户确认（由上层依据工具表决定，agent.dart 不认识工具表）。
typedef AgentNeedsConfirm = bool Function(String name);

/// 智能体服务：配置、历史与 LLM 调用循环（单例）
class AgentService extends ChangeNotifier {
  AgentService._();
  static final AgentService instance = AgentService._();

  static const _kConfig = 'agentConfigJson';
  static const _kHistory = 'agentChatHistoryJson';
  static const _kTasks = 'agentTasksJson';

  /// 单轮对话里工具调用的最大往返次数（防止模型死循环）
  static const int maxToolRounds = 6;

  final AgentConfig config = AgentConfig();
  final List<AgentMessage> messages = [];

  /// 定时任务（内存 + 磁盘）。
  final List<AgentTask> tasks = [];

  bool loaded = false;
  bool busy = false;

  /// 自动回复冷却：会话 key（呼号/群）→ 上次自动回复时刻。
  final Map<String, DateTime> _autoReplyAt = {};

  /// 取消令牌：自增即让进行中的 [send] 在下一个检查点退出
  int _epoch = 0;

  Future<void> load() async {
    if (loaded) return;
    loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final c = p.getString(_kConfig);
      if (c != null && c.isNotEmpty) {
        _copy(AgentConfig.fromJson(jsonDecode(c)), config);
      }
      final h = p.getString(_kHistory);
      if (h != null && h.isNotEmpty) {
        final list = jsonDecode(h);
        if (list is List) {
          for (final m in list) {
            if (m is Map) messages.add(AgentMessage.fromJson(m));
          }
        }
      }
      final tk = p.getString(_kTasks);
      if (tk != null && tk.isNotEmpty) {
        final list = jsonDecode(tk);
        if (list is List) {
          for (final t in list) {
            final task = AgentTask.fromJson(t);
            if (task != null) tasks.add(task);
          }
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  static void _copy(AgentConfig from, AgentConfig to) {
    to
      ..enabled = from.enabled
      ..baseUrl = from.baseUrl
      ..apiKey = from.apiKey
      ..model = from.model
      ..systemPrompt = from.systemPrompt
      ..allowSend = from.allowSend
      ..allowSettings = from.allowSettings
      ..alwaysAllow = {...from.alwaysAllow}
      ..autoReply = from.autoReply
      ..replyGroups = from.replyGroups
      ..autoReplyCooldownSec = from.autoReplyCooldownSec
      ..quietHours = from.quietHours;
  }

  Future<void> saveConfig() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kConfig, jsonEncode(config.toJson()));
    } catch (_) {}
    notifyListeners();
  }

  Future<void> saveTasks() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kTasks, jsonEncode(tasks.map((t) => t.toJson()).toList()));
    } catch (_) {}
    notifyListeners();
  }

  /// 新增一个任务并落盘，返回它。
  Future<AgentTask> addTask(
    String prompt, {
    AgentTaskTrigger trigger = AgentTaskTrigger.timer,
    int intervalMinutes = 0,
  }) async {
    final t = AgentTask(
      id: 't${DateTime.now().microsecondsSinceEpoch}',
      prompt: prompt.trim(),
      trigger: trigger,
      intervalMinutes: intervalMinutes < 0 ? 0 : intervalMinutes,
    );
    tasks.add(t);
    await saveTasks();
    return t;
  }

  Future<void> removeTask(String id) async {
    tasks.removeWhere((t) => t.id == id);
    await saveTasks();
  }

  Future<void> setTaskEnabled(String id, bool on) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    t.enabled = on;
    await saveTasks();
  }

  /// 标一个任务已跑过（循环任务据此顺延下一次）。
  Future<void> markTaskRun(String id) async {
    final t = tasks.where((t) => t.id == id).firstOrNull;
    if (t == null) return;
    t.lastRun = DateTime.now();
    // 只跑一次的任务跑完即停用（不再触发），但保留列表让用户看到它跑过。
    if (!t.recurring) t.enabled = false;
    await saveTasks();
  }

  /// 到点该跑的任务（在 [now] 之前应触发且仍启用）。
  List<AgentTask> dueTasks(DateTime now) =>
      [for (final t in tasks) if (t.nextRun != null && !t.nextRun!.isAfter(now)) t];

  Future<void> saveHistory() async {
    try {
      final p = await SharedPreferences.getInstance();
      // 只留最近 60 条。**必须从一个 user 消息开始**：OpenAI 要求 assistant 的
      // 每个 tool_calls 都紧跟对应的 tool 回复；若裁剪边界正好落在中间，留下
      // 一条孤立的 tool 消息，下一次请求会整段报错（而且是很难查的 400）。
      var start = messages.length > 60 ? messages.length - 60 : 0;
      while (start < messages.length && messages[start].role != 'user') {
        start++;
      }
      final recent = messages.sublist(start);
      await p.setString(
          _kHistory, jsonEncode(recent.map((m) => m.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> clearHistory() async {
    messages.clear();
    await saveHistory();
    notifyListeners();
  }

  /// 恢复出厂：清配置与历史（只动内存，磁盘由 AppState.factoryReset 统一清）
  void resetToDefaults() {
    _copy(AgentConfig(), config);
    messages.clear();
    tasks.clear();
    _autoReplyAt.clear();
    busy = false;
  }

  /// 自动回复是否可用（权限 + 开关 + 不在安静时段）。
  bool canAutoReply(DateTime now) =>
      config.enabled && config.autoReply && !inQuietHours(now);

  /// [now] 是否落在 [AgentConfig.quietHours] 指定的安静时段内。
  bool inQuietHours(DateTime now) {
    final r = _parseQuiet(config.quietHours);
    if (r == null) return false;
    final m = now.hour * 60 + now.minute;
    final (a, b) = r;
    return a <= b ? (m >= a && m < b) : (m >= a || m < b); // 后者=跨零点
  }

  /// 解析 `HH:MM-HH:MM` → (起始分钟, 结束分钟)；非法返回 null。
  static (int, int)? _parseQuiet(String s) {
    final m =
        RegExp(r'^\s*(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})\s*$').firstMatch(s);
    if (m == null) return null;
    int h(int i) => int.parse(m.group(i)!);
    int mi(int i) => int.parse(m.group(i + 1)!);
    final a = h(1) * 60 + mi(1);
    final b = h(3) * 60 + mi(3);
    if (a >= 1440 || b > 1440) return null;
    return (a, b);
  }

  /// 记录一次自动回复并判断是否已过冷却。
  bool autoReplyAllowed(String convoKey, DateTime now) {
    final last = _autoReplyAt[convoKey];
    if (last != null &&
        now.difference(last).inSeconds < config.autoReplyCooldownSec) {
      return false;
    }
    _autoReplyAt[convoKey] = now;
    return true;
  }

  /// 中止进行中的对话
  void cancel() {
    _epoch++;
    busy = false;
    notifyListeners();
  }

  /// 发一条用户消息并跑完整个「模型 ↔ 工具」循环。
  ///
  /// [tools] 是给模型的工具 schema（OpenAI tools 格式）；
  /// [execute] 真正执行某个工具；[confirm] 在「有副作用」的工具执行前询问用户，
  /// 返回 false 则不执行（并把「被拒绝」作为工具结果回给模型）。
  Future<void> send(
    String text, {
    required List<Map<String, dynamic>> tools,
    required AgentToolExecutor execute,
    required AgentToolConfirmer confirm,
    required AgentNeedsConfirm needsConfirm,
    required String needConfigText,
    required String Function(String raw) formatError,
  }) async {
    final t = text.trim();
    if (t.isEmpty || busy) return;
    if (!config.ready) {
      throw AgentException(needConfigText);
    }
    final my = ++_epoch;
    busy = true;
    messages.add(AgentMessage(role: 'user', content: t));
    notifyListeners();

    try {
      // 有些模型（尤其是小模型）会「聊一句」就收尾、明明该查数据却不调工具。
      // 头一轮若一个工具都没调，就**再要一轮**并临时把 tool_choice 设成
      // required，逼它先取一次数据 / 执行动作；只逼这一次，之后回到 auto，
      // 免得把每一句寒暄都变成工具调用。
      var nudged = false;
      for (var round = 0; round < maxToolRounds; round++) {
        if (_epoch != my) return; // 被取消
        final force = !nudged && tools.isNotEmpty;
        // 只在本轮「逼」；下轮起回到 auto（否则模型永远给不出最终回答，
        // 会一路调到 maxToolRounds 也没有收尾）。
        nudged = true;
        AgentMessage reply;
        try {
          reply = await _chat(tools, requireTool: force);
        } on AgentException {
          // 有的 OpenAI 兼容后端不认 tool_choice:"required"：退回 auto 再试一次，
          // 不能因为「强制」这一步失败就把整轮对话搞挂。
          if (!force) rethrow;
          reply = await _chat(tools);
        }
        if (_epoch != my) return;
        final calls = reply.toolCalls;

        if (calls.isEmpty && force) {
          // 被强制却仍没调工具（少见）：收下这条回复，当普通回答结束本轮。
          messages.add(reply);
          notifyListeners();
          break;
        }

        messages.add(reply);
        notifyListeners();

        if (calls.isEmpty) break;

        for (final call in calls) {
          // 取消后不再执行，但**仍要**为每个 tool_call 补一条 tool 消息：
          // OpenAI 要求 assistant 里的每个 tool_calls 都有对应回复，缺一条
          // 会让下一次请求整段历史上报错。
          if (_epoch != my) {
            messages.add(AgentMessage(
              role: 'tool',
              content: 'Canceled by user.',
              toolCallId: call.id,
              name: call.name,
            ));
            continue;
          }
          var result = '';
          // 免确认判定交给上层（它知道工具表）：只读工具、navigate，或用户已在
          // 「始终允许」名单里放行的工具，都直接执行。
          final needsAsk =
              needsConfirm(call.name) && !config.alwaysAllow.contains(call.name);
          if (needsAsk) {
            final decision = await confirm(call.name, call.arguments);
            if (decision == AgentConfirmResult.deny) {
              result = 'User denied this action.';
            } else {
              if (decision == AgentConfirmResult.allowAlways) {
                config.alwaysAllow.add(call.name);
                unawaited(saveConfig());
              }
              final outcome = await execute(call.name, call.arguments);
              result = outcome.text;
            }
          } else {
            final outcome = await execute(call.name, call.arguments);
            result = outcome.text;
          }
          messages.add(AgentMessage(
            role: 'tool',
            content: result,
            toolCallId: call.id,
            name: call.name,
          ));
          notifyListeners();
        }
        if (_epoch != my) return;
      }
    } catch (e) {
      messages.add(AgentMessage(
        role: 'assistant',
        content: formatError('$e'),
      ));
    } finally {
      if (_epoch == my) busy = false;
      notifyListeners();
      unawaited(saveHistory());
    }
  }

  /// 组装发给模型的消息数组
  List<Map<String, dynamic>> _wireMessages() {
    final out = <Map<String, dynamic>>[];
    // 用户没写系统提示时用内置默认：否则模型没有任何角色设定，工具用了也不解释、
    // 甚至可能编造台站数据。用户填了就以用户的为准。
    final sp = config.systemPrompt.trim().isEmpty
        ? kDefaultSystemPrompt
        : config.systemPrompt.trim();
    out.add({'role': 'system', 'content': sp});
    for (final m in messages) {
      out.add(m.toJson());
    }
    return out;
  }

  /// 调一次 chat/completions，返回助手消息（可能带 tool_calls）
  ///
  /// [requireTool] = true 时用 `tool_choice: "required"` 强制模型这一步必须调
  /// 工具（见 [send] 里的「主动调工具」nudge）；默认 `"auto"`。
  Future<AgentMessage> _chat(List<Map<String, dynamic>> tools,
      {bool requireTool = false}) async {
    final body = <String, dynamic>{
      'model': config.model.trim(),
      'messages': _wireMessages(),
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty)
        'tool_choice': requireTool ? 'required' : 'auto',
      'temperature': 0.3,
    };
    String resp;
    try {
      resp = await httpSend(
        'POST',
        Uri.parse(config.endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        body: jsonEncode(body),
        timeout: const Duration(seconds: 60),
      );
    } on HttpStatusError catch (e) {
      throw AgentException('HTTP ${e.status}: ${_brief(e.body)}');
    } on UnsupportedError {
      // Web 构建里 httpSend 明确不支持（CORS），给一句人话而不是裸的异常名。
      throw AgentException(
          'Network requests are not supported on this platform.');
    } catch (e) {
      throw AgentException('$e');
    }
    final data = jsonDecode(resp);
    if (data is! Map) throw AgentException('Unexpected response');
    final err = data['error'];
    if (err != null) {
      final msg = err is Map ? (err['message'] ?? err) : err;
      throw AgentException('$msg');
    }
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) {
      throw AgentException('Empty response');
    }
    final msg = (choices.first as Map)['message'];
    if (msg is! Map) throw AgentException('Empty message');
    return AgentMessage(
      role: 'assistant',
      content: '${msg['content'] ?? ''}',
      toolCalls: [
        for (final c in (msg['tool_calls'] as List? ?? const []))
          if (c is Map) AgentToolCall.fromJson(c),
      ],
    );
  }

  /// 「测试连接」：发一条最短的对话，成功返回模型返回的文本片段。
  Future<String> testConnection() async {
    if (!config.ready) {
      throw AgentException('Incomplete configuration');
    }
    final old = _epoch;
    final body = {
      'model': config.model.trim(),
      'messages': const [
        {'role': 'user', 'content': 'ping'},
      ],
      'max_tokens': 8,
    };
    String resp;
    try {
      resp = await httpSend(
        'POST',
        Uri.parse(config.endpoint),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer ${config.apiKey.trim()}',
        },
        body: jsonEncode(body),
        timeout: const Duration(seconds: 30),
      );
    } on HttpStatusError catch (e) {
      // 把服务端的报错正文带出来（Key 错 / 模型名错都能一眼看出）
      throw AgentException('HTTP ${e.status}: ${_brief(e.body)}');
    } catch (e) {
      throw AgentException('$e');
    }
    if (_epoch != old) return config.model;
    final data = jsonDecode(resp);
    if (data is Map) {
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'];
        if (msg is Map && '${msg['content']}'.trim().isNotEmpty) {
          return '${msg['content']}'.trim();
        }
      }
    }
    return config.model;
  }

  static String _brief(String s) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > 160 ? '${t.substring(0, 160)}…' : t;
  }
}
