import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/models.dart';
import '../services/media.dart';
import '../state/app_state.dart' show everyoneChatId;
import 'media_views.dart';
import 'new_chat.dart';
import 'widgets.dart';

/// Contact / group details: members, media, disappearing timer, mute, leave.
class ChatInfoScreen extends StatelessWidget {
  const ChatInfoScreen({super.key, required this.chatId});
  final String chatId;

  Future<void> _guard(BuildContext context, Future<void> Function() fn) async {
    try {
      await fn();
    } on ApiException catch (e) {
      if (context.mounted) toast(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final chat = app.chats[chatId];
    if (chat == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('You are no longer in this chat.')));
    final peer = app.directPeer(chat);
    final thread = app.thread(chatId);
    final media = thread.messages
        .where((m) => !m.deleted && (m.payload?.type == 'image' || m.payload?.type == 'gif') && m.payload?.file != null &&
            isDisplayableImage(m.payload!.file!.mime))
        .toList()
        .reversed
        .take(30)
        .toList();
    final everyone = chat.id == everyoneChatId;
    final canEdit = chat.isGroup && chat.amAdmin && !everyone;
    final canTimer = !chat.isGroup || chat.amAdmin || everyone;

    return Scaffold(
      appBar: AppBar(title: Text(chat.isGroup ? 'Group info' : 'Contact info')),
      body: ListView(children: [
        const SizedBox(height: 24),
        Center(
          child: Stack(children: [
            ChatAvatar(chat: chat, size: 110),
          ]),
        ),
        const SizedBox(height: 12),
        Center(
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(app.chatTitle(chat), style: Theme.of(context).textTheme.headlineSmall),
            if (canEdit)
              IconButton(
                icon: const Icon(Icons.edit, size: 18),
                onPressed: () async {
                  final name = await promptText(context, 'Group name', initial: chat.name ?? '');
                  if (name != null && name.isNotEmpty) await _guard(context, () => app.renameGroup(chat.id, name));
                },
              ),
          ]),
        ),
        if (peer != null) ...[
          Center(child: Text(lastSeenText(peer), style: const TextStyle(color: Colors.grey))),
          if (peer.about.isNotEmpty) Padding(
            padding: const EdgeInsets.all(12),
            child: Text(peer.about, textAlign: TextAlign.center),
          ),
        ],
        const SizedBox(height: 16),
        if (peer != null || chat.isGroup)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _Action(icon: Icons.call, label: 'Voice', onTap: () => app.calls.start(chat.id, video: false)),
            _Action(icon: Icons.videocam, label: 'Video', onTap: () => app.calls.start(chat.id, video: true)),
            _Action(
              icon: chat.muted ? Icons.notifications_off : Icons.notifications,
              label: chat.muted ? 'Unmute' : 'Mute',
              onTap: () => _guard(context, () => app.mute(chat.id, chat.muted ? null : const Duration(days: 3650))),
            ),
          ]),
        const Divider(height: 32),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Disappearing messages'),
          subtitle: Text(timerLabel(chat.disappearSeconds)),
          enabled: canTimer,
          onTap: () async {
            final v = await showDialog<int>(
              context: context,
              builder: (c) => SimpleDialog(
                title: const Text('Messages disappear after'),
                children: [
                  for (final s in const [0, 10, 60, 300, 3600, 86400, 604800])
                    RadioListTile<int>(
                      value: s,
                      groupValue: chat.disappearSeconds,
                      title: Text(timerLabel(s)),
                      onChanged: (v) => Navigator.pop(c, v),
                    ),
                ],
              ),
            );
            if (v != null && v != chat.disappearSeconds) await _guard(context, () => app.setTimer(chat.id, v));
          },
        ),
        const ListTile(
          leading: Icon(Icons.lock_outline),
          title: Text('End-to-end encrypted'),
          subtitle: Text('Messages, photos, files and voice notes can only be read by people in this chat. Relays and others on the frequency only see scrambled data.'),
        ),
        if (peer?.publicKey != null)
          ListTile(
            leading: const Icon(Icons.verified_user_outlined),
            title: const Text('Security code'),
            subtitle: Text('Compare with ${peer!.displayName}\'s screen:\n${_safetyCode(app.identity!.publicKey, peer!.publicKey!)}',
                style: const TextStyle(fontFamily: 'monospace')),
          ),
        if (media.isNotEmpty) ...[
          const Divider(height: 32),
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Media', style: TextStyle(fontWeight: FontWeight.w600))),
          SizedBox(
            height: 96,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final m in media)
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 88,
                        height: 88,
                        child: EncryptedImage(
                          file: m.payload!.file!,
                          maxWidth: 88,
                          maxHeight: 88,
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ImageViewer(file: m.payload!.file!))),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
        if (chat.isGroup && !everyone) ...[
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text('${chat.members.length} members', style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          if (canEdit)
            ListTile(
              leading: const CircleAvatar(backgroundColor: brand, child: Icon(Icons.person_add, color: Colors.white)),
              title: const Text('Add members'),
              onTap: () async {
                final ids = await Navigator.push<List<String>>(context,
                    MaterialPageRoute(builder: (_) => PickPeopleScreen(exclude: chat.members.map((m) => m.userId).toSet())));
                if (ids != null && ids.isNotEmpty) await _guard(context, () => app.addMembers(chat.id, ids));
              },
            ),
          for (final Member m in chat.members)
            ListTile(
              leading: Avatar.user(app.users[m.userId]),
              title: Text(app.nameOf(m.userId)),
              subtitle: Text(app.users[m.userId] == null ? '' : lastSeenText(app.users[m.userId]!)),
              trailing: m.role == 'admin' ? const Chip(label: Text('Admin'), visualDensity: VisualDensity.compact) : null,
              onTap: m.userId == app.me?.id || !canEdit
                  ? null
                  : () async {
                      final r = await showModalBottomSheet<String>(
                        context: context,
                        builder: (c) => SafeArea(child: Wrap(children: [
                          ListTile(
                            leading: const Icon(Icons.admin_panel_settings),
                            title: Text(m.role == 'admin' ? 'Remove admin' : 'Make admin'),
                            onTap: () => Navigator.pop(c, 'role'),
                          ),
                          ListTile(
                            leading: const Icon(Icons.person_remove, color: Colors.red),
                            title: const Text('Remove from group', style: TextStyle(color: Colors.red)),
                            onTap: () => Navigator.pop(c, 'remove'),
                          ),
                        ])),
                      );
                      if (r == 'role') await _guard(context, () => app.setRole(chat.id, m.userId, m.role == 'admin' ? 'member' : 'admin'));
                      if (r == 'remove') await _guard(context, () => app.removeMember(chat.id, m.userId));
                    },
            ),
          const Divider(height: 32),
          ListTile(
            leading: const Icon(Icons.exit_to_app, color: Colors.red),
            title: const Text('Leave group', style: TextStyle(color: Colors.red)),
            onTap: () async {
              if (await confirm(context, 'Leave “${chat.name}”?', 'You will stop receiving messages from this group.', ok: 'Leave', danger: true)) {
                await _guard(context, () async {
                  await app.removeMember(chat.id, app.me!.id);
                  if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                });
              }
            },
          ),
        ],
        const SizedBox(height: 32),
      ]),
    );
  }

  /// Same code on both phones (XOR of the two public keys) — matching codes mean no one is in the middle.
  String _safetyCode(String a, String b) {
    final x = base64.decode(a), y = base64.decode(b);
    final digits = [for (var i = 0; i < 15; i++) ((x[i] ^ y[i]) % 100).toString().padLeft(2, '0')].join();
    return [for (var i = 0; i < digits.length; i += 5) digits.substring(i, i + 5)].join(' ');
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Column(children: [
          IconButton.filledTonal(onPressed: onTap, icon: Icon(icon, color: brand)),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      );
}
