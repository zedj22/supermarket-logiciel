// PosOptionPickerDialog — reusable product option picker (UX FIX #6).
//
// One layout for variants and selling units: separated option cards with
// number badge, title, price, secondary label, strong selected state,
// and keyboard-first navigation.
//
// Interaction:
//   Click option     → select + confirm (matches existing Phase 8 UX)
//   Enter / confirm  → add currently selected option
//   Number 1–9       → select + add immediately
//   Arrows           → move selection (Up/Down; Left/Right in grid)
//   Escape           → cancel (dialog route default)
//
// Digit shortcuts never fire while an EditableText (e.g. quantity field)
// has primary focus.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/strings.dart';

/// True while an [EditableText] (quantity field, search field, …) holds
/// primary focus. Shared with the POS quantity shortcuts (`+` / `*`) so a
/// key the cashier is typing is never hijacked by a shortcut.
bool editableTextHasFocus() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// One selectable option card.
class PosOptionCard {
  /// Widget key for the card root (e.g. `selling-unit-base`, `variant-var-1`).
  final String optionKey;
  final String title;
  final String? price;
  final String? secondary;
  final bool enabled;

  const PosOptionCard({
    required this.optionKey,
    required this.title,
    this.price,
    this.secondary,
    this.enabled = true,
  });
}

/// Full AlertDialog with card list, keyboard navigation, and confirm action.
///
/// [onConfirm] is invoked with the selected index on click, Enter, number
/// key, or the primary button. The dialog does **not** pop itself — the
/// parent decides (e.g. open quantity dialog, then pop with a result).
class PosOptionPickerDialog extends StatefulWidget {
  final String title;
  final String? subtitle;
  final List<PosOptionCard> options;
  /// Key for the AlertDialog root (e.g. `variant-picker`).
  final String dialogKey;
  final Future<void> Function(int index) onConfirm;

  const PosOptionPickerDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.options,
    required this.dialogKey,
    required this.onConfirm,
  });

  @override
  State<PosOptionPickerDialog> createState() => _PosOptionPickerDialogState();
}

class _PosOptionPickerDialogState extends State<PosOptionPickerDialog> {
  final FocusNode _focusNode = FocusNode();
  int _selected = 0;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    if (widget.options.isNotEmpty) _selected = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  int get _columns {
    if (widget.options.length <= 1) return 1;
    final width = MediaQuery.sizeOf(context).width;
    // Narrow viewports force a single-column card list.
    return width < 520 ? 1 : 2;
  }

  bool _editableTextHasFocus() => editableTextHasFocus();

  void _move(int delta) {
    if (widget.options.isEmpty) return;
    setState(() {
      final next = _selected + delta;
      if (next >= 0 && next < widget.options.length) _selected = next;
    });
  }

  void _moveHorizontal(int delta) {
    if (widget.options.isEmpty) return;
    final cols = _columns;
    if (cols <= 1) {
      _move(delta);
      return;
    }
    setState(() {
      final next = _selected + delta;
      if (next >= 0 && next < widget.options.length) _selected = next;
    });
  }

  void _moveVertical(int delta) {
    if (widget.options.isEmpty) return;
    final cols = _columns;
    _move(cols <= 1 ? delta : delta * cols);
  }

  Future<void> _confirm(int index) async {
    if (_confirming) return;
    if (index < 0 || index >= widget.options.length) return;
    if (!widget.options[index].enabled) return;
    setState(() {
      _selected = index;
      _confirming = true;
    });
    try {
      await widget.onConfirm(index);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  void _onDigit(int digitIndex) {
    // Respect Flutter focus: never hijack keys while a text field edits.
    if (_editableTextHasFocus()) return;
    if (digitIndex < 0 || digitIndex >= widget.options.length) return;
    _confirm(digitIndex);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveVertical(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveVertical(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _moveHorizontal(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _moveHorizontal(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _confirm(_selected);
      return KeyEventResult.handled;
    }

    // Number keys 1–9 (top row + numpad).
    int? digit;
    final keyId = key.keyId;
    final digit1 = LogicalKeyboardKey.digit1.keyId;
    final digit9 = LogicalKeyboardKey.digit9.keyId;
    final numpad1 = LogicalKeyboardKey.numpad1.keyId;
    final numpad9 = LogicalKeyboardKey.numpad9.keyId;
    if (keyId >= digit1 && keyId <= digit9) {
      digit = keyId - digit1;
    } else if (keyId >= numpad1 && keyId <= numpad9) {
      digit = keyId - numpad1;
    }
    if (digit != null) {
      _onDigit(digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _badge(BuildContext context, int index, bool selected) {
    final theme = Theme.of(context);
    final number = index + 1;
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? theme.colorScheme.primary : Colors.transparent,
        border: Border.all(
          color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
          width: selected ? 0 : 1.5,
        ),
      ),
      child: Text(
        '$number',
        key: Key('pos-option-badge-$number'),
        style: theme.textTheme.labelMedium?.copyWith(
          color: selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _optionCard(BuildContext context, int index) {
    final theme = Theme.of(context);
    final card = widget.options[index];
    final selected = index == _selected && card.enabled;
    final loc = Localizations.localeOf(context).languageCode;

    return Material(
      key: Key(card.optionKey),
      color: Colors.transparent,
      child: InkWell(
        key: Key('${card.optionKey}-tappable'),
        borderRadius: BorderRadius.circular(12),
        onTap: card.enabled && !_confirming ? () => _confirm(index) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          constraints: const BoxConstraints(minHeight: 72),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.12)
                : theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline.withValues(alpha: 0.35),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _badge(context, index, selected),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      card.title,
                      key: Key('${card.optionKey}-title'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (card.price != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        card.price!,
                        key: Key('${card.optionKey}-price'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    if (card.secondary != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        card.secondary!,
                        key: Key('${card.optionKey}-secondary'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle,
                  key: const Key('pos-option-selected'),
                  size: 22,
                  color: theme.colorScheme.primary,
                  semanticLabel: AppStrings.t('select', loc),
                )
              else
                const SizedBox(width: 22),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context).width;
    final width = (screen * 0.9).clamp(420.0, 620.0);
    final cols = _columns;

    final content = widget.options.isEmpty
        ? const SizedBox(height: 48)
        : GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              // Fixed row height prevents card content overflow (title+price+secondary).
              mainAxisExtent: cols == 1 ? 92 : 96,
            ),
            itemCount: widget.options.length,
            itemBuilder: (context, index) => _optionCard(context, index),
          );

    return AlertDialog(
      key: Key(widget.dialogKey),
      title: Text(widget.title, key: Key('${widget.dialogKey}-title')),
      content: SizedBox(
        width: width,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.subtitle != null) ...[
                Text(
                  widget.subtitle!,
                  key: Key('${widget.dialogKey}-subtitle'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              content,
              const SizedBox(height: 12),
              Text(
                AppStrings.t('picker_keyboard_hint', loc),
                key: const Key('pos-option-picker-hint'),
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('pos-option-picker-cancel'),
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        FilledButton(
          key: const Key('pos-option-picker-confirm'),
          onPressed:
              widget.options.isEmpty || _confirming ? null : () => _confirm(_selected),
          child: Text(AppStrings.t('select_and_add', loc)),
        ),
      ],
    );
  }
}
