// Single-instance socket service, lifecycle tied to the provider
// container. Connect/disconnect is driven by the auth provider
// (sign-in + sign-out hooks), not by construction.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/env.dart';
import '../core/services/socket_service.dart';

final socketServiceProvider = Provider<SocketService>((ref) {
  final service = SocketService(Env.apiBaseUrl);
  ref.onDispose(service.dispose);
  return service;
});
