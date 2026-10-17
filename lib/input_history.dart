import 'package:flutter/material.dart';

import 'theme.dart';
import 'widgets.dart';

/// 输入框的「最近用过的」历史：按钮 + 选择面板。
///
/// 为什么需要它：数据包页的搜索词与连接设置里的服务器地址这两处，值都是
/// **反复重用**的（同一个呼号前缀、同一台服务器）。每次从零敲一遍既费事，
/// 又记不住上次连的是哪一个。历史本身由 [AppState] 存（见 lib/state.dart 的
/// `rememberInput`），这里只管显示与选择。
///
/// 面板里的每一条都能单独删掉：历史是用户自己攒的，攒错了（敲错的地址、
/// 一次性的搜索词）得能就地划掉，而不是只能整片清空。

/// 输入框右侧的历史按钮。历史为空时**不显示**（一个点开空面板的按钮只会让人困惑）。
class HistoryButton extends StatelessWidget {
  /// 当前的历史条目（新的在前）
  final List<String> entries;

  /// 选中一条时回调（调用方负责写回输入框）
  final ValueChanged<String> onPick;

  /// 面板标题，同时用作按钮的长按提示
  final String title;

  /// 删掉某一条：由调用方写回 AppState
  final ValueChanged<String>? onDelete;

  /// 清空全部
  final VoidCallback? onClear;

  /// 图标大小（默认 18，塞进输入框的 suffixIcon 里够用）
  final double iconSize;

  const HistoryButton({
    super.key,
    required this.entries,
    required this.onPick,
    required this.title,
    this.onDelete,
    this.onClear,
    this.iconSize = 18,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final v = await showInputHistory(
          context,
          title: title,
          entries: entries,
          onDelete: onDelete,
          onClear: onClear,
        );
        if (v != null && v.isNotEmpty) onPick(v);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
        child: Tooltip(
          message: title,
          child: Icon(Icons.history_rounded, size: iconSize, color: C.grey),
        ),
      ),
    );
  }
}

/// 弹出历史面板；选中一条返回它，取消返回 null。
Future<String?> showInputHistory(
  BuildContext context, {
  required String title,
  required List<String> entries,
  ValueChanged<String>? onDelete,
  VoidCallback? onClear,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => _HistorySheet(
      title: title,
      entries: entries,
      onDelete: onDelete,
      onClear: onClear,
    ),
  );
}

class _HistorySheet extends StatefulWidget {
  final String title;
  final List<String> entries;
  final ValueChanged<String>? onDelete;
  final VoidCallback? onClear;

  const _HistorySheet({
    required this.title,
    required this.entries,
    this.onDelete,
    this.onClear,
  });

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  /// 面板自己留一份：删掉一条要立刻从眼前消失，而不是等父级重建
  late final List<String> _items = List<String>.from(widget.entries);

  void _remove(String v) {
    widget.onDelete?.call(v);
    setState(() => _items.remove(v));
    if (_items.isEmpty) Navigator.pop(context);
  }

  void _clearAll() {
    widget.onClear?.call();
    setState(_items.clear);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final maxH = MediaQuery.of(context).size.height * 0.5;
    return Container(
      decoration: BoxDecoration(
        color: C.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.history_rounded, size: 16, color: C.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(widget.title,
                    style: ts(13, w: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
              if (widget.onClear != null)
                TextButton(
                  onPressed: _clearAll,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: C.grey,
                  ),
                  child: Text(s.clear, style: ts(11.5, c: C.grey)),
                ),
            ]),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _items.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 0.5, color: C.border),
                itemBuilder: (_, i) {
                  final v = _items[i];
                  return InkWell(
                    onTap: () => Navigator.pop(context, v),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(2, 11, 2, 11),
                      child: Row(children: [
                        Expanded(
                          child: Text(
                            v,
                            style: ts(13, c: C.ink, w: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.onDelete != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => _remove(v),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Tooltip(
                                message: s.delete,
                                child: Icon(Icons.close_rounded,
                                    size: 15, color: C.greyLight),
                              ),
                            ),
                          ),
                      ]),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}
