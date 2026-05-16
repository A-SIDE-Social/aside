class Group {
  final String id;
  final String userId;
  final String name;
  final String? color;
  final int position;
  final DateTime createdAt;

  Group({
    required this.id,
    required this.userId,
    required this.name,
    this.color,
    required this.position,
    required this.createdAt,
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      name: json['name'] as String,
      color: json['color'] as String?,
      position: json['position'] as int? ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'name': name,
      'color': color,
      'position': position,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
