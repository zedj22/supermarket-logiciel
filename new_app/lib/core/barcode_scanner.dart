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

import 'keyboard.dart';
import 'scan_diagnostics.dart';

/// The shape of a keyboard-wedge burst: a digit run of at least 6
/// characters (EAN-8 / UPC-A / EAN-13 … are 8, 12 or 13 digits) ending
/// in Enter. Same family as `kPosBarcodeScanInput` (pos_qty_shortcuts.dart)
/// — the shared "a pure digit run of barcode length" fingerprint that
/// separates a scan from a human quantity (`1`, `12`, `10*24` + Enter
/// never dispatch).
final RegExp kBarcodeScanShape = RegExp(r'^\d{6,}$');

/// The longest pause that still counts as ONE burst inside an
/// `allowWhileEditing` pass-through run. A wedge types a character every
/// few milliseconds; a human pausing longer than this between two digits
/// is typing, not scanning — the buffered residue and its field snapshot
/// are stale, so the next digit drops them and starts a fresh run (slow
/// typing can therefore never accumulate into a scan-shaped buffer).
/// Bookkeeping only: it never delays or consumes a keystroke, and events
/// whose clock does not advance (the zero-timestamp test seam) never
/// qualify.
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
  BarcodeScanHandler({
    required this.onScan,
    this.context,
    this.name = 'screen',
    this.allowWhileEditing = false,
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

  /// Decision handoff between the two listeners: events the capture
  /// state machine consumed. Weak, identity-keyed ([KeyEvent] has no ==
  /// override), so entries die with the event objects themselves.
  final Expando<bool> _consumed =
      Expando<bool>('barcode_scanner_consumed_event');

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
  BarcodeScanHandler? _runThroughHandler;
  TextEditingController? _runThroughController;
  TextEditingValue? _runThroughValue;

  /// The timestamp of the last digit appended to the current run —
  /// staleness input for pass-through runs ([kBarcodeRunStaleGap]).
  Duration? _lastDigitAt;

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
    // Same correlation contract as the Enter path — the id below is what
    // every downstream hop (scan-receive / scan-resolve / cart-add) reads.
    lastScanCorr = scanDiag('raw-dispatch', {
      'len': code.length,
      'suffix3': scanDiagSuffix3(code),
      'target': owner.name,
    });
    owner.onScan(code);
    return true;
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
    // Only key-downs build or terminate a scan. KeyUps pass without
    // touching the buffer (the wedge interleaves one per character, and a
    // stray up must not eat a burst mid-run); auto-repeat passes without
    // appending (a held key can never fabricate a barcode).
    if (event is! KeyDownEvent) return false;

    final logicalKey = event.logicalKey;
    if (logicalKey == LogicalKeyboardKey.enter ||
        logicalKey == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString();
      // Capture the pass-through run state BEFORE the reset: the
      // terminator below must still know which field the digits transited
      // and where it started.
      final runThrough = _runThrough;
      final runThroughForeign = _runThroughForeign;
      final runThroughHandler = _runThroughHandler;
      final runThroughController = _runThroughController;
      final runThroughValue = _runThroughValue;
      _resetBuffer();
      if (code.isNotEmpty && kBarcodeScanShape.hasMatch(code)) {
        // Pass-through terminator: the burst was never consumed, it
        // transited the focused field — the field must end exactly where
        // it started before the dispatch may proceed. The handler
        // registration is the liveness gate: its dialog unregisters
        // BEFORE disposing the very controller held here, so a still-
        // registered handler means the write below is always safe.
        if (runThrough &&
            runThroughHandler != null &&
            _handlers.contains(runThroughHandler) &&
            runThroughController != null &&
            runThroughValue != null) {
          final text = runThroughController.text;
          final snapshot = runThroughValue.text;
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
              ? text.length == snapshot.length + code.length &&
                  text.startsWith(snapshot)
              : text == snapshot + code;
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
            return false;
          }
          // text == snapshot: nothing reached the field (a key-ignoring
          // widget or the test pipeline) — dispatch with no restore.
        }
        // Not (or no longer) a restorable pass-through: a default
        // consumed run, or a dialog that closed mid-run — dispatch
        // without touching any field.
        final owner = _runOwner();
        if (owner != null) {
          _consumed[event] = true;
          // `dispatch` is an ORIGIN: its seq id becomes the correlation id
          // of every downstream hop (scan-receive / scan-resolve /
          // cart-add). `target` names the screen that will consume it —
          // a dispatch with no matching receive can be attributed.
          lastScanCorr = scanDiag('dispatch', {
            'len': code.length,
            'suffix3': scanDiagSuffix3(code),
            'target': owner.name,
          });
          owner.onScan(code);
          return true;
        }
        // Shape-matching run but no live owner (dialog, dead screen,
        // gates): the consumed digits must never be silently dropped —
        // say so with an explicit reason.
        scanDiag('dispatch-drop', {
          'reason': 'no-owner',
          'len': code.length,
          'suffix3': scanDiagSuffix3(code),
        });
      } else if (code.isNotEmpty) {
        // Digits were claimed (armed run) but Enter showed they were not
        // barcode-shaped — a human quantity: consumed runs dropped them
        // on purpose, pass-through runs left them in the focused field.
        scanDiag('dispatch-drop', {
          'reason': 'shape',
          'len': code.length,
        });
      }
      // Empty / too short / no live owner: an ordinary Enter — shortcuts,
      // submits and buttons keep it.
      return false;
    }

    final character = event.character;
    // Ordinary capture, UNCHANGED: an ASCII digit in `character` (US and
    // correctly configured scanners, NumLock-on numpads — and, on AZERTY,
    // the Shift layer a FR-configured scanner or a human produces).
    final characterDigit = character != null &&
        character.isNotEmpty &&
        _singleDigit.hasMatch(character);
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
    if (characterDigit) {
      digit = character;
    } else if (experimentalPhysicalDigitCapture) {
      final physicalDigitIndex = _physicalDigitIndexOf(event.physicalKey);
      final blocked = _shiftPressed() ||
          (character != null &&
              character.isNotEmpty &&
              _shortcutOwnedCharacters.contains(character));
      if (physicalDigitIndex >= 0 && !blocked) {
        digit = _digitFromPhysicalIndex(physicalDigitIndex);
      }
    }
    if (digit != null) {
      // Pass-through staleness (its runs only): a pause longer than
      // [kBarcodeRunStaleGap] means the buffered residue and its snapshot
      // describe typing, not one burst — drop them and evaluate this
      // digit as a fresh START below. Bookkeeping only: this digit is
      // never delayed or consumed by the check.
      if (_runThrough) {
        final last = _lastDigitAt;
        if (last != null &&
            event.timeStamp > last &&
            event.timeStamp - last > kBarcodeRunStaleGap) {
          scanDiag('run-abandon', {
            'reason': 'stale-gap',
            'len': _buffer.length,
          });
          _resetBuffer();
        }
      }
      if (_buffer.isEmpty) {
        // START: full arming — a focused text field, a chord, a dialog or
        // a dead screen means this digit belongs to the field/shortcut,
        // never to the gateway.
        final owner = _activeHandler();
        if (owner == null) return false;
        _buffer.write(digit);
        _lastDigitAt = event.timeStamp;
        // Non-character digit = the experimental physical path fired:
        // the field will receive layout-translated text, so the
        // terminator must match by growth, not exact ASCII.
        if (!characterDigit) _runThroughForeign = true;
        if (owner.allowWhileEditing) {
          final editable = _focusedEditable();
          if (editable != null) {
            // Pass-through run: the digit reaches this field as ordinary
            // typing (NOT consumed — that is the whole point: typing in
            // the form must work), and the snapshot taken here is
            // restored at Enter when the run turns out to be a scan.
            _runThrough = true;
            _runThroughHandler = owner;
            _runThroughController = editable.controller;
            _runThroughValue = editable.controller.value;
            return false;
          }
        }
        _consumed[event] = true;
        return true;
      }
      // CONTINUE: the run's earlier digits were already claimed here;
      // only hard gates (dialog, chord, dead screen) may abandon it.
      if (_runOwner() == null) {
        scanDiag('run-abandon', {'reason': 'gates', 'len': _buffer.length});
        _resetBuffer();
        return false;
      }
      _buffer.write(digit);
      _lastDigitAt = event.timeStamp;
      if (!characterDigit) _runThroughForeign = true;
      // A pass-through run keeps passing through: the field receives the
      // digit, the terminator above decides what the run was.
      if (_runThrough) return false;
      _consumed[event] = true;
      return true;
    }

    // Anything else means a human is driving: the partial run is junk.
    if (_buffer.isNotEmpty) {
      scanDiag('run-abandon', {'reason': 'non-digit', 'len': _buffer.length});
      _resetBuffer();
    }
    return false;
  }

  /// The consumer — the [FocusManager] half. [FocusManager] consults
  /// early handlers before walking the focus tree (and skips the walk
  /// entirely for a handled event), so a consumed key reaches no
  /// shortcut, no node handler and no text input.
  KeyEventResult _handleEarlyKeyEvent(KeyEvent event) {
    if (_consumed[event] == true) return KeyEventResult.handled;
    return KeyEventResult.ignored;
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
    if (!handler.allowWhileEditing && editableTextHasFocus()) return false;
    return _armedCore(handler, focusContext);
  }

  /// The hard gates every event evaluation needs: a live screen, no
  /// modifier chord, this screen's route current, and the focus scope
  /// sane (the focused node inside this screen's subtree or inside a
  /// route that encloses it — never a modal dialog stacked above).
  bool _armedCore(BarcodeScanHandler handler, BuildContext? focusContext) {
    final context = handler.context;
    // A dead screen (dispose pending) never owns a key.
    if (context != null && !context.mounted) return false;
    // Modifier chords belong to the shortcut layer, never to scanning.
    if (_chordPressed()) return false;
    // Our route must be the live one (a dialog stacked in the SAME
    // navigator makes it non-current).
    final ourRoute = context == null ? null : ModalRoute.of(context);
    if (ourRoute != null && !ourRoute.isCurrent) return false;
    if (context == null || focusContext == null) return true;
    // Ordinary control of this screen focused (row, button, workspace
    // node): still the active scan target.
    if (_isWithin(context, focusContext)) return true;
    // Focus elsewhere: allowed only when the focused node lives in a
    // route that ENCLOSES ours (nav-shell chrome above the screen
    // content). A dialog route — anywhere it was pushed — is not an
    // ancestor of this subtree, so the walk fails and the scan is
    // blocked: never scan behind a modal dialog.
    final focusRoute = ModalRoute.of(focusContext);
    if (focusRoute == null || focusRoute == ourRoute) return true;
    var enclosing = false;
    context.visitAncestorElements((element) {
      if (ModalRoute.of(element) == focusRoute) {
        enclosing = true;
        return false;
      }
      return true;
    });
    return enclosing;
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
    _runThroughHandler = null;
    _runThroughController = null;
    _runThroughValue = null;
    _lastDigitAt = null;
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

  /// Registered screens (all of them, armed or not).
  @visibleForTesting
  int get handlerCount => _handlers.length;

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

  /// Test hermeticity: forget every handler and any burst in progress,
  /// and restore the experimental flag to its default (OFF).
  /// The test binding already clears both listener lists between tests
  /// (and swaps the FocusManager), so this only owns the gateway state.
  @visibleForTesting
  void resetForTest() {
    _handlers.clear();
    _resetBuffer();
    experimentalPhysicalDigitCapture = false;
  }
}
