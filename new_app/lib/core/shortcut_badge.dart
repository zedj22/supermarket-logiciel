// Compact keyboard-key chip rendered next to an action's label.
//
// WHY: a cashier learns the POS from the buttons in front of them — the
// key that triggers the same action has to be visible ON the action, not
// only in the shortcuts help map. The chip is documentation painted onto
// the control: it never participates in key handling, so it cannot fire
// an action twice or shadow the real binding (pos_screen's
// CallbackShortcuts).
//
// The key text is passed IN — this widget never invents a binding. Call
// sites render the SAME PosShortcutKeys constants the shortcuts help
// dialog documents (lib/core/shortcuts.dart), so a badge can never drift
// from the registered key it points at.
//
// Two tones cover every background the chip rides: [ShortcutBadgeTone
// .primary] on plain and accent-tinted surfaces (the help map's look),
// [ShortcutBadgeTone.onColor] on solid filled buttons (PAY) where a
// primary chip would disappear into the fill. Key symbols are literal,
// never localized — they read the same in every locale (and in RTL the
// chip keeps its own LTR run: 'Shift+F7' must not reorder).
import 'package:flutter/material.dart';

/// Which color world the chip sits in.
enum ShortcutBadgeTone {
  /// Plain / accent-tinted surfaces: primary-tinted chip (the help map's
  /// key-badge look).
  primary,

  /// Solid filled buttons (PAY): an on-primary chip so the key stays
  /// legible against the fill, including the disabled grey.
  onColor,
}

/// A small rounded key chip — `'F6'`, `'Shift+F7'`, `'Space'` — sized to
/// sit inside a 36–60px action button next to its label without changing
/// the button's height.
class ShortcutBadge extends StatelessWidget {
  const ShortcutBadge(
    this.keys, {
    super.key,
    this.tone = ShortcutBadgeTone.primary,
    this.compact = false,
  });

  /// The literal key combination. Not user-visible prose — the same
  /// symbol string in every locale (see the help map's contract).
  final String keys;

  /// Background/foreground world — match the surface the chip rides.
  final ShortcutBadgeTone tone;

  /// Smaller chip for dense / short button chrome (reversed cart rows).
  final bool compact;

  /// The chip's exact laid-out width for [keys] in THIS context — padding,
  /// border and text scale included. [ShortcutBadgeLabel] uses it to decide
  /// BEFORE layout whether the chip fits next to its label, so a chip never
  /// appears and then overflows (RenderFlex always lays a non-flex child
  /// out at its intrinsic width, regardless of how little room is left).
  ///
  /// Mirrors [build] byte for byte: the same merged style the chip's own
  /// [Text] resolves (DefaultTextStyle of the call site — i.e. the button's
  /// textStyle — merged with the chip overrides), the same text scaler, the
  /// same horizontal padding and border.
  static double measureWidth(
    BuildContext context,
    String keys, {
    bool compact = false,
  }) {
    final style = DefaultTextStyle.of(context).style.merge(
          Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: compact ? 11.5 : 12.5,
                fontWeight: FontWeight.w700,
                height: 1.2,
                letterSpacing: 0.2,
              ),
        );
    final painter = TextPainter(
      text: TextSpan(text: keys, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width + (compact ? 4 : 5) * 2 + 2; // padding + border
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (bg, border, fg) = switch (tone) {
      ShortcutBadgeTone.primary => (
          cs.primary.withValues(alpha: 0.10),
          cs.primary.withValues(alpha: 0.35),
          cs.primary,
        ),
      ShortcutBadgeTone.onColor => (
          cs.onPrimary.withValues(alpha: 0.16),
          cs.onPrimary.withValues(alpha: 0.45),
          cs.onPrimary,
        ),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 4 : 5,
        vertical: compact ? 0.5 : 1,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: border),
      ),
      child: Text(
        keys,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: theme.textTheme.labelLarge?.copyWith(
          fontSize: compact ? 11.5 : 12.5,
          fontWeight: FontWeight.w700,
          height: 1.2,
          letterSpacing: 0.2,
          color: fg,
        ),
      ),
    );
  }
}

/// An action's label with its [ShortcutBadge], laid out so the chip can
/// never overflow the row it rides in.
///
/// WHY a dedicated widget: RenderFlex gives non-flex children their FULL
/// intrinsic width no matter how tight the row is, so a plain
/// `Row([Flexible(label), badge])` overflows whenever
/// `badge + gap > available` — the label cannot give up any of its share to
/// its sibling. This widget measures the chip up front
/// ([ShortcutBadge.measureWidth]) and only puts it in the row when the
/// measured chip, the gap and a minimum slice of the label
/// ([labelFloor]) all fit inside the width it was actually given. When
/// they don't, it falls back to the bare label — the exact pre-badge
/// layout, which never overflowed — and the words win over the key.
///
/// The chip text is never squeezed or wrapped: a badge is either fully
/// rendered or absent.
class ShortcutBadgeLabel extends StatelessWidget {
  const ShortcutBadgeLabel(
    this.label, {
    super.key,
    this.keys,
    this.tone = ShortcutBadgeTone.primary,
    this.compact = false,
    this.labelStyle,
    this.labelFloor = 44,
    this.dash = false,
  });

  /// The localized action name — plain prose, never the key text.
  final String label;

  /// The chip's keys ([PosShortcutKeys] constant) — `null` renders the
  /// label alone (e.g. PAY while Quick sale (Space) is ON).
  final String? keys;

  /// Chip color world — match the surface (see [ShortcutBadgeTone]).
  final ShortcutBadgeTone tone;

  /// Smaller chip for dense button chrome (see [ShortcutBadge.compact]).
  final bool compact;

  /// Explicit label style; `null` keeps the inherited default (the
  /// button's own textStyle), exactly as the bare [Text] would.
  final TextStyle? labelStyle;

  /// Minimum width the LABEL keeps once the chip is shown — below this the
  /// chip is dropped instead of reducing the words to a sliver. The chip
  /// always beats the label for space, but only down to this floor.
  final double labelFloor;

  /// PAY's baseline tail: a separate `' —'` between the chip and the
  /// amount. When the chip is dropped the tail joins the label text
  /// (`'Pay —'`), byte-for-byte the pre-badge layout.
  final bool dash;

  Widget _labelText({bool withTail = false}) => Text(
        withTail ? '$label —' : label,
        style: labelStyle,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      );

  @override
  Widget build(BuildContext context) {
    // Everything the row lays out besides the (flexible) label — the chip
    // and the PAY dash tail are non-flex, so this is what must fit before
    // the label earns its [labelFloor] slice.
    var nonLabel = 0.0;
    if (keys != null) {
      nonLabel += 6 +
          ShortcutBadge.measureWidth(context, keys!, compact: compact);
    }
    if (dash) {
      nonLabel += 6 + _textWidth(context, '—');
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.maxWidth;
        // Unbounded rows size to their content — there is no overflow to
        // avoid, so the chip always shows (button hugs label + chip).
        if (max.isFinite && max < nonLabel + labelFloor) {
          // No room for the chip without starving the words: fall back to
          // a single Text — it ellipsizes, it can never overflow.
          return _labelText(withTail: dash);
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: _labelText()),
            if (keys != null) ...[
              const SizedBox(width: 6),
              ShortcutBadge(keys!, tone: tone, compact: compact),
            ],
            if (dash) ...[
              const SizedBox(width: 6),
              const Text('—'),
            ],
          ],
        );
      },
    );
  }

  /// Width of [text] in the inherited default style — used for the PAY
  /// tail so the chip's fit check prices the dash too.
  static double _textWidth(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: DefaultTextStyle.of(context).style,
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    return painter.width;
  }
}
