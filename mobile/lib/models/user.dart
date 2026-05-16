class User {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String? bio;
  final String? email;
  final String? phoneE164;
  final String subscriptionStatus;
  final String subscriptionPlan;
  final DateTime? subscriptionPeriodEnd;
  final DateTime? trialEndsAt;
  final String? familyGroupId;
  final DateTime createdAt;

  User({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    this.bio,
    this.email,
    this.phoneE164,
    required this.subscriptionStatus,
    this.subscriptionPlan = 'free',
    this.subscriptionPeriodEnd,
    this.trialEndsAt,
    this.familyGroupId,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      displayName: json['display_name'] as String,
      avatarUrl: json['avatar_url'] as String?,
      bio: json['bio'] as String?,
      email: json['email'] as String?,
      phoneE164: json['phone_e164'] as String?,
      subscriptionStatus: json['subscription_status'] as String? ?? 'free',
      subscriptionPlan: json['subscription_plan'] as String? ?? 'free',
      subscriptionPeriodEnd: json['subscription_period_end'] != null
          ? DateTime.parse(json['subscription_period_end'] as String)
          : null,
      trialEndsAt: json['trial_ends_at'] != null
          ? DateTime.parse(json['trial_ends_at'] as String)
          : null,
      familyGroupId: json['family_group_id'] as String?,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'display_name': displayName,
      'avatar_url': avatarUrl,
      'bio': bio,
      'email': email,
      'phone_e164': phoneE164,
      'subscription_status': subscriptionStatus,
      'subscription_plan': subscriptionPlan,
      'subscription_period_end': subscriptionPeriodEnd?.toIso8601String(),
      'trial_ends_at': trialEndsAt?.toIso8601String(),
      'family_group_id': familyGroupId,
      'created_at': createdAt.toIso8601String(),
    };
  }

  User copyWith({
    String? id,
    String? displayName,
    String? avatarUrl,
    String? bio,
    String? email,
    String? phoneE164,
    String? subscriptionStatus,
    String? subscriptionPlan,
    DateTime? subscriptionPeriodEnd,
    DateTime? trialEndsAt,
    String? familyGroupId,
    DateTime? createdAt,
  }) {
    return User(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      bio: bio ?? this.bio,
      email: email ?? this.email,
      phoneE164: phoneE164 ?? this.phoneE164,
      subscriptionStatus: subscriptionStatus ?? this.subscriptionStatus,
      subscriptionPlan: subscriptionPlan ?? this.subscriptionPlan,
      subscriptionPeriodEnd:
          subscriptionPeriodEnd ?? this.subscriptionPeriodEnd,
      trialEndsAt: trialEndsAt ?? this.trialEndsAt,
      familyGroupId: familyGroupId ?? this.familyGroupId,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
