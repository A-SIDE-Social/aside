class Invite {
  final String id;
  final String code;
  final String status;
  final DateTime expiresAt;
  final DateTime createdAt;
  final String? usedByUserId;
  final DateTime? usedAt;

  Invite({
    required this.id,
    required this.code,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
    this.usedByUserId,
    this.usedAt,
  });

  Invite copyWith({String? status}) {
    return Invite(
      id: id,
      code: code,
      status: status ?? this.status,
      expiresAt: expiresAt,
      createdAt: createdAt,
      usedByUserId: usedByUserId,
      usedAt: usedAt,
    );
  }

  factory Invite.fromJson(Map<String, dynamic> json) {
    return Invite(
      id: json['id'] as String,
      code: json['code'] as String,
      status: json['status'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      usedByUserId: json['used_by_user_id'] as String?,
      usedAt: json['used_at'] != null
          ? DateTime.parse(json['used_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'status': status,
      'expires_at': expiresAt.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'used_by_user_id': usedByUserId,
      'used_at': usedAt?.toIso8601String(),
    };
  }
}
