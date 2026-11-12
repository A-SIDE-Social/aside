import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/app_card.dart';

class WidgetSetupScreen extends StatelessWidget {
  const WidgetSetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Screen widgets')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text('Your people, a glance away',
            style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Text(
            'Show photos from one friend or a personal List. Add more than one widget to keep different people on your Home Screen.'),
        const SizedBox(height: 24),
        const _Step('1', 'Connect with a friend',
            'Share your invite link, accept the connection, and each post a photo. Only posts you can already see in the app can appear in a widget.'),
        TextButton.icon(
            onPressed: () => context.push('/connections'),
            icon: const Icon(Icons.people_outline),
            label: const Text('Open Friends')),
        const _Step('2', 'Add A/SIDE to your Home Screen',
            'Touch and hold an empty area of the Home Screen. Tap Edit, then Add Widget (or the + button). Search for A/SIDE, choose a size, and tap Add Widget.'),
        const _Step('3', 'Choose your people',
            'Touch and hold the widget, then tap Edit Widget. Choose a friend or List. Leave the choice empty to see photos from all your friends. Each widget has its own choice. Requires iOS or iPadOS 17 or later.'),
        const _Step('4', 'Tap a photo to open its post',
            'You can read the caption, listen to a voice caption, or reply in the app.'),
        const SizedBox(height: 12),
        const AppCard(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('A note about privacy',
              style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 8),
          Text(
              'Widget photos are visible on your device to anyone who can see your Home Screen. Choose people you’re comfortable displaying there. Signing out clears the widget’s app data and requests a refresh; the system may briefly retain an earlier preview.'),
        ])),
        const SizedBox(height: 20),
        const Text(
            'Not seeing a photo? Open A/SIDE while online to refresh your account and choices. Your friend needs a photo or video post within your available history. iOS controls refresh timing, so new photos may take a while to appear. On older supported iOS versions, the widget shows all friends without a source selector.'),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.title, this.body);
  final String number, title, body;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$number. $title',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(body),
        ]),
      );
}
