// Application-level keyboard-wedge barcode scanner capture — "scan with
// NO search field focused" (Klick POS global barcode support).
//
// A keyboard-wedge scanner is an ordinary keyboard: it types a run of
// digits and presses Enter. The run must be captured at an app-level
// boundary so the ACTIVE screen can act on the code while the workspace
// is idle — no field requests focus, no burst is ever typed into a box.
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
//    (typing, submits, per-field scan paths) runs untouched;
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

/// One buffered character: a single ASCII digit (the wedge types digits,
/// the numpad produces them through `character` too).
final RegExp _singleDigit = RegExp(r'^[0-9]$');

/// One screen's claim on global scans.
///
/// Registered on initState, unregistered on dispose — the gateway routes
/// each completed burst to the most recently registered handler whose
/// scope is currently on screen (screens never coexist in the shell, and
/// the reversed walk resolves the mount-before-unmount overlap of a
/// route swap to the NEW screen).
class BarcodeScanHandler {
  BarcodeScanHandler({required this.onScan, this.context, this.name = 'screen'});

  /// Diagnostic label for this handler (`pos`, `products`, `stock`) —
  /// printed on `dispatch` so a dispatch that never produces a receive
  /// can be attributed to the screen that consumed it.
  final String name;

  /// The registering screen's build context — the scope every arming gate
  /// is evaluated against (route currency, subtree, enclosing routes).
  /// `null` only in tree-less unit tests, where the widget gates vacuously
  /// pass and only the capture rules apply.
  final BuildContext? context;

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

  final List<BarcodeScanHandler> _handlers = <BarcodeScanHandler>[];

  /// Digits of the burst in progress (cleared by Enter, by any non-scan
  /// key, and whenever the gateway abandons a run).
  final StringBuffer _buffer = StringBuffer();

  /// Decision handoff between the two listeners: events the capture
  /// state machine consumed. Weak, identity-keyed ([KeyEvent] has no ==
  /// override), so entries die with the event objects themselves.
  final Expando<bool> _consumed =
      Expando<bool>('barcode_scanner_consumed_event');

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

  /// Capture state machine — the [HardwareKeyboard] half. Runs for every
  /// key event, before the focus system sees it.
  ///
  /// A run ONCE started belongs to the gateway until its terminator:
  /// every digit was consumed from the focus system, so a same-route
  /// focus move mid-run (the post-add refocus landing inside the next
  /// physical burst) does NOT truncate it — the remainder must never be
  /// retyped into the field that just took focus (that is how barcode
  /// prefixes became quantities). Hard gates still abandon a run: a
  /// dialog/route change, a modifier chord or a dead screen.
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
      _resetBuffer();
      if (code.isNotEmpty && kBarcodeScanShape.hasMatch(code)) {
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
        // Digits were consumed (armed run) but Enter showed they were not
        // barcode-shaped — a human quantity typed with no field focused.
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
    if (character != null &&
        character.isNotEmpty &&
        _singleDigit.hasMatch(character)) {
      if (_buffer.isEmpty) {
        // START: full arming — a focused text field, a chord, a dialog or
        // a dead screen means this digit belongs to the field/shortcut,
        // never to the gateway.
        if (_activeHandler() == null) return false;
        _buffer.write(character);
        _consumed[event] = true;
        return true;
      }
      // CONTINUE: the run's earlier digits were already consumed here;
      // only hard gates (dialog, chord, dead screen) may abandon it.
      if (_runOwner() == null) {
        scanDiag('run-abandon', {'reason': 'gates', 'len': _buffer.length});
        _resetBuffer();
        return false;
      }
      _buffer.write(character);
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
  /// qty-field submit, products/stock Enter) all still work.
  bool _armed(BarcodeScanHandler handler, BuildContext? focusContext) {
    if (editableTextHasFocus()) return false;
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

  void _resetBuffer() => _buffer.clear();

  /// Registered screens (all of them, armed or not).
  @visibleForTesting
  int get handlerCount => _handlers.length;

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

  /// Test hermeticity: forget every handler and any burst in progress.
  /// The test binding already clears both listener lists between tests
  /// (and swaps the FocusManager), so this only owns the gateway state.
  @visibleForTesting
  void resetForTest() {
    _handlers.clear();
    _resetBuffer();
  }
}
