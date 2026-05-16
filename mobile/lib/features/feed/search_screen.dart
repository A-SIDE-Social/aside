import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_colors.dart';
import '../../widgets/widgets.dart';
import '../../providers/providers.dart';
import '../../models/models.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<User>? _results;
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _results = null;
        _isLoading = false;
        _error = null;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search(query.trim());
    });
  }

  Future<void> _search(String query) async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.searchUsers(query);
      final list = data as List<dynamic>;
      final users =
          list.map((e) => User.fromJson(e as Map<String, dynamic>)).toList();

      if (mounted) {
        setState(() {
          _results = users;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Search'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle_outline, size: 28),
            onPressed: () => context.push('/post/new'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Search field
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                autofocus: false,
                decoration: InputDecoration(
                  hintText: 'Search by name...',
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: colors.textTertiary,
                  ),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: Icon(
                            Icons.clear,
                            color: colors.textTertiary,
                            size: 18,
                          ),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                        )
                      : null,
                ),
              ),
            ),

            // Results
            Expanded(
              child: _buildBody(colors, theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColorTokens colors, ThemeData theme) {
    if (_isLoading) {
      return const LoadingIndicator();
    }

    if (_error != null) {
      return ErrorView(
        message: _error,
        onRetry: () => _search(_searchController.text.trim()),
      );
    }

    if (_results == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_rounded,
              size: 48,
              color: colors.textTertiary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              'Search for people',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    if (_results!.isEmpty) {
      return const EmptyState(
        icon: Icons.person_search_outlined,
        title: 'No results found',
        subtitle: 'Try a different name.',
      );
    }

    return ListView.separated(
      itemCount: _results!.length,
      separatorBuilder: (_, __) => Divider(color: colors.borderSubtle),
      itemBuilder: (context, index) {
        final user = _results![index];

        return ListTile(
          leading: Avatar(
            imageUrl: user.avatarUrl,
            displayName: user.displayName,
            size: 44,
          ),
          title: Text(
            user.displayName,
            style: theme.textTheme.titleMedium,
          ),
          onTap: () => context.push('/profile/${user.id}'),
        );
      },
    );
  }
}
