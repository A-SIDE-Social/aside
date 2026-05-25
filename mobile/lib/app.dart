import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/config/app_theme.dart';
import 'core/platform/deep_link.dart';
import 'core/platform/screenshot_service.dart';
import 'core/platform/universal_link_service.dart';
import 'widgets/screenshot_warning.dart';
import 'features/auth/onboarding_contacts_screen.dart';
import 'features/auth/sign_in_screen.dart';
import 'features/auth/splash_screen.dart';
import 'features/connections/send_request_screen.dart';
import 'features/conversations/conversation_detail_screen.dart';
import 'features/conversations/conversations_screen.dart';
import 'features/conversations/group_composer_screen.dart';
import 'features/debug/e2ee_spike_screen.dart';
import 'features/feed/feed_screen.dart'
    show FeedScreen, feedScrollToTopSignalProvider;
import 'features/groups/group_detail_screen.dart';
import 'features/groups/groups_screen.dart';
import 'features/post/create_post_screen.dart';
import 'features/post/post_detail_screen.dart';
import 'features/contacts/contact_sync_screen.dart';
import 'features/profile/connections_screen.dart';
import 'features/profile/profile_screen.dart';
import 'features/settings/notification_preferences_screen.dart';
import 'features/settings/settings_screen.dart';
import 'features/subscription/paywall_screen.dart';
import 'features/subscription/family_management_screen.dart';
import 'models/draft_group.dart';
import 'providers/api_provider.dart';
import 'providers/attachment_cache_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/draft_provider.dart';
import 'providers/feed_provider.dart';
import 'providers/group_members_provider.dart';
import 'providers/invite_link_provider.dart';
import 'providers/subscription_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/usage_provider.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();

/// Max content widths by viewport class.
///
/// Phones (viewport <= 768px): 600px — preserves readable line lengths
/// on captions / comments and matches pre-build-32 layout exactly.
/// Tablets (viewport > 768px, iPad in portrait or landscape, phone in
/// wide landscape): 900px — fills iPad without huge side-bar dead
/// space, while still keeping posts and long-form text constrained
/// enough to read comfortably.
///
/// 768px chosen to match the [isLargeScreen] threshold already in use
/// in `core/utils/extensions.dart`. Anything wider is treated as a
/// tablet-class surface.
const _maxContentWidthPhone = 600.0;
const _maxContentWidthTablet = 900.0;

/// Wraps a screen in a centered max-width container. Uses a
/// [LayoutBuilder] so the cap responds to the actual available width
/// rather than a one-shot MediaQuery read — works for split-view on
/// iPad and landscape rotations without needing a rebuild trigger.
Widget _constrained(Widget child) {
  return LayoutBuilder(
    builder: (context, constraints) {
      final maxWidth = constraints.maxWidth > 768
          ? _maxContentWidthTablet
          : _maxContentWidthPhone;
      return Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
    },
  );
}

/// Bridges Riverpod auth state changes into a [Listenable] that GoRouter can
/// use via [refreshListenable] — so the router is created once and only
/// re-evaluates its redirect when auth status actually changes.
class _AuthNotifierListenable extends ChangeNotifier {
  AuthStatus _status = AuthStatus.initial;

  void update(AuthState authState) {
    if (_status != authState.status) {
      _status = authState.status;
      notifyListeners();
    }
  }
}

final _authListenableProvider = Provider<_AuthNotifierListenable>((ref) {
  final listenable = _AuthNotifierListenable();
  ref.listen<AuthState>(authProvider, (prev, next) {
    listenable.update(next);

    // When the authenticated user changes — whether via sign-out
    // (authenticated → unauthenticated) or account switch (user.id
    // changes without an intermediate sign-out, e.g. after token
    // invalidation) — invalidate every provider that caches per-user
    // state. Without this, long-lived NotifierProviders retain
    // the previous user's feed, groups, subscription, drafts, etc.,
    // and the next login shows a Frankensteined home screen with the
    // new user's identity on top of the old user's data.
    //
    // `commentsProvider` is a family + autoDispose, so it cleans up
    // naturally when its screens unmount. `themeProvider` and
    // `speechProvider` are device-scoped, not user-scoped.
    final prevId = prev?.user?.id;
    final nextId = next.user?.id;
    final userChanged = prevId != nextId;
    final signedOut = prev?.status == AuthStatus.authenticated &&
        next.status != AuthStatus.authenticated;
    if (userChanged || signedOut) {
      ref.invalidate(feedNotifierProvider);
      ref.invalidate(groupsWithMembersProvider);
      ref.invalidate(subscriptionProvider);
      ref.invalidate(draftProvider);
      ref.invalidate(usageProvider);
      // Personal invite link is per-user; invalidate so the next
      // login fetches the new user's slug rather than reusing the
      // previous account's cached link.
      ref.invalidate(inviteLinkProvider);
      // Group/list filter is a user preference, reset to "all".
      ref.read(feedGroupFilterProvider.notifier).set(null);
      // E2EE plaintext attachment cache: must be evicted on auth
      // transitions so a subsequent user on the same device can't
      // read the previous user's decrypted photos out of the engine
      // heap. The cache is memory-only (never hits disk), but we
      // still treat account switches as a clean boundary.
      ref.invalidate(attachmentPlaintextCacheProvider);
    }
  });
  return listenable;
});

final routerProvider = Provider<GoRouter>((ref) {
  final authListenable = ref.watch(_authListenableProvider);

  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: authListenable,
    redirect: (context, state) {
      final authState = ref.read(authProvider);
      final status = authState.status;
      final isOnSignIn = state.matchedLocation == '/sign-in';

      // Startup (initial/loading) is handled above the router in AsideApp —
      // the router is only mounted once auth has resolved, so we don't need
      // a splash route or a loading redirect here.

      if (status == AuthStatus.unauthenticated && !isOnSignIn) {
        return '/sign-in';
      }

      if (status == AuthStatus.authenticated && isOnSignIn) {
        return '/';
      }

      // Allow onboarding screens for authenticated users
      if (state.matchedLocation.startsWith('/onboarding')) {
        return status == AuthStatus.authenticated ? null : '/sign-in';
      }

      return null;
    },
    routes: [
      // Full-screen routes (no bottom nav)
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/onboarding/contacts',
        builder: (context, state) =>
            _constrained(const OnboardingContactsScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/post/new',
        builder: (context, state) => _constrained(const CreatePostScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/post/:id',
        pageBuilder: (context, state) => CustomTransitionPage(
          key: state.pageKey,
          child: _constrained(PostDetailScreen(
            postId: state.pathParameters['id']!,
          )),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              )),
              child: child,
            );
          },
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        // Static path — must be declared before the :id route so the
        // router matches the composer rather than treating "new-group"
        // as a conversation id.
        path: '/conversations/new-group',
        builder: (context, state) => _constrained(const GroupComposerScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        // Draft chat: conversation not yet persisted on the server.
        // The composer navigates here with a DraftGroup as `extra`;
        // the detail screen materializes the group on first message
        // send. Must also be declared before the :id route.
        path: '/conversations/new-group/chat',
        builder: (context, state) {
          final draft = state.extra as DraftGroup?;
          // Defensive: if someone deep-links here without state (e.g.
          // back button from an orphaned route), bounce back to the
          // conversations list instead of crashing on a null draft.
          if (draft == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/messages');
            });
            return const SizedBox.shrink();
          }
          return _constrained(ConversationDetailScreen(draft: draft));
        },
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/conversations/:id',
        builder: (context, state) => _constrained(ConversationDetailScreen(
          conversationId: state.pathParameters['id']!,
        )),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/profile/:id',
        builder: (context, state) => _constrained(ProfileScreen(
          userId: state.pathParameters['id']!,
        )),
      ),
      // Settings is now a bottom-nav tab; keep this route for deep links.
      // GoRoute(
      //   parentNavigatorKey: _rootNavigatorKey,
      //   path: '/settings',
      //   builder: (context, state) => _constrained(const SettingsScreen()),
      // ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/settings/notifications',
        builder: (context, state) =>
            _constrained(const NotificationPreferencesScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/upgrade',
        builder: (context, state) => _constrained(const PaywallScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/family',
        builder: (context, state) =>
            _constrained(const FamilyManagementScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/groups',
        builder: (context, state) => _constrained(const GroupsScreen()),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/groups/:id',
        builder: (context, state) => _constrained(GroupDetailScreen(
          groupId: state.pathParameters['id']!,
        )),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/connections',
        builder: (context, state) => _constrained(const ConnectionsScreen()),
      ),
      // Personal-invite-link send-request screen. Reached when an
      // already-authenticated user taps a Universal Link / App Link
      // of the form `<configured-app-url>/<slug>` — the bridge in
      // UniversalLinkService maps the URL to this in-app route. The
      // path namespace uses `/u/` (not the public slug at root) to
      // keep the in-app routing tree unambiguous — slugs cannot
      // collide with `/post/:id`, `/profile/:id`, etc.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/u/:slug',
        builder: (context, state) => _constrained(
          SendRequestScreen(slug: state.pathParameters['slug']!),
        ),
      ),
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/contacts',
        builder: (context, state) => _constrained(const ContactSyncScreen()),
      ),
      // Phase 1a dev-only: smoke-tests the flutter_rust_bridge + Rust
      // crypto FFI pipeline. Remove once Phase 1b lands.
      GoRoute(
        parentNavigatorKey: _rootNavigatorKey,
        path: '/debug/e2ee',
        builder: (context, state) => const E2eeSpikeScreen(),
      ),

      // Bottom nav shell
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MainScaffold(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const FeedScreen(),
              ),
            ],
          ),
          // Search tab hidden — discovery is invite-only for now
          // StatefulShellBranch(
          //   routes: [
          //     GoRoute(
          //       path: '/search',
          //       builder: (context, state) => const SearchScreen(),
          //     ),
          //   ],
          // ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/conversations',
                builder: (context, state) => const ConversationsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/profile',
                builder: (context, state) => const ProfileScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

class AsideApp extends ConsumerStatefulWidget {
  const AsideApp({super.key});

  @override
  ConsumerState<AsideApp> createState() => _AsideAppState();
}

class _AsideAppState extends ConsumerState<AsideApp>
    with WidgetsBindingObserver {
  DateTime? _lastFeedRefresh;
  static const _feedRefreshInterval = Duration(minutes: 5);

  /// Tracks whether the cold-start pendingDeepLink drain has run. The
  /// drain only needs to fire once per app launch — the warm-resume
  /// `ref.listen` below covers every change after that. Without this
  /// flag the drain re-evaluates on every AsideApp rebuild, scheduling
  /// redundant post-frame callbacks (mostly harmless thanks to the
  /// inner null-check, but also a needless allocation pattern).
  bool _drainedColdStart = false;

  /// Stream subscription for the screenshot detector. Cancelled in
  /// dispose() so we don't leak a long-lived subscription past the
  /// app's lifetime.
  StreamSubscription<void>? _screenshotSub;

  /// Currently-visible screenshot warning, if any. Re-firing replaces
  /// the existing handle (timer cancel + overlay remove + re-insert)
  /// so consecutive screenshots don't stack overlays.
  ScreenshotWarningHandle? _screenshotWarningHandle;

  /// Bridges Universal Links / App Links → pendingDeepLinkProvider.
  /// Initialized once in initState; lives for the app's lifetime
  /// (the underlying [AppLinks] stream has no explicit teardown
  /// requirement).
  UniversalLinkService? _universalLinkService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Initialize usage tracking
    ref.read(usageProvider);

    // Subscribe to screenshot events. iOS emits via UIApplication's
    // userDidTakeScreenshotNotification (after the OS captures);
    // Android stub emits nothing in v1.
    _screenshotSub = ScreenshotService.instance.onScreenshot.listen((_) {
      _onScreenshot();
    });

    // Bridge Universal Links / App Links. The service translates
    // incoming invite-link URLs into the in-app
    // route `/u/<slug>` and stashes them in pendingDeepLinkProvider
    // — same channel the FCM push handler uses, so the warm-listen +
    // cold-start drain logic below works for URL taps too.
    _universalLinkService = UniversalLinkService(
      onDeepLink: (route) {
        debugPrint('[deep_link] universal link → $route');
        ref.read(pendingDeepLinkProvider.notifier).set(route);
      },
    );
    unawaited(_universalLinkService!.initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _screenshotSub?.cancel();
    _screenshotWarningHandle?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final usage = ref.read(usageProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      usage.startSession();
      final auth = ref.read(authProvider);
      if (auth.status == AuthStatus.authenticated) {
        // Refresh feed on resume only if it's been a while —
        // otherwise the cached state is still fresh enough and a
        // refresh is just visual noise.
        final now = DateTime.now();
        final last = _lastFeedRefresh;
        if (last == null || now.difference(last) >= _feedRefreshInterval) {
          _lastFeedRefresh = now;
          ref.read(feedNotifierProvider.notifier).refresh();
        }

        // Always tell the server we've seen the feed on resume.
        // Without this the badge race window stretches across the
        // entire `_feedRefreshInterval` (5 min): the app icon clears
        // locally on resume, but the next inbound push computes a
        // stale badge from the server's pre-resume
        // `last_feed_seen_at` and the icon jumps back up. Firing
        // markFeedSeen here closes that window — the next push will
        // have an accurate count. Fire-and-forget; a failure to
        // reach the server is at worst a re-occurrence of the bug,
        // never something the user needs to see.
        ref.read(apiServiceProvider).markFeedSeen().catchError((_) {});

        // Re-assert the push token on resume. The backend upsert is
        // idempotent, and this repairs the silent case where the server
        // deleted our device-token row while the app was not running.
        unawaited(ref.read(authProvider.notifier).reregisterPushToken());
      }
    } else if (state == AppLifecycleState.paused) {
      usage.pauseSession();
      // Cancel any in-flight screenshot warning so the user doesn't
      // return to a stale banner sliding away.
      _screenshotWarningHandle?.cancel();
      _screenshotWarningHandle = null;
    }
  }

  /// Fire-once handler for a screenshot event. Mounts the warning
  /// banner into the root navigator's overlay. If a banner is
  /// already showing (rapid consecutive screenshots), cancels the
  /// existing one before inserting fresh — no stacking. Silently
  /// no-ops if there's no overlay context yet (auth splash, pre-
  /// router-mount frames).
  void _onScreenshot() {
    if (!mounted) return;
    final overlay = _rootNavigatorKey.currentState?.overlay;
    if (overlay == null) return; // auth splash, no overlay yet

    _screenshotWarningHandle?.cancel();
    _screenshotWarningHandle = showScreenshotWarning(overlay);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final authStatus = ref.watch(authProvider.select((s) => s.status));

    // While auth is resolving on cold start, show the splash above the router.
    // Mounting MaterialApp.router only after auth resolves means the router's
    // initial redirect runs exactly once with a final auth status — no
    // intermediate /splash -> / hop that would animate as a slide.
    if (authStatus == AuthStatus.initial || authStatus == AuthStatus.loading) {
      return MaterialApp(
        themeMode: themeMode,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
        home: const SplashScreen(),
      );
    }

    final router = ref.watch(routerProvider);

    // Notification taps stash a route in pendingDeepLinkProvider; consume it
    // here and route on the next frame. Listening from AsideApp (rather than
    // inside a screen) means we catch taps regardless of which tab is active.
    //
    // Use `router.push` rather than `router.go`. `go` REPLACES the stack —
    // the deep-link target becomes the only entry, so the user has nothing
    // to back out to and the AppBar shows no back button. `push` layers
    // the target on top of whatever's currently mounted (or the
    // initialLocation `/` on cold-start) so the AppBar's back arrow pops
    // cleanly back to the feed / wherever they were.
    ref.listen<String?>(pendingDeepLinkProvider, (_, next) {
      if (next == null) return;
      debugPrint('[deep_link] warm tap → push $next');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        router.push(next);
        ref.read(pendingDeepLinkProvider.notifier).set(null);
      });
    });

    // Cold-start race: `PushNotificationService.initialize()` awaits
    // `getInitialMessage()` inside `AuthNotifier.initialize()`, which
    // can resolve before (or while) this widget first builds with
    // `authStatus == authenticated`. `ref.listen` above does NOT replay
    // the provider's current value — it only fires on *future* changes.
    // So if the tap that cold-started the app already stashed a route,
    // the listener above misses it and we land on `/` instead of the
    // DM. Drain the pending value on the first build only. `ref.read`
    // keeps this off the dependency graph so it doesn't cause rebuild
    // loops; the `_drainedColdStart` flag dedupes if AsideApp rebuilds
    // before the post-frame callback fires.
    if (!_drainedColdStart) {
      _drainedColdStart = true;
      final pendingOnMount = ref.read(pendingDeepLinkProvider);
      if (pendingOnMount != null) {
        debugPrint('[deep_link] cold-start drain → push $pendingOnMount');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          // Re-check — the listener above may have consumed it in between.
          final current = ref.read(pendingDeepLinkProvider);
          if (current == null) return;
          // Same `push` over `go` reasoning as above — the cold-start path
          // also needs a navigable back stack, otherwise the user lands on
          // /connections (or /post/abc, etc.) with no way back to the feed.
          router.push(current);
          ref.read(pendingDeepLinkProvider.notifier).set(null);
        });
      }
    }

    return GestureDetector(
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: MaterialApp.router(
        routerConfig: router,
        themeMode: themeMode,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class MainScaffold extends ConsumerWidget {
  const MainScaffold({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Drives the small dot on the Messages icon. We watch the
    // conversations list (cached at app level — already fetched on
    // startup and on every new socket message) and check whether any
    // conversation has an unread message. The provider is invalidated
    // on _markAsRead in conversation_detail_screen, so visiting an
    // unread conversation clears the dot the next frame.
    final hasUnreadDm = ref.watch(conversationsProvider).maybeWhen(
          data: (convos) => convos.any((c) => c.unreadCount > 0),
          orElse: () => false,
        );
    return Scaffold(
      body: _constrained(navigationShell),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.5,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (index) {
            final isSameTab = index == navigationShell.currentIndex;
            // Re-tapping Home while already on the feed should scroll to top.
            // goBranch(initialLocation: true) also resets the branch's nav
            // stack, which is the right behavior if the user drilled into a
            // sub-route within the home branch.
            if (isSameTab && index == 0) {
              ref.read(feedScrollToTopSignalProvider.notifier).bump();
            }
            // Build 38: any time the user lands on Home (whether via
            // re-tap or branch switch from another tab), tell the
            // server we've seen the feed. Drives the post-side of
            // the app-icon badge count. Fire-and-forget; only fired
            // when arriving at Home, not when leaving it.
            if (index == 0) {
              ref.read(apiServiceProvider).markFeedSeen().catchError((_) {});
            }
            navigationShell.goBranch(index, initialLocation: isSameTab);
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            NavigationDestination(
              // Material 3 Badge with no label renders as a small dot
              // anchored to the upper-right of the child. Shown only
              // when at least one conversation has an unread message;
              // clears as soon as the user opens that conversation
              // (markAsRead invalidates conversationsProvider).
              icon: Badge(
                isLabelVisible: hasUnreadDm,
                smallSize: 8,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.chat_bubble_outline_rounded),
              ),
              selectedIcon: Badge(
                isLabelVisible: hasUnreadDm,
                smallSize: 8,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child: const Icon(Icons.chat_bubble_rounded),
              ),
              label: 'Messages',
            ),
            const NavigationDestination(
              icon: Icon(Icons.person_outline_rounded),
              selectedIcon: Icon(Icons.person_rounded),
              label: 'Profile',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}
