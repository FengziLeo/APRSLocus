/// ─── 智能体界面（浮动聊天框 + 设置页）───
///
/// 聊天框挂在 `MaterialApp.builder` 的 child 之上（见 app.dart），因此**任何
/// 页面**上都能看到它；设置页则从「实验功能」里推入。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'agent.dart';
import 'agent_tools.dart';
import 'l10n/app_localizations.dart';
import 'markdown_view.dart';
import 'material.dart';
import 'settings_widgets.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// ─────────────── 智能体设置页 ───────────────

/// 常用接口预设：填一个「最省事」的默认，用户仍可逐项改。
class _Preset {
  final String label;
  final String baseUrl;
  final String model;
  const _Preset(this.label, this.baseUrl, this.model);
}

const List<_Preset> _presets = [
  _Preset('OpenAI', 'https://api.openai.com/v1', 'gpt-4o-mini'),
  _Preset('DeepSeek', 'https://api.deepseek.com/v1', 'deepseek-chat'),
  _Preset('Moonshot', 'https://api.moonshot.cn/v1', 'moonshot-v1-8k'),
  _Preset('智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4-flash'),
  _Preset('通义千问', 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      'qwen-plus'),
  _Preset('Ollama', 'http://localhost:11434/v1', 'llama3.1'),
  _Preset('LM Studio', 'http://localhost:1234/v1', 'local-model'),
];

class AgentSettingsPage extends StatefulWidget {
  final AppState state;
  const AgentSettingsPage({super.key, required this.state});

  @override
  State<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends State<AgentSettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _apiKey;
  late final TextEditingController _model;
  late final TextEditingController _systemPrompt;

  late final TextEditingController _quiet;

  bool _testing = false;
  String _testResult = '';
  bool _testOk = false;

  AgentConfig get cfg => AgentService.instance.config;

  @override
  void initState() {
    super.initState();
    _baseUrl = TextEditingController(text: cfg.baseUrl);
    _apiKey = TextEditingController(text: cfg.apiKey);
    _model = TextEditingController(text: cfg.model);
    _systemPrompt = TextEditingController(text: cfg.systemPrompt);
    _quiet = TextEditingController(text: cfg.quietHours);
  }

  @override
  void dispose() {
    for (final c in [_baseUrl, _apiKey, _model, _systemPrompt, _quiet]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _collect() async {
    cfg
      ..baseUrl = _baseUrl.text.trim()
      ..apiKey = _apiKey.text.trim()
      ..model = _model.text.trim()
      ..systemPrompt = _systemPrompt.text.trim()
      ..quietHours = _quiet.text.trim();
    await AgentService.instance.saveConfig();
  }

  void _toast(String msg, {Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        backgroundColor: color ?? C.ink,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<void> _test() async {
    await _collect();
    // await 之后必须重新确认 mounted，再碰 context（lint: 跨 await 用 context）。
    if (!mounted) return;
    final s = S.of(context);
    if (!cfg.ready) {
      _toast(s.agentNeedConfig, color: C.orange);
      return;
    }
    setState(() {
      _testing = true;
      _testResult = '';
    });
    try {
      final r = await AgentService.instance.testConnection();
      if (mounted) {
        setState(() {
          _testOk = true;
          _testResult = s.agentTestOk(r);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testOk = false;
          _testResult = s.agentError('$e');
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 当前分页：0 连接 / 1 权限 / 2 自动化
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListenableBuilder(
      listenable: AgentService.instance,
      builder: (context, _) => SettingsPageShell(
        title: s.agentSettings,
        subtitle: s.agentSettingsDesc,
        icon: Icons.smart_toy_rounded,
        color: C.purple,
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _segmented(s),
          const SizedBox(height: 14),
          if (_tab == 0) _connectionTab(s),
          if (_tab == 1) _permissionsTab(s),
          if (_tab == 2) _automationTab(s),
        ]),
      ),
    );
  }

  /// 顶部分段选择：把原来一长条的功能折成三页，少滚动、少干扰。
  Widget _segmented(S s) {
    final tabs = [s.agentTabConnection, s.agentTabPermissions, s.agentTabAutomation];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: C.bgSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.border),
      ),
      child: Row(children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _tab = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: _tab == i ? C.purple : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(tabs[i],
                    textAlign: TextAlign.center,
                    style: ts(12,
                        c: _tab == i ? Colors.white : C.slate,
                        w: FontWeight.w700)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _connectionTab(S s) {
    return Column(children: [
      SettingsFold(
        title: s.agentMode,
        subtitle: s.agentModeDesc,
        icon: Icons.smart_toy_rounded,
        color: C.purple,
        open: true,
        onToggle: () {},
        children: [
          SettingsSwitch(s.agentEnabled,
              value: cfg.enabled, color: C.purple, onChanged: (v) async {
            // 开启需先签「智能体使用告知」：未签时 setAgentEnabled 会改为弹告知页。
            widget.state.setAgentEnabled(v);
            if (mounted) setState(() {});
          }),
          SettingsHint(s.agentApiKeyTip),
        ],
      ),
      const SizedBox(height: 16),
      SettingsFold(
        title: s.agentInterfaceSection,
        subtitle: s.agentPresetHint,
        icon: Icons.key_rounded,
        color: C.blue,
        open: true,
        onToggle: () {},
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in _presets)
                GestureDetector(
                  onTap: () {
                    _baseUrl.text = p.baseUrl;
                    _model.text = p.model;
                    _collect();
                    setState(() {});
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: C.bgSoft,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: C.border),
                    ),
                    child: Text(p.label,
                        style: ts(11, c: C.slate, w: FontWeight.w600)),
                  ),
                ),
            ]),
          ),
          SettingsInput(s.agentBaseUrl, _baseUrl,
              hint: 'https://api.openai.com/v1'),
          SettingsInput(s.agentApiKey, _apiKey,
              hint: 'sk-...', tip: s.agentApiKeyTip),
          SettingsInput(s.agentModel, _model, hint: 'gpt-4o-mini'),
          SettingsInput(s.agentSystemPrompt, _systemPrompt,
              hint: s.agentSystemPromptHint),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
                  label: Text(_testing ? s.agentTesting : s.agentTest),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.blue,
                    side: BorderSide(color: C.blue.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: ts(12, w: FontWeight.w600),
                  ),
                ),
              ),
            ]),
          ),
          if (_testResult.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _testOk ? C.greenBg : C.redBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_testResult,
                    style: ts(11,
                        c: _testOk ? C.green : C.red,
                        w: FontWeight.w600)),
              ),
            ),
        ],
      ),
    ]);
  }

  Widget _permissionsTab(S s) {
    final always = cfg.alwaysAllow.toList()..sort();
    return Column(children: [
      SettingsFold(
        title: s.agentPermissions,
        subtitle: '',
        icon: Icons.published_with_changes_rounded,
        color: C.orange,
        open: true,
        onToggle: () {},
        children: [
          SettingsSwitch(s.agentAllowSend,
              value: cfg.allowSend, color: C.orange, onChanged: (v) async {
            cfg.allowSend = v;
            await AgentService.instance.saveConfig();
            if (mounted) setState(() {});
          }),
          SettingsHint(s.agentAllowSendDesc),
          SettingsSwitch(s.agentAllowSettings,
              value: cfg.allowSettings, color: C.orange, onChanged: (v) async {
            cfg.allowSettings = v;
            await AgentService.instance.saveConfig();
            if (mounted) setState(() {});
          }),
          SettingsHint(s.agentAllowSettingsDesc),
        ],
      ),
      const SizedBox(height: 16),
      SettingsFold(
        title: s.agentAlwaysAllow,
        subtitle: s.agentAlwaysAllowDesc,
        icon: Icons.verified_user_rounded,
        color: C.green,
        open: true,
        onToggle: () {},
        children: [
          if (always.isEmpty)
            SettingsHint(s.agentAlwaysAllowEmpty)
          else
            for (final n in always)
              SettingsRow2(s.agentToolLabel(n), '✓', valueColor: C.green),
          if (always.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: OutlinedButton.icon(
                onPressed: () async {
                  cfg.alwaysAllow.clear();
                  await AgentService.instance.saveConfig();
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                label: Text(s.agentAlwaysAllowClear),
                style: OutlinedButton.styleFrom(
                  foregroundColor: C.red,
                  side: BorderSide(color: C.red.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  textStyle: ts(12, w: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
    ]);
  }

  Widget _automationTab(S s) {
    return Column(children: [
      SettingsFold(
        title: s.agentAutoReply,
        subtitle: s.agentAutoReplyDesc,
        icon: Icons.reply_rounded,
        color: C.cyan,
        open: true,
        onToggle: () {},
        children: [
          SettingsSwitch(s.agentAutoReplyOn,
              value: cfg.autoReply, color: C.cyan, onChanged: (v) async {
            cfg.autoReply = v;
            await AgentService.instance.saveConfig();
            if (mounted) setState(() {});
          }),
          SettingsHint(s.agentAutoReplyHint),
          SettingsSwitch(s.agentReplyGroups,
              value: cfg.replyGroups, color: C.cyan, onChanged: (v) async {
            cfg.replyGroups = v;
            await AgentService.instance.saveConfig();
            if (mounted) setState(() {});
          }),
          SettingsHint(s.agentReplyGroupsDesc),
          SettingsInput(s.agentQuietHours, _quiet,
              hint: '23:00-07:00',
              onEditingComplete: () {
                _collect();
                setState(() {});
              }),
          SettingsHint(s.agentQuietHoursDesc),
        ],
      ),
      const SizedBox(height: 16),
      SettingsFold(
        title: s.agentTasks,
        subtitle: s.agentTasksDesc,
        icon: Icons.schedule_rounded,
        color: C.purple,
        open: true,
        onToggle: () {},
        children: [
          if (_tasksOf(AgentTaskTrigger.timer).isEmpty)
            SettingsHint(s.agentTasksEmpty)
          else
            for (final t in _tasksOf(AgentTaskTrigger.timer))
              _TaskRow(
                task: t,
                onToggle: (v) async {
                  await AgentService.instance.setTaskEnabled(t.id, v);
                  if (mounted) setState(() {});
                },
                onDelete: () async {
                  await AgentService.instance.removeTask(t.id);
                  if (mounted) setState(() {});
                },
              ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _newTask(AgentTaskTrigger.timer),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(s.agentTaskNew),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.purple,
                    side: BorderSide(color: C.purple.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: ts(12, w: FontWeight.w600),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
      const SizedBox(height: 16),
      // 消息触发：收到别人发来的 APRS 消息时，跑一段给智能体的指令。
      // 与定时任务是同一套任务模型（[AgentTask.trigger] 区分「到点」还是「来消息」），
      // 所以「改了一处」不会出现两条路径行为不一致。
      SettingsFold(
        title: s.agentMessageTasks,
        subtitle: s.agentMessageTasksDesc,
        icon: Icons.mark_email_unread_rounded,
        color: C.cyan,
        open: true,
        onToggle: () {},
        children: [
          if (_tasksOf(AgentTaskTrigger.message).isEmpty)
            SettingsHint(s.agentMessageTasksEmpty)
          else
            for (final t in _tasksOf(AgentTaskTrigger.message))
              _TaskRow(
                task: t,
                onToggle: (v) async {
                  await AgentService.instance.setTaskEnabled(t.id, v);
                  if (mounted) setState(() {});
                },
                onDelete: () async {
                  await AgentService.instance.removeTask(t.id);
                  if (mounted) setState(() {});
                },
              ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _newTask(AgentTaskTrigger.message),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: Text(s.agentMessageTaskNew),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: C.cyan,
                    side: BorderSide(color: C.cyan.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    textStyle: ts(12, w: FontWeight.w600),
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    ]);
  }

  List<AgentTask> _tasksOf(AgentTaskTrigger t) =>
      [for (final x in AgentService.instance.tasks) if (x.trigger == t) x];

  /// 手动新建一个任务（也让用户不靠模型就能用上这个能力）。
  ///
  /// [trigger] 决定是「到点」还是「来消息」触发：定时型多问一个间隔，消息型没有间隔。
  Future<void> _newTask(AgentTaskTrigger trigger) async {
    final s = S.of(context);
    final isMessage = trigger == AgentTaskTrigger.message;
    final prompt = TextEditingController();
    final interval = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isMessage ? s.agentMessageTaskNew : s.agentTaskNew),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: prompt,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: s.agentTaskPrompt,
              hintText: isMessage
                  ? s.agentMessageTaskPromptHint
                  : s.agentTaskPromptHint,
            ),
          ),
          if (!isMessage) ...[
            const SizedBox(height: 12),
            TextField(
              controller: interval,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: s.agentTaskInterval,
                helperText: s.agentTaskIntervalHint,
              ),
            ),
          ],
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(s.agentTaskCreate),
          ),
        ],
      ),
    );
    final p = prompt.text.trim();
    if (ok != true || p.isEmpty) {
      prompt.dispose();
      interval.dispose();
      return;
    }
    final mins = int.tryParse(interval.text.trim()) ?? 0;
    await AgentService.instance.addTask(
      p,
      trigger: trigger,
      intervalMinutes: trigger == AgentTaskTrigger.message || mins < 0 ? 0 : mins,
    );
    prompt.dispose();
    interval.dispose();
    if (mounted) setState(() {});
  }
}

/// ─────────────── 浮动聊天框 ───────────────

/// 覆盖在所有页面之上的智能体聊天框容器。
///
/// 由 `MaterialApp.builder` 负责挂载/卸载：只有「实验功能」开启了智能体模式时
/// 才实例化，因此关闭时零开销。
class AgentOverlay extends StatefulWidget {
  final AppState state;
  const AgentOverlay({super.key, required this.state});

  @override
  State<AgentOverlay> createState() => _AgentOverlayState();
}

class _AgentOverlayState extends State<AgentOverlay> {
  bool _minimized = false;
  Offset _drag = Offset.zero;

  /// 待确认的工具调用（有副作用的操作执行前，面板内联询问用户）
  AgentToolCall? _pendingCall;
  Completer<AgentConfirmResult>? _pendingCompleter;

  /// 待确认的「清空对话」
  bool _clearPending = false;

  /// 聊天消息列表的滚动控制器：每次新增消息 / 展开面板都跳到最底部，
  /// 否则会停在历史顶部（用户反馈「每次打开都在最上面」）。
  final ScrollController _scroll = ScrollController();

  /// 待执行的「滚到底」回调（合并同一帧内的多次请求）
  bool _scrollScheduled = false;

  AgentService get svc => AgentService.instance;
  AgentConfig get cfg => svc.config;

  /// 打开面板或收到新消息时滚到底部。
  ///
  /// * 面板展开用 `jumpTo`：列表刚 build 完，位置还没稳定，动画会滚不到底；
  /// * 新增消息用 `animateTo`（若已在底部附近）：观感更自然。
  ///
  /// 二者都延到帧后执行 —— 这一刻 `maxScrollExtent` 才是新内容算完的值。
  void _scrollToBottom({bool animate = false}) {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!mounted || !_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (animate && (max - _scroll.position.pixels).abs() > 4) {
        _scroll.animateTo(max,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(max);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (!svc.loaded) svc.load();
    // 定时任务到点轮询。60 秒粒度足够（最短循环 5 分钟），且不必为每个任务各起
    // 一个 timer —— 任务在磁盘里可随时增删，单一轮询器最容易保持一致。
    _taskTimer = Timer.periodic(const Duration(seconds: 60), (_) => _runDueTasks());
    // 接收消息激活：收到别人发来的消息时可自动回复（默认关，见配置页）。
    widget.state.onNewMessage = _onIncoming;
    // 消息一变（用户发送 / 模型回复 / 工具结果）就滚到底。
    svc.addListener(_onSvcChanged);
    // 展开面板（初始即展开）后也要滚到底：延迟启动时不显示面板，
    // 之后 `_minimized` 转 false 时会在 build 里补一次。
    if (!_minimized) _scrollToBottom();
  }

  Timer? _taskTimer;

  void _onSvcChanged() {
    _scrollToBottom(animate: true);
  }

  @override
  void dispose() {
    svc.removeListener(_onSvcChanged);
    _scroll.dispose();
    _taskTimer?.cancel();
    super.dispose();

  }

  /// 定时任务到点：逐个跑（串行，避免并发占用把对话搅乱）。
  Future<void> _runDueTasks() async {
    if (!mounted || !cfg.enabled || svc.busy) return;
    if (!svc.loaded) return;
    final due = svc.dueTasks(DateTime.now());
    for (final t in due) {
      if (!mounted) return;
      // 先标记已跑：即便这一轮因未配置好而失败，也不会 60 秒后立刻重试刷屏。
      await svc.markTaskRun(t.id);
      if (!mounted) return;
      if (!cfg.ready) {
        await svc.recordTaskRun(t.id, t.prompt, false, 'Agent not configured');
        continue;
      }
      final s = S.of(context);
      final reply = await _runChat(s, t.prompt, background: true);
      if (!mounted) return;
      await svc.recordTaskRun(
        t.id,
        t.prompt,
        reply != null,
        reply == null ? 'No reply (see chat)' : reply,
      );
    }
  }

  /// 收到新消息：先跑「消息触发」的任务（用户在自动化里配置的指令），
  /// 再按原有逻辑做自动回复。
  ///
  /// 两条路径都走同一套闸门（智能体开启、不在安静时段、就绪且不忙、[allowSend]、
  /// 冷却）。消息触发的任务**只在后台跑、不改设置也不发消息**（`background: true`
  /// 时 [AgentConfirmResult.deny]），因此需要「允许发送 / 改设置」的工具会被拒，
  /// 它自己也不会去发消息——「怎么发」由自动回复那一档单独负责。
  Future<void> _onIncoming(String src, String text, String? groupId) async {
    final now = DateTime.now();
    if (!svc.canAutoReply(now)) return;
    if (groupId != null && !cfg.replyGroups) return;
    if (!cfg.allowSend) return; // 没开「允许发送」就不自动发
    if (!cfg.ready || svc.busy) return;
    // 只处理看起来像人发的消息（跳过系统 / 位置点提示）。
    if (text.trim().isEmpty || src == '系统') return;
    final key = (groupId ?? src).toUpperCase();
    if (!svc.autoReplyAllowed(key, now)) return;
    if (!mounted) return;

    final s = S.of(context);

    // ① 消息触发的任务：每条指令依次跑一轮（串行，避免把对话搅乱）。
    final triggers = [
      for (final t in svc.tasks)
        if (t.enabled && t.trigger == AgentTaskTrigger.message) t
    ];
    for (var i = 0; i < triggers.length; i++) {
      if (!mounted || svc.busy) break;
      final tr = triggers[i];
      final reply = await _runChat(
        s,
        s.agentMessageTaskRunPrompt(i + 1, tr.prompt, src, text),
        background: true,
      );
      if (!mounted) return;
      await svc.recordTaskRun(
        tr.id,
        tr.prompt,
        reply != null,
        'Message from $src: ${reply ?? 'no reply'}',
      );
    }
    if (!mounted) return;

    // ② 自动回复：让模型「起草一条回复」，再由本地直接发送。
    String target = src;
    if (groupId != null) {
      final g = widget.state.chatGroups.where((g) => g.id == groupId).firstOrNull;
      if (g == null) return;
      target = g.groupCall;
    }
    final draft = await _runChat(
      s,
      s.agentAutoReplyPrompt(src, text),
      background: true,
    );
    if (draft == null || draft.isEmpty || !mounted) return;
    widget.state.sendMessage(target, draft);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        // 未开启智能体模式：这一层不显示、也不吃手势（SizedBox 无子节点不吸收点击）。
        if (!cfg.enabled) return const SizedBox.shrink();
        if (_minimized) {
          return Stack(children: [
            Positioned(right: 16, bottom: 96, child: _bubble()),
          ]);
        }
        return Stack(children: [
          Positioned(
            right: 12,
            bottom: _panelBottom(context),
            child: Transform.translate(offset: _drag, child: _panel(context)),
          ),
        ]);
      },
    );
  }

  /// 面板距屏幕底部的距离：键盘弹出时抬到键盘之上，否则固定 88（与胶囊一致）。
  double _panelBottom(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom;
    return kb > 0 ? kb + 12 : 88.0;
  }

  Widget _bubble() {
    return GestureDetector(
      onTap: () {
        setState(() => _minimized = false);
        // 展开后滚到最新消息处（用户上次可能没看完就收起了）。
        _scrollToBottom();
      },
      child: MaterialSurface(
        radius: 999,
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: C.purple,
            shape: BoxShape.circle,
            boxShadow: elev2(),
          ),
          child: Stack(children: [
            const Center(
              child: Icon(Icons.smart_toy_rounded,
                  color: Colors.white, size: 24),
            ),
            if (svc.busy)
              Positioned(
                right: 6,
                top: 6,
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final w = size.width < 480 ? size.width - 24 : 380.0;
    // 键盘弹出时面板会整体上移（见 `_panelBottom`），这里只需要把高度压到
    // 「键盘顶到状态栏之间的可用高度」以内，否则小屏 + 键盘会顶出屏幕。
    final kb = mq.viewInsets.bottom;
    final maxH = (size.height - mq.viewPadding.top - kb - 24).clamp(240.0, 560.0);
    final h = (size.height * 0.62).clamp(320.0, maxH);
    final s = S.of(context);
    return GestureDetector(
      onPanUpdate: (d) => setState(() => _drag += d.delta),
      onPanEnd: (_) => setState(() {}),
      child: MaterialSurface(
        radius: 20,
        child: Material(
          // 面板里用到了 TextField 和一堆 TextButton/FilledButton/IconButton，
          // 它们都要求有 Material 祖先（渲染墨水/涟漪）。MaterialSurface 只负责
          // 磨砂与投影，**不提供** Material；漏了它每个这类控件都会抛
          // "No Material widget found"，整块面板连同布局一起崩成黄黑条纹 ——
          // 这正是用户看到的「聊天框里的下划线」。type 用 transparency 让
          // Material 不画自己的底，填色/描边/阴影照旧由下面的 Container 出。
          type: MaterialType.transparency,
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: C.sheetFill,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: C.border),
              boxShadow: elev2(),
            ),
            child: Column(children: [
              _header(s),
              Divider(height: 1, color: C.border),
              if (!cfg.ready) _notReady(s),
              Expanded(child: _messageList(s)),
              if (svc.busy && _pendingCall == null) _thinking(s),
              if (_clearPending) _clearBar(s),
              if (_pendingCall != null) _confirmBar(s, _pendingCall!),
              Divider(height: 1, color: C.border),
              _input(s),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header(S s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: C.purpleBg,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Icon(Icons.smart_toy_rounded, size: 16, color: C.purple),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(s.agentChatTitle,
              style: ts(13, w: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
        IconButton(
          tooltip: s.agentClear,
          onPressed: () => setState(() => _clearPending = true),
          icon: Icon(Icons.delete_outline_rounded, size: 18, color: C.grey),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: s.agentOpenSettings,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => AgentSettingsPage(state: widget.state)),
          ),
          icon: Icon(Icons.settings_rounded, size: 18, color: C.grey),
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          tooltip: s.agentMinimize,
          onPressed: () {
            // 收起前把待确认的操作按「拒绝」结掉，否则对话会一直卡在等待里。
            if (_pendingCompleter != null) {
              _resolveConfirm(AgentConfirmResult.deny);
            }
            setState(() => _minimized = true);
          },
          icon: Icon(Icons.close_fullscreen_rounded, size: 18, color: C.grey),
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }

  Widget _notReady(S s) {
    return Container(
      width: double.infinity,
      color: C.orangeBg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        Icon(Icons.info_outline_rounded, size: 14, color: C.orange),
        const SizedBox(width: 6),
        Expanded(
          child: Text(s.agentWelcome,
              style: ts(10, c: C.orange, h: 1.3),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
                builder: (_) => AgentSettingsPage(state: widget.state)),
          ),
          child: Text(s.agentOpenSettings,
              style: ts(11, c: C.orange, w: FontWeight.w700)),
        ),
      ]),
    );
  }

  Widget _messageList(S s) {
    final msgs = svc.messages
        .where((m) => m.role == 'user' || m.role == 'assistant' || m.role == 'tool')
        .toList();
    final items = <Widget>[
      _welcomeBubble(s),
      for (final m in msgs) _bubbleFor(m, s),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      children: items,
    );
  }

  Widget _welcomeBubble(S s) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          constraints: const BoxConstraints(maxWidth: 280),
          decoration: BoxDecoration(
            color: C.bgSoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(s.agentWelcome, style: ts(11, c: C.slate, h: 1.4)),
        ),
      );

  Widget _bubbleFor(AgentMessage m, S s) {
    if (m.role == 'tool') {
      final name = m.name ?? '';
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Icon(Icons.check_circle_outline_rounded, size: 13, color: C.green),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '${s.agentExecuted} · ${s.agentToolLabel(name)}',
              style: ts(10, c: C.grey),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
      );
    }
    // assistant 消息可能只带 tool_calls、没有正文
    if (m.role == 'assistant' && m.content.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    final isUser = m.role == 'user';
    // 助手回复按 Markdown 渲染（模型几乎总是输出 `**粗体**` / 列表 / 代码），
    // 直接当纯文本显示会满屏星号与井号。用户自己的输入保持纯文本。
    final body = isUser
        ? SelectableText(
            m.content,
            style: ts(12, c: Colors.white, h: 1.4),
          )
        : SelectionArea(child: MarkdownView(m.content));
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: isUser ? C.blue : C.bgSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: body,
      ),
    );
  }

  Widget _thinking(S s) => Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
        child: Row(children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: C.purple),
          ),
          const SizedBox(width: 8),
          Text(s.agentThinking, style: ts(10, c: C.grey)),
        ]),
      );

  Widget _input(S s) {
    return Padding(
      padding: EdgeInsets.fromLTRB(10, 8, 10, 8 + MediaQuery.of(context).viewPadding.bottom),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _controller,
            enabled: !svc.busy,
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            style: ts(12),
            decoration: InputDecoration(
              isDense: true,
              hintText: s.agentInputHint,
              hintStyle: ts(11, c: C.greyLight),
              filled: true,
              fillColor: C.bgSoft,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: C.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: C.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: C.purple, width: 1.4),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 44,
          height: 44,
          child: svc.busy
              ? OutlinedButton(
                  onPressed: () {
                    // 若正卡在「等待确认」，先按拒绝结掉，再取消本轮对话。
                    if (_pendingCompleter != null) {
                      _resolveConfirm(AgentConfirmResult.deny);
                    }
                    svc.cancel();
                  },
                  style: OutlinedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: C.red),
                  ),
                  child: Icon(Icons.stop_rounded, size: 20, color: C.red),
                )
              : FilledButton(
                  onPressed: _send,
                  style: FilledButton.styleFrom(
                    padding: EdgeInsets.zero,
                    backgroundColor: C.purple,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Icon(Icons.send_rounded, size: 18, color: Colors.white),
                ),
        ),
      ]),
    );
  }

  final TextEditingController _controller = TextEditingController();

  /// 清空对话的确认条（内联，避免对话框被置顶面板遮挡）
  Widget _clearBar(S s) {
    return Container(
      width: double.infinity,
      color: C.redBg,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(s.agentClearConfirm,
              style: ts(11, c: C.red, w: FontWeight.w600)),
        ),
        // 同确认条：按钮排成 Wrap，避免窄屏 / 长译文时横向溢出（黄黑条纹）。
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: () => setState(() => _clearPending = false),
              child: Text(s.cancel, style: ts(12, c: C.grey)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: C.red,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () {
                svc.clearHistory();
                setState(() => _clearPending = false);
              },
              child: Text(s.agentClear,
                  style: ts(12, c: Colors.white, w: FontWeight.w700)),
            ),
          ],
        ),
      ]),
    );
  }

  /// 工具确认条：模型请求执行有副作用的操作时，内联问用户「允许 / 拒绝」。
  ///
  /// 用内联条而不是 `showDialog`：本面板挂在 `MaterialApp.builder` 之上，
  /// 而对话框挂在 Navigator 的 Overlay 里 —— 面板永远盖在对话框上面，
  /// 用户会看不到确认框。内联则万无一失，也少一次跨层。
  Widget _confirmBar(S s, AgentToolCall call) {
    final detail = _humanArgs(call.arguments);
    return Container(
      width: double.infinity,
      color: C.purpleBg,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${s.agentConfirmTitle}：${s.agentToolLabel(call.name)}',
            style: ts(11, c: C.purple, w: FontWeight.w700)),
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            detail,
            style: ts(10, c: C.slate),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 2),
        // 用 Wrap 而不是 Row：三种按钮在多语言下（如西语「Permitir siempre」）
        // 叠加起来很容易超过面板宽度，Row 会直接溢出并画出黄黑条纹（就是用户
        // 说的「下划线」，其实是 Flutter 的 RenderFlex 溢出报错标志）。Wrap 让
        // 按钮必要时换行，既不会溢出，窄屏也仍可用。
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton(
              onPressed: () => _resolveConfirm(AgentConfirmResult.deny),
              child: Text(s.agentConfirmDeny, style: ts(12, c: C.grey)),
            ),
            TextButton(
              // 「始终允许」把该工具加入免确认名单，之后同类操作不再打断对话。
              onPressed: () => _resolveConfirm(AgentConfirmResult.allowAlways),
              child: Text(s.agentAlwaysAllow,
                  style: ts(12, c: C.purple, w: FontWeight.w600)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: C.purple,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: () => _resolveConfirm(AgentConfirmResult.allowOnce),
              child: Text(s.agentConfirmRun,
                  style: ts(12, c: Colors.white, w: FontWeight.w700)),
            ),
          ],
        ),
      ]),
    );
  }

  /// 回填确认结果（由 [AgentService.send] 的 confirm 回调 await）
  void _resolveConfirm(AgentConfirmResult r) {
    final c = _pendingCompleter;
    setState(() {
      _pendingCall = null;
      _pendingCompleter = null;
    });
    if (c != null && !c.isCompleted) c.complete(r);
  }

  /// 有副作用的工具执行前，内联弹确认条并等待用户选择
  Future<AgentConfirmResult> _confirm(
      String name, Map<String, dynamic> args) async {
    if (!mounted) return AgentConfirmResult.deny;
    final completer = Completer<AgentConfirmResult>();
    setState(() {
      _pendingCall = AgentToolCall(id: '', name: name, arguments: args);
      _pendingCompleter = completer;
      _minimized = false; // 需要用户决策：把面板亮出来，别藏在气泡后
    });
    return completer.future;
  }

  /// 后台（定时任务）执行时的确认：用户不在场，一律拒绝未预先放行的工具。
  ///
  /// 「预先放行」指用户在界面上对某工具点过「始终允许」——由 [AgentService.send]
  /// 在调用本回调之前就短路掉，所以走到这里的一律拒绝。
  Future<AgentConfirmResult> _denyBackground(
          String name, Map<String, dynamic> args) async =>
      AgentConfirmResult.deny;

  Future<void> _send() async {
    final text = _controller.text;
    if (text.trim().isEmpty) return;
    final s = S.of(context);
    _controller.clear();
    setState(() {});
    await _runChat(s, text, background: false);
  }

  /// 跑一轮对话。[background] = true 时用于定时任务 / 自动回复：有副作用的工具
  /// 不再弹确认（无人可确认），只有用户预先「始终允许」过的工具才会执行。
  /// 返回本轮最后一条助手文本（自动回复用它作为要发送的内容）。
  Future<String?> _runChat(S s, String text, {required bool background}) async {
    final before = svc.messages.length;
    try {
      await svc.send(
        text,
        tools: agentToolSchemas(allowSend: cfg.allowSend),
        execute: (name, args) => executeAgentTool(
          widget.state,
          name,
          args,
          allowedSend: cfg.allowSend,
          allowedSettings: cfg.allowSettings,
        ),
        confirm: background ? _denyBackground : _confirm,
        needsConfirm: agentNeedsConfirm,
        needConfigText: s.agentNeedConfig,
        formatError: (raw) => s.agentError(raw),
      );
    } on AgentException catch (e) {
      if (!background && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: C.orange,
        ));
      }
      return null;
    }
    for (var i = svc.messages.length - 1; i >= before; i--) {
      final m = svc.messages[i];
      if (m.role == 'assistant' && m.content.trim().isNotEmpty) {
        return m.content.trim();
      }
    }
    return null;
  }
}

/// 工具名 → 人类可读称呼。
///
/// 界面上**不直接显示** `get_app_state` / `create_task` 这种带下划线的标识符：
/// 对用户来说那是内部实现（用户反馈「智能体页面一堆下划线」）。这里映射到 l10n
/// 文案；连接/断开/重启这类没有专用文案的（理论上不会出现在工具表里）兜底成
/// 「执行操作」。新增工具时记得在 add_agent_v2_l10n.py 里补一条。
extension AgentToolLabel on AppLocalizations {
  String agentToolLabel(String name) {
    switch (name) {
      case 'get_app_state':
        return agentTool_get_app_state;
      case 'list_groups':
        return agentTool_list_groups;
      case 'search_stations':
        return agentTool_search_stations;
      case 'list_stations':
        return agentTool_list_stations;
      case 'station_detail':
        return agentTool_station_detail;
      case 'read_messages':
        return agentTool_read_messages;
      case 'send_message':
        return agentTool_send_message;
      case 'send_beacon_now':
        return agentTool_send_beacon_now;
      case 'set_preferences':
        return agentTool_set_preferences;
      case 'set_station_filters':
        return agentTool_set_station_filters;
      case 'set_nickname':
        return agentTool_set_nickname;
      case 'navigate':
        return agentTool_navigate;
      case 'create_task':
        return agentTool_create_task;
      case 'list_tasks':
        return agentTool_list_tasks;
      case 'cancel_task':
        return agentTool_cancel_task;
      case 'set_connection_server':
        return agentTool_set_connection_server;
      case 'set_connection_source':
        return agentTool_set_connection_source;
      case 'connect':
        return agentTool_connect;
      case 'disconnect':
        return agentTool_disconnect;
      case 'nearby_stations':
        return agentTool_nearby_stations;
      case 'reply_message':
        return agentTool_reply_message;
      case 'send_group_message':
        return agentTool_send_group_message;
      case 'create_group':
        return agentTool_create_group;
      case 'set_task_enabled':
        return agentTool_set_task_enabled;
      default:
        return agentTool_unknown;
    }
  }
}

/// 定时任务行：开关 / 内容 / 间隔 / 删除。
class _TaskRow extends StatelessWidget {
  final AgentTask task;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  const _TaskRow(
      {required this.task, required this.onToggle, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final subtitle = task.trigger == AgentTaskTrigger.message
        ? s.agentMessageTaskEvery
        : (task.recurring
            ? s.agentTaskEvery(task.intervalMinutes)
            : s.agentTaskOnce);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: C.border, width: 0.4))),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(task.prompt,
                style: ts(12, w: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(subtitle,
                style: ts(10, c: task.enabled ? C.purple : C.greyLight)),
          ]),
        ),
        Switch(
          value: task.enabled,
          onChanged: onToggle,
          activeThumbColor: C.purple,
        ),
        IconButton(
          tooltip: s.agentTaskDelete,
          onPressed: onDelete,
          icon: Icon(Icons.delete_outline_rounded, size: 18, color: C.grey),
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }
}

/// 工具参数 → 人类可读摘要（确认条用）。
///
/// 旧的 `_ArgsFormat` 直接把 JSON 键名（`beacon_interval` 这类）连同下划线怼到
/// 用户脸上，还把 `null` 显示成字符串 "null"。这里只取每对「键：值」，键名去掉
/// 下划线，值超过 60 字就截断——确认条是一句「要做什么」的摘要，不是调试面板。
String _humanArgs(Map<String, dynamic> args) {
  if (args.isEmpty) return '';
  final parts = <String>[];
  for (final e in args.entries) {
    if (e.value == null) continue;
    final v = e.value;
    var val = v is List ? v.join('、') : '$v';
    val = val.replaceAll('\n', ' ');
    if (val.length > 60) val = '${val.substring(0, 60)}…';
    parts.add('${e.key.replaceAll('_', ' ')}：$val');
    if (parts.length >= 4) break;
  }
  return parts.join('；');
}
