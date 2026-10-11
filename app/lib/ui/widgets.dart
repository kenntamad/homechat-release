import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';

/// Gives every widget below access to the app state and rebuilds on change.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without subscribing to rebuilds (for callbacks).
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

const brand = Color(0xFF7360F2); // a friendly purple

const _palette = [
  Color(0xFF7360F2), Color(0xFFE5677B), Color(0xFF3FA796), Color(0xFFF0A23B),
  Color(0xFF4B8FE2), Color(0xFFB15FD8), Color(0xFF5DAE4F), Color(0xFFDB6E3E),
];

Color colorFor(String seed) => _palette[seed.codeUnits.fold<int>(0, (a, b) => a + b) % _palette.length];

String initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  final first = parts.first.characters.first;
  final second = parts.length > 1 ? parts.last.characters.first : '';
  return (first + second).toUpperCase();
}

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, required this.seed, this.blobId, this.size = 44, this.online = false, this.icon});
  final String name;
  final String seed;
  final String? blobId;
  final double size;
  final bool online;
  final IconData? icon;

  factory Avatar.user(User? u, {double size = 44, bool showOnline = true}) => Avatar(
        name: u?.displayName ?? '?',
        seed: u?.id ?? '?',
        blobId: u?.avatar,
        size: size,
        online: showOnline && (u?.online ?? false),
      );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    final fallback = CircleAvatar(
      radius: size / 2,
      backgroundColor: colorFor(seed),
      child: icon != null
          ? Icon(icon, color: Colors.white, size: size * 0.5)
          : Text(initials(name), style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: size * 0.36)),
    );
    Widget child = fallback;
    final cached = blobId == null ? null : app.media.get(blobId!);
    if (cached != null) {
      child = CircleAvatar(radius: size / 2, backgroundImage: MemoryImage(cached));
    } else if (blobId != null) {
      child = FutureBuilder<Uint8List>(
        future: app.avatarBytes(blobId!),
        builder: (context, snap) => snap.hasData
            ? CircleAvatar(radius: size / 2, backgroundImage: MemoryImage(snap.data!))
            : fallback,
      );
    }
    if (!online) return SizedBox(width: size, height: size, child: child);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        child,
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            width: size * 0.28,
            height: size * 0.28,
            decoration: BoxDecoration(
              color: const Color(0xFF34C759),
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
            ),
          ),
        ),
      ]),
    );
  }
}

class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.chat, this.size = 48});
  final Chat chat;
  final double size;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (chat.isGroup) {
      return Avatar(name: chat.name ?? 'Group', seed: chat.id, blobId: chat.avatar, size: size,
          icon: chat.avatar == null ? Icons.group : null);
    }
    final peer = app.directPeer(chat);
    if (peer == null) return Avatar(name: 'My Notes', seed: chat.id, size: size, icon: Icons.bookmark);
    return Avatar.user(peer, size: size);
  }
}

// ------------------------------------------------------------------ time
String two(int n) => n.toString().padLeft(2, '0');

String clock(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${two(d.minute)} ${d.hour < 12 ? 'AM' : 'PM'}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "3:04 PM", "Yesterday", "Tue", "12 Mar"
String listTime(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  if (sameDay(d, now)) return clock(d);
  if (sameDay(d, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  if (now.difference(d).inDays < 7) return _days[d.weekday - 1];
  return '${d.day} ${_months[d.month - 1]}${d.year != now.year ? ' ${d.year}' : ''}';
}

String dayHeader(DateTime d) {
  final now = DateTime.now();
  if (sameDay(d, now)) return 'Today';
  if (sameDay(d, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${_days[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}${d.year != now.year ? ' ${d.year}' : ''}';
}

String lastSeenText(User u) {
  if (u.online) return 'Online';
  if (u.lastSeen == null) return 'Offline';
  final d = DateTime.fromMillisecondsSinceEpoch(u.lastSeen!);
  final diff = DateTime.now().difference(d);
  if (diff.inMinutes < 1) return 'Last seen just now';
  if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes} min ago';
  if (sameDay(d, DateTime.now())) return 'Last seen today at ${clock(d)}';
  return 'Last seen ${listTime(u.lastSeen!)}';
}

String duration(Duration d) {
  final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String timerLabel(int seconds) => switch (seconds) {
      0 => 'Off',
      10 => '10 seconds',
      60 => '1 minute',
      300 => '5 minutes',
      3600 => '1 hour',
      86400 => '1 day',
      604800 => '1 week',
      _ => '$seconds s',
    };

/// Human text for server system messages (group changes, calls…).
String systemText(AppState app, Map<String, dynamic> s) {
  final by = app.nameOf(s['by'] as String?);
  switch (s['event']) {
    case 'group_created':
      return '$by created the group “${s['name']}”';
    case 'members_added':
      final names = (s['users'] as List).map((u) => app.nameOf(u as String)).join(', ');
      return '$by added $names';
    case 'member_removed':
      return '$by removed ${app.nameOf(s['user'] as String?)}';
    case 'member_left':
      return '$by left';
    case 'renamed':
      return '$by renamed the group to “${s['name']}”';
    case 'photo_changed':
      return '$by changed the group photo';
    case 'timer':
      final secs = (s['seconds'] as num).toInt();
      return secs == 0 ? '$by turned off disappearing messages' : '$by set messages to disappear after ${timerLabel(secs)}';
    case 'pinned':
      return '$by pinned a message';
    case 'call':
      final kind = s['video'] == true ? 'Video call' : 'Voice call';
      return switch (s['status']) {
        'completed' => '$kind · ${duration(Duration(milliseconds: (s['durationMs'] as num).toInt()))}',
        'declined' => '$kind declined',
        'cancelled' => 'Cancelled ${kind.toLowerCase()}',
        _ => s['by'] == app.me?.id ? '$kind · no answer' : 'Missed ${kind.toLowerCase()}',
      };
    default:
      return '';
  }
}

void toast(BuildContext context, String text) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
}

Future<bool> confirm(BuildContext context, String title, String body, {String ok = 'OK', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = '', int maxLength = 60}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: maxLength,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Save')),
      ],
    ),
  );
}
