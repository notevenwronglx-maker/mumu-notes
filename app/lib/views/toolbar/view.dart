import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

const kToolbarSmall = Size.fromHeight(46.0);
const kToolbarLarge = Size.fromHeight(72.0);

class ToolbarView extends StatefulWidget {
  const ToolbarView({super.key});

  @override
  State<ToolbarView> createState() => _ToolbarViewState();
}

class _ToolbarViewState extends State<ToolbarView> {
  String? currentPalette;
  final GlobalKey _animatedKey = .new();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BlocBuilder<SettingsCubit, ButterflySettings>(
      buildWhen: (previous, current) =>
          previous.toolbarPosition != current.toolbarPosition,
      builder: (context, state) {
        return Align(
          child: Container(
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: isDark
                  ? MumuPalette.darkSlateSurface.withValues(alpha: 0.92)
                  : MumuPalette.warmPaperSurface.withValues(alpha: 0.96),
              borderRadius: const BorderRadius.all(Radius.circular(18)),
              border: Border.all(
                color: isDark
                    ? MumuPalette.darkSlateBorder
                    : MumuPalette.warmCardBorder,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(18)),
              child: BlocBuilder<ToolCubit, ToolRuntimeState>(
                buildWhen: (previous, current) =>
                    previous.temporaryToolbar != current.temporaryToolbar ||
                    previous.toolbar != current.toolbar,
                builder: (context, toolState) {
                  Widget? child;
                  var height = 0.0;
                  final toolbar =
                      toolState.temporaryToolbar ?? toolState.toolbar;
                  if (toolbar != null) {
                    height = toolbar.preferredSize.height;
                    child = toolbar;
                  }
                  return AnimatedContainer(
                    height: height,
                    key: _animatedKey,
                    curve: Curves.fastOutSlowIn,
                    duration: const Duration(milliseconds: 200),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 100),
                      curve: Curves.fastOutSlowIn,
                      child: child,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
