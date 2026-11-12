import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../widgets/app_card.dart';

/// Shown once a connection exists; dismissal is scoped to this account.
class WidgetSetupPrompt extends StatefulWidget {
  const WidgetSetupPrompt({super.key, required this.userId});
  final String userId;
  @override
  State<WidgetSetupPrompt> createState() => _WidgetSetupPromptState();
}

class _WidgetSetupPromptState extends State<WidgetSetupPrompt> {
  bool _visible = false;
  String get _key => 'widget_setup_dismissed_${widget.userId}';
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _visible = prefs.getBool(_key) != true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: AppCard(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(
                  child: Text('Keep a friend on your Home Screen',
                      style: TextStyle(fontWeight: FontWeight.w600))),
              IconButton(
                  tooltip: 'Dismiss widget setup',
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    setState(() => _visible = false);
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.setBool(_key, true);
                  }),
            ]),
            const Text(
                'Your widget can show one friend or a personal List. Add another widget for someone else.'),
            TextButton(
                onPressed: () => context.push('/settings/widgets'),
                child: const Text('Set up a widget')),
          ]),
        ));
  }
}
