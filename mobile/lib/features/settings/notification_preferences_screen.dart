import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_colors.dart';
import '../../providers/providers.dart';
import '../../widgets/widgets.dart';

class NotificationPreferencesScreen extends ConsumerStatefulWidget {
  const NotificationPreferencesScreen({super.key});

  @override
  ConsumerState<NotificationPreferencesScreen> createState() =>
      _NotificationPreferencesScreenState();
}

class _NotificationPreferencesScreenState
    extends ConsumerState<NotificationPreferencesScreen> {
  bool _loading = true;
  bool _pushEnabled = true;

  // Preference values (default all true)
  bool _connections = true;
  bool _posts = true;
  bool _comments = true;
  bool _messages = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    // Check OS-level push permission
    final settings = await FirebaseMessaging.instance.getNotificationSettings();
    _pushEnabled =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;

    // Load server-side preferences
    try {
      final api = ref.read(apiServiceProvider);
      final prefs = await api.getNotificationPreferences();
      if (mounted) {
        setState(() {
          _connections = prefs['connections'] as bool? ?? true;
          _posts = prefs['posts'] as bool? ?? true;
          _comments = prefs['comments'] as bool? ?? true;
          _messages = prefs['messages'] as bool? ?? true;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _updatePreference(String key, bool value) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.updateNotificationPreferences({key: value});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update: $e')),
        );
      }
    }
  }

  Future<void> _enablePush() async {
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    final granted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
            settings.authorizationStatus == AuthorizationStatus.provisional;
    if (granted) {
      await ref.read(authProvider.notifier).enablePush();
    }
    if (mounted) setState(() => _pushEnabled = granted);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const LoadingIndicator()
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              children: [
                const SizedBox(height: 16),

                // OS-level push permission banner
                if (!_pushEnabled)
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.notifications_off_outlined,
                                color: AppColors.error, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Push notifications are disabled',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Enable notifications in your device settings or tap below to request permission.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.textTertiary,
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            onPressed: _enablePush,
                            child: const Text('Enable Notifications'),
                          ),
                        ),
                      ],
                    ),
                  ),

                if (!_pushEnabled) const SizedBox(height: 16),

                // Preference toggles
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PrefToggle(
                        title: 'Friends',
                        subtitle: 'New friend requests and accepted requests',
                        value: _connections,
                        onChanged: (v) {
                          setState(() => _connections = v);
                          _updatePreference('connections', v);
                        },
                        colors: colors,
                        theme: theme,
                      ),
                      Divider(height: 1, color: colors.borderSubtle),
                      _PrefToggle(
                        title: 'Posts',
                        subtitle: 'New posts from friends',
                        value: _posts,
                        onChanged: (v) {
                          setState(() => _posts = v);
                          _updatePreference('posts', v);
                        },
                        colors: colors,
                        theme: theme,
                      ),
                      Divider(height: 1, color: colors.borderSubtle),
                      _PrefToggle(
                        title: 'Comments',
                        subtitle: 'Comments on your posts',
                        value: _comments,
                        onChanged: (v) {
                          setState(() => _comments = v);
                          _updatePreference('comments', v);
                        },
                        colors: colors,
                        theme: theme,
                      ),
                      Divider(height: 1, color: colors.borderSubtle),
                      _PrefToggle(
                        title: 'Messages',
                        subtitle: 'New direct messages',
                        value: _messages,
                        onChanged: (v) {
                          setState(() => _messages = v);
                          _updatePreference('messages', v);
                        },
                        colors: colors,
                        theme: theme,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
    );
  }
}

class _PrefToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final AppColorTokens colors;
  final ThemeData theme;

  const _PrefToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    required this.colors,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    )),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
