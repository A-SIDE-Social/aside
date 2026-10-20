import 'package:flutter/material.dart';

/// Temporarily shows the original photo without changing any saved edits.
class HoldToCompare extends StatefulWidget {
  const HoldToCompare({
    super.key,
    required this.enabled,
    required this.builder,
  });

  final bool enabled;
  final Widget Function(bool showOriginal) builder;

  @override
  State<HoldToCompare> createState() => _HoldToCompareState();
}

class _HoldToCompareState extends State<HoldToCompare> {
  bool _comparing = false;

  void _setComparing(bool value) {
    if (_comparing == value) return;
    setState(() => _comparing = value);
  }

  @override
  void didUpdateWidget(HoldToCompare oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _comparing = false;
  }

  @override
  Widget build(BuildContext context) {
    final original = widget.enabled && _comparing;
    return Semantics(
      hint: widget.enabled ? 'Touch and hold to compare with original' : null,
      value: original ? 'Original photo' : 'Edited photo',
      // Screen readers can toggle comparison without holding a pointer.
      onLongPress: widget.enabled ? () => _setComparing(!_comparing) : null,
      child: Listener(
        onPointerUp: (_) => _setComparing(false),
        onPointerCancel: (_) => _setComparing(false),
        child: GestureDetector(
          onLongPressStart: widget.enabled ? (_) => _setComparing(true) : null,
          onLongPressEnd: widget.enabled ? (_) => _setComparing(false) : null,
          onLongPressCancel: widget.enabled ? () => _setComparing(false) : null,
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              widget.builder(original),
              if (original)
                const Positioned(
                  top: 12,
                  left: 12,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.all(Radius.circular(8)),
                      ),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Text('Original',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
