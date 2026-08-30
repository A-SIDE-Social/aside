import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_colors.dart';
import '../../core/config/constants.dart';
import '../../core/network/api_client.dart';
import '../../models/models.dart';
import '../../providers/providers.dart';

class EditProfileNameScreen extends ConsumerStatefulWidget {
  const EditProfileNameScreen({super.key});

  @override
  ConsumerState<EditProfileNameScreen> createState() =>
      _EditProfileNameScreenState();
}

class _EditProfileNameScreenState extends ConsumerState<EditProfileNameScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late String _initialName;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _initialName = ref.read(authProvider).user?.displayName ?? '';
    _nameController = TextEditingController(text: _initialName);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String? _validateName(String? value) {
    final name = value?.trim() ?? '';
    if (name.isEmpty) return 'Enter your name';
    if (name.runes.length > AppLimits.maxDisplayNameLength) {
      return 'Use ${AppLimits.maxDisplayNameLength} characters or fewer';
    }
    if (RegExp(r'[\u0000-\u001F\u007F-\u009F\u2028\u2029]').hasMatch(name)) {
      return 'Name cannot contain line breaks or control characters';
    }
    return null;
  }

  String _errorMessage(Object error) {
    if (error is ApiException) return error.message;
    if (error is DioException) {
      return ApiException.fromDioException(error).message;
    }
    return 'Could not update your name. Please try again.';
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    if (name == _initialName) {
      await Navigator.of(context).maybePop(false);
      return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });

    try {
      final data = await ref.read(apiServiceProvider).updateMe(
            displayName: name,
          );
      final updatedUser = User.fromJson(data as Map<String, dynamic>);

      ref.read(authProvider.notifier).setUser(updatedUser);
      ref.invalidate(feedNotifierProvider);
      ref.invalidate(userPostsProvider(updatedUser.id));
      _initialName = updatedUser.displayName;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name updated')),
      );
      final popped = await Navigator.of(context).maybePop(true);
      if (!popped && mounted) {
        setState(() => _saving = false);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = _errorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Edit Name')),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                'This is the name your friends see on your profile, posts, comments, and messages.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: 24),
              TextFormField(
                key: const Key('profile-name-field'),
                controller: _nameController,
                autofocus: true,
                autocorrect: false,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                maxLength: AppLimits.maxDisplayNameLength,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'How your friends know you',
                ),
                validator: _validateName,
                onChanged: (_) {
                  if (_saveError != null) {
                    setState(() => _saveError = null);
                  }
                },
                onFieldSubmitted: (_) => _save(),
              ),
              if (_saveError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _saveError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.error,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const Key('save-profile-name'),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
