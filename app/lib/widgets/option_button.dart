import 'package:butterfly/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class OptionButton extends StatefulWidget {
  final Widget icon;
  final Widget? selectedIcon, bottomIcon, leadingIcon;
  final VoidCallback? onPressed, onSecondaryPressed, onLongPressed, onDoubleTap;
  final bool selected, highlighted, focussed, showBottom;
  final String tooltip;

  const OptionButton({
    super.key,
    this.tooltip = '',
    required this.icon,
    this.selectedIcon,
    this.bottomIcon,
    this.leadingIcon,
    this.onPressed,
    this.onSecondaryPressed,
    this.onLongPressed,
    this.onDoubleTap,
    this.selected = false,
    this.highlighted = false,
    this.focussed = false,
    this.showBottom = false,
  });

  @override
  State<OptionButton> createState() => _OptionButtonState();
}

class _OptionButtonState extends State<OptionButton>
    with TickerProviderStateMixin {
  final GlobalKey<TooltipState> _tooltipKey = GlobalKey();
  late final AnimationController _animationController;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 120),
      vsync: this,
      value: _nextValue,
    );
    _animation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    super.dispose();
    _animationController.dispose();
  }

  double get _nextValue => widget.showBottom ? 1 : 0;

  @override
  void didUpdateWidget(covariant OptionButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected ||
        widget.highlighted != oldWidget.highlighted ||
        widget.showBottom != oldWidget.showBottom) {
      setState(() {});
      _animationController.animateTo(_nextValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = isDark
        ? MumuPalette.primaryAccent
        : MumuPalette.oliveAccent;

    final selectedBottom = IconTheme(
      data: Theme.of(context).iconTheme.copyWith(
        size: 12,
        color: widget.selected ? Colors.white : null,
      ),
      child: Align(
        child:
            widget.bottomIcon ??
            const PhosphorIcon(PhosphorIconsLight.caretDown),
      ),
    );
    return Tooltip(
      triggerMode: TooltipTriggerMode.manual,
      message: widget.tooltip,
      key: _tooltipKey,
      child: AspectRatio(
        aspectRatio: 1,
        child: InkWell(
          radius: 14,
          borderRadius: const BorderRadius.all(Radius.circular(14)),
          onTap: widget.onPressed,
          onDoubleTap: widget.onDoubleTap,
          onSecondaryTap: widget.onSecondaryPressed,
          onLongPress: widget.onLongPressed == null
              ? null
              : () {
                  _tooltipKey.currentState?.ensureTooltipVisible();
                  widget.onLongPressed?.call();
                },
          child: AnimatedBuilder(
            animation: _animation,
            builder: (context, child) {
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(
                  gradient: widget.selected
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: isDark
                              ? const [Color(0xFF3B82F6), Color(0xFF2F7D6E)]
                              : const [
                                  MumuPalette.oliveAccent,
                                  MumuPalette.oliveAccentDark,
                                ],
                        )
                      : null,
                  color: !widget.selected && widget.highlighted
                      ? activeColor.withValues(alpha: 0.14)
                      : null,
                  border: widget.highlighted
                      ? Border.all(
                          color: widget.selected ? Colors.white70 : activeColor,
                          width: 1.8,
                        )
                      : (widget.focussed
                            ? Border.all(
                                color: ColorScheme.of(context).outlineVariant,
                                width: 1.5,
                              )
                            : null),
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                  boxShadow: widget.selected
                      ? [
                          BoxShadow(
                            color: activeColor.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ]
                      : null,
                ),
                margin: const EdgeInsets.all(2),
                child: child,
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: IconTheme(
                data: Theme.of(context).iconTheme.copyWith(
                  size: 24,
                  color: widget.selected
                      ? Colors.white
                      : (isDark
                            ? const Color(0xFFE2E8F0)
                            : MumuPalette.inkPrimary),
                ),
                child: Column(
                  mainAxisAlignment: .center,
                  children: [
                    Stack(
                      children: [
                        if (widget.leadingIcon != null)
                          Align(
                            alignment: Alignment.topLeft,
                            child: widget.leadingIcon!,
                          ),
                        widget.selected
                            ? (widget.selectedIcon ?? widget.icon)
                            : widget.icon,
                      ],
                    ),
                    SizeTransition(
                      axis: .vertical,
                      sizeFactor: _animation,
                      child: Column(
                        children: [const SizedBox(height: 2), selectedBottom],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
