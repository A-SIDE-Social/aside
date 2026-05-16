import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_colors.dart';
import '../core/services/speech_service.dart';
import '../providers/speech_provider.dart';

/// A mic button that toggles on-device speech-to-text and pipes the transcript
/// into the given [controller]. Returns an empty widget on iOS < 26.
class SpeechInputButton extends ConsumerStatefulWidget {
  const SpeechInputButton({
    required this.controller,
    this.maxLength,
    super.key,
  });

  final TextEditingController controller;
  final int? maxLength;

  @override
  ConsumerState<SpeechInputButton> createState() => _SpeechInputButtonState();
}

class _SpeechInputButtonState extends ConsumerState<SpeechInputButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;
  String _preExistingText = '';

  /// Session id captured when this button starts its own dictation
  /// session. Cross-checked against `speech.sessionId` in build() so
  /// we only apply transcript updates from the session we initiated.
  /// Prevents a DM composer's button from picking up stale transcript
  /// from a post composer's session mid-navigation.
  int? _sessionId;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    // Cancel if still listening when widget is removed
    final speech = ref.read(speechProvider);
    if (speech.status == SpeechStatus.listening) {
      ref.read(speechProvider.notifier).cancelListening();
    }
    _pulseController.dispose();
    super.dispose();
  }

  void _toggle() async {
    final notifier = ref.read(speechProvider.notifier);
    final status = ref.read(speechProvider).status;

    if (status == SpeechStatus.listening) {
      await notifier.stopListening();
      _pulseController.stop();
      _pulseController.reset();
    } else {
      _preExistingText = widget.controller.text;
      final started = await notifier.startListening();
      if (started) {
        // Capture the session id minted by startListening so subsequent
        // builds can distinguish "our session" from stale state left by
        // a different screen's button.
        _sessionId = ref.read(speechProvider).sessionId;
        _pulseController.repeat(reverse: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Don't show if SpeechAnalyzer is unavailable (iOS < 26, Android, etc.)
    if (!SpeechService.instance.isAvailable) {
      return const SizedBox.shrink();
    }

    final colors = AppColors.of(context);
    final speech = ref.watch(speechProvider);
    final isListening = speech.status == SpeechStatus.listening;

    // Update the text field with the transcript. Guard on:
    //  - isListening (some other dispatch set status without toggling)
    //  - non-empty transcript (nothing to write)
    //  - sessionId matches ours (the provider is global — without this
    //    check a freshly-mounted button on a different screen would
    //    pick up transcript from whoever was dictating last).
    if (isListening &&
        speech.transcript.isNotEmpty &&
        speech.sessionId != null &&
        speech.sessionId == _sessionId) {
      final newText = _preExistingText.isEmpty
          ? speech.transcript
          : '$_preExistingText ${speech.transcript}';

      // Respect maxLength
      final truncated =
          widget.maxLength != null && newText.length > widget.maxLength!
              ? newText.substring(0, widget.maxLength!)
              : newText;

      if (widget.controller.text != truncated) {
        widget.controller.text = truncated;
        widget.controller.selection = TextSelection.collapsed(
          offset: truncated.length,
        );
      }
    }

    // Show error via SnackBar
    if (speech.status == SpeechStatus.error && speech.errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(speech.errorMessage!),
              duration: const Duration(seconds: 2),
            ),
          );
          ref.read(speechProvider.notifier).clearError();
        }
      });
    }

    // Manage pulse animation state
    if (isListening && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!isListening && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }

    return GestureDetector(
      onTap: _toggle,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: ScaleTransition(
          scale:
              isListening ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
          child: Icon(
            isListening ? Icons.mic_rounded : Icons.mic_none_rounded,
            color: isListening ? colors.accent : colors.textTertiary,
            size: 22,
          ),
        ),
      ),
    );
  }
}
