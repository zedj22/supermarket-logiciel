// Isolated PoC — Windows Raw Input capture for keyboard-wedge barcode
// scanners (layout-independent scanning under en-US / fr-FR / ar-DZ).
//
// SCOPE: this module is a PROOF OF CONCEPT. It does NOT replace the
// Flutter keyboard-wedge gateway (`lib/core/barcode_scanner.dart`) — the
// existing gateway keeps running untouched, and this module only becomes
// active when Dart explicitly enables it (and a scanner device has been
// "learned"). With the PoC off, this code is a no-op observer.
//
// WHY RUNNER-LEVEL (design evidence, Phase 1):
//  * Raw Input is the only Windows API that attributes keyboard events
//    to a PHYSICAL DEVICE (`RAWINPUTHEADER.hDevice` + RIDI_DEVICENAME).
//    Legacy messages (WM_KEYDOWN / WM_CHAR) carry no device id, and
//    RIDEV_NOLEGACY is scoped to the whole keyboard usage page/usage —
//    it would silence ALL keyboards, not just the scanner, so it cannot
//    be used for selective suppression.
//  * `Win32Window` gives focus to the CHILD view window on WM_ACTIVATE,
//    so key messages arrive at the engine's child window — plugin
//    top-level WindowProc delegates never see them. The runner message
//    loop is the single choke point that sees every message of the
//    thread BEFORE TranslateMessage/DispatchMessage, which is exactly
//    where scanner-attributed legacy messages must be dropped (dropping
//    before TranslateMessage also prevents the WM_CHAR from ever being
//    generated).
//  * Empirical ordering evidence on this machine (injected key probe,
//    Win11 build 26200): for every key, WM_INPUT is delivered BEFORE
//    WM_KEYDOWN, which is delivered before the TranslateMessage-generated
//    WM_CHAR. That order is what makes raw-attributed suppression work;
//    the module also measures it at runtime (`orderViolations`) so real
//    scanner hardware can confirm it instead of assuming it.
//
// WHAT RAW INPUT IS NOT: it never returns the barcode string. It returns
// per-key make/break codes (+ E0/E1 flags) from one HID device. The
// barcode is reconstructed in Dart (`raw_scanner_decoder.dart`) from the
// SCANNER's declared keyboard country table — never from the Windows
// layout, never from a symbol→digit heuristic, with no Shift synthesis
// and no input-layout changes anywhere.
//
// Suppression model (only while enabled AND the event's device matches a
// learned scanner device):
//  * raw DOWN  -> pending.down++ (TTL kPendingTtlMs) + latch until break;
//  * raw UP    -> pending.up++  (TTL kPendingTtlMs);
//  * legacy DOWN with pending/down latch  -> drop (queue filter skips
//    TranslateMessage + DispatchMessage entirely, so the engine never
//    sees the key and no WM_CHAR is produced);
//  * legacy UP with pending/latch          -> drop;
//  * legacy CHAR with an active latch      -> safety-net drop.
// Anything else (human keyboards, other devices, PoC disabled) passes
// through byte-for-byte unchanged.
#ifndef RUNNER_RAW_SCANNER_INPUT_H_
#define RUNNER_RAW_SCANNER_INPUT_H_

#include <windows.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

class RawScannerInput {
 public:
  static RawScannerInput& Instance();

  RawScannerInput(const RawScannerInput&) = delete;
  RawScannerInput& operator=(const RawScannerInput&) = delete;

  // Registers keyboard raw input against |target| (foreground-only — no
  // RIDEV_INPUTSINK: the PoC must never observe input while another
  // application is focused) and creates the Dart-facing channels.
  void Initialize(flutter::BinaryMessenger* messenger, HWND target);

  // Unregisters raw input (RIDEV_REMOVE) and drops the channels.
  void Shutdown();

  bool initialized() const { return initialized_; }

  // Runner message-loop hook: runs BEFORE TranslateMessage/DispatchMessage
  // for every message of this thread. Parses WM_INPUT (forwarding raw
  // events for the learned scanner device to Dart) and returns true when
  // a legacy key/char message is attributed to the scanner device and
  // must be dropped so it never reaches the Flutter engine.
  bool FilterMessage(const MSG& msg);

 private:
  RawScannerInput() = default;

  // Packed key identity: make code | E0 (0x100) | E1 (0x200).
  static std::uint32_t PackKey(USHORT make, USHORT flags);

  void HandleRawInput(LPARAM lparam);
  bool ShouldDropLegacy(UINT message, LPARAM lparam);

  std::string DeviceName(HANDLE device) const;
  static std::string VidPidToken(const std::string& device_name);
  bool LearnedMatches(const std::string& device_name) const;

  void Emit(const flutter::EncodableMap& event);

  bool initialized_ = false;
  HWND target_ = nullptr;

  // Dart-facing channels (platform thread only).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  flutter::EventSink<flutter::EncodableValue>* sink_ = nullptr;

  // Configuration pushed from Dart.
  bool enabled_ = false;
  bool learn_armed_ = false;
  std::vector<std::string> learned_devices_;

  // Suppression bookkeeping (scanner device only, only while enabled).
  struct Pending {
    int downs = 0;
    int ups = 0;
    ULONGLONG expiry_ms = 0;
  };
  std::map<std::uint32_t, Pending> pending_;
  std::map<std::uint32_t, ULONGLONG> latch_until_break_;

  // Evidence counters for the hardware report.
  std::uint64_t raw_seen_ = 0;
  std::uint64_t raw_matched_ = 0;
  std::uint64_t dropped_ = 0;
  std::uint64_t passed_ = 0;
  std::uint64_t order_violations_ = 0;
  std::string order_detail_;
  std::map<std::uint32_t, ULONGLONG> last_legacy_down_ms_;
};

#endif  // RUNNER_RAW_SCANNER_INPUT_H_
