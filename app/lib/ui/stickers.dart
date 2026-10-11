import 'dart:io';

import 'package:flutter/material.dart';

import 'media_views.dart';
import 'widgets.dart';

/// Built-in sticker packs (big animated emoji) + emoji keyboard + your own stickers.
const stickerPacks = <String, List<String>>{
  '😀': ['😀', '😂', '🤣', '😊', '😍', '🥰', '😘', '😜', '🤪', '😎', '🤩', '🥳', '😇', '🤗', '🤔', '😴', '🙄', '😬', '😱', '😭', '😡', '🤯', '🥺', '😅'],
  '❤️': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '💕', '💖', '💘', '💝', '💌', '😻', '🫶', '💐', '🌹'],
  '👍': ['👍', '👎', '👏', '🙌', '🙏', '💪', '🤝', '✌️', '🤞', '👌', '👋', '🫡', '🤙', '👊', '✋', '🫰'],
  '🍕': ['🍕', '🍔', '🍟', '🌭', '🍿', '🍜', '🍣', '🍗', '🍰', '🎂', '🍩', '🍪', '☕', '🧋', '🍺', '🍳', '🥗', '🍉', '🍦', '🍫'],
  '🐶': ['🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔', '🐧', '🐦', '🦄', '🐝'],
  '🎉': ['🎉', '🎊', '🎁', '🎈', '🎄', '🎆', '✨', '🔥', '⭐', '🌈', '☀️', '🌙', '⚡', '❄️', '💯', '🏆', '🎶', '📸', '🏠', '🚗'],
};

const quickReactions = ['❤️', '😂', '😮', '😢', '😡', '👍'];

class StickerPanel extends StatefulWidget {
  const StickerPanel({super.key, required this.onSticker, required this.onEmoji, required this.onCustom});
  final void Function(String emoji) onSticker;
  final void Function(String emoji) onEmoji;
  final void Function(String path) onCustom;
  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  String _pack = stickerPacks.keys.first;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final custom = app.customStickers;
    final recent = app.recentEmoji;
    final packs = {if (recent.isNotEmpty) '🕘': recent, ...stickerPacks};
    if (!packs.containsKey(_pack)) _pack = packs.keys.first;

    return Container(
      height: 290,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Column(children: [
        TabBar(controller: _tabs, tabs: const [Tab(text: 'Stickers'), Tab(text: 'Emoji')]),
        Expanded(
          child: TabBarView(controller: _tabs, children: [
            // Stickers: built-in packs + custom
            Column(children: [
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final k in packs.keys)
                    _PackButton(label: k, selected: _pack == k, onTap: () => setState(() => _pack = k)),
                  _PackButton(label: '⭐', selected: _pack == '⭐', onTap: () => setState(() => _pack = '⭐'), tooltip: 'My stickers'),
                ]),
              ),
              Expanded(
                child: _pack == '⭐'
                    ? (custom.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text('Long-press any photo in a chat and choose “Save as sticker”.',
                                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                            ),
                          )
                        : GridView.extent(
                            maxCrossAxisExtent: 90,
                            padding: const EdgeInsets.all(8),
                            children: [
                              for (final s in custom)
                                if (File(s['path']).existsSync())
                                  InkWell(
                                    onTap: () => widget.onCustom(s['path']),
                                    onLongPress: () async {
                                      if (await confirm(context, 'Remove sticker?', 'It will be removed from your sticker tray.', ok: 'Remove')) {
                                        app.removeCustomSticker(s['path']);
                                      }
                                    },
                                    child: Padding(padding: const EdgeInsets.all(6), child: LocalStickerImage(path: s['path'])),
                                  ),
                            ],
                          ))
                    : GridView.extent(
                        maxCrossAxisExtent: 72,
                        padding: const EdgeInsets.all(8),
                        children: [
                          for (final e in packs[_pack]!)
                            InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () => widget.onSticker(e),
                              child: Center(child: Text(e, style: const TextStyle(fontSize: 40))),
                            ),
                        ],
                      ),
              ),
            ]),
            // Emoji keyboard: tap to insert into the message
            GridView.extent(
              maxCrossAxisExtent: 44,
              padding: const EdgeInsets.all(8),
              children: [
                for (final e in {...recent, ...stickerPacks.values.expand((x) => x)})
                  InkWell(
                    onTap: () => widget.onEmoji(e),
                    child: Center(child: Text(e, style: const TextStyle(fontSize: 26))),
                  ),
              ],
            ),
          ]),
        ),
      ]),
    );
  }
}

class _PackButton extends StatelessWidget {
  const _PackButton({required this.label, required this.selected, required this.onTap, this.tooltip});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? '',
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: selected ? brand : Colors.transparent, width: 2)),
            ),
            child: Text(label, style: const TextStyle(fontSize: 22)),
          ),
        ),
      );
}

/// A sent sticker: a big emoji that pops in.
class EmojiSticker extends StatelessWidget {
  const EmojiSticker({super.key, required this.emoji});
  final String emoji;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.6, end: 1),
        duration: const Duration(milliseconds: 450),
        curve: Curves.elasticOut,
        builder: (_, v, child) => Transform.scale(scale: v, child: child),
        child: Text(emoji, style: const TextStyle(fontSize: 96, height: 1.1)),
      );
}
