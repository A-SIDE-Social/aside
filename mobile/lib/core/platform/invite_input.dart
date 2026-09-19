import '../config/env.dart';

/// Shared by manual entry and OS links. Legacy /join links keep their
/// case-sensitive code; personal slugs are case-insensitive.
class InviteInput {
  const InviteInput(this.code, {this.legacy = false});

  final String code;
  final bool legacy;

  String get route => '/u/$code${legacy ? '?legacy=1' : ''}';

  static InviteInput? parse(String input, {List<String>? allowedHosts}) {
    final value = input.trim();
    if (RegExp(r'^[a-zA-Z0-9]{12}$').hasMatch(value)) {
      return InviteInput(value);
    }
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri?.scheme == 'aside' &&
        ['invite', 'join'].contains(uri!.host) &&
        uri.userInfo.isEmpty &&
        !uri.hasPort) {
      final match = RegExp(r'^/([a-zA-Z0-9]{12})/?$').firstMatch(uri.path);
      if (match == null) return null;
      return InviteInput(
          uri.host == 'join' ? match[1]! : match[1]!.toLowerCase(),
          legacy: uri.host == 'join');
    }
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        !(allowedHosts ?? Env.appLinkHosts)
            .map((host) => host.toLowerCase())
            .contains(uri.host.toLowerCase())) {
      return null;
    }
    final path = uri.path;
    final personal = RegExp(r'^/([a-zA-Z0-9]{12})/?$').firstMatch(path);
    if (personal != null) return InviteInput(personal[1]!.toLowerCase());
    final legacy = RegExp(r'^/join/([a-zA-Z0-9]{12})/?$').firstMatch(path);
    if (legacy != null) return InviteInput(legacy[1]!, legacy: true);
    return null;
  }
}
