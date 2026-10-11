import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../services/media.dart';
import '../state/app_state.dart';
import 'chat_info.dart';
import 'composer.dart';
import 'message_bubble.dart';
import 'stickers.dart';
import 'widgets.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, this.embedded = false});
  final String chatId;
  final bool embedded; // shown in the right pane on wide screens
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _scroll = ScrollController();
  Message? _replyTo;
  Message? _editing;
  bool _searching = false;
  String _query = '';
  String? _highlight;
  bool _loadError = false;
  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    // Marking read notifies listeners, which isn't allowed mid-build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _app.setOpenChat(widget.chatId);
    });
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    if (_app.openChatId == widget.chatId) _app.setOpenChat(null);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _app.loadThread(widget.chatId);
      _app.markRead(widget.chatId);
      if (mounted) setState(() => _loadError = false);
    } catch (_) {
      if (mounted) setState(() => _loadError = true);
    }
  }

  void _onScroll() {
    // The list is reversed: maxScrollExtent is the oldest end.
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) {
      _app.loadOlder(widget.chatId);
    }
  }

  void _jumpTo(String messageId) {
    final t = _app.thread(widget.chatId);
    final i = t.indexOfId(messageId);
    if (i < 0) {
      toast(context, 'That message is no longer here.');
      return;
    }
    setState(() {
      _searching = false;
      _highlight = messageId;
    });
    // Rough position: reversed list, ~72px per message. Wait a frame in case
    // we're coming back from search and the list isn't on screen yet.
    final fromBottom = t.messages.length - 1 - i;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo((fromBottom * 72.0).clamp(0.0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    });
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  // ------------------------------------------------------------------ message actions
  Future<void> _actions(Message m, Offset? at) async {
    final app = _app;
    final chat = app.chats[widget.chatId]!;
    final mine = m.senderId == app.me?.id;
    final p = m.payload;

    if (m.failed) {
      final r = await showModalBottomSheet<String>(
        context: context,
        builder: (c) => SafeArea(child: Wrap(children: [
          ListTile(leading: const Icon(Icons.refresh), title: const Text('Try again'), onTap: () => Navigator.pop(c, 'retry')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Discard'), onTap: () => Navigator.pop(c, 'discard')),
        ])),
      );
      if (r == 'retry') app.retry(m);
      if (r == 'discard') app.discardFailed(m);
      return;
    }
    if (m.isSystem || m.pending) return;

    final canDeleteForAll = !m.deleted && (mine || (chat.isGroup && chat.amAdmin));
    final r = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!m.deleted && p != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  for (final e in quickReactions)
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () => Navigator.pop(c, 'react:$e'),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: m.reactions[app.me!.id] == e ? brand.withValues(alpha: 0.2) : null,
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 28)),
                      ),
                    ),
                ]),
              ),
            if (!m.deleted && p != null) ...[
              ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(c, 'reply')),
              if (p.text.isNotEmpty)
                ListTile(leading: const Icon(Icons.copy), title: const Text('Copy text'), onTap: () => Navigator.pop(c, 'copy')),
              if (mine && (p.type == 'text' || p.text.isNotEmpty))
                ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(c, 'edit')),
              ListTile(leading: const Icon(Icons.shortcut), title: const Text('Forward'), onTap: () => Navigator.pop(c, 'forward')),
              ListTile(
                leading: Icon(chat.pinnedMessageId == m.id ? Icons.push_pin_outlined : Icons.push_pin),
                title: Text(chat.pinnedMessageId == m.id ? 'Unpin' : 'Pin'),
                onTap: () => Navigator.pop(c, 'pin'),
              ),
              if (p.file != null)
                ListTile(leading: const Icon(Icons.download), title: const Text('Save to device'), onTap: () => Navigator.pop(c, 'save')),
              if (p.file != null && (p.type == 'image' || p.type == 'gif') && isDisplayableImage(p.file!.mime))
                ListTile(leading: const Icon(Icons.star_outline), title: const Text('Save as sticker'), onTap: () => Navigator.pop(c, 'sticker')),
              if (mine && chat.isGroup)
                ListTile(leading: const Icon(Icons.info_outline), title: const Text('Seen by'), onTap: () => Navigator.pop(c, 'info')),
            ],
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete for me'), onTap: () => Navigator.pop(c, 'del-me')),
            if (canDeleteForAll)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for everyone', style: TextStyle(color: Colors.red)),
                onTap: () => Navigator.pop(c, 'del-all'),
              ),
          ]),
        ),
      ),
    );
    if (r == null || !mounted) return;
    try {
      if (r.startsWith('react:')) {
        await app.react(m, r.substring(6));
      } else {
        switch (r) {
          case 'reply':
            setState(() {
              _editing = null;
              _replyTo = m;
            });
          case 'copy':
            await Clipboard.setData(ClipboardData(text: p!.text));
            if (mounted) toast(context, 'Copied');
          case 'edit':
            setState(() {
              _replyTo = null;
              _editing = m;
            });
          case 'forward':
            await _forward(m);
          case 'pin':
            await app.pin(chat.id, chat.pinnedMessageId == m.id ? null : m.id);
          case 'save':
            final f = await saveToDownloads(p!.file!.name, await app.fileBytes(p.file!));
            if (mounted) toast(context, 'Saved to ${f.path}');
          case 'sticker':
            await app.addCustomSticker(await app.fileBytes(p!.file!), p.file!.name);
            if (mounted) toast(context, 'Added to your stickers ⭐');
          case 'info':
            _seenBy(m);
          case 'del-me':
            await app.deleteForMe(m);
          case 'del-all':
            if (await confirm(context, 'Delete for everyone?', 'The message will be removed from everyone\'s devices.', ok: 'Delete', danger: true)) {
              await app.deleteForEveryone(m);
            }
        }
      }
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  void _seenBy(Message m) {
    final app = _app;
    final chat = app.chats[widget.chatId]!;
    final seen = app.seenBy(chat, m);
    final delivered = [
      for (final x in chat.members)
        if (x.userId != app.me?.id && !seen.contains(x.userId) && x.lastDeliveredSeq >= m.seq) x.userId
    ];
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Seen', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final u in seen) ListTile(leading: Avatar.user(app.users[u], size: 36), title: Text(app.nameOf(u))),
          if (seen.isEmpty) const ListTile(title: Text('Nobody yet', style: TextStyle(color: Colors.grey))),
          if (delivered.isNotEmpty) ...[
            const ListTile(title: Text('Delivered', style: TextStyle(fontWeight: FontWeight.bold))),
            for (final u in delivered) ListTile(leading: Avatar.user(app.users[u], size: 36), title: Text(app.nameOf(u))),
          ],
        ]),
      ),
    );
  }

  Future<void> _forward(Message m) async {
    final app = _app;
    final target = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (c, scroll) => ListView(controller: scroll, children: [
          const ListTile(title: Text('Forward to…', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final chat in app.sortedChats)
            ListTile(leading: ChatAvatar(chat: chat, size: 40), title: Text(app.chatTitle(chat)), onTap: () => Navigator.pop(c, chat.id)),
        ]),
      ),
    );
    if (target == null) return;
    await app.forward(m, target);
    if (mounted) toast(context, 'Forwarded to ${app.chatTitle(app.chats[target]!)}');
  }

  // ------------------------------------------------------------------ app bar
  PreferredSizeWidget _appBar(Chat chat) {
    final app = AppScope.of(context);
    if (_searching) {
      return AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => setState(() {
          _searching = false;
          _query = '';
        })),
        title: TextField(
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          cursorColor: Colors.white,
          decoration: const InputDecoration(hintText: 'Search in chat', hintStyle: TextStyle(color: Colors.white70), border: InputBorder.none),
          onChanged: (v) => setState(() => _query = v),
        ),
      );
    }
    final peer = app.directPeer(chat);
    final typing = app.typingIn(chat.id);
    String sub;
    if (typing.isNotEmpty) {
      sub = chat.isGroup ? '${typing.map(app.nameOf).join(', ')} typing…' : 'typing…';
    } else if (chat.isGroup) {
      final online = chat.members.where((m) => app.users[m.userId]?.online == true).length;
      sub = '${chat.members.length} members${online > 1 ? ' · $online online' : ''}';
    } else {
      sub = peer == null ? 'Notes only you can see' : lastSeenText(peer);
    }
    final inThisCall = app.calls.active?.chatId == chat.id;
    return AppBar(
      automaticallyImplyLeading: !widget.embedded,
      titleSpacing: widget.embedded ? 16 : 0,
      title: InkWell(
        onTap: () => _openInfo(chat),
        child: Row(children: [
          ChatAvatar(chat: chat, size: 38),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(app.chatTitle(chat), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400)),
            ]),
          ),
        ]),
      ),
      actions: [
        if (peer != null || chat.isGroup) ...[
          IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call), onPressed: inThisCall ? null : () => app.calls.start(chat.id, video: false)),
          IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam), onPressed: inThisCall ? null : () => app.calls.start(chat.id, video: true)),
        ],
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'info':
                _openInfo(chat);
              case 'search':
                setState(() => _searching = true);
                await _app.loadAll(chat.id);
              case 'mute':
                await _app.mute(chat.id, chat.muted ? null : const Duration(days: 3650));
              case 'clear':
                if (await confirm(context, 'Clear chat history?', 'Messages will be removed from this chat for you only.', ok: 'Clear', danger: true)) {
                  await _app.clearHistory(chat.id);
                }
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'info', child: Text('Chat info')),
            const PopupMenuItem(value: 'search', child: Text('Search')),
            PopupMenuItem(value: 'mute', child: Text(chat.muted ? 'Unmute' : 'Mute')),
            const PopupMenuItem(value: 'clear', child: Text('Clear history')),
          ],
        ),
      ],
    );
  }

  void _openInfo(Chat chat) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatInfoScreen(chatId: chat.id)));
  }

  // ------------------------------------------------------------------ build
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final chat = app.chats[widget.chatId];
    if (chat == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('This chat is no longer available.')));
    }
    final thread = app.thread(chat.id);
    final ongoing = app.calls.ongoing[chat.id];
    final pinned = chat.pinnedMessageId == null
        ? null
        : thread.messages.where((m) => m.id == chat.pinnedMessageId).firstOrNullX;

    return Scaffold(
      appBar: _appBar(chat),
      body: Column(children: [
        if (ongoing != null && app.calls.active?.id != ongoing.id)
          Material(
            color: const Color(0xFF34C759),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.call, color: Colors.white),
              title: Text('Call in progress · ${ongoing.participants.length} joined', style: const TextStyle(color: Colors.white)),
              trailing: TextButton(onPressed: () => app.calls.join(ongoing), child: const Text('JOIN', style: TextStyle(color: Colors.white))),
            ),
          ),
        if (chat.pinnedMessageId != null)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.push_pin, color: brand, size: 20),
              title: const Text('Pinned message', style: TextStyle(color: brand, fontWeight: FontWeight.w600)),
              subtitle: Text(pinned?.payload?.preview ?? 'Tap to view', maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => _jumpTo(chat.pinnedMessageId!),
              trailing: IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => app.pin(chat.id, null)),
            ),
          ),
        if (chat.disappearSeconds > 0)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 4),
            color: brand.withValues(alpha: 0.1),
            child: Text('⏱ Messages disappear after ${timerLabel(chat.disappearSeconds)}',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
          ),
        Expanded(
          child: ListenableBuilder(
            listenable: thread,
            builder: (context, _) {
              if (!thread.loaded) {
                return Center(
                  child: _loadError
                      ? TextButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: const Text('Couldn\'t load messages. Retry'))
                      : const CircularProgressIndicator(),
                );
              }
              if (_searching) return _searchResults(thread);
              return _messageList(chat, thread);
            },
          ),
        ),
        if (!_searching)
          Composer(
            chat: chat,
            replyTo: _replyTo,
            editing: _editing,
            onClearContext: () => setState(() {
              _replyTo = null;
              _editing = null;
            }),
          ),
      ]),
    );
  }

  Widget _messageList(Chat chat, ChatThread thread) {
    final msgs = thread.messages;
    if (msgs.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('👋', style: TextStyle(fontSize: 56)),
          const SizedBox(height: 8),
          Text('Say hello to ${_app.chatTitle(chat)}', style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          const Text('🔒 Messages are end-to-end encrypted', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      );
    }
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: msgs.length + (thread.hasOlder ? 1 : 0),
      itemBuilder: (context, rev) {
        if (rev == msgs.length) {
          return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final i = msgs.length - 1 - rev;
        final m = msgs[i];
        final prev = i > 0 ? msgs[i - 1] : null;
        final d = DateTime.fromMillisecondsSinceEpoch(m.createdAt);
        final newDay = prev == null || !sameDay(d, DateTime.fromMillisecondsSinceEpoch(prev.createdAt));
        final showSender = newDay || prev == null || prev.isSystem || prev.senderId != m.senderId ||
            m.createdAt - prev.createdAt > 5 * 60 * 1000;
        return Column(children: [
          if (newDay)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(dayHeader(d), style: const TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
            ),
          MessageBubble(
            key: ValueKey(m.id),
            chat: chat,
            message: m,
            showSender: showSender,
            highlight: _highlight == m.id,
            onLongPress: (pos) => _actions(m, pos),
            onReplyTap: _jumpTo,
            onDoubleTap: () => _app.react(m, '❤️'),
          ),
        ]);
      },
    );
  }

  Widget _searchResults(ChatThread thread) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) {
      return const Center(child: Text('Type to search this chat', style: TextStyle(color: Colors.grey)));
    }
    final hits = thread.messages.reversed
        .where((m) => !m.deleted && (m.payload?.text.toLowerCase().contains(q) == true || m.payload?.file?.name.toLowerCase().contains(q) == true))
        .toList();
    if (hits.isEmpty) return Center(child: Text('No messages with “$_query”', style: const TextStyle(color: Colors.grey)));
    return ListView.separated(
      itemCount: hits.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final m = hits[i];
        return ListTile(
          leading: Avatar.user(_app.users[m.senderId], size: 36, showOnline: false),
          title: Text(_app.nameOf(m.senderId)),
          subtitle: Text(m.payload!.preview, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(listTime(m.createdAt), style: const TextStyle(fontSize: 12, color: Colors.grey)),
          onTap: () => _jumpTo(m.id),
        );
      },
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNullX => isEmpty ? null : first;
}
