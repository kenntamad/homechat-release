import 'package:flutter/material.dart';

import '../data/models.dart';
import '../services/media.dart';
import 'home_screen.dart' show Ticks;
import 'media_views.dart';
import 'stickers.dart';
import 'widgets.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.chat,
    required this.message,
    required this.showSender,
    required this.onLongPress,
    required this.onReplyTap,
    required this.onDoubleTap,
    this.highlight = false,
  });

  final Chat chat;
  final Message message;
  final bool showSender;
  final void Function(Offset? position) onLongPress;
  final void Function(String messageId) onReplyTap;
  final VoidCallback onDoubleTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final m = message;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;

    if (m.isSystem) {
      final isCall = m.system?['event'] == 'call';
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (isCall) ...[
              Icon(m.system!['video'] == true ? Icons.videocam : Icons.call, size: 14,
                  color: m.system!['status'] == 'completed' ? Colors.grey : Colors.redAccent),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text('${systemText(app, m.system!)} · ${clock(DateTime.fromMillisecondsSinceEpoch(m.createdAt))}',
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: Colors.grey)),
            ),
          ]),
        ),
      );
    }

    final mine = m.senderId == app.me?.id;
    final p = m.payload;
    final bubbleColor = mine ? (dark ? const Color(0xFF4A3FA8) : const Color(0xFFE8E2FF)) : scheme.surfaceContainerHighest;
    final textColor = dark ? Colors.white : Colors.black87;
    final accent = mine ? brand : colorFor(m.senderId ?? '');
    final isSticker = p?.type == 'sticker';
    final isMedia = p != null && (p.type == 'image' || p.type == 'gif') && !m.deleted;

    // ---- content
    Widget content;
    if (m.deleted) {
      content = Text('🚫 This message was deleted', style: TextStyle(color: textColor.withValues(alpha: 0.6), fontStyle: FontStyle.italic));
    } else if (m.undecryptable || p == null) {
      content = Text('🔒 This message can\'t be decrypted on this device.',
          style: TextStyle(color: textColor.withValues(alpha: 0.6), fontStyle: FontStyle.italic));
    } else {
      final file = p.file;
      final caption = p.text;
      final parts = <Widget>[];
      switch (p.type) {
        case 'image':
        case 'gif':
          if (file != null && isDisplayableImage(file.mime)) {
            parts.add(ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: EncryptedImage(
                file: file,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImageViewer(file: file, caption: caption))),
              ),
            ));
          } else if (file != null) {
            parts.add(FileTile(file: file, color: accent));
          }
        case 'video':
          if (file != null) parts.add(ClipRRect(borderRadius: BorderRadius.circular(12), child: VideoTile(file: file)));
        case 'voice':
          if (file != null) parts.add(VoicePlayer(file: file, color: accent));
        case 'file':
          if (file != null) parts.add(FileTile(file: file, color: accent));
        case 'sticker':
          if (p.stickerEmoji != null) {
            parts.add(EmojiSticker(emoji: p.stickerEmoji!));
          } else if (file != null) {
            parts.add(EncryptedImage(file: file, maxWidth: 160, maxHeight: 160, fit: BoxFit.contain));
          }
      }
      if (caption.isNotEmpty && p.type != 'sticker') {
        if (parts.isNotEmpty) parts.add(const SizedBox(height: 6));
        parts.add(_LinkText(text: caption, style: TextStyle(color: textColor, fontSize: _emojiOnly(caption) ? 34 : 15.5)));
      }
      content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: parts);
    }

    // ---- header bits: sender, forwarded, reply quote
    final header = <Widget>[
      if (showSender && !mine && chat.isGroup)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(app.nameOf(m.senderId), style: TextStyle(color: accent, fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      if (p?.forwarded == true && !m.deleted)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.shortcut, size: 14, color: textColor.withValues(alpha: 0.55)),
            const SizedBox(width: 3),
            Text('Forwarded', style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: textColor.withValues(alpha: 0.55))),
          ]),
        ),
      if (p?.reply != null && !m.deleted)
        GestureDetector(
          onTap: () => onReplyTap(p!.reply!['id'] as String),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: dark ? 0.2 : 0.05),
              border: Border(left: BorderSide(color: colorFor(p!.reply!['senderId'] as String? ?? ''), width: 3)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.nameOf(p.reply!['senderId'] as String?),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colorFor(p.reply!['senderId'] as String? ?? ''))),
              Text(p.reply!['preview'] as String? ?? '', maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: textColor.withValues(alpha: 0.75))),
            ]),
          ),
        ),
    ];

    // ---- footer: edited, timer, time, ticks
    final footerColor = isSticker ? Colors.grey : textColor.withValues(alpha: 0.55);
    final footer = Row(mainAxisSize: MainAxisSize.min, children: [
      if (m.editedAt != null && !m.deleted) Text('edited · ', style: TextStyle(fontSize: 11, color: footerColor)),
      if (m.expiresAt != null) Padding(padding: const EdgeInsets.only(right: 3), child: Icon(Icons.timer_outlined, size: 12, color: footerColor)),
      Text(clock(DateTime.fromMillisecondsSinceEpoch(m.createdAt)), style: TextStyle(fontSize: 11, color: footerColor)),
      if (mine && !m.failed) ...[const SizedBox(width: 3), Ticks(state: app.deliveryState(chat, m), size: 15, color: footerColor)],
      if (m.failed) const Padding(padding: EdgeInsets.only(left: 3), child: Icon(Icons.error, size: 15, color: Colors.red)),
    ]);

    // IntrinsicWidth + stretch lets the footer sit at the bubble's right edge
    // while the bubble itself stays as narrow as its content.
    Widget bubble = IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in header) Align(alignment: Alignment.centerLeft, child: h),
          Align(alignment: Alignment.centerLeft, child: content),
          const SizedBox(height: 3),
          Align(alignment: Alignment.centerRight, child: footer),
        ],
      ),
    );

    if (!isSticker) {
      bubble = Container(
        padding: isMedia ? const EdgeInsets.all(4) : const EdgeInsets.fromLTRB(11, 7, 11, 6),
        decoration: BoxDecoration(
          color: highlight ? brand.withValues(alpha: 0.35) : bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 4),
            bottomRight: Radius.circular(mine ? 4 : 16),
          ),
        ),
        child: isMedia ? Padding(padding: const EdgeInsets.only(bottom: 2), child: bubble) : bubble,
      );
    }

    // ---- reactions
    final reactions = <String, int>{};
    for (final e in m.reactions.values) {
      reactions[e] = (reactions[e] ?? 0) + 1;
    }

    final maxW = MediaQuery.sizeOf(context).width * (MediaQuery.sizeOf(context).width > 840 ? 0.5 : 0.78);
    return Padding(
      padding: EdgeInsets.only(left: mine ? 48 : 8, right: mine ? 8 : 48, top: showSender ? 6 : 2, bottom: reactions.isEmpty ? 2 : 0),
      child: Row(
        mainAxisAlignment: mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine && chat.isGroup)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 2),
              child: showSender ? Avatar.user(app.users[m.senderId], size: 30, showOnline: false) : const SizedBox(width: 30),
            ),
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxW),
              child: Column(
                crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onLongPressStart: (d) => onLongPress(d.globalPosition),
                    onSecondaryTapDown: (d) => onLongPress(d.globalPosition),
                    onDoubleTap: m.deleted || m.pending ? null : onDoubleTap,
                    child: bubble,
                  ),
                  if (m.failed)
                    TextButton.icon(
                      onPressed: () => onLongPress(null),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Not sent — tap for options'),
                    ),
                  if (reactions.isNotEmpty)
                    Transform.translate(
                      offset: const Offset(0, -4),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: scheme.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                        child: Text(
                          reactions.entries.map((e) => e.value > 1 ? '${e.key}${e.value}' : e.key).join(' '),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _emojiOnly(String s) {
  final t = s.trim();
  if (t.isEmpty || t.characters.length > 3) return false;
  return !RegExp(r'[A-Za-z0-9]').hasMatch(t) && RegExp(r'[^\x00-\x7F]').hasMatch(t);
}

/// Text with selectable content on desktop.
class _LinkText extends StatelessWidget {
  const _LinkText({required this.text, required this.style});
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Text(text, style: style);
}
