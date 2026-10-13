import 'package:flutter/material.dart';

import 'markdown_view.dart';
import 'theme.dart';

/// 台站备注：**单列显示、可换行、不截断**，并把备注里的网址变成可点链接。
///
/// 为什么单开一个组件（用户报的「台站备注被截断」）：
///
/// * 备注原本和「符号名」挤在**同一行**，并且 `maxLines: 1 + ellipsis` ——
///   稍长一点的备注（中继台频点、天气、活动公告、ARISS 排期）就被省略号吃掉，
///   用户根本看不到内容；
/// * 备注里常带网址（`https://…` / `www.…`），原来只是一段死文字，得手动复制。
///
/// 链接的渲染沿用 [MarkdownView] 的做法：用 [WidgetSpan] + `GestureDetector`，
/// 而不是 `TapGestureRecognizer` —— 后者是 `ChangeNotifier`，得在 State 里
/// `dispose`，列表里每行都要跟一个生命周期，太容易漏（公告页已经踩过一次）。
/// WidgetSpan 里放 GestureDetector 没有这个问题。
class StationNote extends StatelessWidget {
  /// 备注正文。
  final String text;

  /// 正文样式；链接会在此基础之上加蓝色下划线。
  final TextStyle? style;

  /// 行首图标（可空）。
  final IconData? icon;
  final Color? iconColor;

  /// 最大行数；`null`（默认）= 不限制，完整展示、绝不截断。
  final int? maxLines;

  const StationNote(
    this.text, {
    super.key,
    this.style,
    this.icon,
    this.iconColor,
    this.maxLines,
  });

  /// 备注里的网址：`http(s)://…` 与裸 `www.…`。
  ///
  /// 结尾常跟着标点（APRS 备注是人写的，`…/ 25W.` 之类），必须剔掉 ——
  /// 否则链接会带上标点，`launchUrl` 直接失败，用户只看到「点了没反应」。
  static final RegExp _url = RegExp(
    r'(https?://[^\s]+|www\.[^\s]+)',
    caseSensitive: false,
  );
  // 英文 + 中文（。，）标点，链接末尾连着几个就剔几个。
  static const String _trailing = '.,;:!?)]}>\u3002\uff0c\uff09\uff1b\uff1a';

  @override
  Widget build(BuildContext context) {
    final base = style ?? ts(12, c: C.slate);
    final content = Text.rich(
      TextSpan(children: _spans(context, base)),
      style: base,
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
    );
    if (icon == null) return content;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 13, color: iconColor ?? base.color),
        ),
        const SizedBox(width: 5),
        Expanded(child: content),
      ],
    );
  }

  List<InlineSpan> _spans(BuildContext context, TextStyle base) {
    final linkStyle = base.copyWith(
      color: C.blue,
      decoration: TextDecoration.underline,
      decorationColor: C.blue,
    );
    final out = <InlineSpan>[];
    var i = 0;
    for (final m in _url.allMatches(text)) {
      if (m.start > i) {
        out.add(TextSpan(text: text.substring(i, m.start)));
      }
      var raw = m.group(0)!;
      while (raw.isNotEmpty && _trailing.contains(raw[raw.length - 1])) {
        raw = raw.substring(0, raw.length - 1);
      }
      if (raw.isEmpty) continue;
      out.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            onTap: () => openExternal(context, _abs(raw)),
            child: Text(raw, style: linkStyle),
          ),
        ),
      );
      i = m.start + raw.length;
    }
    if (i < text.length) out.add(TextSpan(text: text.substring(i)));
    return out;
  }

  /// 补齐协议头：APRS 备注里常见的 `www.xxx` 没有 scheme，`launchUrl` 不认它，
  /// 直接给 `https://`（绝不手输 `http://` 去赌）。
  static String _abs(String url) =>
      url.toLowerCase().startsWith('http') ? url : 'https://$url';
}
