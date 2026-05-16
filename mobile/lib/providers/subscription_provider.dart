import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../core/services/revenuecat_service.dart';
import 'providers.dart';

class FamilyInfo {
  final String id;
  final Map<String, dynamic>? owner;
  final List<Map<String, dynamic>> members;
  final int memberCount;
  final int maxMembers;
  final bool isOwner;

  const FamilyInfo({
    required this.id,
    this.owner,
    this.members = const [],
    this.memberCount = 0,
    this.maxMembers = 6,
    this.isOwner = false,
  });

  factory FamilyInfo.fromJson(Map<String, dynamic> json) {
    return FamilyInfo(
      id: json['id'] as String,
      owner: json['owner'] as Map<String, dynamic>?,
      members:
          (json['members'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ??
              [],
      memberCount: json['member_count'] as int? ?? 0,
      maxMembers: json['max_members'] as int? ?? 6,
      isOwner: json['is_owner'] as bool? ?? false,
    );
  }
}

class SubscriptionState {
  final bool isLoading;
  final Offerings? offerings;
  final String subscriptionPlan;
  final String subscriptionStatus;
  final DateTime? periodEnd;
  final FamilyInfo? familyInfo;
  final String? error;

  const SubscriptionState({
    this.isLoading = false,
    this.offerings,
    this.subscriptionPlan = 'free',
    this.subscriptionStatus = 'free',
    this.periodEnd,
    this.familyInfo,
    this.error,
  });

  SubscriptionState copyWith({
    bool? isLoading,
    Offerings? offerings,
    String? subscriptionPlan,
    String? subscriptionStatus,
    DateTime? periodEnd,
    FamilyInfo? familyInfo,
    String? error,
  }) {
    return SubscriptionState(
      isLoading: isLoading ?? this.isLoading,
      offerings: offerings ?? this.offerings,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      periodEnd: periodEnd ?? this.periodEnd,
      familyInfo: familyInfo ?? this.familyInfo,
      error: error,
    );
  }
}

class SubscriptionNotifier extends Notifier<SubscriptionState> {
  @override
  SubscriptionState build() => const SubscriptionState();

  /// Load RevenueCat offerings (available packages for purchase).
  Future<void> loadOfferings() async {
    try {
      final offerings = await RevenueCatService.getOfferings();
      state = state.copyWith(offerings: offerings);
    } catch (e) {
      state = state.copyWith(error: 'Failed to load offerings: $e');
    }
  }

  /// Refresh subscription status from the backend (source of truth).
  Future<void> refreshStatus() async {
    state = state.copyWith(isLoading: true);
    try {
      final api = ref.read(apiServiceProvider);
      final data = await api.getSubscriptionStatus();

      FamilyInfo? family;
      if (data['family'] != null) {
        family = FamilyInfo.fromJson(
          Map<String, dynamic>.from(data['family'] as Map),
        );
      }

      state = state.copyWith(
        isLoading: false,
        subscriptionPlan: data['plan'] as String? ?? 'free',
        subscriptionStatus: data['status'] as String? ?? 'free',
        periodEnd: data['period_end'] != null
            ? DateTime.parse(data['period_end'] as String)
            : null,
        familyInfo: family,
      );

      // Also update the auth provider's user with new subscription info
      final authState = ref.read(authProvider);
      if (authState.user != null) {
        ref.read(authProvider.notifier).setUser(
              authState.user!.copyWith(
                subscriptionStatus: data['status'] as String? ?? 'free',
                subscriptionPlan: data['plan'] as String? ?? 'free',
              ),
            );
      }
    } catch (e) {
      state = state.copyWith(isLoading: false, error: '$e');
    }
  }

  /// Purchase a subscription package.
  Future<bool> purchase(Package package) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await RevenueCatService.purchasePackage(package);
      // After purchase, refresh from backend (webhook will have fired)
      await Future.delayed(const Duration(seconds: 2));
      await refreshStatus();
      return true;
    } on PurchasesErrorCode catch (e) {
      if (e == PurchasesErrorCode.purchaseCancelledError) {
        state = state.copyWith(isLoading: false);
        return false;
      }
      state = state.copyWith(isLoading: false, error: 'Purchase failed: $e');
      return false;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Purchase failed: $e');
      return false;
    }
  }

  /// Restore previous purchases.
  Future<void> restorePurchases() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await RevenueCatService.restorePurchases();
      await Future.delayed(const Duration(seconds: 2));
      await refreshStatus();
    } catch (e) {
      state = state.copyWith(isLoading: false, error: 'Restore failed: $e');
    }
  }

  /// Add a family member (owner only).
  Future<void> addFamilyMember(String userId) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.addFamilyMember(userId);
      await refreshStatus();
    } catch (e) {
      state = state.copyWith(error: 'Failed to add member: $e');
    }
  }

  /// Remove a family member (owner only).
  Future<void> removeFamilyMember(String userId) async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.removeFamilyMember(userId);
      await refreshStatus();
    } catch (e) {
      state = state.copyWith(error: 'Failed to remove member: $e');
    }
  }

  /// Leave a family group (member only).
  Future<void> leaveFamily() async {
    try {
      final api = ref.read(apiServiceProvider);
      await api.leaveFamily();
      await refreshStatus();
    } catch (e) {
      state = state.copyWith(error: 'Failed to leave family: $e');
    }
  }
}

final subscriptionProvider =
    NotifierProvider<SubscriptionNotifier, SubscriptionState>(
        SubscriptionNotifier.new);
