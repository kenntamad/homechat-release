import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../data/api.dart';
import '../services/media.dart';
import '../services/updater.dart';
import '../version.dart';
import 'setup_screens.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final me = app.me!;
    final t = app.transport;
    void push(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    final relays = t?.relayCount ?? 0;
    final wifi = t?.lan.freshPeers.length ?? 0;

    return ListView(children: [
      ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        leading: Avatar.user(me, size: 60, showOnline: false),
        title: Text(me.displayName, style: Theme.of(context).textTheme.titleLarge),
        subtitle: Text(me.about.isNotEmpty ? me.about : 'Tap to edit your profile'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => push(const ProfileScreen()),
      ),
      const Divider(),
      ListTile(
        leading: const Icon(Icons.cell_tower),
        title: const Text('Frequency'),
        subtitle: Text('${app.householdName} · relays $relays/${app.relayUrls.length} · Wi‑Fi devices $wifi'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => push(const FrequencySettingsScreen()),
      ),
      ListTile(
        leading: const Icon(Icons.notifications_outlined),
        title: const Text('Phone notifications'),
        subtitle: Text(app.pushUrl != null ? 'On' : 'Off · get messages while the app is closed'),
        onTap: () => push(const NotificationSetupScreen()),
      ),
      ListTile(
        leading: const Icon(Icons.devices_other),
        title: const Text('Link another device'),
        subtitle: const Text('Use your account on another phone or computer'),
        onTap: () => push(const LinkDeviceScreen()),
      ),
      ListTile(
        leading: const Icon(Icons.system_update_alt),
        title: const Text('App updates'),
        subtitle: Text(app.update != null ? 'Version ${app.update!.version} is available' : 'Version $appVersion'),
        trailing: app.update != null ? const Badge(label: Text('NEW')) : null,
        onTap: () => push(const UpdatesScreen()),
      ),
      const Divider(),
      ListTile(
        leading: Icon(app.connected ? Icons.cloud_done_outlined : Icons.cloud_off, color: app.connected ? Colors.green : Colors.orange),
        title: Text(app.connected ? 'Connected' : 'Not connected'),
        subtitle: Text(app.connected
            ? (wifi > 0 ? 'Talking directly over Wi‑Fi${relays > 0 ? ' and through relays' : ''}' : 'Through public relays')
            : 'Messages will send when you\'re back online or near another device on the same Wi‑Fi.'),
      ),
      const SizedBox(height: 24),
      Center(child: Text('Home Chat $appVersion · 🔒 end-to-end encrypted', style: const TextStyle(color: Colors.grey, fontSize: 12))),
      const SizedBox(height: 24),
    ]);
  }
}

// ------------------------------------------------------------------ profile
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final me = app.me!;
    Future<void> guard(Future<void> Function() fn) async {
      try {
        await fn();
      } on ApiException catch (e) {
        if (context.mounted) toast(context, e.message);
      } catch (e) {
        if (context.mounted) toast(context, 'Could not use that picture.');
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: ListView(children: [
        const SizedBox(height: 24),
        Center(
          child: Stack(children: [
            Avatar.user(me, size: 120, showOnline: false),
            Positioned(
              right: 0,
              bottom: 0,
              child: IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: brand),
                icon: const Icon(Icons.photo_camera, color: Colors.white),
                onPressed: () => guard(() async {
                  final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: false);
                  if (r == null || r.files.isEmpty) return;
                  final f = r.files.first;
                  final Uint8List bytes = f.bytes ?? await File(f.path!).readAsBytes();
                  await app.setAvatar(await shrinkImage(bytes));
                }),
              ),
            ),
          ]),
        ),
        if (me.avatar != null) Center(child: TextButton(onPressed: () => guard(() => app.setAvatar(null)), child: const Text('Remove photo'))),
        const SizedBox(height: 16),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Name'),
          subtitle: Text(me.displayName),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: () async {
            final v = await promptText(context, 'Your name', initial: me.displayName);
            if (v != null && v.isNotEmpty) await guard(() => app.updateProfile(displayName: v));
          },
        ),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('About'),
          subtitle: Text(me.about.isEmpty ? 'Add a status: "At work", "Busy", "🎮"' : me.about),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: () async {
            final v = await promptText(context, 'About', initial: me.about, maxLength: 140);
            if (v != null) await guard(() => app.updateProfile(about: v));
          },
        ),
        ListTile(
          leading: const Icon(Icons.key),
          title: const Text('Your key fingerprint'),
          subtitle: Text(app.identity!.fingerprint, style: const TextStyle(fontFamily: 'monospace')),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------ frequency
class FrequencySettingsScreen extends StatefulWidget {
  const FrequencySettingsScreen({super.key});
  @override
  State<FrequencySettingsScreen> createState() => _FrequencySettingsScreenState();
}

class _FrequencySettingsScreenState extends State<FrequencySettingsScreen> {
  bool _reveal = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final status = app.transport?.relays.status ?? [];
    final wifi = app.transport?.lan.freshPeers ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('Frequency')),
      body: ListView(children: [
        ListTile(
          leading: const Icon(Icons.cell_tower),
          title: Text(_reveal ? app.frequency : '•' * 12, style: const TextStyle(fontFamily: 'monospace', fontSize: 16)),
          subtitle: const Text('Anyone with this frequency can join your chat'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(icon: Icon(_reveal ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _reveal = !_reveal)),
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: app.frequency));
                if (context.mounted) toast(context, 'Copied. Share it privately.');
              },
            ),
          ]),
        ),
        ListTile(
          leading: const Icon(Icons.label_outline),
          title: const Text('Name of the group chat'),
          subtitle: Text(app.householdName),
          trailing: const Icon(Icons.edit, size: 18),
          onTap: () async {
            final v = await promptText(context, 'Group chat name', initial: app.householdName);
            if (v != null && v.isNotEmpty) await app.setChannelName(v);
          },
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Change frequency'),
          subtitle: const Text('Move to a new one (e.g. if someone who shouldn\'t have it learned it). Everyone has to switch.'),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FrequencyScreen(fromSettings: true))),
        ),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text('On this Wi‑Fi (${wifi.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        if (wifi.isEmpty)
          const ListTile(
            dense: true,
            title: Text('No other devices on this frequency found on the Wi‑Fi right now.', style: TextStyle(color: Colors.grey)),
          ),
        for (final p in wifi)
          ListTile(dense: true, leading: const Icon(Icons.wifi), title: Text(app.nameOf(p.userId)), subtitle: Text(p.address.address)),
        if (app.transport?.lan.error != null)
          ListTile(dense: true, leading: const Icon(Icons.warning_amber), title: Text(app.transport!.lan.error!)),
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            const Expanded(child: Text('Relays', style: TextStyle(fontWeight: FontWeight.w600))),
            TextButton.icon(
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Edit'),
              onPressed: () async {
                final v = await _editRelays(context, app.relayUrls);
                if (v != null) await app.setRelays(v);
              },
            ),
          ]),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Public relays pass your encrypted messages along when you\'re not on the same Wi‑Fi, and hold them for up to 7 days. '
            'They can\'t read anything.',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),
        ),
        for (final s in status)
          ListTile(
            dense: true,
            leading: Icon(Icons.circle, size: 12, color: s.connected ? Colors.green : Colors.grey),
            title: Text(s.url),
            subtitle: s.lastError != null && !s.connected ? Text(s.lastError!, maxLines: 2, overflow: TextOverflow.ellipsis) : null,
          ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text('Leave this frequency', style: TextStyle(color: Colors.red)),
          subtitle: const Text('Deletes its messages from this device'),
          onTap: () async {
            if (await confirm(context, 'Leave this frequency?', 'Chats on it will be deleted from this device. Others keep theirs.',
                ok: 'Leave', danger: true)) {
              await app.forgetFrequency();
              if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
            }
          },
        ),
      ]),
    );
  }

  Future<List<String>?> _editRelays(BuildContext context, List<String> current) {
    final ctrl = TextEditingController(text: current.join('\n'));
    return showDialog<List<String>>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Relays (one per line)'),
        content: TextField(controller: ctrl, maxLines: 8, decoration: const InputDecoration(hintText: 'wss://relay.example.com')),
        actions: [
          TextButton(onPressed: () => ctrl.text = defaultRelays.join('\n'), child: const Text('Defaults')),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final list = ctrl.text.split(RegExp(r'\s+')).map((x) => x.trim()).where((x) => x.startsWith('wss://') || x.startsWith('ws://')).toList();
              Navigator.pop(c, list.isEmpty ? defaultRelays : list);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ notifications
class NotificationSetupScreen extends StatefulWidget {
  const NotificationSetupScreen({super.key});
  @override
  State<NotificationSetupScreen> createState() => _NotificationSetupScreenState();
}

class _NotificationSetupScreenState extends State<NotificationSetupScreen> {
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final on = app.pushUrl != null;
    final topic = app.pushTopic;
    final server = app.ntfyServer;

    return Scaffold(
      appBar: AppBar(title: const Text('Phone notifications')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'While Home Chat is open (or in the background), it notifies you itself. When the app is fully closed, '
          'the others\' apps can ping you through the free ntfy app instead. The ping only says who wrote, never the message.',
        ),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Notify me when the app is closed'),
          value: on,
          onChanged: (v) => app.setPush(on: v),
        ),
        if (on) ...[
          _Step(n: 1, text: 'Install "ntfy" from Google Play or F‑Droid.'),
          _Step(n: 2, text: 'Subscribe to your private topic: tap the button below on this phone, or in ntfy tap "+" and enter the topic.'),
          Card(child: ListTile(title: const Text('Server'), subtitle: SelectableText(server))),
          Card(
            child: ListTile(
              title: const Text('Your topic (keep it private)'),
              subtitle: SelectableText(topic),
              trailing: IconButton(
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: '$server/$topic'));
                  if (context.mounted) toast(context, 'Copied');
                },
              ),
            ),
          ),
          if (Platform.isAndroid)
            FilledButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Subscribe in ntfy'),
              onPressed: () async {
                final u = Uri.parse(server);
                final link = Uri.parse('ntfy://${u.authority}/$topic${u.scheme == 'http' ? '?secure=false' : ''}');
                var ok = false;
                try {
                  ok = await launchUrl(link, mode: LaunchMode.externalApplication);
                } catch (_) {}
                if (!ok && context.mounted) toast(context, 'Install ntfy first, then try again.');
              },
            ),
          _Step(n: 3, text: 'For calls, set priority-5 notifications to ring loudly in ntfy.'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Send me a test notification'),
            onPressed: () async {
              try {
                await app.sendTestPush();
                if (context.mounted) toast(context, 'Sent! Check ntfy.');
              } on ApiException catch (e) {
                if (context.mounted) toast(context, e.message);
              } catch (e) {
                if (context.mounted) toast(context, 'Could not reach $server.');
              }
            },
          ),
          TextButton(
            onPressed: () async {
              final v = await promptText(context, 'ntfy server', initial: server, maxLength: 200);
              if (v != null && v.startsWith('http')) await app.setPush(on: true, server: v);
            },
            child: const Text('Use a different ntfy server'),
          ),
          TextButton(
            onPressed: () async {
              if (await confirm(context, 'Make a new topic?', 'Use this if someone else learned your topic. You\'ll need to subscribe again in ntfy.')) {
                await app.rotatePushTopic();
              }
            },
            child: const Text('Generate a new private topic'),
          ),
        ],
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          CircleAvatar(radius: 12, backgroundColor: brand, child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12))),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ]),
      );
}

// ------------------------------------------------------------------ link device
class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key});
  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Link another device')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('To use your account on another phone or computer:'),
        const SizedBox(height: 8),
        const Text('1. Install Home Chat there and choose "I already use Home Chat on another device".\n'
            '2. Enter this account code.\n'
            '3. Tune in to the same frequency.'),
        const SizedBox(height: 16),
        Card(
          color: Colors.orange.withValues(alpha: 0.12),
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Text('⚠️ This code IS your account. Anyone who has it can read your messages and write as you. '
                'Never send it to anyone, only type it into your own device.'),
          ),
        ),
        const SizedBox(height: 12),
        if (!_show)
          FilledButton(onPressed: () => setState(() => _show = true), child: const Text('Show my account code'))
        else ...[
          SelectableText(app.accountCode, style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('Copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: app.accountCode));
              if (context.mounted) toast(context, 'Copied. Paste it on your other device, then clear your clipboard.');
            },
          ),
        ],
      ]),
    );
  }
}

// ------------------------------------------------------------------ updates
class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key});
  @override
  State<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends State<UpdatesScreen> {
  bool _checking = false;
  double? _progress;
  String? _message;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      final u = await AppScope.read(context).checkForUpdates(quiet: false);
      _message = u == null ? 'You have the latest version.' : null;
    } catch (e) {
      _message = 'Could not check for updates: $e';
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _install(UpdateInfo u) async {
    setState(() {
      _progress = 0;
      _message = null;
    });
    try {
      await Updater.install(u, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) setState(() => _message = Platform.isAndroid ? 'Tap "Install" on the screen Android shows.' : null);
    } catch (e) {
      if (mounted) setState(() => _message = 'Update failed: $e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final u = app.update;
    return Scaffold(
      appBar: AppBar(title: const Text('App updates')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('Installed: version $appVersion', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(Updater.configured ? 'Updates come from github.com/$updateRepo' : 'Updates are not set up yet (see README: "Releases").',
            style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 16),
        if (u != null) ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Version ${u.version} is available', style: Theme.of(context).textTheme.titleMedium),
                if (u.notes.trim().isNotEmpty) ...[const SizedBox(height: 8), Text(u.notes.trim())],
                const SizedBox(height: 12),
                if (_progress != null)
                  LinearProgressIndicator(value: _progress == 0 ? null : _progress)
                else
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text(u.assetUrl == null ? 'Open download page' : (Platform.isWindows ? 'Update and restart' : 'Download and install')),
                    onPressed: () => _install(u),
                  ),
              ]),
            ),
          ),
        ],
        OutlinedButton.icon(
          onPressed: _checking || !Updater.configured ? null : _check,
          icon: _checking ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
          label: const Text('Check for updates'),
        ),
        if (_message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_message!)),
        const SizedBox(height: 16),
        const Text('The app also checks by itself every few hours.', style: TextStyle(color: Colors.grey, fontSize: 13)),
      ]),
    );
  }
}
