import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'chat_screen.dart';
import 'new_chat.dart';
import 'settings.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  String? _selected; // wide layout: chat shown on the right

  late final AppState _app;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _app.openChatRequest.addListener(_onOpenRequest);
  }

  @override
  void dispose() {
    _app.openChatRequest.removeListener(_onOpenRequest);
    super.dispose();
  }

  void _onOpenRequest() {
    final app = AppScope.read(context);
    final id = app.openChatRequest.value;
    if (id == null) return;
    app.openChatRequest.value = null;
    if (app.chats.containsKey(id)) openChat(id);
  }

  bool get _wide => MediaQuery.sizeOf(context).width >= 840;

  void openChat(String chatId) {
    setState(() => _tab = 0);
    if (_wide) {
      setState(() => _selected = chatId);
    } else {
      Navigator.of(context).popUntil((r) => r.isFirst);
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(chatId: chatId)));
    }
  }

  Future<void> _newChat() async {
    final id = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const NewChatScreen()));
    if (id != null) openChat(id);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final tabs = [
      ChatList(onOpen: openChat, selected: _wide ? _selected : null),
      CallsTab(onOpenChat: openChat),
      const SettingsScreen(),
    ];
    final titles = [app.householdName, 'Calls', 'More'];
    final unread = app.totalUnread;

    final appBar = AppBar(
      title: Row(children: [
        Flexible(child: Text(titles[_tab], overflow: TextOverflow.ellipsis)),
        if (!app.connected) ...[
          const SizedBox(width: 10),
          const Tooltip(message: 'Not connected. Messages will send when you\'re back online or on the same Wi‑Fi.', child: Icon(Icons.cloud_off, size: 18)),
        ],
      ]),
    );

    if (_wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Avatar.user(app.me, size: 40, showOnline: false),
            ),
            trailing: _tab == 0
                ? Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: FloatingActionButton.small(onPressed: _newChat, tooltip: 'New chat', child: const Icon(Icons.edit)),
                  )
                : null,
            destinations: [
              NavigationRailDestination(
                icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble_outline)),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: const Text('Chats'),
              ),
              const NavigationRailDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call), label: Text('Calls')),
              const NavigationRailDestination(icon: Icon(Icons.more_horiz), label: Text('More')),
            ],
          ),
          const VerticalDivider(width: 1),
          SizedBox(width: 360, child: Scaffold(appBar: appBar, body: tabs[_tab])),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selected != null && app.chats.containsKey(_selected)
                ? ChatScreen(key: ValueKey(_selected), chatId: _selected!, embedded: true)
                : Container(
                    color: Theme.of(context).colorScheme.surfaceContainerLowest,
                    child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.forum_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 12),
                      Text('Pick a chat to start messaging', style: TextStyle(color: Colors.grey)),
                    ])),
                  ),
          ),
        ]),
      );
    }

    return Scaffold(
      appBar: appBar,
      body: tabs[_tab],
      floatingActionButton: _tab == 0
          ? FloatingActionButton(onPressed: _newChat, tooltip: 'New chat', child: const Icon(Icons.edit))
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          NavigationDestination(
            icon: Badge(isLabelVisible: unread > 0, label: Text('$unread'), child: const Icon(Icons.chat_bubble_outline)),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          const NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call), label: 'Calls'),
          const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ chat list
class ChatList extends StatefulWidget {
  const ChatList({super.key, required this.onOpen, this.selected});
  final void Function(String chatId) onOpen;
  final String? selected;
  @override
  State<ChatList> createState() => _ChatListState();
}

class _ChatListState extends State<ChatList> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final q = _q.toLowerCase();
    final list = app.sortedChats.where((c) => q.isEmpty || app.chatTitle(c).toLowerCase().contains(q)).toList();
    final update = app.update;
    return Column(children: [
      if (update != null && !app.updateDismissed)
        MaterialBanner(
          leading: const Icon(Icons.system_update_alt, color: brand),
          content: Text('Home Chat ${update.version} is available.'),
          actions: [
            TextButton(
              onPressed: () {
                app.updateDismissed = true;
                app.refresh();
              },
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdatesScreen())),
              child: const Text('Update'),
            ),
          ],
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: SearchBar(
          hintText: 'Search chats',
          leading: const Icon(Icons.search),
          elevation: const WidgetStatePropertyAll(0),
          onChanged: (v) => setState(() => _q = v),
        ),
      ),
      Expanded(
        child: list.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    app.chats.isEmpty ? 'No chats yet.\nTap ✏️ to message someone in the house.' : 'No chats match “$_q”.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
              )
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (_, i) => ChatTile(chat: list[i], selected: list[i].id == widget.selected, onTap: () => widget.onOpen(list[i].id)),
              ),
      ),
    ]);
  }
}

class ChatTile extends StatelessWidget {
  const ChatTile({super.key, required this.chat, required this.onTap, this.selected = false});
  final Chat chat;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final typing = app.typingIn(chat.id);
    final last = chat.lastMessage;
    final ongoingCall = app.calls.ongoing[chat.id];

    Widget subtitle;
    if (typing.isNotEmpty) {
      subtitle = Text(
        chat.isGroup ? '${app.nameOf(typing.first)} is typing…' : 'typing…',
        style: const TextStyle(color: brand, fontStyle: FontStyle.italic),
      );
    } else if (ongoingCall != null) {
      subtitle = const Row(children: [
        Icon(Icons.call, size: 14, color: Color(0xFF34C759)),
        SizedBox(width: 4),
        Text('Call in progress', style: TextStyle(color: Color(0xFF34C759))),
      ]);
    } else {
      String text;
      if (last == null) {
        text = chat.isGroup ? 'Group created' : 'Say hi 👋';
      } else if (last.isSystem) {
        text = systemText(app, last.system!);
      } else if (last.deleted) {
        text = 'Message deleted';
      } else if (last.undecryptable) {
        text = '🔒 Encrypted message';
      } else {
        final who = last.senderId == app.me?.id ? 'You: ' : (chat.isGroup ? '${app.nameOf(last.senderId)}: ' : '');
        text = '$who${last.payload?.preview ?? ''}';
      }
      subtitle = Row(children: [
        if (last != null && !last.isSystem && last.senderId == app.me?.id) ...[
          Ticks(state: app.deliveryState(chat, last), size: 15),
          const SizedBox(width: 3),
        ],
        Expanded(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis)),
      ]);
    }

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.primaryContainer.withValues(alpha: 0.35),
      onTap: onTap,
      leading: ChatAvatar(chat: chat),
      title: Row(children: [
        Expanded(
          child: Text(app.chatTitle(chat),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: chat.unread > 0 ? FontWeight.w700 : FontWeight.w500)),
        ),
        if (chat.disappearSeconds > 0) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.timer_outlined, size: 14, color: Colors.grey)),
        if (chat.muted) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.volume_off, size: 14, color: Colors.grey)),
      ]),
      subtitle: subtitle,
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(chat.lastActivity == 0 ? "" : listTime(chat.lastActivity),
              style: TextStyle(fontSize: 12, color: chat.unread > 0 && !chat.muted ? brand : Colors.grey)),
          const SizedBox(height: 4),
          if (chat.unread > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: chat.muted ? Colors.grey : brand, borderRadius: BorderRadius.circular(10)),
              child: Text('${chat.unread}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            )
          else
            const SizedBox(height: 18),
        ],
      ),
    );
  }
}

/// ✓ sent, ✓✓ delivered, purple ✓✓ seen.
class Ticks extends StatelessWidget {
  const Ticks({super.key, required this.state, this.size = 16, this.color});
  final int state;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final base = color ?? Colors.grey;
    return switch (state) {
      0 => Icon(Icons.schedule, size: size - 2, color: base),
      1 => Icon(Icons.check, size: size, color: base),
      2 => Icon(Icons.done_all, size: size, color: base),
      _ => Icon(Icons.done_all, size: size, color: const Color(0xFF4FC3F7)),
    };
  }
}

// ------------------------------------------------------------------ calls tab
class CallsTab extends StatelessWidget {
  const CallsTab({super.key, required this.onOpenChat});
  final void Function(String chatId) onOpenChat;

  Future<void> _call(BuildContext context, User u, bool video) async {
    final app = AppScope.read(context);
    final chat = await app.openDirect(u.id);
    await app.calls.start(chat.id, video: video);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final people = app.users.values.where((u) => u.id != app.me?.id && !u.disabled).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    final ongoing = app.calls.ongoing.values.where((c) => app.calls.active?.id != c.id).toList();
    return ListView(children: [
      for (final call in ongoing)
        Card(
          margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          color: const Color(0xFF34C759).withValues(alpha: 0.15),
          child: ListTile(
            leading: const Icon(Icons.call, color: Color(0xFF34C759)),
            title: Text(app.chats[call.chatId] != null ? app.chatTitle(app.chats[call.chatId]!) : 'Call'),
            subtitle: Text('${call.participants.length} in call'),
            trailing: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF34C759)),
              onPressed: () => app.calls.join(call),
              child: const Text('Join'),
            ),
          ),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text('Household', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey)),
      ),
      for (final u in people)
        ListTile(
          leading: Avatar.user(u),
          title: Text(u.displayName),
          subtitle: Text(lastSeenText(u)),
          onTap: () async => onOpenChat((await app.openDirect(u.id)).id),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call_outlined, color: brand), onPressed: () => _call(context, u, false)),
            IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam_outlined, color: brand), onPressed: () => _call(context, u, true)),
          ]),
        ),
      if (people.isEmpty)
        const Padding(
          padding: EdgeInsets.all(32),
          child: Text('Nobody else is on this frequency yet.\nShare it from More → Frequency.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
    ]);
  }
}
