import 'dart:async';

import 'package:dio/dio.dart';

/// Wires a stall-detection timer to a [CancelToken].
///
/// Call [noteProgress] whenever bytes are sent. If no progress is reported for
/// longer than [threshold], the token is cancelled — which surfaces as a
/// `DioException` of type `cancel` at the upload call site. Callers should
/// translate that into whatever UI they want (dialog, snackbar, etc.).
///
/// Always call [stop] in a `finally` block to release the timer.
class UploadWatchdog {
  UploadWatchdog({
    required this.cancelToken,
    this.threshold = const Duration(seconds: 30),
  }) {
    _lastProgressAt = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(_lastProgressAt) > threshold &&
          !cancelToken.isCancelled) {
        cancelToken.cancel('stalled');
      }
    });
  }

  final CancelToken cancelToken;
  final Duration threshold;
  late DateTime _lastProgressAt;
  Timer? _timer;

  void noteProgress() {
    _lastProgressAt = DateTime.now();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Returns `true` when the given exception is one of the "upload looks
/// broken" modes — cancelled by the stall watchdog, or any Dio timeout /
/// connection error. Callers treat these the same.
bool isUploadStallOrTimeout(Object error) {
  if (error is DioException) {
    if (CancelToken.isCancel(error)) return true;
    return error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError;
  }
  return false;
}
