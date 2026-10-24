#include "raw_scanner_input.h"

#include <hidusage.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>

#include <cstring>
#include <optional>
#include <sstream>
#include <utility>
#include <vector>

namespace {

constexpr char kMethodChannelName[] = "klick/raw_scanner_poc";
constexpr char kEventChannelName[] = "klick/raw_scanner_poc/events";

// Pending raw-attributed key counts must be consumed by the matching
// legacy message within this window (a wedge key pair arrives within
// ~1ms; the TTL only has to outlive message-pump jitter).
constexpr ULONGLONG kPendingTtlMs = 2000;
// After a scanner DOWN was suppressed, suppress the same key until its
// break arrives (autorepeat / stray WM_CHAR safety net).
constexpr ULONGLONG kLatchTtlMs = 1000;
// Order-evidence window: a legacy DOWN for key k seen within this many
// ms BEFORE that device's raw DOWN means legacy arrived first — the
// ordering assumption failed. A human's own press landing in the same
// 50ms slot is possible and is called out in the recorded detail.
constexpr ULONGLONG kOrderWindowMs = 50;

enum class LegacyKind { kDown, kUp, kChar };

std::optional<LegacyKind> Classify(UINT message) {
  switch (message) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      return LegacyKind::kDown;
    case WM_KEYUP:
    case WM_SYSKEYUP:
      return LegacyKind::kUp;
    case WM_CHAR:
    case WM_SYSCHAR:
      return LegacyKind::kChar;
    default:
      return std::nullopt;
  }
}

// EncodableValue's converting constructors are explicit, so map literal
// keys are built here by direct-initialization (see the canonical usage
// in encodable_value.h).
flutter::EncodableValue Ev(const char* text) {
  return flutter::EncodableValue(text);
}

flutter::EncodableMap StatusMap(bool ready, bool enabled, bool learn_armed,
                                const std::vector<std::string>& learned,
                                std::uint64_t raw_seen,
                                std::uint64_t raw_matched,
                                std::uint64_t dropped, std::uint64_t passed,
                                std::uint64_t order_violations,
                                const std::string& order_detail) {
  flutter::EncodableList learned_values;
  for (const auto& device : learned) {
    learned_values.emplace_back(device);
  }
  return {
      {Ev("ready"), flutter::EncodableValue(ready)},
      {Ev("enabled"), flutter::EncodableValue(enabled)},
      {Ev("learnArmed"), flutter::EncodableValue(learn_armed)},
      {Ev("learned"), flutter::EncodableValue(learned_values)},
      {Ev("rawSeen"),
       flutter::EncodableValue(static_cast<std::int64_t>(raw_seen))},
      {Ev("rawMatched"),
       flutter::EncodableValue(static_cast<std::int64_t>(raw_matched))},
      {Ev("dropped"),
       flutter::EncodableValue(static_cast<std::int64_t>(dropped))},
      {Ev("passed"),
       flutter::EncodableValue(static_cast<std::int64_t>(passed))},
      {Ev("orderViolations"),
       flutter::EncodableValue(static_cast<std::int64_t>(order_violations))},
      {Ev("orderDetail"), flutter::EncodableValue(order_detail)},
  };
}

}  // namespace

RawScannerInput& RawScannerInput::Instance() {
  static RawScannerInput* instance = new RawScannerInput();
  return *instance;
}

// static
std::uint32_t RawScannerInput::PackKey(USHORT make, USHORT flags) {
  std::uint32_t key = make & 0xFF;
  if (flags & RI_KEY_E0) {
    key |= 0x100;
  }
  if (flags & RI_KEY_E1) {
    key |= 0x200;
  }
  return key;
}

void RawScannerInput::Initialize(flutter::BinaryMessenger* messenger,
                                 HWND target) {
  if (initialized_) {
    Shutdown();
  }
  target_ = target;

  method_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kMethodChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  method_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "status") {
          result->Success(flutter::EncodableValue(StatusMap(
              initialized_, enabled_, learn_armed_, learned_devices_,
              raw_seen_, raw_matched_, dropped_, passed_, order_violations_,
              order_detail_)));
          return;
        }
        if (method == "setEnabled") {
          const auto* value =
              std::get_if<bool>(call.arguments());
          if (value == nullptr) {
            result->Error("bad-args", "expected bool");
            return;
          }
          enabled_ = *value;
          if (!enabled_) {
            pending_.clear();
            latch_until_break_.clear();
            last_legacy_down_ms_.clear();
          }
          result->Success();
          return;
        }
        if (method == "setLearned") {
          const auto* list =
              std::get_if<flutter::EncodableList>(call.arguments());
          if (list == nullptr) {
            result->Error("bad-args", "expected list");
            return;
          }
          learned_devices_.clear();
          for (const auto& entry : *list) {
            const auto* device = std::get_if<std::string>(&entry);
            if (device != nullptr && !device->empty()) {
              learned_devices_.push_back(*device);
            }
          }
          if (learned_devices_.empty()) {
            pending_.clear();
            latch_until_break_.clear();
          }
          result->Success();
          return;
        }
        if (method == "learn") {
          if (!initialized_) {
            result->Error("unavailable", "raw input not initialized");
            return;
          }
          learn_armed_ = true;
          result->Success();
          return;
        }
        if (method == "cancelLearn") {
          learn_armed_ = false;
          result->Success();
          return;
        }
        if (method == "resetStats") {
          raw_seen_ = 0;
          raw_matched_ = 0;
          dropped_ = 0;
          passed_ = 0;
          order_violations_ = 0;
          order_detail_.clear();
          last_legacy_down_ms_.clear();
          result->Success();
          return;
        }
        result->NotImplemented();
      });

  event_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          messenger, kEventChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events) -> std::unique_ptr<
                                 flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = events.release();
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            sink_ = nullptr;
            return nullptr;
          }));

  RAWINPUTDEVICE rid{};
  rid.usUsagePage = HID_USAGE_PAGE_GENERIC;
  rid.usUsage = HID_USAGE_GENERIC_KEYBOARD;
  rid.dwFlags = 0;  // no RIDEV_INPUTSINK: foreground-only observation
  rid.hwndTarget = target_;
  RegisterRawInputDevices(&rid, 1, sizeof(rid));

  initialized_ = true;
}

void RawScannerInput::Shutdown() {
  if (!initialized_) {
    return;
  }
  RAWINPUTDEVICE rid{};
  rid.usUsagePage = HID_USAGE_PAGE_GENERIC;
  rid.usUsage = HID_USAGE_GENERIC_KEYBOARD;
  rid.dwFlags = RIDEV_REMOVE;
  rid.hwndTarget = nullptr;
  RegisterRawInputDevices(&rid, 1, sizeof(rid));

  if (method_channel_) {
    method_channel_->SetMethodCallHandler(nullptr);
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
  method_channel_.reset();
  event_channel_.reset();

  sink_ = nullptr;
  initialized_ = false;
  target_ = nullptr;
  enabled_ = false;
  learn_armed_ = false;
  learned_devices_.clear();
  pending_.clear();
  latch_until_break_.clear();
  last_legacy_down_ms_.clear();
}

bool RawScannerInput::FilterMessage(const MSG& msg) {
  if (msg.message == WM_INPUT) {
    HandleRawInput(msg.lParam);
    return false;  // still dispatched: DefWindowProc performs the cleanup
  }
  if (!initialized_ || !enabled_ || learned_devices_.empty()) {
    return false;
  }
  if (!Classify(msg.message).has_value()) {
    return false;
  }
  return ShouldDropLegacy(msg.message, msg.lParam);
}

void RawScannerInput::HandleRawInput(LPARAM lparam) {
  if (!initialized_) {
    return;
  }
  UINT size = 0;
  if (GetRawInputData(reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, nullptr,
                      &size, sizeof(RAWINPUTHEADER)) != 0 ||
      size == 0) {
    return;
  }
  std::vector<std::uint8_t> buffer(size);
  const UINT written = GetRawInputData(
      reinterpret_cast<HRAWINPUT>(lparam), RID_INPUT, buffer.data(), &size,
      sizeof(RAWINPUTHEADER));
  if (written == static_cast<UINT>(-1) || written == 0) {
    return;
  }
  const RAWINPUT* raw = reinterpret_cast<const RAWINPUT*>(buffer.data());
  if (raw->header.dwType != RIM_TYPEKEYBOARD) {
    return;
  }

  ++raw_seen_;
  const RAWKEYBOARD& keyboard = raw->data.keyboard;
  std::string device = DeviceName(raw->header.hDevice);
  if (device.empty()) {
    device = "<unknown>";
  }

  if (learn_armed_) {
    // First keyboard device that speaks wins — the operator presses
    // Learn and then triggers the SCANNER, never a typing key.
    learn_armed_ = false;
    Emit({{Ev("t"), flutter::EncodableValue("learn")},
          {Ev("device"), flutter::EncodableValue(device)}});
  }

  if (!enabled_ || !LearnedMatches(device)) {
    return;  // ordinary keyboards pass untouched, invisibly to the PoC
  }
  ++raw_matched_;

  const bool is_break = (keyboard.Flags & RI_KEY_BREAK) != 0;
  const std::uint32_t key = PackKey(keyboard.MakeCode, keyboard.Flags);
  const ULONGLONG now = GetTickCount64();

  if (!is_break) {
    // Order evidence: a PASSED legacy DOWN for this same key arriving
    // right before this device's raw DOWN means legacy beat raw.
    const auto seen = last_legacy_down_ms_.find(key);
    if (seen != last_legacy_down_ms_.end()) {
      const ULONGLONG legacy_at = seen->second;
      last_legacy_down_ms_.erase(seen);
      if (now >= legacy_at && now - legacy_at <= kOrderWindowMs) {
        ++order_violations_;
        std::ostringstream detail;
        detail << "legacy-before-raw key=0x" << std::hex << key << std::dec
               << " gap_ms=" << (now - legacy_at);
        order_detail_ = detail.str();
      }
    }
    Pending& pending = pending_[key];
    pending.downs++;
    pending.expiry_ms = now + kPendingTtlMs;
  } else {
    Pending& pending = pending_[key];
    pending.ups++;
    pending.expiry_ms = now + kPendingTtlMs;
  }

  Emit({{Ev("t"), flutter::EncodableValue("raw")},
        {Ev("device"), flutter::EncodableValue(device)},
        {Ev("make"),
         flutter::EncodableValue(static_cast<std::int64_t>(
             keyboard.MakeCode))},
        {Ev("e0"),
         flutter::EncodableValue((keyboard.Flags & RI_KEY_E0) != 0)},
        {Ev("e1"),
         flutter::EncodableValue((keyboard.Flags & RI_KEY_E1) != 0)},
        {Ev("up"), flutter::EncodableValue(is_break)},
        {Ev("vk"),
         flutter::EncodableValue(static_cast<std::int64_t>(
             keyboard.VKey))},
        {Ev("seq"),
         flutter::EncodableValue(static_cast<std::int64_t>(raw_seen_))}});
}

bool RawScannerInput::ShouldDropLegacy(UINT message, LPARAM lparam) {
  const LegacyKind kind = *Classify(message);
  const std::uint32_t make =
      (static_cast<std::uint32_t>(static_cast<std::uintptr_t>(lparam)) >> 16) &
      0xFF;
  const bool e0 =
      ((static_cast<std::uint32_t>(static_cast<std::uintptr_t>(lparam)) >> 24) &
       1) != 0;
  const std::uint32_t key = make | (e0 ? 0x100 : 0);
  const ULONGLONG now = GetTickCount64();

  if (kind == LegacyKind::kChar) {
    // Safety net only: with the message-loop filter running before
    // TranslateMessage, a suppressed DOWN never produces a WM_CHAR. This
    // branch exists for anomalous pump orders (the extended bit is not
    // trustworthy on WM_CHAR, so both packed variants are checked).
    for (const std::uint32_t candidate : {key, make}) {
      const auto latch = latch_until_break_.find(candidate);
      if (latch != latch_until_break_.end()) {
        if (now <= latch->second) {
          ++dropped_;
          return true;
        }
        latch_until_break_.erase(latch);
      }
    }
    ++passed_;
    return false;
  }

  const auto latch = latch_until_break_.find(key);
  if (latch != latch_until_break_.end()) {
    if (now > latch->second) {
      latch_until_break_.erase(latch);
    } else if (kind == LegacyKind::kDown) {
      ++dropped_;
      return true;
    }
  }

  const auto pending = pending_.find(key);
  if (pending != pending_.end()) {
    if (now > pending->second.expiry_ms) {
      pending_.erase(pending);
    } else if (kind == LegacyKind::kDown && pending->second.downs > 0) {
      pending->second.downs--;
      latch_until_break_[key] = now + kLatchTtlMs;
      last_legacy_down_ms_.erase(key);
      ++dropped_;
      return true;
    } else if (kind == LegacyKind::kUp && pending->second.ups > 0) {
      pending->second.ups--;
      latch_until_break_.erase(key);
      ++dropped_;
      return true;
    }
  }

  if (kind == LegacyKind::kUp) {
    const auto up_latch = latch_until_break_.find(key);
    if (up_latch != latch_until_break_.end() && now <= up_latch->second) {
      latch_until_break_.erase(up_latch);
      ++dropped_;
      return true;
    }
  }

  if (kind == LegacyKind::kDown) {
    // Not attributed to the scanner device: ordinary typing. Record it
    // for the order-evidence window above.
    last_legacy_down_ms_[key] = now;
  }
  ++passed_;
  return false;
}

std::string RawScannerInput::DeviceName(HANDLE device) const {
  UINT size = 0;
  GetRawInputDeviceInfo(device, RIDI_DEVICENAME, nullptr, &size);
  if (size == 0) {
    return std::string();
  }
  std::vector<wchar_t> buffer(size);
  const UINT written =
      GetRawInputDeviceInfo(device, RIDI_DEVICENAME, buffer.data(), &size);
  if (written == static_cast<UINT>(-1)) {
    return std::string();
  }
  const int chars =
      WideCharToMultiByte(CP_UTF8, 0, buffer.data(), -1, nullptr, 0, nullptr,
                          nullptr);
  if (chars <= 1) {
    return std::string();
  }
  std::string utf8(chars - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, buffer.data(), -1, utf8.data(), chars,
                      nullptr, nullptr);
  return utf8;
}

// static
std::string RawScannerInput::VidPidToken(const std::string& device_name) {
  const auto vid = device_name.find("VID_");
  if (vid == std::string::npos) {
    return std::string();
  }
  const auto end = device_name.find('#', vid);
  return device_name.substr(vid, end == std::string::npos
                                     ? std::string::npos
                                     : end - vid);
}

bool RawScannerInput::LearnedMatches(const std::string& device_name) const {
  for (const auto& learned : learned_devices_) {
    if (learned == device_name) {
      return true;
    }
    // Port-stable match: two interface paths that share VID/PID are the
    // same device model (the interface instance segment changes when the
    // scanner is replugged into another port).
    const std::string learned_token = VidPidToken(learned);
    if (!learned_token.empty() && learned_token == VidPidToken(device_name)) {
      return true;
    }
  }
  return false;
}

void RawScannerInput::Emit(const flutter::EncodableMap& event) {
  if (sink_ == nullptr) {
    return;
  }
  sink_->Success(flutter::EncodableValue(event));
}
