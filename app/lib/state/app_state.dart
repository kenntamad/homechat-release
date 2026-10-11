// Everything the screens show, worked out from the encrypted packets on this
// device. There is no server: packets arrive from relays, from devices on the
// same Wi-Fi, or from our own history file, and are applied in any order.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../crypto/e2e.dart';
import '../crypto/frequency.dart';
import '../crypto/schnorr.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../net/transport.dart';
import '../services/media.dart';
import '../services/notifications.dart';
import '../services/updater.dart';
import 'calls.dart';

String get platformName => Platform.isAndroid
    ? 'android'
    : Platform.isIOS
        ? 'ios'
        : Platform.isWindows
            ? 'windows'
            : Platform.isMacOS
                ? 'macos'
                : 'linux';

const everyoneChatId = 'all';

/// Messages of one conversation, oldest first.
class ChatThread extends ChangeNotifier {
  ChatThread(this.chatId);
  final String chatId;
  final List<Message> messages = [];
  bool loaded = true;
  bool loadingOlder = false;
  bool hasOlder = false;

  int indexOfId(String id) => messages.indexWhere((m) => m.id == id);

  void upsert(Message m) {
    final i = indexOfId(m.id);
    if (i >= 0) {
      messages[i] = m;
    } else if (messages.isEmpty || messages.last.createdAt <= m.createdAt) {
      messages.add(m);
    } else {
      var j = messages.length - 1;
      while (j > 0 && messages[j - 1].createdAt > m.createdAt) {
        j--;
      }
      messages.insert(j, m);
    }
    notifyListeners();
  }

  void remove(Iterable<String> ids) {
    final set = ids.toSet();
    messages.removeWhere((m) => set.contains(m.id));
    notifyListeners();
  }

  void touch() => notifyListeners();
}

class _GroupState {
  _GroupState({required this.name, required this.members, required this.admins, required this.ts});
  String name;
  List<String> members;
  List<String> admins;
  int ts;
}

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState(this.prefs) {
    calls = CallController(this);
  }

  final SharedPreferences prefs;
  late final CallController calls;

  // identity (this person) and device
  Identity? identity;
  NostrKey? _nostrKey;
  late String deviceId;
  User? me;

  // the frequency we're tuned to
  Channel? channel;
  Store? _store;
  Transport? transport;
  bool booting = true;
  bool tuning = false;

  final Map<String, User> users = {};
  final Map<String, Chat> chats = {};
  final Map<String, ChatThread> _threads = {};
  final Map<String, Map<String, int>> _typing = {};
  final Map<String, int> _profileTs = {};
  final Map<String, int> _heardFrom = {}; // userId -> local ms of last presence
  final Map<String, Uint8List> _avatars = {};
  final Map<String, _GroupState> _groups = {};
  final Map<String, Map<String, dynamic>> _edits = {}; // msgId -> {text, from, ts}
  final Map<String, String> _deletes = {}; // msgId -> who deleted
  final Map<String, Map<String, (String, int)>> _reactions = {}; // msgId -> userId -> (emoji, ts)
  final Map<String, (String?, int)> _pins = {}; // chatId -> (msgId, ts)
  final Map<String, (int, int)> _timers = {}; // chatId -> (seconds, ts)
  final Set<String> _leftChats = {};
  Map<String, int> _muted = {};
  Map<String, int> _cleared = {};
  final MediaCache media = MediaCache();
  final Map<String, Future<Uint8List>> _downloads = {};
  final Map<String, Timer> _receiptTimers = {};
  final List<Timer> _timers2 = [];

  String? openChatId;
  bool appActive = true;
  final ValueNotifier<String?> openChatRequest = ValueNotifier(null);

  // ------------------------------------------------------------------ prefs
  bool get hasIdentity => identity != null;
  bool get signedIn => identity != null && channel != null && me != null;
  bool get connected => transport?.online ?? false;
  String get householdName => prefs.getString('channel_name') ?? 'Home Chat';
  String get frequency => prefs.getString('frequency') ?? '';
  List<String> get relayUrls => prefs.getStringList('relays') ?? defaultRelays;
  String get ntfyServer => prefs.getString('ntfy') ?? defaultNtfyServer;
  String get pushTopic => prefs.getString('push_topic') ?? '';
  String? get pushUrl => prefs.getBool('push_on') == true && pushTopic.isNotEmpty ? '$ntfyServer/$pushTopic' : null;
  List<Map<String, dynamic>> get iceServers => [for (final s in defaultIceServers) Map<String, dynamic>.from(s)];
  String get _tagKey => channel?.tag ?? 'none';
  Set<String>? _hidden;
  Set<String> get hiddenForMe => _hidden ??= (prefs.getStringList('hidden:$_tagKey') ?? []).toSet();
  List<Map<String, dynamic>> get customStickers =>
      [for (final s in prefs.getStringList('stickers') ?? []) (jsonDecode(s) as Map).cast<String, dynamic>()];
  List<String> get recentEmoji => prefs.getStringList('recent_emoji') ?? [];

  Map<String, int> _intMap(String key) {
    final raw = prefs.getString(key);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveIntMap(String key, Map<String, int> m) => prefs.setString(key, jsonEncode(m));

  void refresh() => notifyListeners();

  // ------------------------------------------------------------------ updates
  UpdateInfo? update;
  bool updateDismissed = false;
  Timer? _updateTimer;

  /// Returns the newer release, if any. [quiet] swallows errors (background checks).
  Future<UpdateInfo?> checkForUpdates({bool quiet = true}) async {
    try {
      update = await Updater.check();
      notifyListeners();
      return update;
    } catch (e) {
      if (!quiet) rethrow;
      return null;
    }
  }

  // ------------------------------------------------------------------ boot
  Future<void> boot() async {
    _updateTimer = Timer(const Duration(seconds: 8), () {
      checkForUpdates();
      _updateTimer = Timer.periodic(const Duration(hours: 6), (_) => checkForUpdates());
    });
    await Notifications.init();
    Notifications.onTap = (payload) {
      if (payload.startsWith('chat:')) openChatRequest.value = payload.substring(5);
    };
    deviceId = prefs.getString('device_id') ?? newId();
    await prefs.setString('device_id', deviceId);
    final seed = prefs.getString('seed');
    if (seed != null) await _loadIdentity(base64.decode(seed));
    final f = prefs.getString('frequency'), k = prefs.getString('frequency_key'), t = prefs.getString('frequency_tag');
    if (identity != null && f != null && k != null && t != null) {
      await _startChannel(Channel.restore(f, k, t));
    }
    booting = false;
    notifyListeners();
  }

  Future<void> _loadIdentity(Uint8List seed) async {
    identity = await Identity.fromSeed(seed);
    _nostrKey = await nostrKeyFor(seed);
  }

  /// First run: make this person's keys.
  Future<void> createIdentity({required String name, Uint8List? seed}) async {
    final s = seed ?? randomBytes(32);
    await prefs.setString('seed', base64.encode(s));
    await prefs.setString('name', name.trim());
    if (!prefs.containsKey('push_topic')) await prefs.setString('push_topic', 'hc-${hexOf(randomBytes(10))}');
    await _loadIdentity(s);
    notifyListeners();
  }

  /// "Account code" to use the same identity on another of your devices.
  String get accountCode => 'HC1-${base64Url.encode(identity!.seed).replaceAll('=', '')}';

  static Uint8List? parseAccountCode(String code) {
    final c = code.trim().replaceAll(RegExp(r'\s'), '');
    if (!c.startsWith('HC1-')) return null;
    try {
      var b = c.substring(4);
      while (b.length % 4 != 0) {
        b += '=';
      }
      final seed = base64Url.decode(b);
      return seed.length == 32 ? Uint8List.fromList(seed) : null;
    } catch (_) {
      return null;
    }
  }

  /// Tune to a frequency (slow the first time: the key is stretched on purpose).
  Future<void> tune(String freq, {String? label}) async {
    tuning = true;
    notifyListeners();
    try {
      final ch = await Channel.derive(freq);
      await prefs.setString('frequency', freq.trim());
      await prefs.setString('frequency_key', ch.keyB64);
      await prefs.setString('frequency_tag', ch.tag);
      if (label != null && label.trim().isNotEmpty) await prefs.setString('channel_name', label.trim());
      await _stopChannel();
      await _startChannel(ch);
    } finally {
      tuning = false;
      notifyListeners();
    }
  }

  Future<void> _stopChannel() async {
    for (final t in _timers2) {
      t.cancel();
    }
    _timers2.clear();
    await calls.hangUp();
    await transport?.stop();
    await _store?.close();
    transport = null;
    _store = null;
    channel = null;
    users.clear();
    chats.clear();
    _threads.clear();
    _typing.clear();
    _profileTs.clear();
    _groups.clear();
    _edits.clear();
    _deletes.clear();
    _reactions.clear();
    _pins.clear();
    _timers.clear();
    _leftChats.clear();
    _hidden = null;
  }

  Future<void> _startChannel(Channel ch) async {
    channel = ch;
    final store = await Store.open(ch.tag);
    _store = store;

    me = User(
      id: userIdOf(identity!.publicKey),
      username: prefs.getString('name') ?? 'Me',
      displayName: prefs.getString('name') ?? 'Me',
      about: prefs.getString('about') ?? '',
      publicKey: identity!.publicKey,
      online: true,
      push: pushUrl,
    );
    final av = prefs.getString('avatar');
    if (av != null) _setAvatar(me!, base64.decode(av));
    users[me!.id] = me!;
    _muted = _intMap('muted:${ch.tag}');
    _cleared = _intMap('cleared:${ch.tag}');
    final seen = _intMap('last_seen:${ch.tag}');
    _ensureEveryone();

    // Rebuild everything from this device's history.
    for (final p in store.all) {
      final inner = await ch.open(p.packet);
      if (inner != null) await _apply(inner, false);
    }
    for (final e in seen.entries) {
      users[e.key]?.lastSeen ??= e.value;
    }
    for (final c in chats.values) {
      _recount(c);
    }

    final outboxFile = File('${store.dir.path}${Platform.pathSeparator}outbox.json');
    List<Map<String, dynamic>> outbox = [];
    try {
      if (await outboxFile.exists()) {
        outbox = [for (final e in jsonDecode(await outboxFile.readAsString()) as List) (e as Map).cast<String, dynamic>()];
      }
    } catch (_) {}
    final marks = _intMap('lan_sync:${ch.tag}');
    transport = Transport(
      channel: ch,
      store: store,
      nostrKey: _nostrKey!,
      deviceId: deviceId,
      userId: me!.id,
      relayUrls: relayUrls,
      lanSyncMarks: marks,
      outbox: outbox,
      onOutboxChanged: (list) {
        outboxFile.writeAsString(jsonEncode(list)).catchError((_) => outboxFile);
        if (list.isEmpty) _markAllSent();
      },
      onInner: (inner, live) => _apply(inner, live),
      onStatus: notifyListeners,
    );
    await transport!.start();
    await _publishProfile();
    _sendPresence();

    _timers2.add(Timer.periodic(const Duration(seconds: 30), (_) => _sendPresence()));
    _timers2.add(Timer.periodic(const Duration(hours: 12), (_) => _publishProfile()));
    _timers2.add(Timer.periodic(const Duration(seconds: 10), (_) => _sweep()));
    _timers2.add(Timer.periodic(const Duration(minutes: 2), (_) {
      _saveIntMap('lan_sync:${ch.tag}', marks);
      _saveIntMap('last_seen:${ch.tag}', {for (final u in users.values) if (u.lastSeen != null) u.id: u.lastSeen!});
    }));
    // After history has had time to arrive, tell senders we received their messages.
    _timers2.add(Timer(const Duration(seconds: 20), () {
      for (final c in chats.values) {
        _scheduleReceipt(c.id);
      }
    }));
    notifyListeners();
  }

  // ------------------------------------------------------------------ profile & presence
  void _setAvatar(User u, Uint8List bytes) {
    final id = 'av-${u.id}-${hexOf(bytes.take(8).toList())}${bytes.length}';
    _avatars[id] = bytes;
    media.put(id, bytes);
    u.avatar = id;
  }

  Future<void> _publishProfile() async {
    final t = transport;
    if (t == null || me == null) return;
    final av = prefs.getString('avatar');
    await t.publish({
      'k': 'profile',
      'n': me!.displayName,
      'a': me!.about,
      'x': identity!.publicKey,
      if (pushUrl != null) 'p': pushUrl,
      if (av != null) 'av': av,
    });
  }

  void _sendPresence() {
    transport?.publish({'k': 'presence', 'a': appActive}, ephemeral: true);
  }

  Future<void> updateProfile({String? displayName, String? about}) async {
    if (displayName != null) {
      await prefs.setString('name', displayName);
      me?.displayName = displayName;
    }
    if (about != null) {
      await prefs.setString('about', about);
      me?.about = about;
    }
    notifyListeners();
    await _publishProfile();
  }

  /// Profile photos travel inside the profile, so keep them small (they're shrunk first).
  Future<void> setAvatar(Uint8List? bytes) async {
    if (bytes == null) {
      await prefs.remove('avatar');
      me?.avatar = null;
    } else {
      if (bytes.length > 48 * 1024) throw ApiException('too_large', 'Pick a smaller photo (under 48 KB after cropping).');
      await prefs.setString('avatar', base64.encode(bytes));
      _setAvatar(me!, bytes);
    }
    notifyListeners();
    await _publishProfile();
  }

  Future<void> setPush({required bool on, String? server}) async {
    await prefs.setBool('push_on', on);
    if (server != null && server.trim().isNotEmpty) await prefs.setString('ntfy', server.trim().replaceAll(RegExp(r'/+$'), ''));
    me?.push = pushUrl;
    notifyListeners();
    await _publishProfile();
  }

  Future<void> rotatePushTopic() async {
    await prefs.setString('push_topic', 'hc-${hexOf(randomBytes(10))}');
    me?.push = pushUrl;
    notifyListeners();
    await _publishProfile();
  }

  Future<void> setRelays(List<String> urls) async {
    await prefs.setStringList('relays', urls);
    final ch = channel;
    if (ch != null) {
      await _stopChannel();
      await _startChannel(ch);
    }
  }

  Future<void> setChannelName(String name) async {
    await prefs.setString('channel_name', name);
    chats[everyoneChatId]?.name = name;
    notifyListeners();
  }

  /// Leave this frequency and wipe its history from this device.
  Future<void> forgetFrequency() async {
    final store = _store;
    await _stopChannel();
    await store?.destroy();
    for (final k in ['frequency', 'frequency_key', 'frequency_tag']) {
      await prefs.remove(k);
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ lifecycle
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == appActive) return;
    appActive = active;
    _sendPresence();
    if (active) {
      transport?.kick();
      if (openChatId != null) markRead(openChatId!);
    }
  }

  // ------------------------------------------------------------------ helpers
  String nameOf(String? userId) {
    if (userId == null) return '';
    if (userId == me?.id) return 'You';
    return users[userId]?.displayName ?? 'Someone';
  }

  String chatTitle(Chat c) {
    if (c.id == everyoneChatId) return householdName;
    if (c.isGroup) return c.name ?? 'Group';
    final other = c.members.where((m) => m.userId != me?.id).toList();
    if (other.isEmpty) return 'My Notes';
    return users[other.first.userId]?.displayName ?? 'Chat';
  }

  User? directPeer(Chat c) {
    if (c.isGroup) return null;
    for (final m in c.members) {
      if (m.userId != me?.id) return users[m.userId];
    }
    return null;
  }

  List<Chat> get sortedChats {
    final list = chats.values.toList()..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    return list;
  }

  int get totalUnread => chats.values.where((c) => !c.muted).fold(0, (a, c) => a + c.unread);

  List<String> typingIn(String chatId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final m = _typing[chatId];
    if (m == null) return [];
    m.removeWhere((_, until) => until < now);
    return m.keys.toList();
  }

  ChatThread thread(String chatId) => _threads.putIfAbsent(chatId, () => ChatThread(chatId));

  bool isOnline(String userId) {
    if (userId == me?.id) return true;
    final t = _heardFrom[userId];
    return t != null && DateTime.now().millisecondsSinceEpoch - t < 75000;
  }

  // ------------------------------------------------------------------ chats
  static String directId(String a, String b) {
    final s = [a, b]..sort();
    return 'd:${s[0]}:${s[1]}';
  }

  void _ensureEveryone() {
    final c = chats.putIfAbsent(
        everyoneChatId,
        () => Chat(
              id: everyoneChatId,
              type: 'group',
              name: householdName,
              lastSeq: 0,
              lastActivity: 0,
              members: [],
            ));
    for (final u in users.values) {
      if (c.member(u.id) == null) c.members.add(Member(userId: u.id, role: 'member'));
    }
  }

  /// The chat a packet belongs to, created on first sight. Null if it isn't ours.
  Chat? _chatFor(String chatId, String from) {
    if (_leftChats.contains(chatId)) return null;
    final existing = chats[chatId];
    if (existing != null) return existing;
    final myId = me!.id;
    if (chatId.startsWith('d:')) {
      final parts = chatId.split(':');
      if (parts.length != 3 || (parts[1] != myId && parts[2] != myId)) return null;
      final c = Chat(
        id: chatId,
        type: 'direct',
        lastSeq: 0,
        lastActivity: 0,
        members: [
          Member(userId: parts[1], role: 'member'),
          if (parts[2] != parts[1]) Member(userId: parts[2], role: 'member'),
        ],
      );
      chats[chatId] = c;
      return c;
    }
    if (chatId.startsWith('g:')) {
      // Group we haven't seen the details of yet; filled in when its "grp" packet arrives.
      final c = Chat(
        id: chatId,
        type: 'group',
        name: 'Group',
        lastSeq: 0,
        lastActivity: 0,
        members: [Member(userId: myId, role: 'member'), if (from != myId) Member(userId: from, role: 'member')],
      );
      chats[chatId] = c;
      return c;
    }
    if (chatId == everyoneChatId) {
      _ensureEveryone();
      return chats[everyoneChatId];
    }
    return null;
  }

  List<String> _memberIds(String chatId) {
    if (chatId == everyoneChatId) return users.keys.toList();
    final g = _groups[chatId];
    if (g != null) return g.members;
    return chats[chatId]?.members.map((m) => m.userId).toList() ?? [];
  }

  Map<String, String> _recipients(Iterable<String> userIds) => {
        for (final u in userIds)
          if (users[u]?.publicKey != null) u: users[u]!.publicKey!,
      };

  void _recount(Chat c) {
    final myRead = c.member(me!.id)?.lastReadSeq ?? 0;
    final cleared = _cleared[c.id] ?? 0;
    var n = 0;
    Message? last;
    for (final m in thread(c.id).messages) {
      if (m.createdAt <= cleared) continue;
      last = m;
      if (m.isSystem || m.deleted || m.senderId == me!.id) continue;
      if (m.createdAt > myRead) n++;
    }
    c.unread = n;
    c.clearedSeq = cleared;
    c.lastMessage = last;
    if (last != null) {
      c.lastActivity = max(c.lastActivity, last.createdAt);
      c.lastSeq = max(c.lastSeq, last.createdAt);
    }
    c.mutedUntil = _muted[c.id] ?? 0;
    final timer = _timers[c.id];
    c.disappearSeconds = timer?.$1 ?? 0;
    c.pinnedMessageId = _pins[c.id]?.$1;
  }

  // ------------------------------------------------------------------ applying packets
  Future<void> _apply(Map<String, dynamic> inner, bool live) async {
    try {
      await _applyInner(inner, live);
    } catch (e) {
      debugPrint('could not apply packet: $e');
    }
  }

  Future<void> _applyInner(Map<String, dynamic> inner, bool live) async {
    final from = inner['f'] as String? ?? '';
    final ts = inner['t'] as int;
    final id = inner['i'] as String;
    switch (inner['k']) {
      case 'profile':
        final x = inner['x'] as String?;
        if (x == null || userIdOf(x) != from) return;
        if ((_profileTs[from] ?? 0) > ts) return;
        _profileTs[from] = ts;
        final u = users[from] ?? User(id: from, username: '', displayName: '', publicKey: x);
        u
          ..displayName = (inner['n'] as String? ?? 'Someone').trim()
          ..about = inner['a'] as String? ?? ''
          ..push = inner['p'] as String?
          ..publicKey = x;
        final av = inner['av'];
        if (av is String && av.length < 80000) {
          try {
            _setAvatar(u, base64.decode(av));
          } catch (_) {}
        } else if (from != me?.id) {
          u.avatar = null;
        }
        u.lastSeen = max(u.lastSeen ?? 0, ts);
        users[from] = u;
        if (from == me?.id) me = u;
        _ensureEveryone();
        notifyListeners();
      case 'presence':
        if (from == me?.id) return;
        final u = users[from];
        _heardFrom[from] = DateTime.now().millisecondsSinceEpoch;
        if (u != null) {
          final wasOnline = u.online;
          u.online = true;
          u.lastSeen = DateTime.now().millisecondsSinceEpoch;
          if (!wasOnline) notifyListeners();
        }
      case 'typing':
        if (!live || from == me?.id) return;
        final map = _typing.putIfAbsent(inner['c'] as String, () => {});
        if (inner['on'] == true) {
          map[from] = DateTime.now().millisecondsSinceEpoch + 6000;
          Timer(const Duration(milliseconds: 6100), notifyListeners);
        } else {
          map.remove(from);
        }
        notifyListeners();
      case 'c':
        final env = (inner['env'] as Map?)?.cast<String, dynamic>();
        if (env == null || env['s'] is! String || userIdOf(env['s'] as String) != from) return;
        final chatId = inner['c'] as String? ?? '';
        final payload = await identity!.open(me!.id, env);
        if (payload == null) return; // not addressed to us
        await _applyChat(chatId, from, ts, id, payload, live);
      case 'call':
        final env = (inner['env'] as Map?)?.cast<String, dynamic>();
        if (!live || env == null || env['s'] is! String || userIdOf(env['s'] as String) != from) return;
        final payload = await identity!.open(me!.id, env);
        if (payload == null) return;
        _heardFrom[from] = DateTime.now().millisecondsSinceEpoch;
        await calls.onSignal(from, inner['d'] as String? ?? '', inner['c'] as String? ?? '', payload);
    }
  }

  Future<void> _applyChat(String chatId, String from, int ts, String id, Map<String, dynamic> p, bool live) async {
    // Group membership changes are handled first: they decide whether the chat is ours.
    if (p['k'] == 'grp') return _applyGroup(chatId, from, ts, id, p, live);
    final chat = _chatFor(chatId, from);
    if (chat == null) return;
    final t = thread(chatId);
    switch (p['k']) {
      case 'msg':
      case 'sys':
        final exp = (p['exp'] as num?)?.toInt();
        if (exp != null && exp <= DateTime.now().millisecondsSinceEpoch) {
          _store?.remove(id);
          return;
        }
        if (hiddenForMe.contains(id)) return;
        final isSys = p['k'] == 'sys';
        final m = Message(
          id: id,
          chatId: chatId,
          seq: ts,
          senderId: isSys ? null : from,
          kind: isSys ? 'system' : 'msg',
          system: isSys ? {...(p['s'] as Map).cast<String, dynamic>(), 'by': from} : null,
          createdAt: ts,
          expiresAt: exp,
        );
        if (!isSys) m.payload = Payload((p['m'] as Map).cast<String, dynamic>());
        _applyOps(m, chat);
        t.upsert(m);
        if (ts > chat.lastActivity) chat.lastActivity = ts;
        _recount(chat);
        if (live && from != me!.id && !isSys) _onIncoming(chat, m);
        notifyListeners();
      case 'edit':
        final target = p['id'] as String;
        final prev = _edits[target];
        if (prev != null && (prev['ts'] as int) > ts) return;
        _edits[target] = {'text': p['text'], 'from': from, 'ts': ts};
        _reapply(chat, target);
      case 'del':
        final target = p['id'] as String;
        _deletes[target] = from;
        _reapply(chat, target);
      case 'react':
        final target = p['id'] as String;
        final map = _reactions.putIfAbsent(target, () => {});
        final prev = map[from];
        if (prev != null && prev.$2 > ts) return;
        map[from] = (p['e'] as String? ?? '', ts);
        _reapply(chat, target);
      case 'rcpt':
        var m = chat.member(from);
        if (m == null && chatId == everyoneChatId) {
          m = Member(userId: from, role: 'member');
          chat.members.add(m);
        }
        if (m == null) return;
        m.lastReadSeq = max(m.lastReadSeq, (p['r'] as num?)?.toInt() ?? 0);
        m.lastDeliveredSeq = max(m.lastDeliveredSeq, max(m.lastReadSeq, (p['dl'] as num?)?.toInt() ?? 0));
        if (from == me!.id) {
          _recount(chat);
          notifyListeners();
        }
        t.touch();
        if (from != me!.id) notifyListeners();
      case 'pin':
        final prev = _pins[chatId];
        if (prev != null && prev.$2 > ts) return;
        _pins[chatId] = (p['id'] as String?, ts);
        _recount(chat);
        if (p['id'] != null) {
          _sysLocal(chat, '$id-pin', ts, {'event': 'pinned', 'by': from});
        }
        notifyListeners();
      case 'timer':
        final g = _groups[chatId];
        if (g != null && !g.admins.contains(from)) return;
        final prev = _timers[chatId];
        if (prev != null && prev.$2 > ts) return;
        final secs = (p['s'] as num?)?.toInt() ?? 0;
        _timers[chatId] = (secs, ts);
        _recount(chat);
        _sysLocal(chat, '$id-timer', ts, {'event': 'timer', 'by': from, 'seconds': secs});
        notifyListeners();
    }
  }

  void _sysLocal(Chat chat, String id, int ts, Map<String, dynamic> system) {
    thread(chat.id).upsert(Message(id: id, chatId: chat.id, seq: ts, kind: 'system', system: system, createdAt: ts));
    if (ts > chat.lastActivity) chat.lastActivity = ts;
    _recount(chat);
  }

  Future<void> _applyGroup(String chatId, String from, int ts, String id, Map<String, dynamic> p, bool live) async {
    if (!chatId.startsWith('g:')) return;
    final prev = _groups[chatId];
    if (prev != null && (!prev.admins.contains(from) || prev.ts > ts)) return;
    final members = (p['members'] as List).cast<String>().toSet().toList();
    final admins = (p['admins'] as List).cast<String>().where(members.contains).toList();
    final name = (p['name'] as String? ?? 'Group').trim();
    final g = _GroupState(name: name, members: members, admins: admins.isEmpty ? [members.first] : admins, ts: ts);
    _groups[chatId] = g;
    final myId = me!.id;
    if (!members.contains(myId)) {
      _leftChats.add(chatId);
      chats.remove(chatId);
      _threads.remove(chatId);
      notifyListeners();
      return;
    }
    _leftChats.remove(chatId);
    final chat = chats[chatId] ??
        (chats[chatId] = Chat(id: chatId, type: 'group', lastSeq: ts, lastActivity: ts, members: []));
    chat.name = name;
    final old = {for (final m in chat.members) m.userId: m};
    chat.members = [
      for (final u in members) (old[u] ?? Member(userId: u, role: 'member'))..role = g.admins.contains(u) ? 'admin' : 'member',
    ];
    chat.myRole = g.admins.contains(myId) ? 'admin' : 'member';
    // A readable note in the chat about what changed.
    if (prev == null) {
      _sysLocal(chat, '$id-g', ts, {'event': 'group_created', 'by': from, 'name': name});
    } else {
      if (prev.name != name) _sysLocal(chat, '$id-n', ts, {'event': 'renamed', 'by': from, 'name': name});
      final added = members.where((u) => !prev.members.contains(u)).toList();
      final removed = prev.members.where((u) => !members.contains(u)).toList();
      if (added.isNotEmpty) _sysLocal(chat, '$id-a', ts, {'event': 'members_added', 'by': from, 'users': added});
      for (final u in removed) {
        _sysLocal(chat, '$id-r$u', ts, u == from ? {'event': 'member_left', 'by': from} : {'event': 'member_removed', 'by': from, 'user': u});
      }
    }
    _recount(chat);
    notifyListeners();
  }

  void _applyOps(Message m, Chat chat) {
    final del = _deletes[m.id];
    final isAdmin = _groups[chat.id]?.admins.contains(del) ?? false;
    if (del != null && (del == m.senderId || isAdmin)) {
      m
        ..deleted = true
        ..payload = null
        ..reactions = {};
      _store?.remove(m.id);
      return;
    }
    final e = _edits[m.id];
    if (e != null && e['from'] == m.senderId && m.payload != null) {
      m.payload = Payload({...m.payload!.raw, 'text': e['text']});
      m.editedAt = e['ts'] as int;
    }
    final r = _reactions[m.id];
    if (r != null) {
      m.reactions = {for (final x in r.entries) if (x.value.$1.isNotEmpty) x.key: x.value.$1};
    }
  }

  void _reapply(Chat chat, String target) {
    final t = thread(chat.id);
    final i = t.indexOfId(target);
    if (i < 0) return;
    _applyOps(t.messages[i], chat);
    t.touch();
    _recount(chat);
    notifyListeners();
  }

  void _sweep() {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final t in _threads.values) {
      final gone = t.messages.where((m) => m.expiresAt != null && m.expiresAt! <= now).toList();
      if (gone.isEmpty) continue;
      for (final m in gone) {
        _store?.remove(m.id);
        final f = m.payload?.file;
        if (f != null) _store?.deleteBlob(f.id);
      }
      t.remove(gone.map((m) => m.id));
      final c = chats[t.chatId];
      if (c != null) _recount(c);
      notifyListeners();
    }
    // Presence: people we haven't heard from in a while are offline.
    var changed = false;
    for (final u in users.values) {
      if (u.id == me?.id) continue;
      final on = isOnline(u.id);
      if (u.online != on) {
        u.online = on;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ------------------------------------------------------------------ receiving
  void _onIncoming(Chat chat, Message m) {
    final viewing = openChatId == chat.id && appActive;
    if (viewing) {
      markRead(chat.id);
    } else {
      _scheduleReceipt(chat.id);
      if (!chat.muted) {
        final sender = nameOf(m.senderId);
        Notifications.message(
          chatId: chat.id,
          title: chat.isGroup ? '$sender · ${chatTitle(chat)}' : sender,
          body: m.payload?.preview ?? 'New message',
        );
      }
    }
  }

  // ------------------------------------------------------------------ reading
  void setOpenChat(String? chatId) {
    openChatId = chatId;
    if (chatId != null) {
      markRead(chatId);
      Notifications.clearChat(chatId);
    }
  }

  void markRead(String chatId) {
    final c = chats[chatId];
    if (c == null || me == null) return;
    final mine = c.member(me!.id);
    final newest = c.lastSeq;
    if (mine == null || mine.lastReadSeq >= newest) return;
    mine.lastReadSeq = newest;
    mine.lastDeliveredSeq = max(mine.lastDeliveredSeq, newest);
    _recount(c);
    notifyListeners();
    _scheduleReceipt(chatId, read: true);
  }

  /// Receipts are batched per chat so a burst of messages sends one.
  void _scheduleReceipt(String chatId, {bool read = false}) {
    final c = chats[chatId];
    if (c == null) return;
    final mine = c.member(me!.id);
    if (mine == null && chatId != everyoneChatId) return;
    _receiptTimers[chatId]?.cancel();
    _receiptTimers[chatId] = Timer(Duration(milliseconds: read ? 1200 : 3000), () {
      final cc = chats[chatId];
      if (cc == null) return;
      final m = cc.member(me!.id);
      final newest = cc.lastSeq;
      if (newest == 0) return;
      final readTs = m?.lastReadSeq ?? 0;
      _sendChat(chatId, {'k': 'rcpt', 'r': readTs, 'dl': newest}, storeLocal: false);
    });
  }

  void setTyping(String chatId, bool typing) =>
      transport?.publish({'k': 'typing', 'c': chatId, 'on': typing}, ephemeral: true);

  /// Ticks for my message: 0 waiting, 1 sent, 2 delivered to all, 3 seen by all.
  int deliveryState(Chat c, Message m) {
    if (m.pending) return 0;
    final others = c.members.where((x) => x.userId != me?.id).toList();
    if (others.isEmpty) return 3;
    if (others.every((x) => x.lastReadSeq >= m.seq)) return 3;
    if (others.every((x) => x.lastDeliveredSeq >= m.seq)) return 2;
    return 1;
  }

  List<String> seenBy(Chat c, Message m) => [for (final x in c.members) if (x.userId != me?.id && x.lastReadSeq >= m.seq) x.userId];

  // ------------------------------------------------------------------ sending
  /// Seal [payload] for the chat's members and send it. Applied locally right away.
  Future<bool> _sendChat(String chatId, Map<String, dynamic> payload, {String? id, int? ts, bool storeLocal = true, Duration? ttl}) async {
    final t = transport;
    if (t == null) throw ApiException('offline');
    final memberIds = {..._memberIds(chatId), me!.id};
    if (payload['k'] == 'grp') memberIds.addAll((payload['members'] as List).cast<String>());
    final recipients = _recipients(memberIds);
    final env = await identity!.seal(recipients, payload);
    final inner = <String, dynamic>{'k': 'c', 'c': chatId, 'env': env, 'i': id ?? newId(), 't': ts ?? DateTime.now().millisecondsSinceEpoch};
    final reached = await t.publish(inner, ttl: ttl);
    if (storeLocal) await _applyChat(chatId, me!.id, inner['t'] as int, inner['i'] as String, payload, false);
    if (payload['k'] == 'msg' || payload['k'] == 'sys') _notifyOffline(chatId, memberIds, payload);
    return reached;
  }

  Future<Message?> sendPayload(String chatId, Map<String, dynamic> content, {List<String> blobIds = const [], Message? retryOf}) async {
    final chat = chats[chatId];
    if (chat == null) return null;
    final id = retryOf?.id ?? newId();
    final ts = retryOf?.createdAt ?? DateTime.now().millisecondsSinceEpoch;
    final timer = chat.disappearSeconds;
    final payload = <String, dynamic>{
      'k': 'msg',
      'm': content,
      if (timer > 0) 'exp': ts + timer * 1000,
    };
    try {
      final reached = await _sendChat(chatId, payload, id: id, ts: ts, ttl: timer > 0 ? Duration(seconds: timer) : null);
      final i = thread(chatId).indexOfId(id);
      if (i >= 0) {
        thread(chatId).messages[i].pending = !reached;
        thread(chatId).touch();
      }
      return i >= 0 ? thread(chatId).messages[i] : null;
    } catch (e) {
      debugPrint('send failed: $e');
      return null;
    }
  }

  void _markAllSent() {
    for (final t in _threads.values) {
      var changed = false;
      for (final m in t.messages) {
        if (m.pending) {
          m.pending = false;
          changed = true;
        }
      }
      if (changed) t.touch();
    }
  }

  Future<void> retry(Message m) async {
    if (m.payload == null) return;
    await sendPayload(m.chatId, m.payload!.raw, retryOf: m);
  }

  void discardFailed(Message m) => thread(m.chatId).remove([m.id]);

  Future<void> sendText(String chatId, String text, {Message? replyTo}) =>
      sendPayload(chatId, {'t': 'text', 'text': text, if (replyTo != null) 'reply': replyRef(replyTo)});

  Future<void> sendSticker(String chatId, String emoji) {
    _rememberEmoji(emoji);
    return sendPayload(chatId, {'t': 'sticker', 'emoji': emoji});
  }

  Map<String, dynamic> replyRef(Message m) => {
        'id': m.id,
        'senderId': m.senderId,
        'preview': (m.payload?.preview ?? '').characters.take(120).toString(),
      };

  /// Encrypt a file and send it. Returns false if it's too big for the relays
  /// (then it only reaches devices on the same Wi-Fi, or when they're both online here).
  Future<bool> sendFile(
    String chatId, {
    required Uint8List bytes,
    required String name,
    required String kind,
    String caption = '',
    int? durationMs,
    Message? replyTo,
    ValueNotifier<double>? progress,
  }) async {
    if (bytes.length > 512 * 1024 * 1024) throw ApiException('too_large');
    progress?.value = 0.3;
    final sealed = await sealFile(bytes);
    final blobId = Transport.blobIdOf(sealed.data);
    final timer = chats[chatId]?.disappearSeconds ?? 0;
    final viaRelays = await transport!.sendBlob(blobId, sealed.data, ttl: timer > 0 ? Duration(seconds: timer) : null);
    progress?.value = 1;
    media.put(blobId, bytes);
    await sendPayload(chatId, {
      't': kind,
      if (caption.isNotEmpty) 'text': caption,
      if (replyTo != null) 'reply': replyRef(replyTo),
      'file': {
        'id': blobId,
        'key': base64.encode(sealed.key),
        'nonce': base64.encode(sealed.nonce),
        'name': name,
        'mime': mimeFor(name),
        'size': bytes.length,
        if (durationMs != null) 'dur': durationMs,
      },
    });
    return viaRelays;
  }

  Future<void> forward(Message m, String toChatId) async {
    final p = Map<String, dynamic>.from(m.payload!.raw)
      ..remove('reply')
      ..['fwd'] = true;
    await sendPayload(toChatId, p);
  }

  Future<void> edit(Message m, String newText) => _sendChat(m.chatId, {'k': 'edit', 'id': m.id, 'text': newText});

  Future<void> deleteForEveryone(Message m) => _sendChat(m.chatId, {'k': 'del', 'id': m.id});

  Future<void> deleteForMe(Message m) async {
    final h = hiddenForMe..add(m.id);
    await prefs.setStringList('hidden:$_tagKey', h.toList());
    _hidden = h;
    thread(m.chatId).remove([m.id]);
    final c = chats[m.chatId];
    if (c != null) _recount(c);
    notifyListeners();
  }

  Future<void> react(Message m, String? emoji) async {
    final mine = m.reactions[me!.id];
    final next = mine == emoji ? '' : (emoji ?? '');
    await _sendChat(m.chatId, {'k': 'react', 'id': m.id, 'e': next});
  }

  Future<void> pin(String chatId, String? messageId) => _sendChat(chatId, {'k': 'pin', 'id': messageId});

  // ------------------------------------------------------------------ attachments
  Future<Uint8List> fileBytes(FileRef f) {
    final cached = media.get(f.id);
    if (cached != null) return Future.value(cached);
    return _downloads.putIfAbsent(f.id, () async {
      try {
        final enc = await transport?.getBlob(f.id);
        if (enc == null) throw ApiException('not_here', 'Not downloaded yet. It arrives when the sender is online or on the same Wi‑Fi.');
        final plain = await openFile(enc, f.key, f.nonce);
        media.put(f.id, plain);
        return plain;
      } finally {
        _downloads.remove(f.id);
      }
    });
  }

  Future<Uint8List> avatarBytes(String id) {
    final b = _avatars[id];
    return b != null ? Future.value(b) : Future.error(StateError('no avatar'));
  }

  Future<void> addCustomSticker(Uint8List bytes, String name) async {
    final f = await writeTemp('sticker-${DateTime.now().millisecondsSinceEpoch}', name, bytes);
    final list = prefs.getStringList('stickers') ?? [];
    list.insert(0, jsonEncode({'path': f.path, 'name': name}));
    await prefs.setStringList('stickers', list.take(60).toList());
    notifyListeners();
  }

  Future<void> removeCustomSticker(String path) async {
    final list = (prefs.getStringList('stickers') ?? []).where((s) => (jsonDecode(s) as Map)['path'] != path).toList();
    await prefs.setStringList('stickers', list);
    notifyListeners();
  }

  void _rememberEmoji(String e) {
    final list = recentEmoji..remove(e);
    list.insert(0, e);
    prefs.setStringList('recent_emoji', list.take(24).toList());
  }

  // ------------------------------------------------------------------ chat management
  Future<Chat> openDirect(String userId) async {
    final id = directId(me!.id, userId);
    final c = _chatFor(id, me!.id)!;
    _recount(c);
    if (c.lastActivity == 0) c.lastActivity = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    return c;
  }

  Future<Chat> createGroup(String name, List<String> memberIds) async {
    final id = 'g:${newId()}';
    await _sendChat(id, {'k': 'grp', 'name': name, 'members': {me!.id, ...memberIds}.toList(), 'admins': [me!.id]});
    return chats[id]!;
  }

  Future<void> _updateGroup(String chatId, {String? name, List<String>? members, List<String>? admins}) async {
    final g = _groups[chatId];
    if (g == null) throw ApiException('not_member');
    await _sendChat(chatId, {
      'k': 'grp',
      'name': name ?? g.name,
      'members': members ?? g.members,
      'admins': admins ?? g.admins,
    });
  }

  Future<void> renameGroup(String chatId, String name) => _updateGroup(chatId, name: name);

  Future<void> addMembers(String chatId, List<String> ids) =>
      _updateGroup(chatId, members: {...?_groups[chatId]?.members, ...ids}.toList());

  Future<void> removeMember(String chatId, String userId) async {
    final g = _groups[chatId];
    if (g == null) throw ApiException('not_member');
    final members = g.members.where((u) => u != userId).toList();
    var admins = g.admins.where((u) => u != userId).toList();
    if (admins.isEmpty && members.isNotEmpty) admins = [members.first];
    if (userId == me!.id && !g.admins.contains(me!.id)) {
      // Members can't change the group; leaving just hides it here.
      _leftChats.add(chatId);
      chats.remove(chatId);
      notifyListeners();
      return;
    }
    await _updateGroup(chatId, members: members, admins: admins);
  }

  Future<void> setRole(String chatId, String userId, String role) async {
    final g = _groups[chatId];
    if (g == null) throw ApiException('not_member');
    final admins = {...g.admins};
    if (role == 'admin') {
      admins.add(userId);
    } else {
      admins.remove(userId);
    }
    await _updateGroup(chatId, admins: admins.toList());
  }

  Future<void> setTimer(String chatId, int seconds) => _sendChat(chatId, {'k': 'timer', 's': seconds});

  Future<void> mute(String chatId, Duration? d) async {
    final m = _muted;
    if (d == null) {
      m.remove(chatId);
    } else {
      m[chatId] = DateTime.now().add(d).millisecondsSinceEpoch;
    }
    await _saveIntMap('muted:$_tagKey', m);
    final c = chats[chatId];
    if (c != null) _recount(c);
    notifyListeners();
  }

  Future<void> clearHistory(String chatId) async {
    _cleared[chatId] = DateTime.now().millisecondsSinceEpoch;
    await _saveIntMap('cleared:$_tagKey', _cleared);
    thread(chatId).messages.clear();
    thread(chatId).touch();
    final c = chats[chatId];
    if (c != null) _recount(c);
    notifyListeners();
  }

  // No server history to page through: everything is already on the device.
  Future<void> loadThread(String chatId) async {}
  Future<void> loadOlder(String chatId) async {}
  Future<void> loadAll(String chatId) async {}

  // ------------------------------------------------------------------ calls plumbing
  /// Send call signaling to a chat's members (or just [toUser]). Live only, never stored.
  Future<void> sendCallSignal(String chatId, Map<String, dynamic> payload, {String? toUser}) async {
    final t = transport;
    if (t == null) return;
    final ids = toUser != null ? {toUser, me!.id} : {..._memberIds(chatId), me!.id};
    final env = await identity!.seal(_recipients(ids), payload);
    await t.publish({'k': 'call', 'c': chatId, 'env': env}, ephemeral: true);
    if (payload['k'] == 'invite') _notifyOffline(chatId, ids, {'k': 'call', 'video': payload['video']});
  }

  /// Phone notifications through ntfy for people whose app isn't running.
  void _notifyOffline(String chatId, Set<String> memberIds, Map<String, dynamic> payload) {
    final chat = chats[chatId];
    if (chat == null) return;
    final isCall = payload['k'] == 'call';
    for (final u in memberIds) {
      if (u == me!.id || isOnline(u)) continue;
      final url = users[u]?.push;
      if (url == null) continue;
      final uri = Uri.tryParse(url);
      if (uri == null || uri.pathSegments.isEmpty) continue;
      final server = uri.replace(path: '', query: null).toString().replaceAll(RegExp(r'/+$'), '');
      final title = chat.isGroup ? '${me!.displayName} · ${chatTitle(chat)}' : me!.displayName;
      http
          .post(Uri.parse(server),
              headers: {'content-type': 'application/json'},
              body: jsonEncode({
                'topic': uri.pathSegments.last,
                'title': title,
                'message': isCall ? 'Incoming ${payload['video'] == true ? 'video' : 'voice'} call' : 'New message',
                'priority': isCall ? 5 : 4,
                'tags': [isCall ? 'telephone_receiver' : 'speech_balloon'],
              }))
          .timeout(const Duration(seconds: 10))
          .catchError((_) => http.Response('', 599));
    }
  }

  /// Call starter records the call in the chat once it's over.
  Future<void> logCall(String chatId, Map<String, dynamic> info) =>
      _sendChat(chatId, {'k': 'sys', 's': {'event': 'call', ...info}});

  Future<void> sendTestPush() async {
    final url = pushUrl;
    if (url == null) throw ApiException('push_off', 'Turn on phone notifications first.');
    final uri = Uri.parse(url);
    final server = uri.replace(path: '', query: null).toString().replaceAll(RegExp(r'/+$'), '');
    final r = await http.post(Uri.parse(server),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'topic': uri.pathSegments.last, 'title': 'Home Chat', 'message': 'Notifications are working 🎉', 'tags': ['tada']}));
    if (r.statusCode >= 300) throw ApiException('push_failed', 'The notification server said ${r.statusCode}.');
  }
}
