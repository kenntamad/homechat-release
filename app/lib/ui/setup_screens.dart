import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../crypto/frequency.dart';
import '../state/app_state.dart';
import 'widgets.dart';

/// First launch: who are you?
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _name = TextEditingController();
  final _code = TextEditingController();
  bool _link = false;
  bool _busy = false;
  String? _error;

  Future<void> _go() async {
    final app = AppScope.read(context);
    final name = _name.text.trim();
    if (name.isEmpty) return setState(() => _error = 'Enter your name.');
    final seed = _link ? AppState.parseAccountCode(_code.text) : null;
    if (_link && seed == null) return setState(() => _error = 'That account code doesn\'t look right. It starts with HC1-.');
    setState(() {
      _busy = true;
      _error = null;
    });
    await app.createIdentity(name: name, seed: seed);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.cell_tower_rounded, size: 72, color: brand),
              const SizedBox(height: 16),
              Text('Home Chat', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Private chats and calls for your family.\nNo accounts, no servers: just tune in to your frequency.',
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),
              TextField(
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Your name', hintText: 'Mom, Kuya Ben, Lola…'),
                onSubmitted: (_) => _link ? null : _go(),
              ),
              if (_link) ...[
                const SizedBox(height: 14),
                TextField(
                  controller: _code,
                  decoration: const InputDecoration(labelText: 'Account code from your other device', hintText: 'HC1-…'),
                ),
                const SizedBox(height: 6),
                Text('On your other device: More → Link another device.', style: Theme.of(context).textTheme.bodySmall),
              ],
              if (_error != null)
                Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
              const SizedBox(height: 20),
              FilledButton(onPressed: _busy ? null : _go, child: Text(_link ? 'Link this device' : 'Continue')),
              TextButton(
                onPressed: () => setState(() {
                  _link = !_link;
                  _error = null;
                }),
                child: Text(_link ? 'I\'m new here' : 'I already use Home Chat on another device'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Pick or enter the frequency. Also used from Settings to change it.
class FrequencyScreen extends StatefulWidget {
  const FrequencyScreen({super.key, this.fromSettings = false});
  final bool fromSettings;
  @override
  State<FrequencyScreen> createState() => _FrequencyScreenState();
}

class _FrequencyScreenState extends State<FrequencyScreen> {
  final _freq = TextEditingController();
  late final TextEditingController _label;
  bool _show = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: AppScope.read(context).householdName);
  }

  Future<void> _tune() async {
    final app = AppScope.read(context);
    final f = _freq.text.trim();
    if (f.isEmpty) return setState(() => _error = 'Enter a frequency, or tap 🎲 to make one.');
    if (frequencyStrength(f) == 0) {
      return setState(() => _error = 'Too easy to guess: anyone could tune in. Add more words or numbers.');
    }
    setState(() => _error = null);
    await app.tune(f, label: _label.text);
    if (mounted && widget.fromSettings) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final strength = frequencyStrength(_freq.text);
    final labels = ['Too easy to guess', 'Weak', 'Good', 'Strong'];
    final colors = [Colors.red, Colors.orange, Colors.lightGreen, Colors.green];

    final body = Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!widget.fromSettings) ...[
              const Icon(Icons.radio, size: 64, color: brand),
              const SizedBox(height: 12),
              Text('Tune in', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
            ],
            const Text(
              'Everyone who enters the same frequency joins the same private chat, like walkie-talkies. '
              'Treat it like a password: make it hard to guess and share it in person.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _freq,
              obscureText: !_show,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Frequency',
                hintText: 'e.g. sunflower-743-orbit-218',
                suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Make one for me',
                    icon: const Text('🎲', style: TextStyle(fontSize: 20)),
                    onPressed: () => setState(() {
                      _freq.text = generateFrequency();
                      _show = true;
                    }),
                  ),
                  IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
                ]),
              ),
            ),
            if (_freq.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(children: [
                  Expanded(
                    child: LinearProgressIndicator(value: (strength + 1) / 4, color: colors[strength], minHeight: 5, borderRadius: BorderRadius.circular(3)),
                  ),
                  const SizedBox(width: 10),
                  Text(labels[strength], style: TextStyle(color: colors[strength], fontSize: 12)),
                ]),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _label,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name of the group chat (just for you)', hintText: 'Home Chat'),
            ),
            if (_error != null)
              Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: app.tuning ? null : _tune,
              icon: app.tuning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cell_tower),
              label: Text(app.tuning ? 'Tuning in…' : 'Tune in'),
            ),
            if (_freq.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy frequency to share'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _freq.text.trim()));
                  if (context.mounted) toast(context, 'Copied. Send it privately (in person is best).');
                },
              ),
            ],
          ]),
        ),
      ),
    );
    return Scaffold(appBar: widget.fromSettings ? AppBar(title: const Text('Change frequency')) : null, body: body);
  }
}
