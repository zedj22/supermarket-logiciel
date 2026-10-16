// Shared LTR display for numeric / monetary text (Klick POS).
//
// WHY: the app runs RTL under the Arabic locale, so every `Text` inherits a
// RTL paragraph direction.  The Unicode bidi algorithm treats the regular
// space we use for thousands grouping as a neutral character *between*
// number runs: in an RTL paragraph those group runs (and a trailing Latin
// currency suffix like `DA`) resolve to the embedding direction and get
// visually reordered —
//
//     logical : '217 915 895 577.85 DA'
//     RTL view: 'DA 577.85 915 895 217'   ← wrong
//     LTR view: '217 915 895 577.85 DA'   ← correct
//
// The fix is display-only: [numericText] builds the exact same `Text` the
// call site would have built, but with an explicit [TextDirection.ltr]
// paragraph direction so the formatted string renders in logical order.
// Surrounding layout (rows, cards, tables, pages) stays RTL — only the
// numeric paragraph flips.  Nothing is parsed, reformatted, or sent over
// the wire by this helper.
//
// USAGE:
// - Use [numericText] for any Text whose content is ONLY a formatted
//   number, money amount (with or without a `DA` / `%` suffix), quantity,
//   points or percentage — a standalone value.
// - For a label followed by such a value (`'الرصيد: 2 000'`, multi-segment
//   ledger meta), do NOT wrap the whole sentence: rule W7 of the bidi
//   algorithm still reverses grouped digits that follow an Arabic run
//   inside an LTR paragraph. Use a plain `Text` and wrap each money
//   segment in [bidiIsolateLtr] instead.
// - Keep pure-label Texts (Arabic sentences, section titles…) untouched —
//   they must remain RTL.
// - Never use these helpers to build payloads; they render the strings
//   they are given, verbatim (isolates are zero-width display controls).

import 'package:flutter/widgets.dart';

/// Unicode Left-to-Right Isolate (U+2066) and Pop Directional Isolate
/// (U+2069) — zero-width UBA controls honored by Flutter's text engine.
const String _lri = '\u2066';
const String _pdi = '\u2069';

/// Wraps a formatted money string (optionally with its currency suffix,
/// e.g. `'2 000'`, `'2 000 DA'`, `'-1 234.56 DA'`) so it renders as ONE
/// LTR bidi unit inside mixed-direction text.
///
/// WHY NOT [numericText] FOR ARABIC SENTENCES: forcing the whole
/// paragraph LTR does NOT fix an Arabic label followed by a grouped
/// amount. Bidi rule W7 turns European digits into RTL runs when a
/// strong right-to-left character precedes them *in the same paragraph*,
/// so `numericText('الرصيد: 2 000')` still renders the groups reversed
/// (`000 2`). Verified with RenderParagraph box proofs in
/// `numeric_text_test.dart`.
///
/// The isolate resolves the enclosed amount independently (first strong
/// character is a digit / sign → LTR), keeping:
/// - the surrounding sentence in its natural RTL (or LTR) order,
/// - grouping spaces, decimal separators, signs and the `DA` suffix in
///   logical left-to-right visual order,
/// - the payload/formatter strings untouched — isolation is a
///   zero-width display-only control, never parsed back.
///
/// USAGE: keep using [numericText] for STANDALONE amounts; for any
/// "Arabic label + amount" or multi-segment sentence, build a plain
/// `Text` and wrap each money segment with this helper.
String bidiIsolateLtr(String money) => '$_lri$money$_pdi';

/// Builds a [Text] that renders [data] in LTR order inside an RTL layout.
///
/// Forwards the everyday [Text] knobs so call sites can swap `Text(...)` →
/// `numericText(...)` one-for-one (keys, styles, alignment, overflow).
/// [TextDirection.ltr] is forced; everything else keeps its default
/// semantics.
///
/// ONLY for standalone amount strings. Mixed Arabic-label + amount
/// sentences must use a plain `Text` with [bidiIsolateLtr] segments —
/// see the helper's doc for the W7 pitfall.
Text numericText(
  String data, {
  Key? key,
  TextStyle? style,
  TextAlign? textAlign,
  TextOverflow overflow = TextOverflow.clip,
  int? maxLines,
  bool? softWrap,
  Locale? locale,
  StrutStyle? strutStyle,
  TextWidthBasis? textWidthBasis,
  TextHeightBehavior? textHeightBehavior,
  TextScaler? textScaler,
}) {
  return Text(
    data,
    key: key,
    style: style,
    textAlign: textAlign,
    textDirection: TextDirection.ltr,
    overflow: overflow,
    maxLines: maxLines,
    softWrap: softWrap,
    locale: locale,
    strutStyle: strutStyle,
    textWidthBasis: textWidthBasis,
    textHeightBehavior: textHeightBehavior,
    textScaler: textScaler,
  );
}
