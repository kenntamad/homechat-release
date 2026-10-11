import 'package:flutter/material.dart';

import '../data/api.dart';
import '../data/models.dart';
import 'widgets.dart';

/// Pick someone in the household to chat with, or start a group.
/// Pops with the chat id.
class NewChatScreen extends StatelessWidget {
  const NewChatScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final people = app.users.values.where((u) => u.id != app.me?.id && !u.disabled).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    Future<void> open(String userId) async {
      try {
        final chat = await app.openDirect(userId);
        if (context.mounted) Navigator.pop(context, chat.id);
      } on ApiException catch (e) {
        if (context.mounted) toast(context, e.message);
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('New chat')),
      body: ListView(children: [
        ListTile(
          leading: const CircleAvatar(backgroundColor: brand, child: Icon(Icons.group_add, color: Colors.white)),
          title: const Text('New group'),
          onTap: () async {
            final id = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const NewGroupScreen()));
            if (id != null && context.mounted) Navigator.pop(context, id);
          },
        ),
        ListTile(
          leading: Avatar(name: 'My Notes', seed: 'notes', icon: Icons.bookmark),
          title: const Text('My Notes'),
          subtitle: const Text('Send yourself reminders, links and files'),
          onTap: () => open(app.me!.id),
        ),
        const Divider(),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text('Household', style: TextStyle(fontWeight: FontWeight.w600, color: Colors.grey)),
        ),
        for (final u in people)
          ListTile(
            leading: Avatar.user(u),
            title: Text(u.displayName),
            subtitle: Text(u.about.isNotEmpty ? u.about : lastSeenText(u), maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => open(u.id),
          ),
        if (people.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('Nobody else is on this frequency yet. Share the frequency from More → Frequency; people show up here once they tune in.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
          ),
      ]),
    );
  }
}

class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({super.key});
  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  final _name = TextEditingController();
  final Set<String> _picked = {};
  bool _busy = false;

  Future<void> _create() async {
    final app = AppScope.read(context);
    if (_name.text.trim().isEmpty) return toast(context, 'Give the group a name.');
    setState(() => _busy = true);
    try {
      final chat = await app.createGroup(_name.text.trim(), _picked.toList());
      if (mounted) Navigator.pop(context, chat.id);
    } on ApiException catch (e) {
      if (mounted) toast(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final people = app.users.values.where((u) => u.id != app.me?.id && !u.disabled).toList()
      ..sort((a, b) => a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    return Scaffold(
      appBar: AppBar(title: const Text('New group')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _create,
        icon: const Icon(Icons.check),
        label: Text('Create${_picked.isEmpty ? '' : ' (${_picked.length + 1})'}'),
      ),
      body: ListView(children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _name,
            autofocus: true,
            maxLength: 60,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Group name', hintText: 'Family 🏠'),
          ),
        ),
        for (final User u in people)
          CheckboxListTile(
            value: _picked.contains(u.id),
            onChanged: (v) => setState(() => v == true ? _picked.add(u.id) : _picked.remove(u.id)),
            secondary: Avatar.user(u),
            title: Text(u.displayName),
          ),
        const SizedBox(height: 80),
      ]),
    );
  }
}

/// Pick people to add to an existing group. Pops with the selected ids.
class PickPeopleScreen extends StatefulWidget {
  const PickPeopleScreen({super.key, required this.exclude});
  final Set<String> exclude;
  @override
  State<PickPeopleScreen> createState() => _PickPeopleScreenState();
}

class _PickPeopleScreenState extends State<PickPeopleScreen> {
  final Set<String> _picked = {};

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final people = app.users.values.where((u) => !widget.exclude.contains(u.id) && !u.disabled).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Add members'), actions: [
        TextButton(
          onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, _picked.toList()),
          child: const Text('ADD', style: TextStyle(color: Colors.white)),
        ),
      ]),
      body: people.isEmpty
          ? const Center(child: Text('Everyone is already in this group.', style: TextStyle(color: Colors.grey)))
          : ListView(children: [
              for (final u in people)
                CheckboxListTile(
                  value: _picked.contains(u.id),
                  onChanged: (v) => setState(() => v == true ? _picked.add(u.id) : _picked.remove(u.id)),
                  secondary: Avatar.user(u),
                  title: Text(u.displayName),
                ),
            ]),
    );
  }
}
