// Application-level keyboard-wedge barcode scanner capture — "scan with
// NO search field focused" (Klick POS global barcode support).
//
// A keyboard-wedge scanner is an ordinary keyboard: it types a run of
// digits and presses Enter. The run must be captured at an app-level
// boundary so the ACTIVE screen can act on the code while the workspace
// is idle — no field requests focus, and with no field focused no burst
// is ever typed into a box (the one opt-in exception, the Add Product
// form, transits the focused field and is rolled back at Enter).
//
// Two listeners, because Flutter dispatches every key event through BOTH
// paths (`hardware_keyboard.dart` `handleRawKeyMessage` runs the
// [HardwareKeyboard] handlers FIRST, then [FocusManager.handleKeyMessage]
// — and returning true from a [HardwareKeyboard] handler does NOT stop
// the focus system; the focus tree always receives the event):
//
//  * [HardwareKeyboard.addHandler] — the capture state machine. It runs
//    for every event, even when no node has primary focus
//    (`handleKeyMessage` returns early in that case), and it decides
//    whether a key belongs to a scan.
//  * [FocusManager.addEarlyKeyEventHandler] — the consumer. It replays
//    only the decision (an [Expando] keyed on event identity — [KeyEvent]
//    does not override ==) and returns [KeyEventResult.handled] so the
//    focus tree never processes a captured key: no shortcut, no
//    onKeyEvent, no focus movement, no text insertion attempt.
//
// Arming rules — why the gateway never fights a human typist, a chord or
// a dialog (all checked per event before any buffer touch):
//
//  * an EditableText owns primary focus → the field's existing behavior
//    (typing, submits, per-field scan paths) runs untouched — unless the
//    topmost handler opted in with `allowWhileEditing` (the Add Product
//    form: a scan lands in its barcode field while any field is focused).
//    Those runs PASS THROUGH: no digit is consumed, every keystroke
//    reaches the focused field exactly as if the gateway were absent, and
//    Enter decides — a confident [kBarcodeScanShape] run is rolled back
//    to the field's pre-run text and dispatched as the scan, anything
//    else stays human typing in the field;
//  * Ctrl / Alt / Meta held → app shortcut chords stay untouched;
//  * this screen's route must be current, and the focused node must sit
//    inside this screen's subtree or inside a route that encloses it
//    (nav-shell chrome) — a modal dialog, or focus in another
//    navigator's route, blocks the scan (never scan behind a dialog);
//  * capture is digit-only and terminator-driven: KeyDown digits buffer,
//    Enter dispatches when the buffer matches [kBarcodeScanShape].
//    KeyUps never reset the buffer (wedge scanners interleave them per
//    character) and auto-repeat never extends it (holding one key can
//    never fake a burst).
//
// Scanner suspension — the dialog-side boundary (see
// [BarcodeScannerGateway.withScannerSuspended]): the route/focus gates
// above DISARM scanning behind a modal dialog, but disarming only means
// "no dispatch" — the keys themselves still fell through to the dialog's
// own focus tree, where a second burst could drive the digit shortcuts,
// the Enter confirmation and the quantity text field. A scoped
// suspension closes that hole for dialogs that declare it (the
// selling-unit picker and the quantity dialog): while a suspension token
// is held, NO burst may dispatch (the raw-PoC entry point is gated too),
// every run is reset on suspend/resume so nothing is ever queued or
// replayed, and tokens that START while suspended are captured instead of
// rejected:
//
//  * no text field focused (the unit picker) → the digit keys are
//    CONSUMED, so the dialog's 1–9 shortcut and its Enter confirmation
//    never see a scanner key (arrow keys, Enter with an empty buffer,
//    mouse and Escape are untouched — manual interaction is unaffected).
//    The one exception: a provably MANUAL digit — a numpad key or an
//    AZERTY Shift-digit (a scanner never sends numpad codes, never
//    sends Shift; see [_isProvablyManualDigit]) — passes through so the
//    picker's number-key selection keeps working. An unshifted main-row
//    digit is event-identical to a scanner's first key and stays
//    consumed: it can never select a unit;
//  * a dialog text field focused (the quantity/amount field) → the run
//    is PASS-THROUGH exactly like an `allowWhileEditing` run: human
//    typing keeps reaching the field untouched, and the terminator
//    restores the field's pre-run snapshot and CONSUMES the Enter
//    instead of dispatching or submitting — the burst is dropped, never
//    queued for after the dialog closes.
//
// A run whose shape or stage says "human" (a short digit run in a text
// field, an Enter with an empty buffer) passes through unchanged, so
// manual quantities, confirmations and cancels behave exactly as before.
//
// Distinction limit (documented, by design): the gateway can only tell
// "digit burst + Enter in a scope where digits have no consumer" from
// "nothing". A human typing the same shape with no field focused is
// indistinguishable from a scan — every such code goes through the
// canonical barcode lookup (lookup-first on all screens), so a miss
// degrades to not-found feedback and never selects the wrong product.
// Codes shorter than 6 digits, or alphanumeric codes, are only resolved
// through the focused search field (retail barcodes are 8/12/13 digits).
//
// EXPERIMENT — foreign-layout scanning (flag-gated, default OFF): on
// French AZERTY and many Arabic Windows layouts a US-configured
// scanner's number row arrives as layout symbols (`&é"'(-è_çà`), so
// the character-only capture above drops the burst. Two follow-ups
// were investigated:
//  * "Shift semantics": on AZERTY the ASCII digits live on the SHIFT
//    layer (Shift+& produces 1). The Flutter event pipeline cannot
//    supply "the shifted character of this key" — an event carries
//    only the character resolved for the CURRENT modifier state — and
//    Shift synthesis / OS input injection is forbidden, so this route
//    is a dead end inside Flutter.
//  * [BarcodeScannerGateway.experimentalPhysicalDigitCapture] (see the
//    class): capture on the PHYSICAL scan-code keys while no Shift is
//    held. Physical keys are layout-independent (scan-code 1:1 with
//    the US number row for a US-configured scanner), so this bypasses
//    the VK→logical-key mapping of the earlier logical-key attempt
//    that failed on field hardware. If this also fails on field
//    hardware, the device's events are not interpretable from the
//    Flutter stream — escalate to per-device scanner configuration
//    (keyboard country-code programming barcodes) or a Windows Raw
//    Input investigation; do NOT add character heuristics.
//
// The same limit governs `allowWhileEditing` runs from the other side:
// until Enter, a wedge burst in a focused field is indistinguishable
// from typing, so the digits MUST reach the field (consuming them is
// what silently ate digits typed into the form) and the terminator is
// the only confident moment — a ≥6-digit pure run ending in Enter while
// that form is open is taken as the scan and stripped from the field.
// The [kBarcodeRunStaleGap] rule keeps that honest for humans: a pause
// longer than the gap between two digits restarts the run, so slow
// typing never accumulates a scan-shaped buffer.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'barcode/barcode_normalizer.dart';
import 'keyboard.dart';
import 'scan_diagnostics.dart';

/// The shape of a keyboard-wedge burst: a digit run of at least 6
/// characters (EAN-8 / UPC-A / EAN-13 … are 8, 12 or 13 digits) ending
/// in Enter. Same family as `kPosBarcodeScanInput` (pos_qty_shortcuts.dart)
/// — the shared "a pure digit run of barcode length" fingerprint that
/// separates a scan from a human quantity (`1`, `12`, `10*24` + Enter
/// never dispatch).
final RegExp kBarcodeScanShape = RegExp(r'^\d{6,}$');

/// The longest pause that still counts as ONE burst — the framing rule
/// for EVERY run, not only pass-through ones.
///
/// A wedge types a character every few milliseconds. A pause longer than
/// this between two digits means the digits on either side of it belong
/// to DIFFERENT bursts, and the buffered residue is stale:
///
///  * inside a pass-through run, a human pausing is typing, not scanning
///    (slow typing can never accumulate into a scan-shaped buffer);
///  * inside a CONSUMED run, the earlier burst's terminator never
///    arrived (a lost Enter, a dialog that swallowed it, a scanner with
///    its suffix disabled). Without this rule the next physical scan
///    appends to that residue and ONE glued code is dispatched — the
///    characteristically inconsistent "sometimes it reads the wrong
///    barcode / says the product does not exist" symptom.
///
/// The next digit always drops the residue and starts a fresh, cleanly
/// framed run; nothing is queued or replayed, and a dispatch can only
/// ever carry digits of one burst. Bookkeeping only: it never delays or
/// consumes a keystroke, and events whose clock does not advance (the
/// zero-timestamp test seam) never qualify.
const Duration kBarcodeRunStaleGap = Duration(milliseconds: 400);

/// One buffered character: a single ASCII digit (the wedge types digits,
/// the numpad produces them through `character` too).
final RegExp _singleDigit = RegExp(r'^[0-9]$');

/// The main-row PHYSICAL digit keys in positional order: index == digit
/// value. Physical keys are scan-code derived (engine source — no
/// layout translation): for a US-configured keyboard-wedge scanner the
/// number row IS these keys on every Windows layout, which is the
/// strongest physical-key evidence the event stream carries. Numpad
/// keys are deliberately absent (NumLock-off numpad keys are
/// navigation and must never be captured; NumLock-on numpad digits
/// arrive as digit characters and take the character path).
const List<PhysicalKeyboardKey> _physicalMainRowDigitKeys =
    <PhysicalKeyboardKey>[
      PhysicalKeyboardKey.digit0,
      PhysicalKeyboardKey.digit1,
      PhysicalKeyboardKey.digit2,
      PhysicalKeyboardKey.digit3,
      PhysicalKeyboardKey.digit4,
      PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit6,
      PhysicalKeyboardKey.digit7,
      PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.digit9,
    ];

/// Index of the main-row physical digit [key] stands for (0–9), or -1
/// when [key] is not one.
int _physicalDigitIndexOf(PhysicalKeyboardKey key) =>
    _physicalMainRowDigitKeys.indexOf(key);

/// The numpad's digit keys — the digits a CASHIER presses by hand on a
/// POS keyboard, and the digits a keyboard-wedge scanner NEVER emits
/// (wedge scanners type bare main-number-row scan codes + Enter; the
/// capture tables above are main-row only by construction).
const List<PhysicalKeyboardKey> _physicalNumpadDigitKeys =
    <PhysicalKeyboardKey>[
      PhysicalKeyboardKey.numpad0,
      PhysicalKeyboardKey.numpad1,
      PhysicalKeyboardKey.numpad2,
      PhysicalKeyboardKey.numpad3,
      PhysicalKeyboardKey.numpad4,
      PhysicalKeyboardKey.numpad5,
      PhysicalKeyboardKey.numpad6,
      PhysicalKeyboardKey.numpad7,
      PhysicalKeyboardKey.numpad8,
      PhysicalKeyboardKey.numpad9,
    ];

/// Whether [key] is one of the numpad's digit keys.
bool _isNumpadDigitPhysical(PhysicalKeyboardKey key) =>
    _physicalNumpadDigitKeys.contains(key);

/// Whether this digit key-down can ONLY be a human's manual press —
/// never a keyboard-wedge scanner burst. Consulted ONLY while a scanner
/// suspension is active (the selling-unit dialogs): their 1–9 number
/// shortcut may see these keys while every scanner-shaped key stays
/// consumed. The two shapes rest on the codebase's own scanner model
/// ("a scanner never sends Shift"; wedge scanners type bare main-row
/// digit scan codes + Enter):
///
///  * a NUMPAD digit key (any layout, NumLock on: the engine delivers
///    the digit character) — no evidenced scanner sends numpad codes;
///  * a MAIN-ROW digit with Shift HELD delivering an ASCII digit
///    character — the AZERTY human digit (`Shift+2` → `2`; the ASCII
///    digits live on AZERTY's Shift layer). A US-layout `Shift+2`
///    produces `@`, not a digit character, so this shape cannot be a
///    scanner on any evidenced layout.
///
/// Everything else — an unshifted main-row digit, an AZERTY symbol, an
/// Arabic-Indic digit — stays claimed: at the FIRST digit of a burst it
/// is event-identical to a cashier's top-row press, and handing it to
/// the dialog would reopen the sold-by-accident bug.
bool _isProvablyManualDigit(KeyEvent event, {required bool characterDigit}) {
  if (_physicalDigitIndexOf(event.physicalKey) >= 0) {
    return characterDigit && _shiftPressed();
  }
  return _isNumpadDigitPhysical(event.physicalKey);
}

/// The ASCII digit a main-row physical digit key stands for — the key's
/// own scan-code ordinal (physical digit3 IS "the 3 key" on the US
/// row), never a translation of the layout-translated character (which
/// on a foreign layout would be a symbol).
String _digitFromPhysicalIndex(int index) => String.fromCharCode(0x30 + index);

/// Characters owned outright by the POS quantity-shortcut layer (`+`
/// and `*` — `pos_qty_shortcuts.dart` matches them by character on ANY
/// layout) that have NO evidence of appearing unshifted at any digit
/// position of the layouts this experiment is evidenced for (US,
/// AZERTY, Arabic 101 — all probed: none produces `+` or `*` on the
/// unshifted number row). They keep their owner, even on a digit
/// physical key.
///
/// `-` is deliberately NOT in this set: the AZERTY and Arabic number
/// rows produce it at the digit-6 position (probed), so a scanner's 6
/// IS that key — the scan meaning and the minus-shortcut meaning
/// collide by construction, and the scan wins exactly as it does for a
/// digit character (the documented distinction limit). The minus
/// shortcut remains available there through the numpad minus key, the
/// focused quantity field and the cart buttons.
const Set<String> _shortcutOwnedCharacters = {'+', '*'};

/// Whether a Shift key is currently held.
///
/// The experimental physical path never captures while Shift is down:
/// shifted keys always keep their produced-character semantics
/// (`Shift+8` is `*`, the POS quantity dialog — never a scan digit),
/// and a keyboard-wedge scanner never sends Shift (configuration
/// manuals; a scanner types bare digit scan codes + Enter). On AZERTY,
/// where the ASCII digits live on the Shift layer, a Shift-produced
/// digit character is already captured by the ordinary character path.
bool _shiftPressed() {
  final keyboard = HardwareKeyboard.instance;
  return keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftLeft) ||
      keyboard.isLogicalKeyPressed(LogicalKeyboardKey.shiftRight);
}

/// One screen's claim on global scans.
///
/// Registered on initState, unregistered on dispose — the gateway routes
/// each completed burst to the most recently registered handler whose
/// scope is currently on screen (screens never coexist in the shell, and
/// the reversed walk resolves the mount-before-unmount overlap of a
/// route swap to the NEW screen).
class BarcodeScanHandler {
  factory BarcodeScanHandler.forTextController({
    required BuildContext context,
    required String name,
    required TextEditingController controller,
    required ValueChanged<String> onScan,
  }) =>
      BarcodeScanHandler(
        context: context,
        name: name,
        allowWhileEditingFor: (editable) =>
            identical(editable.controller, controller),
        allowIncompletePassThrough: true,
        allowReplacementPassThrough: true,
        onScan: onScan,
      );

  BarcodeScanHandler({
    required this.onScan,
    this.context,
    this.name = 'screen',
    this.allowWhileEditing = false,
    this.allowWhileEditingFor,
    this.allowIncompletePassThrough = false,
    this.allowReplacementPassThrough = false,
  });

  /// Diagnostic label for this handler (`pos`, `products`, `stock`) —
  /// printed on `dispatch` so a dispatch that never produces a receive
  /// can be attributed to the screen that consumed it.
  final String name;

  /// The registering screen's build context — the scope every arming gate
  /// is evaluated against (route currency, subtree, enclosing routes).
  /// `null` only in tree-less unit tests, where the widget gates vacuously
  /// pass and only the capture rules apply.
  final BuildContext? context;

  /// Opt-in exception to the "a focused text field wins" rule: this
  /// handler may START a burst even while an [EditableText] owns primary
  /// focus (the Add Product form — a scan must land in the barcode field
  /// even while another field is being typed in). Runs started this way
  /// are PASS-THROUGH: no key is consumed, the focused field receives
  /// every digit as ordinary typing, and the run's snapshot is restored
  /// at Enter when the run turns out to be a scan (the field ends exactly
  /// where it started — typing is never silently eaten). Screens keep the
  /// default `false`: their runs consume every key, so a burst started
  /// with nothing focused is never half-typed into a field that takes
  /// focus mid-run.
  final bool allowWhileEditing;

  /// Optional narrower exception for a particular editable controller.
  /// Unlike [allowWhileEditing], this does not enable every text field in
  /// the screen (for example, POS quantity editors).
  final bool Function(EditableText editable)?
      allowWhileEditingFor;

  /// Some platform text-input paths can omit one or more layout-translated
  /// characters even though the gateway observed every physical digit key.
  /// When enabled for a dedicated scan field, a scanner-shaped run may be
  /// restored if the field contains only a bounded append to its snapshot.
  final bool allowIncompletePassThrough;

  /// A focused field may replace its current value with the first scanner
  /// character (rather than appending). Permit a verified scan run to roll
  /// the field back to its pre-run snapshot before dispatch.
  final bool allowReplacementPassThrough;

  /// Handles one completed burst (already matched [kBarcodeScanShape]).
  /// May be async; the gateway never awaits it.
  final void Function(String code) onScan;
}

/// App-level capture of keyboard-wedge barcode bursts.
///
/// Singleton: the app has exactly one hardware keyboard and one focus
/// manager, and exactly one screen owns "the active scan target" at a
/// time.
class BarcodeScannerGateway {
  BarcodeScannerGateway._();

  static final BarcodeScannerGateway instance = BarcodeScannerGateway._();

  /// EXPERIMENTAL: capture foreign-layout scanner bursts on the main-row
  /// PHYSICAL (scan-code) digit keys — see the file-header EXPERIMENT
  /// note and the capture comment in [_handleKeyEvent] for the full
  /// rationale, guardrails and escalation path.
  ///
  /// Default OFF: with the flag down, the gateway is exactly the
  /// character-only capture that shipped before this experiment (English
  /// US and correctly configured scanners, numpads) — the experiment can
  /// be field-tested and disabled without touching that behavior. Flip to
  /// `true` for a hardware session; [resetForTest] restores the default
  /// between tests.
  @visibleForTesting
  static bool experimentalPhysicalDigitCapture = false;

  final List<BarcodeScanHandler> _handlers = <BarcodeScanHandler>[];

  /// Digits of the burst in progress (cleared by Enter, by any non-scan
  /// key, and whenever the gateway abandons a run).
  final StringBuffer _buffer = StringBuffer();

  // Diagnostic-only observations since the last Enter. These counters do
  // not participate in capture or arming; they let a Windows hardware run
  // distinguish digit characters from layout-translated physical keys
  // without logging any key character or barcode content.
  int _diagCharacterDigitKeyDowns = 0;
  int _diagPhysicalDigitKeyDowns = 0;
  int _diagOtherKeyDowns = 0;
  int _scanAttemptSequence = 0;
  int? _activeScanAttemptId;
  int? _dispatchingScanAttemptId;

  /// True only while a scanner burst is being captured or synchronously
  /// handed to its scan callback. POS quantity shortcuts consult this
  /// boundary so layout translated barcode symbols cannot trigger them.
  bool get isScanAttemptActive =>
      _activeScanAttemptId != null || _dispatchingScanAttemptId != null;

  /// Decision handoff between the two listeners: events the capture
  /// state machine consumed. Weak, identity-keyed ([KeyEvent] has no ==
  /// override), so entries die with the event objects themselves.
  final Expando<bool> _consumed = Expando<bool>(
    'barcode_scanner_consumed_event',
  );
  final Expando<bool> _scannerOwnedShortcutEvents = Expando<bool>(
    'barcode_scanner_owned_shortcut_event',
  );
  final Set<PhysicalKeyboardKey> _scanPhysicalKeysDown =
      <PhysicalKeyboardKey>{};

  /// Pass-through run state (an `allowWhileEditing` run started while an
  /// [EditableText] holds focus): whether the current run transits that
  /// field, which handler and controller it belongs to, and the field's
  /// pre-run value — the snapshot the terminator restores when the run is
  /// a scan. All five live and die with [_buffer] (see [_resetBuffer]).
  bool _runThrough = false;

  /// Whether any digit of the current run was captured through the
  /// EXPERIMENTAL physical-key path (the character was foreign layout
  /// text, not an ASCII digit — only possible while
  /// [experimentalPhysicalDigitCapture] is on). Such a run transited
  /// the focused field as layout-translated text, so the terminator's
  /// restore check matches by snapshot prefix and per-digit growth
  /// instead of exact ASCII text.
  bool _runThroughForeign = false;
  final StringBuffer _runThroughText = StringBuffer();
  BarcodeScanHandler? _runThroughHandler;
  TextEditingController? _runThroughController;
  TextEditingValue? _runThroughValue;

  /// The focus context a pass-through run started under — the liveness
  /// gate for a run that has NO owning screen (a scanner-suspension
  /// protection run inside a dialog): the terminator may only write the
  /// snapshot back while that dialog element is still mounted, so an
  /// asynchronous burst can never mutate a disposed dialog.
  BuildContext? _runThroughContext;

  /// The timestamp of the last digit appended to the current run —
  /// staleness input for pass-through runs ([kBarcodeRunStaleGap]).
  Duration? _lastDigitAt;

  /// Cross-origin duplicate record — the last SUCCESSFULLY dispatched
  /// code, its origin, and the wall-clock millisecond of that dispatch
  /// (see [_dropCrossOriginDuplicate]).
  String? _dupLastCode;
  bool _dupLastFromRaw = false;
  int _dupLastAtMs = 0;

  /// Window in which the SAME code arriving from the OTHER dispatch
  /// origin counts as the same physical burst.
  ///
  /// The two observations of ONE burst — the raw-PoC decoder's terminator
  /// and the legacy Enter key-down — land within milliseconds of each
  /// other. A deliberate re-scan of the same product is a new trigger
  /// pull and decode: ~100 ms or more. The window must therefore stay
  /// tight: at 250 ms it swallowed the NEXT scan of one product whenever
  /// the previous one happened to be observed by the raw path (the
  /// "re-scanning does not always increment" symptom). Same-origin
  /// repeats are never matched anyway (see [_dropCrossOriginDuplicate]).
  static const int kCrossOriginDispatchDupMs = 80;

  /// Active scoped suspensions — one opaque token per open dialog that
  /// declared scanner suspension (the selling-unit picker and the
  /// quantity dialog). The gateway is suspended while AT LEAST ONE token
  /// is held, so nested dialogs (quantity stacked on the picker) keep
  /// protection until each of them has closed.
  final List<Object> _suspensions = <Object>[];

  /// Whether a scoped scanner suspension is active — see the file header
  /// "Scanner suspension" section for what it changes.
  bool get isScannerSuspended => _suspensions.isNotEmpty;

  /// Begins a scoped suspension owned by [token]. Idempotent per token;
  /// any run in progress is abandoned immediately so a half-typed burst
  /// can never bridge into the dialog.
  void suspendScans(Object token) {
    if (_suspensions.contains(token)) return;
    _suspensions.add(token);
    _resetBuffer();
    scanDiag('scanner-suspend', {'phase': 'open'});
  }

  /// Ends the suspension owned by [token]. Unknown/already-released
  /// tokens are ignored, so the dialog's widget guard and its route
  /// future may both call this safely. The buffer reset guarantees a
  /// burst swallowed inside the dialog can never leak out of it.
  void resumeScans(Object token) {
    if (!_suspensions.remove(token)) return;
    _resetBuffer();
    scanDiag('scanner-resume', {'phase': 'close'});
  }

  /// Runs [body] with a scanner suspension held for its whole duration —
  /// suspended from the moment the dialog future is created (before the
  /// route is even pushed) until the future completes (the pop). [body]
  /// receives the suspension token so it can place a
  /// [ScannerSuspensionGuard] inside the dialog: the guard releases the
  /// SAME token when the dialog element unmounts, covering route
  /// teardown where the future never completes. Whichever fires first
  /// releases the token; the second call is a no-op.
  Future<T> withScannerSuspended<T>(
    Future<T> Function(Object token) body,
  ) async {
    final token = Object();
    suspendScans(token);
    try {
      return await body(token);
    } finally {
      resumeScans(token);
    }
  }

  /// Installs (or re-arms) the listeners and claims [handler] as the
  /// current scan target.
  ///
  /// Remove-then-add on EVERY call, deliberately: the test binding wipes
  /// all [HardwareKeyboard] handlers and swaps the [FocusManager] after
  /// each test, so a remembered "installed" flag would go stale and the
  /// next screen would silently not scan. Tear-offs of the same instance
  /// method compare equal, so this always leaves exactly one of each.
  void register(BarcodeScanHandler handler) {
    _handlers.remove(handler); // idempotent re-registration
    _handlers.add(handler);
    _resetBuffer();
    final keyboard = HardwareKeyboard.instance;
    keyboard.removeHandler(_handleKeyEvent);
    keyboard.addHandler(_handleKeyEvent);
    final focus = FocusManager.instance;
    focus.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    focus.addEarlyKeyEventHandler(_handleEarlyKeyEvent);
  }

  /// Drops [handler]; removes both listeners once no screen claims the
  /// scan target anymore (nothing to capture for).
  void unregister(BarcodeScanHandler handler) {
    if (!_handlers.remove(handler)) return;
    if (_handlers.isNotEmpty) return;
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    FocusManager.instance.removeEarlyKeyEventHandler(_handleEarlyKeyEvent);
    _resetBuffer();
  }

  /// EXPERIMENTAL (raw-input PoC) entry point: dispatch an EXTERNALLY
  /// decoded code — one the raw-scanner path reconstructed from the
  /// scanner device's own MakeCodes, with the legacy key messages
  /// suppressed before the engine ever saw them — through the same owner
  /// resolution and arming gates as the Enter terminator.
  ///
  /// No pass-through restore can be needed: the suppressed digits never
  /// reached a focused field, so there is nothing to roll back (the
  /// [BarcodeScanHandler.allowWhileEditing] form receives the code through
  /// its [BarcodeScanHandler.onScan] exactly like any other scan).
  /// [kBarcodeScanShape] still decides what may dispatch; diagnostics
  /// report the raw origin as its own event name (`raw-dispatch`) so a
  /// hardware session can tell the two paths apart.
  bool dispatchExternalScan(String code) {
    // Suspended dialog: the raw path must be ignored exactly like the
    // key path — no dispatch, no duplicate record, nothing queued for
    // after the dialog closes.
    if (isScannerSuspended) {
      scanDiag('dispatch-drop', {
        'reason': 'scanner-suspended',
        'len': code.length,
        'suffix3': scanDiagSuffix3(code),
      });
      return false;
    }
    if (!kBarcodeScanShape.hasMatch(code)) {
      scanDiag('dispatch-drop', {'reason': 'shape', 'len': code.length});
      return false;
    }
    final owner = _activeHandler();
    if (owner == null) {
      scanDiag('dispatch-drop', {
        'reason': 'no-owner',
        'len': code.length,
        'suffix3': scanDiagSuffix3(code),
      });
      return false;
    }
    // Rule 8 — one burst, one action: the native suppression that keeps
    // legacy key messages off the raw path is best-effort with a
    // documented order-violation window, so the legacy Enter dispatch may
    // already have handed THIS run to a handler moments ago (or vice
    // versa below). Only reached with a live owner, so a dropped
    // observation here can never suppress the other origin's legitimate
    // dispatch — it just refuses to act twice.
    if (_dropCrossOriginDuplicate(code, fromRaw: true)) {
      scanDiag('dispatch-drop', {
        'reason': 'cross-origin-duplicate',
        'len': code.length,
        'suffix3': scanDiagSuffix3(code),
      });
      return false;
    }
    // Same correlation contract as the Enter path — the id below is what
    // every downstream hop (scan-receive / scan-resolve / cart-add) reads.
    lastScanCorr = scanDiag('raw-dispatch', {
      'len': code.length,
      'suffix3': scanDiagSuffix3(code),
      'target': owner.name,
    });
    scanDiag('scan-dispatch', {
      'phase': 'attempt',
      'origin': 'raw-input',
      'target': owner.name,
      'len': code.length,
      'result': 'attempted',
    });
    _dispatchingScanAttemptId = ++_scanAttemptSequence;
    try {
      owner.onScan(code);
    } finally {
      _dispatchingScanAttemptId = null;
    }
    scanDiag('scan-dispatch', {
      'phase': 'complete',
      'origin': 'raw-input',
      'target': owner.name,
      'len': code.length,
      'result': 'callback-invoked',
    });
    return true;
  }

  /// Cross-origin duplicate suppression for completed dispatches: true =
  /// [code] was ALREADY dispatched from the other origin within
  /// [kCrossOriginDispatchDupMs] and this observation must be dropped.
  ///
  /// Only a dispatch that is about to reach a handler updates the record
  /// (a dropped attempt — no-owner, shape — never does), so the raw path
  /// being disarmed (dialog open, focused field) leaves the legacy path
  /// free to act, and vice versa. Same-origin repeats never match: rapid
  /// re-scans of one product must each add their own line.
  bool _dropCrossOriginDuplicate(String code, {required bool fromRaw}) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (code == _dupLastCode &&
        fromRaw != _dupLastFromRaw &&
        nowMs - _dupLastAtMs <= kCrossOriginDispatchDupMs) {
      return true;
    }
    _dupLastCode = code;
    _dupLastFromRaw = fromRaw;
    _dupLastAtMs = nowMs;
    return false;
  }

  /// Capture state machine — the [HardwareKeyboard] half. Runs for every
  /// key event, before the focus system sees it.
  ///
  /// A run ONCE started belongs to the gateway until its terminator: a
  /// default run consumes every digit from the focus system, so a
  /// same-route focus move mid-run (the post-add refocus landing inside
  /// the next physical burst) does NOT truncate it — the remainder must
  /// never be retyped into the field that just took focus (that is how
  /// barcode prefixes became quantities). An `allowWhileEditing`
  /// pass-through run claims the digits without consuming them (the
  /// focused field keeps them until Enter restores its snapshot).
  /// Hard gates still abandon a run: a dialog/route change, a modifier
  /// chord or a dead screen.
  bool _handleKeyEvent(KeyEvent event) {
    // Track physical key-up/repeat events separately from the barcode
    // buffer. A repeat of a scanner-owned `Digit 6` must not fall through
    // to POS '-' while the burst remains active.
    if (event is KeyUpEvent) {
      _scanPhysicalKeysDown.remove(event.physicalKey);
      return false;
    }
    if (event is KeyRepeatEvent) {
      final attemptId = _activeScanAttemptId ?? _dispatchingScanAttemptId;
      final handlerName = _posQuantityShortcutFor(event);
      if (attemptId != null &&
          _scanPhysicalKeysDown.contains(event.physicalKey) &&
          handlerName != null) {
        _logSuppressedPosShortcut(event, attemptId, handlerName);
        _consumed[event] = true;
        return true;
      }
      return false;
    }
    // Only key-downs build or terminate a scan. A stray up or repeat never
    // appends to the barcode buffer (a held key cannot fabricate a code).
    if (event is! KeyDownEvent) return false;

    final logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.enter ||
        logicalKey == LogicalKeyboardKey.numpadEnter) {
      final rawCode = _buffer.toString();
      final code = normalizeScannerBarcode(rawCode);
      final attemptId = _activeScanAttemptId;
      if (rawCode.isNotEmpty) {
        scanDiag('scan-terminator', {
          'attemptId': attemptId,
          'rawLength': rawCode.length,
          'normalizedLength': code.length,
          'normalized': rawCode != code,
          'validShape': kBarcodeScanShape.hasMatch(code),
          'runThrough': _runThrough,
        });
      }
      if (scanDiagObservationEnabled) {
        scanDiag('key-burst-observed', {
          'characterDigits': _diagCharacterDigitKeyDowns,
          'physicalDigits': _diagPhysicalDigitKeyDowns,
          'otherKeys': _diagOtherKeyDowns,
          'bufferedDigits': code.length,
          'editableFocus': editableTextHasFocus(),
        });
      }
      _diagCharacterDigitKeyDowns = 0;
      _diagPhysicalDigitKeyDowns = 0;
      _diagOtherKeyDowns = 0;
      // Capture the pass-through run state BEFORE the reset: the
      // terminator below must still know which field the digits transited
      // and where it started.
      final runThrough = _runThrough;
      final runThroughForeign = _runThroughForeign;
      final runThroughText = _runThroughText.toString();
      final runThroughHandler = _runThroughHandler;
      final runThroughController = _runThroughController;
      final runThroughValue = _runThroughValue;
      final runThroughContext = _runThroughContext;
      // Suspension is sampled BEFORE the reset: the reset cannot end the
      // suspension (it holds no token), but a run CAN be terminated in
      // the same turn a dialog closes — whichever the terminator sees is
      // the state that governs this event.
      final suspended = isScannerSuspended;
      _resetBuffer();
      if (code.isNotEmpty && kBarcodeScanShape.hasMatch(code)) {
        // Pass-through terminator: the burst was never consumed, it
        // transited the focused field — the field must end exactly where
        // it started before the dispatch may proceed. The liveness gate:
        // a screen-owned run proves safety by still being registered (its
        // dialog unregisters BEFORE disposing the very controller held
        // here); a suspension run has no screen, so its dialog element
        // must still be mounted.
        final runAlive = runThroughHandler != null
            ? _handlers.contains(runThroughHandler)
            : runThroughContext?.mounted ?? false;
        if (runThrough &&
            runAlive &&
            runThroughController != null &&
            runThroughValue != null) {
          // A suspension protection run has no handler flags: it may
          // restore whatever landed (identical allowances to the POS
          // handler — bounded append or replacement of the snapshot).
          final allowIncompletePassThrough =
              runThroughHandler?.allowIncompletePassThrough ?? true;
          final allowReplacementPassThrough =
              runThroughHandler?.allowReplacementPassThrough ?? true;
          final text = runThroughController.text;
          final snapshot = runThroughValue.text;
          final appendedText = text.startsWith(snapshot)
              ? text.substring(snapshot.length)
              : null;
          final partialRunMatches =
              allowIncompletePassThrough &&
              appendedText != null &&
              appendedText.length <= runThroughText.length &&
              _isSubsequence(appendedText, runThroughText);
          final replacementRunMatches =
              allowReplacementPassThrough &&
              text.length <= runThroughText.length &&
              _isSubsequence(text, runThroughText);
          // The field must show the snapshot followed by EXACTLY this
          // run. A US (character-digit) run lands as the ASCII code
          // itself, matched verbatim. A foreign-layout run transited the
          // field as layout-translated text (`&é"'(` on AZERTY) — the
          // text can never equal snapshot + ASCII code — so it is
          // matched by what the real device guarantees: the snapshot is
          // untouched and the field grew by exactly one UTF-16 unit per
          // buffered digit (every key a wedge presses produces exactly
          // one such unit). Same confidence, same restore; nothing is
          // ever remapped.
          final matchesRun = runThroughForeign
              ? text.startsWith(snapshot) &&
                    (text.length ==
                            snapshot.length +
                                rawCode.length ||
                        partialRunMatches || replacementRunMatches)
              : text == snapshot + code ||
                    partialRunMatches ||
                    replacementRunMatches;
          if (matchesRun) {
            // The whole burst landed in the field (real device): strip
            // it — the dispatch below routes the code to the barcode.
            runThroughController.value = runThroughValue;
          } else if (text != snapshot) {
            // The field changed beyond this run (human edited mid-run):
            // never dispatch, never restore — this is typing, and the
            // edit stands exactly as the user left it.
            scanDiag('dispatch-drop', {
              'reason': 'field-diverged',
              'len': code.length,
              'suffix3': scanDiagSuffix3(code),
            });
            // Outside a suspension the run simply ends here. Inside one
            // the terminator still belongs to the scanner: keep the
            // human's edit, but fall through to the suspension drop so
            // this Enter can never submit the dialog either.
            if (!suspended) return false;
          }
          // text == snapshot: nothing reached the field (a key-ignoring
          // widget or the test pipeline) — dispatch with no restore.
        }
        // Suspended dialog: a completed burst is NEVER an action. The
        // field snapshot (if any) has already been restored above; now
        // swallow the terminator so it cannot confirm the dialog, and
        // drop the code without queueing it — the cashier must scan
        // again once the dialog is gone.
        if (suspended) {
          scanDiag('dispatch-drop', {
            'attemptId': attemptId,
            'reason': 'scanner-suspended',
            'len': code.length,
            'suffix3': scanDiagSuffix3(code),
          });
          _consumed[event] = true;
          return true;
        }
        // Not (or no longer) a restorable pass-through: a default
        // consumed run, or a dialog that closed mid-run — dispatch
        // without touching any field.
        final owner = _runOwner();
        if (owner != null) {
          _consumed[event] = true;
          // Rule 8 — one burst, one action: the raw-PoC decoder may have
          // dispatched this very run through [dispatchExternalScan]
          // moments ago (the native suppression's order-violation
          // window lets both observations through). The run is still
          // consumed — it IS a scan shape, never typing — but the ACTION
          // belongs to exactly one dispatch.
          if (_dropCrossOriginDuplicate(code, fromRaw: false)) {
            scanDiag('dispatch-drop', {
              'attemptId': attemptId,
              'reason': 'cross-origin-duplicate',
              'len': code.length,
              'suffix3': scanDiagSuffix3(code),
            });
            return true;
          }
          // `dispatch` is an ORIGIN: its seq id becomes the correlation id
          // of every downstream hop (scan-receive / scan-resolve /
          // cart-add). `target` names the screen that will consume it —
          // a dispatch with no matching receive can be attributed.
          lastScanCorr = scanDiag('dispatch', {
            'len': code.length,
            'suffix3': scanDiagSuffix3(code),
            'target': owner.name,
          });
          scanDiag('scan-dispatch', {
            'attemptId': attemptId,
            'phase': 'attempt',
            'target': owner.name,
            'len': code.length,
            'result': 'attempted',
          });
          _dispatchingScanAttemptId = attemptId;
          try {
            owner.onScan(code);
          } finally {
            _dispatchingScanAttemptId = null;
          }
          scanDiag('scan-dispatch', {
            'attemptId': attemptId,
            'phase': 'complete',
            'target': owner.name,
            'len': code.length,
            'result': 'callback-invoked',
          });
          return true;
        }
        // Shape-matching run but no live owner (dialog, dead screen,
        // gates): the consumed digits must never be silently dropped —
        // say so with an explicit reason.
        scanDiag('dispatch-drop', {
          'attemptId': attemptId,
          'reason': 'no-owner',
          'len': code.length,
          'suffix3': scanDiagSuffix3(code),
        });
      } else if (code.isNotEmpty) {
        // Digits were claimed (armed run) but Enter showed they were not
        // barcode-shaped — a human quantity: consumed runs dropped them
        // on purpose, pass-through runs left them in the focused field.
        scanDiag('dispatch-drop', {
          'attemptId': attemptId,
          'reason': 'shape',
          'len': code.length,
        });
        // Suspended with a CONSUMED run (the unit picker's stage): this
        // Enter must never fall through to the dialog's confirmation —
        // the digits it accompanies are not barcode-shaped, but nothing
        // here can tell them from a scanner's truncated burst, and a
        // false confirmation would silently sell the default unit. A
        // pass-through run (the quantity field) keeps the Enter: it is
        // manual typing submitting its own value.
        if (suspended && !runThrough) {
          _consumed[event] = true;
          return true;
        }
      }
      // Empty / too short / no live owner: an ordinary Enter — shortcuts,
      // submits and buttons keep it.
      return false;
    }

    final character = event.character;
    // Ordinary capture, UNCHANGED: an ASCII digit in `character` (US and
    // correctly configured scanners, NumLock-on numpads — and, on AZERTY,
    // the Shift layer a FR-configured scanner or a human produces).
    final characterDigit =
        character != null &&
        character.isNotEmpty &&
        _singleDigit.hasMatch(character);
    final physicalDigitIndex = _physicalDigitIndexOf(event.physicalKey);
    final azertySymbol = character != null &&
        _azertyScannerCharacters.contains(character) &&
        physicalDigitIndex >= 0 &&
        !_shiftPressed();
    final arabicDigit = character != null &&
        character.runes.length == 1 &&
        physicalDigitIndex >= 0 &&
        ((character.runes.single >= 0x0660 &&
                character.runes.single <= 0x0669) ||
            (character.runes.single >= 0x06F0 &&
                character.runes.single <= 0x06F9));
    final scannerTokenCharacter = characterDigit || azertySymbol || arabicDigit;
    if (scanDiagObservationEnabled) {
      if (scannerTokenCharacter && characterDigit) {
        _diagCharacterDigitKeyDowns++;
      }
      if (physicalDigitIndex >= 0 && scannerTokenCharacter) {
        _diagPhysicalDigitKeyDowns++;
      }
      if (_buffer.isNotEmpty && !scannerTokenCharacter) {
        _diagOtherKeyDowns++;
      }
    }
    // EXPERIMENTAL, gated by [experimentalPhysicalDigitCapture] (default
    // OFF): capture on the PHYSICAL key identity — the scan code, 1:1
    // with the US number row for a US-configured scanner on ANY Windows
    // layout (physical keys are scan-code derived; no layout translation
    // is involved). This bypasses the VK→logical-key mapping of the
    // earlier logical-key attempt that failed on field hardware. Two
    // ownership rules keep other key consumers safe: a held Shift
    // (shifted keys keep their produced character — `Shift+8` stays the
    // `*` shortcut; a scanner never sends Shift) and the shortcut-owned
    // `+`/`*` characters (no evidenced number row produces them
    // unshifted at a digit position). The buffered digit comes from the
    // PHYSICAL key's own scan-code ordinal — never from mapping the
    // character (no symbol-to-digit table, no Shift synthesis, no layout
    // modification anywhere). With the flag down this branch never
    // runs: `digit` stays null for every non-character-digit event and
    // the gateway behaves exactly as before the experiment.
    String? digit;
    String? captureOrigin;
    if (scannerTokenCharacter) {
      digit = character;
      captureOrigin = characterDigit
          ? 'character'
          : azertySymbol
          ? 'azerty-symbol'
          : 'arabic-digit';
    } else if (experimentalPhysicalDigitCapture) {
      final blocked =
          _shiftPressed() ||
          (character != null &&
              character.isNotEmpty &&
              _shortcutOwnedCharacters.contains(character));
      if (physicalDigitIndex >= 0 && !blocked) {
        digit = _digitFromPhysicalIndex(physicalDigitIndex);
        captureOrigin = 'physical-key';
      }
    }
    if (digit == null && physicalDigitIndex >= 0) {
      final rejectionReason = character == null
          ? 'no-character'
          : _shiftPressed() && _azertyScannerCharacters.contains(character)
          ? 'shift-modifier'
          : _shortcutOwnedCharacters.contains(character)
          ? 'shortcut-owned'
          : experimentalPhysicalDigitCapture
          ? 'unsupported-layout-character'
          : 'layout-character-unmapped';
      if (character == null || !characterDigit) {
        scanDiag('scan-key-rejected', {
          'origin': 'physical-key',
          'reason': rejectionReason,
          'bufferBefore': _buffer.length,
          'bufferAfter': _buffer.length,
        });
      }
    }
    if (digit != null) {
      final bufferBefore = _buffer.length;
      // Suspended dialog, provably manual digit: a numpad key or an
      // AZERTY Shift-digit a scanner cannot emit (see
      // [_isProvablyManualDigit]). The selling-unit picker's 1–9 number
      // shortcut (and the quantity field's typing) receives it exactly
      // as if no scanner layer existed — no buffer touch, nothing to
      // restore later. The empty-buffer condition keeps a run already in
      // progress intact: a digit arriving MID-burst belongs to the burst
      // and may never double as a dialog shortcut.
      if (isScannerSuspended &&
          _buffer.isEmpty &&
          _isProvablyManualDigit(event, characterDigit: characterDigit)) {
        scanDiag('scan-key-rejected', {
          'origin': captureOrigin,
          'reason': 'manual-digit',
          'bufferBefore': bufferBefore,
          'bufferAfter': bufferBefore,
        });
        return false;
      }
      // Burst framing, applied to EVERY run: a pause longer than
      // [kBarcodeRunStaleGap] between this digit and the previous one
      // means they belong to different bursts — the buffered residue and
      // (for pass-through runs) its field snapshot are stale, so they are
      // dropped and this digit is evaluated as a fresh START below. This
      // is what keeps a run whose terminator never arrived from gluing
      // itself onto the NEXT scan and dispatching one impossible code; a
      // run that did receive its terminator has no residue at all (the
      // buffer is reset at dispatch), so fast consecutive scans and fast
      // double-scans of one product are untouched. Bookkeeping only: this
      // digit is never delayed or consumed by the check.
      final lastDigitAt = _lastDigitAt;
      if (lastDigitAt != null &&
          event.timeStamp > lastDigitAt &&
          event.timeStamp - lastDigitAt > kBarcodeRunStaleGap) {
        scanDiag('run-abandon', {
          'attemptId': _activeScanAttemptId,
          'reason': 'stale-gap',
          'len': _buffer.length,
          'runThrough': _runThrough,
        });
        _resetBuffer();
      }
      if (_buffer.isEmpty) {
        // START: full arming — a focused text field, a chord, a dialog or
        // a dead screen means this digit belongs to the field/shortcut,
        // never to the gateway. The one exception is a SUSPENDED dialog:
        // with no armed screen the digit is captured as a protection run
        // (see the file header "Scanner suspension") instead of being
        // handed to the dialog's digit shortcut.
        final owner = _activeHandler();
        if (owner == null && !isScannerSuspended) {
          scanDiag('scan-key-rejected', {
            'origin': captureOrigin,
            'reason': 'no-active-handler',
            'bufferBefore': bufferBefore,
            'bufferAfter': _buffer.length,
          });
          return false;
        }
        _buffer.write(digit);
        _activeScanAttemptId = ++_scanAttemptSequence;
        _lastDigitAt = event.timeStamp;
        // Non-character digit = the experimental physical path fired:
        // the field will receive layout-translated text, so the
        // terminator must match by growth, not exact ASCII.
        if (!characterDigit) _runThroughForeign = true;
        final editable = _focusedEditable();
        // Screen-owned runs keep their own `allowWhileEditing` rule. A
        // suspension run has no owner and no handler flags: an owned
        // field means the run may pass through (the dialog's quantity /
        // amount field keeps manual typing intact); no owned field means
        // the digit is consumed so the picker's 1–9 shortcut never fires.
        if (editable != null &&
            (owner == null || _allowsWhileEditing(owner, editable))) {
          // Pass-through run: the digit reaches this field as ordinary
          // typing (NOT consumed — that is the whole point: typing in
          // the form must work), and the snapshot taken here is
          // restored at Enter when the run turns out to be a scan.
          _runThrough = true;
          _runThroughHandler = owner;
          _runThroughController = editable.controller;
          _runThroughValue = editable.controller.value;
          // Suspension runs have no registered handler to prove their
          // dialog is still alive at the terminator — the focus context
          // they started under plays that role instead.
          _runThroughContext = owner == null
              ? FocusManager.instance.primaryFocus?.context
              : null;
          _runThroughText
            ..clear()
            ..write(character ?? digit);
          _scanPhysicalKeysDown.add(event.physicalKey);
          scanDiag('scan-key', {
            'attemptId': _activeScanAttemptId,
            'phase': 'start',
            'origin': captureOrigin,
            'accepted': true,
            'bufferBefore': bufferBefore,
            'bufferAfter': _buffer.length,
          });
          final shortcutHandler = _posQuantityShortcutFor(event);
          if (shortcutHandler != null) {
            _scannerOwnedShortcutEvents[event] = true;
            _logSuppressedPosShortcut(
              event,
              _activeScanAttemptId!,
              shortcutHandler,
            );
          }
          return false;
        }
        _scanPhysicalKeysDown.add(event.physicalKey);
        scanDiag('scan-key', {
          'attemptId': _activeScanAttemptId,
          'phase': 'start',
          'origin': captureOrigin,
          'accepted': true,
          'bufferBefore': bufferBefore,
          'bufferAfter': _buffer.length,
        });
        final shortcutHandler = _posQuantityShortcutFor(event);
        if (shortcutHandler != null) {
          _logSuppressedPosShortcut(
            event,
            _activeScanAttemptId!,
            shortcutHandler,
          );
        }
        _consumed[event] = true;
        return true;
      }
      // CONTINUE: the run's earlier digits were already claimed here;
      // only hard gates (dialog, chord, dead screen) may abandon it. A
      // suspension protection run has no registered owner by design —
      // the suspension itself is its gate, so it never abandons here.
      if (_runOwner() == null && !isScannerSuspended) {
        scanDiag('scan-key-rejected', {
          'attemptId': _activeScanAttemptId,
          'origin': captureOrigin,
          'reason': 'run-owner-lost',
          'bufferBefore': bufferBefore,
          'bufferAfter': _buffer.length,
        });
        scanDiag('run-abandon', {
          'attemptId': _activeScanAttemptId,
          'reason': 'gates',
          'len': _buffer.length,
        });
        _resetBuffer();
        return false;
      }
      _buffer.write(digit);
      _lastDigitAt = event.timeStamp;
      _scanPhysicalKeysDown.add(event.physicalKey);
      if (!characterDigit) _runThroughForeign = true;
      if (_runThrough) _runThroughText.write(character ?? digit);
      scanDiag('scan-key', {
        'attemptId': _activeScanAttemptId,
        'phase': 'continue',
        'origin': captureOrigin,
        'accepted': true,
        'bufferBefore': bufferBefore,
        'bufferAfter': _buffer.length,
      });
      final shortcutHandler = _posQuantityShortcutFor(event);
      if (shortcutHandler != null) {
        if (_runThrough) _scannerOwnedShortcutEvents[event] = true;
        _logSuppressedPosShortcut(
          event,
          _activeScanAttemptId!,
          shortcutHandler,
        );
        if (_runThrough) return false;
        _consumed[event] = true;
        return true;
      }
      // A pass-through run keeps passing through: the field receives the
      // digit, the terminator above decides what the run was.
      if (_runThrough) return false;
      _consumed[event] = true;
      return true;
    }

    // Anything else means a human is driving: the partial run is junk.
    if (_buffer.isNotEmpty) {
      final bufferBefore = _buffer.length;
      scanDiag('scan-key-rejected', {
        'attemptId': _activeScanAttemptId,
        'origin': 'non-token-event',
        'reason': 'run-abandoned',
        'bufferBefore': bufferBefore,
        'bufferAfter': 0,
      });
      scanDiag('run-abandon', {
        'attemptId': _activeScanAttemptId,
        'reason': 'non-digit',
        'len': _buffer.length,
      });
      _resetBuffer();
    }
    return false;
  }

  static const Set<String> _azertyScannerCharacters = <String>{
    '&',
    'é',
    '"',
    "'",
    '(',
    '-',
    'è',
    '_',
    'ç',
    'à',
  };

  /// The consumer — the [FocusManager] half. [FocusManager] consults
  /// early handlers before walking the focus tree (and skips the walk
  /// entirely for a handled event), so a consumed key reaches no
  /// shortcut, no node handler and no text input.
  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    if (_consumed[event] == true) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  void _logSuppressedPosShortcut(
    KeyEvent event,
    int attemptId,
    String handlerName,
  ) {
    final primaryFocus = FocusManager.instance.primaryFocus;
    scanDiag('pos-shortcut-suppressed', {
      'attemptId': attemptId,
      'handlerName': handlerName,
      'physicalKey': event.physicalKey.debugName ??
          event.physicalKey.usbHidUsage.toRadixString(16),
      'logicalKey': event.logicalKey.debugName ??
          event.logicalKey.keyId.toRadixString(16),
      'eventType': event.runtimeType.toString(),
      'focusState': primaryFocus == null
          ? 'none'
          : '${primaryFocus.debugLabel ?? primaryFocus.runtimeType} '
                'editable=${editableTextHasFocus()}',
    });
  }

  /// Identify only the POS +/- shortcuts. Other keys retain their normal
  /// handling during a scan attempt.
  String? _posQuantityShortcutFor(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
    if (event.character == '-') return 'PosQtyShortcutActivator.decrement';
    if (event.character == '+') return 'PosQtyShortcutActivator.increment';
    if (event.logicalKey == LogicalKeyboardKey.minus ||
        event.logicalKey == LogicalKeyboardKey.numpadSubtract) {
      return 'PosQtyShortcutActivator.decrement';
    }
    if (event.logicalKey == LogicalKeyboardKey.numpadAdd) {
      return 'PosQtyShortcutActivator.increment';
    }
    return null;
  }

  /// The screen that currently owns STARTING a scan: the most recent
  /// registration whose scope passes every arming gate — including "no
  /// editable owns focus". Null = a new burst must not start here.
  BarcodeScanHandler? _activeHandler() {
    if (_handlers.isEmpty) return null;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    for (var i = _handlers.length - 1; i >= 0; i--) {
      final handler = _handlers[i];
      if (_armed(handler, focusContext)) return handler;
    }
    return null;
  }

  /// The screen that owns a run ALREADY in flight (and its terminator):
  /// every hard gate — mounted, chord, route currency, focus scope — but
  /// NOT the editable-focus check, because the post-add refocus may have
  /// landed mid-run while the gateway was already consuming the burst.
  BarcodeScanHandler? _runOwner() {
    if (_handlers.isEmpty) return null;
    final focusContext = FocusManager.instance.primaryFocus?.context;
    for (var i = _handlers.length - 1; i >= 0; i--) {
      final handler = _handlers[i];
      if (_armedCore(handler, focusContext)) return handler;
    }
    return null;
  }

  /// Start gate: a focused text field keeps its exact existing behavior —
  /// typing, submits, and the per-field scan paths (POS search submit,
  /// qty-field submit, products/stock Enter) all still work — unless the
  /// handler opted in via [BarcodeScanHandler.allowWhileEditing] (the
  /// Add Product form: the run passes through the focused field, which
  /// keeps typing normally, and Enter rolls it back before the scan lands
  /// in the barcode field).
  bool _armed(BarcodeScanHandler handler, BuildContext? focusContext) {
    final editable = _focusedEditable();
    if (editable != null && !_allowsWhileEditing(handler, editable)) {
      return false;
    }
    return _armedCore(handler, focusContext);
  }

  bool _allowsWhileEditing(
    BarcodeScanHandler handler,
    EditableText editable,
  ) =>
      handler.allowWhileEditing ||
      handler.allowWhileEditingFor?.call(editable) == true;

  /// Whether [controller] currently owns a pass-through scanner run.
  /// Quantity fields use this to defer live quantity parsing until Enter
  /// decides whether the run is a scan or a manual numeric edit.
  bool isPassThroughRunFor(TextEditingController controller) =>
      _runThrough && identical(_runThroughController, controller);

  /// True when this exact key event was accepted into a scanner run and
  /// also resembles a POS quantity shortcut. Pass-through fields still
  /// receive their text; POS shortcut activators must decline this event.
  bool isScannerOwnedShortcutEvent(KeyEvent event) =>
      _scannerOwnedShortcutEvents[event] == true;

  /// The hard gates every event evaluation needs: a live screen, no
  /// modifier chord, this screen's route current, and the focus scope
  /// sane (the focused node inside this screen's subtree or inside a
  /// route that encloses it — never a modal dialog stacked above).
  bool _armedCore(BarcodeScanHandler handler, BuildContext? focusContext) {
    final context = handler.context;
    // A dead screen (dispose pending) never owns a key.
    if (context != null && !context.mounted) {
      _recordArmingDecision(handler, 'screen-unmounted');
      return false;
    }
    // Modifier chords belong to the shortcut layer, never to scanning.
    if (_chordPressed()) {
      _recordArmingDecision(handler, 'modifier-chord');
      return false;
    }
    // Our route must be the live one (a dialog stacked in the SAME
    // navigator makes it non-current).
    final ourRoute = context == null ? null : ModalRoute.of(context);
    if (ourRoute != null && !ourRoute.isCurrent) {
      _recordArmingDecision(handler, 'route-not-current');
      return false;
    }
    if (context == null || focusContext == null) {
      _recordArmingDecision(handler, 'missing-context');
      return true;
    }
    // Ordinary control of this screen focused (row, button, workspace
    // node): still the active scan target.
    if (_isWithin(context, focusContext)) {
      _recordArmingDecision(
        handler,
        'focus-in-screen',
        focusContext: focusContext,
      );
      return true;
    }
    // Focus elsewhere: allowed only when the focused node lives in a
    // route that ENCLOSES ours (nav-shell chrome above the screen
    // content). A dialog route — anywhere it was pushed — is not an
    // ancestor of this subtree, so the walk fails and the scan is
    // blocked: never scan behind a modal dialog.
    final focusRoute = ModalRoute.of(focusContext);
    if (focusRoute == null || focusRoute == ourRoute) {
      _recordArmingDecision(
        handler,
        'focus-route-same-or-null',
        focusContext: focusContext,
      );
      return true;
    }
    // Dialogs and other popup routes are overlays. They cannot enclose the
    // registered screen, so reject them directly. Besides being equivalent
    // to the ancestry result below, this avoids calling ModalRoute.of on
    // every ancestor Element from the global keyboard callback while a
    // DialogRoute is focused; those transient inherited dependencies can
    // outlive/reparent across nested root-Navigator dialog transitions.
    if (focusRoute is PopupRoute<dynamic>) {
      _recordArmingDecision(
        handler,
        'focus-popup-route',
        focusContext: focusContext,
        focusRoute: focusRoute,
      );
      return false;
    }
    var enclosing = false;
    context.visitAncestorElements((element) {
      if (ModalRoute.of(element) == focusRoute) {
        enclosing = true;
        return false;
      }
      return true;
    });
    _recordArmingDecision(
      handler,
      enclosing ? 'focus-route-encloses-screen' : 'focus-outside-screen',
      focusContext: focusContext,
      focusRoute: focusRoute,
    );
    return enclosing;
  }

  /// Detailed route/focus breadcrumbs are opt-in with
  /// `--dart-define=KLICK_SCAN_DIAG=true`; they do not alter an arming
  /// decision and contain no typed key or barcode content.
  void _recordArmingDecision(
    BarcodeScanHandler handler,
    String reason, {
    BuildContext? focusContext,
    Route<dynamic>? focusRoute,
  }) {
    if (!kScanDiagnosticsEnabled) return;
    scanDiag('scanner-arm', {
      'target': handler.name,
      'reason': reason,
      'focusWidget': ?focusContext?.widget.runtimeType.toString(),
      'focusRoute': ?focusRoute?.runtimeType.toString(),
    });
  }

  /// Whether [descendant] is [ancestor] itself or sits below it in the
  /// element tree (BuildContext offers no containment helper of its own,
  /// so the walk starts at [descendant] and climbs).
  static bool _isWithin(BuildContext ancestor, BuildContext descendant) {
    if (identical(ancestor, descendant)) return true;
    var found = false;
    descendant.visitAncestorElements((element) {
      if (identical(element, ancestor)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool _chordPressed() {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isLogicalKeyPressed(LogicalKeyboardKey.controlLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.controlRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.altRight) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.metaLeft) ||
        keyboard.isLogicalKeyPressed(LogicalKeyboardKey.metaRight);
  }

  /// Ends the current run: buffer, pass-through state and staleness
  /// clock together — they describe ONE run and must never outlive it.
  void _resetBuffer() {
    _buffer.clear();
    _runThrough = false;
    _runThroughForeign = false;
    _runThroughText.clear();
    _runThroughHandler = null;
    _runThroughController = null;
    _runThroughValue = null;
    _runThroughContext = null;
    _lastDigitAt = null;
    _activeScanAttemptId = null;
    _dispatchingScanAttemptId = null;
    _scanPhysicalKeysDown.clear();
    _diagCharacterDigitKeyDowns = 0;
    _diagPhysicalDigitKeyDowns = 0;
    _diagOtherKeyDowns = 0;
  }

  /// The [EditableText] that owns primary focus, resolved exactly like
  /// [editableTextHasFocus] — the field a pass-through run transits (its
  /// controller takes the digits, its value becomes the snapshot).
  EditableText? _focusedEditable() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context.widget is EditableText) return context.widget as EditableText;
    return context.findAncestorWidgetOfExactType<EditableText>();
  }

  bool _isSubsequence(String value, String candidate) {
    var candidateIndex = 0;
    for (final unit in value.codeUnits) {
      while (candidateIndex < candidate.length &&
          candidate.codeUnitAt(candidateIndex) != unit) {
        candidateIndex++;
      }
      if (candidateIndex == candidate.length) return false;
      candidateIndex++;
    }
    return true;
  }

  /// Registered screens (all of them, armed or not).
  @visibleForTesting
  int get handlerCount => _handlers.length;

  /// Open suspension tokens — a leak detector for tests: it must be 0
  /// once every dialog that called [withScannerSuspended] has been torn
  /// down.
  @visibleForTesting
  int get suspensionCount => _suspensions.length;

  /// Digits currently held in the run-in-progress buffer (0 when idle).
  /// Read-only observation for the scan-diagnostics panel; never mutates
  /// capture state.
  int get bufferedDigitCount => _buffer.length;

  /// Whether a registered screen would accept a scan right now — the full
  /// arming evaluation, identical to [hasActiveHandler]. Read-only
  /// observation for the scan-diagnostics panel.
  bool get isCaptureArmed => _activeHandler() != null;

  /// Whether some registered screen would accept a scan right now —
  /// the full gate evaluation (mounted, no editable focus, no chord,
  /// live route, focus scope sane).
  @visibleForTesting
  bool get hasActiveHandler => _activeHandler() != null;

  /// Direct seam for asserting the capture state machine's return value
  /// (true = consumed) without going through the test binding's event
  /// pipeline.
  @visibleForTesting
  bool handleKeyForTest(KeyEvent event) => _handleKeyEvent(event);

  /// Test seam: forget only the cross-origin duplicate record. The record
  /// is wall-clock based, so a test whose OWN two dispatches must both be
  /// evaluated cannot inherit the previous test's dispatch even when the
  /// two tests ran within the same [kCrossOriginDispatchDupMs] window.
  /// Handlers and burst state stay untouched (the registered screens keep
  /// scanning).
  @visibleForTesting
  void resetDispatchDedupForTest() {
    _dupLastCode = null;
    _dupLastFromRaw = false;
    _dupLastAtMs = 0;
  }

  /// Test hermeticity: forget every handler and any burst in progress,
  /// drop every open suspension, and restore the experimental flag to
  /// its default (OFF).
  /// The test binding already clears both listener lists between tests
  /// (and swaps the FocusManager), so this only owns the gateway state.
  @visibleForTesting
  void resetForTest() {
    _handlers.clear();
    _suspensions.clear();
    _resetBuffer();
    _diagCharacterDigitKeyDowns = 0;
    _diagPhysicalDigitKeyDowns = 0;
    _diagOtherKeyDowns = 0;
    resetDispatchDedupForTest();
    experimentalPhysicalDigitCapture = false;
  }
}

/// The in-dialog half of a [BarcodeScannerGateway.withScannerSuspended]
/// run: releases the suspension token when the dialog element unmounts,
/// covering the route-teardown path where the dialog future never
/// completes. The future's own `finally` releases the same token first in
/// the normal pop path — releasing twice is a no-op, so the token can
/// never leak and scanning is never suspended for one tick longer than
/// the dialog exists.
class ScannerSuspensionGuard extends StatefulWidget {
  const ScannerSuspensionGuard({
    required this.token,
    required this.child,
    super.key,
  });

  /// The suspension token handed to the dialog by
  /// [BarcodeScannerGateway.withScannerSuspended].
  final Object token;

  final Widget child;

  @override
  State<ScannerSuspensionGuard> createState() => _ScannerSuspensionGuardState();
}

class _ScannerSuspensionGuardState extends State<ScannerSuspensionGuard> {
  @override
  void dispose() {
    BarcodeScannerGateway.instance.resumeScans(widget.token);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
