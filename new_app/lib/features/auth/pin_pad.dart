import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/strings.dart';

/// PIN input formatter for desktop/mobile keyboards.
///
/// - Accepts ASCII digits 0-9 (main row and numpad produce these).
/// - Maps Arabic-Indic (٠-٩) and Extended Arabic-Indic/Persian (۰-۹)
///   keystrokes to ASCII digits so an Arabic keyboard layout still enters
///   a backend-compatible PIN — Arabic numeral characters are never stored.
/// - Drops every other character (letters, symbols, whitespace).
class AsciiPinInputFormatter extends TextInputFormatter {
  static const List<String> _arabicIndic = [
    '٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩',
  ];
  static const List<String> _extendedArabicIndic = [
    '۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹',
  ];

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final buffer = StringBuffer();
    for (final unit in newValue.text.runes) {
      final ch = String.fromCharCode(unit);
      final ai = _arabicIndic.indexOf(ch);
      if (ai >= 0) {
        buffer.write(ai);
        continue;
      }
      final ei = _extendedArabicIndic.indexOf(ch);
      if (ei >= 0) {
        buffer.write(ei);
        continue;
      }
      if (unit >= 0x30 && unit <= 0x39) {
        buffer.write(ch);
      }
    }
    final text = buffer.toString();
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

class PinPad extends StatefulWidget {
  final int maxLength;
  final String locale;
  final ValueChanged<String> onSubmit;
  final ValueChanged<String>? onChanged;
  final bool obscure;
  final String? errorText;
  final bool enabled;

  /// When true (default), the PIN TextField takes focus as soon as it is
  /// built so physical keyboard digits go straight to the authoritative
  /// input on Windows desktop.
  final bool autofocus;

  const PinPad({
    super.key,
    this.maxLength = 6,
    required this.locale,
    required this.onSubmit,
    this.onChanged,
    this.obscure = true,
    this.errorText,
    this.enabled = true,
    this.autofocus = true,
  });

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _obscure = true;

  /// Authoritative PIN text (single source of truth shared with parent
  /// via [onChanged]).
  String get pin => _controller.text;

  void _syncToParent() {
    widget.onChanged?.call(_controller.text);
  }

  /// Give keyboard focus to the PIN field (physical digits then type here).
  void requestPinFocus() {
    _focusNode.requestFocus();
  }

  /// Whether the authoritative PIN TextField currently has focus.
  bool get hasPinFocus => _focusNode.hasFocus;

  /// Append one ASCII digit (used by on-screen pad and physical keys).
  void inputDigit(String digit) {
    if (!widget.enabled) return;
    if (_controller.text.length >= widget.maxLength) return;
    _controller.text += digit;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    _syncToParent();
    _focusNode.requestFocus();
    if (_controller.text.length == widget.maxLength) {
      widget.onSubmit(_controller.text);
    }
  }

  /// Remove the last digit (Backspace / on-screen backspace).
  void deleteLast() {
    if (!widget.enabled) return;
    if (_controller.text.isNotEmpty) {
      _controller.text = _controller.text.substring(
        0,
        _controller.text.length - 1,
      );
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _syncToParent();
      _focusNode.requestFocus();
    }
  }

  /// Clear the entire PIN (used after failed login so the user can retry).
  void clearPin() {
    if (_controller.text.isNotEmpty) {
      _controller.clear();
      _syncToParent();
      _focusNode.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    _obscure = widget.obscure;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isRtl = widget.locale == 'ar';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // PIN display — editable TextField is the authoritative input:
        // physical keyboard digits/numpad/backspace edit this field directly.
        SizedBox(
          width: 280,
          child: TextField(
            key: const Key('pin-input'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: widget.autofocus,
            readOnly: false,
            enableInteractiveSelection: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              AsciiPinInputFormatter(),
              LengthLimitingTextInputFormatter(widget.maxLength),
            ],
            obscureText: _obscure,
            textAlign: TextAlign.center,
            onChanged: (value) {
              widget.onChanged?.call(value);
            },
            onSubmitted: widget.onSubmit,
            style: theme.textTheme.headlineMedium?.copyWith(
              letterSpacing: 8,
            ),
            decoration: InputDecoration(
              hintText: AppStrings.t('pin', widget.locale),
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure ? Icons.visibility_off : Icons.visibility,
                  size: 20,
                ),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
              counterText: '',
            ),
            maxLength: widget.maxLength,
          ),
        ),

        if (widget.errorText != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.errorText!,
            style: TextStyle(
              color: theme.colorScheme.error,
              fontSize: 13,
            ),
          ),
        ],

        const SizedBox(height: 16),

        // Number pad
        _buildNumberPad(context, isRtl),
      ],
    );
  }

  Widget _buildNumberPad(BuildContext context, bool isRtl) {
    final theme = Theme.of(context);
    final keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      [
        AppStrings.t('clear', widget.locale),
        '0',
        AppStrings.t('backspace', widget.locale),
      ],
    ];

    return SizedBox(
      width: 280,
      child: Column(
        children: keys.map((row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: row.map((key) {
                final isClear =
                    key == AppStrings.t('clear', widget.locale);
                final isBackspace =
                    key == AppStrings.t('backspace', widget.locale);
                final isDigit = !isClear && !isBackspace;

                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton(
                        onPressed: widget.enabled
                            ? () {
                                if (isClear) {
                                  clearPin();
                                } else if (isBackspace) {
                                  deleteLast();
                                } else {
                                  inputDigit(key);
                                }
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isClear || isBackspace
                              ? theme.colorScheme.surface
                              : theme.colorScheme.primary,
                          foregroundColor: isClear || isBackspace
                              ? theme.colorScheme.onSurface
                              : Colors.white,
                          padding: EdgeInsets.zero,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: isDigit
                            ? Text(
                                key,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                isBackspace ? Icons.backspace_outlined : Icons.clear,
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          );
        }).toList(),
      ),
    );
  }
}
