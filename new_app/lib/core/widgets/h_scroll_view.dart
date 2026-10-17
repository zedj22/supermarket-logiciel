import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// A horizontally scrolling region for a row of content that would
/// otherwise overflow a narrow window.
///
/// Why this exists (two desktop gaps in stock Flutter):
///
///  1. A horizontal scrollable only honours the *matching* axis of a
///     wheel event, so a plain mouse wheel (vertical delta) scrolls a
///     filter row or a chip strip by exactly 0px — the content past the
///     edge is simply unreachable without a trackpad swipe.
///  2. A bare scrollable gives no visual cue that there IS more content,
///     so nothing invites the user to drag it.
///
/// [HScrollView] closes both gaps while keeping the normal behaviour:
///
///  * the child is laid out at its intrinsic width and scrolled on
///    overflow — it never overflows;
///  * a wheel delta with no horizontal component is bridged onto the
///    horizontal axis. The bridge is registered through
///    [PointerSignalResolver] from *inside* the scroll view, so it only
///    wins when nothing deeper (an inner text field or list) claimed the
///    event, and it never claims a gesture that already has a horizontal
///    component — native trackpad horizontal scrolling is untouched;
///  * a draggable scrollbar thumb is shown while, and only while, there
///    is something to scroll;
///  * [Directionality] is honoured, so Arabic (RTL) starts at the right
///    edge and English/French (LTR) at the left.
///
/// Content that fits is laid out exactly as it would be without this
/// widget — the scroll view is a no-op until its child is too wide.
class HScrollView extends StatefulWidget {
  const HScrollView({
    super.key,
    required this.child,
    this.controller,
    this.padding,
    this.physics,
    this.height,
    this.alwaysShowScrollbar = false,
  });

  /// The horizontally arranged content (usually a [Row]); laid out with
  /// unbounded width so it can never be squashed or overflowed.
  final Widget child;

  /// Drives the scroll position. One is created internally when null.
  final ScrollController? controller;

  final EdgeInsetsGeometry? padding;

  final ScrollPhysics? physics;

  /// Fixed cross-axis size. When null the region takes the height its
  /// parent gives it (the child is then stretched to that height).
  final double? height;

  /// Keep the thumb painted even while the content fits. Off by default
  /// so a row that does not overflow shows no scrollbar at all.
  final bool alwaysShowScrollbar;

  @override
  State<HScrollView> createState() => _HScrollViewState();
}

class _HScrollViewState extends State<HScrollView> {
  ScrollController? _internalController;
  bool _canScroll = false;

  ScrollController get _controller =>
      widget.controller ?? (_internalController ??= ScrollController());

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recomputeScrollability);
    // The first layout decides whether a thumb is needed at all.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recomputeScrollability();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_recomputeScrollability);
    _internalController?.dispose();
    super.dispose();
  }

  void _recomputeScrollability() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final canScroll =
        position.maxScrollExtent > position.minScrollExtent + 0.5;
    if (canScroll != _canScroll && mounted) {
      setState(() => _canScroll = canScroll);
    }
  }

  /// Bridges a vertical wheel delta onto the horizontal axis.
  ///
  /// Registered from inside the scroll view (see the class docs) so it
  /// sits deeper in the hit-test path than the scrollable itself: the
  /// resolver keeps the FIRST registration, and hit test entries are
  /// dispatched deepest-first, so the bridge wins over the scroll view's
  /// own horizontal handler — which would otherwise swallow a pure
  /// vertical delta without scrolling anything.
  void _onPointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    final delta = signal.scrollDelta;
    // Only a pure vertical wheel/trackpad-pull: anything with a
    // horizontal component belongs to the scrollable's own axis handling.
    if (delta.dx != 0 || delta.dy == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(signal, (_) {
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      final target = (position.pixels + delta.dy)
          .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (target == position.pixels) return;
      position.jumpTo(target);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Content can shrink after the first layout (filters removed, a
    // list swapped for an empty state, locale changed). The controller
    // only fires on scroll, so re-check after every layout too —
    // otherwise a stale thumb would advertise content that is gone.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _recomputeScrollability();
    });

    final scrollable = SingleChildScrollView(
      controller: _controller,
      scrollDirection: Axis.horizontal,
      physics: widget.physics,
      padding: widget.padding,
      child: Listener(
        // Opaque so the bridge is hit-tested over the whole strip
        // (gaps between children would otherwise swallow the wheel).
        behavior: HitTestBehavior.opaque,
        onPointerSignal: _onPointerSignal,
        child: widget.child,
      ),
    );

    final child = widget.height == null
        ? scrollable
        : SizedBox(height: widget.height, child: scrollable);

    if (!widget.alwaysShowScrollbar && !_canScroll) {
      // Nothing to scroll: skip the Scrollbar entirely so the row looks
      // exactly as it did before.
      return child;
    }

    return Scrollbar(
      controller: _controller,
      thumbVisibility: widget.alwaysShowScrollbar || _canScroll,
      interactive: true,
      child: child,
    );
  }
}
