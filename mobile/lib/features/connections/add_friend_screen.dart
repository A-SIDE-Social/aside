import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/invite_input.dart';

class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _continue() {
    final invite = InviteInput.parse(_controller.text);
    if (invite == null) {
      setState(
          () => _error = 'Enter a friend’s invite link or 12-character code.');
      return;
    }
    FocusScope.of(context).unfocus();
    context.push(invite.route);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Add friend')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Have an invite?',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(
                  'Paste a friend’s link or enter their code. You don’t need to share your contacts.'),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Invite link or code',
                  errorText: _error,
                ),
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
                onSubmitted: (_) => _continue(),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                  onPressed: _continue, child: const Text('Continue')),
            ],
          ),
        ),
      );
}
