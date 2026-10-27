import 'package:flex_color_scheme/flex_color_scheme.dart';
import 'package:material_ui/material_ui.dart';

import 'main.dart';

/// 木木笔记：暖白纸感与深色视觉令牌
class MumuPalette {
  MumuPalette._();

  // 浅色暖纸模式
  static const Color warmPaperSurface = Color(0xFFF7F7F2);
  static const Color warmCanvasBg = Color(0xFFEFEFE8);
  static const Color warmCardBorder = Color(0xFFE2E1D8);
  static const Color inkPrimary = Color(0xFF292929);
  static const Color inkSecondary = Color(0xFF64645E);
  static const Color oliveAccent = Color(0xFFA8794B);
  static const Color oliveAccentDark = Color(0xFF5F700E);
  static const Color primaryAccent = Color(0xFF2F7D6E);

  // 深色极客模式
  static const Color darkSlateBg = Color(0xFF0B1120);
  static const Color darkSlateSurface = Color(0xFF0F172A);
  static const Color darkSlateCard = Color(0xFF1E293B);
  static const Color darkSlateBorder = Color(0xFF334155);
  static const Color emeraldGuard = Color(0xFF10B981);
  static const Color roseReject = Color(0xFFF43F5E);
}

const kClassicFirstColor = Color(0xFF2F7D6E);
const kClassicSecondColor = Color(0xFFA8794B);
const kClassicThemePrimary = isNightly
    ? kClassicSecondColor
    : kClassicFirstColor;
const kClassicThemeSecondary = isNightly
    ? kClassicFirstColor
    : kClassicSecondColor;
const kClassicTheme = FlexSchemeColor(
  primary: kClassicThemePrimary,
  secondary: kClassicThemeSecondary,
  primaryContainer: Color(0xFFD9EFE9),
  secondaryContainer: Color(0xFFF4E8D7),
);
const kClassicThemeData = FlexSchemeData(
  name: '木木暖纸',
  description: '木木笔记 · 暖纸与松墨绿主题',
  light: kClassicTheme,
  dark: FlexSchemeColor(
    primary: Color(0xFF5FA895),
    secondary: Color(0xFFC79A6B),
    primaryContainer: Color(0xFF174A42),
    secondaryContainer: Color(0xFF4A3624),
  ),
);

const EdgeInsets settingsCardMargin = .all(8);
const EdgeInsets settingsCardPadding = .all(16);
const EdgeInsets settingsCardTitlePadding = .only(left: 12, top: 8, right: 12);

ThemeData getThemeData(
  String name,
  bool dark, [
  VisualDensity? density,
  ColorScheme? overridden,
  bool highContrast = false,
]) {
  final color = getFlexThemeColor(name, dark);
  final override = overridden != null && name.isEmpty;
  final isMumuDefault = name.isEmpty || name == 'Classic';
  ThemeData theme;
  if (dark) {
    theme = FlexThemeData.dark(
      colors: override ? null : color,
      colorScheme: override ? overridden : null,
      useMaterial3: true,
      appBarElevation: 0,
      scaffoldBackground: isMumuDefault ? MumuPalette.darkSlateBg : null,
      surface: isMumuDefault ? MumuPalette.darkSlateSurface : null,
      fontFamily: 'Comfortaa',
      visualDensity: density,
      darkIsTrueBlack: highContrast,
      fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans Arabic', 'Roboto'],
    );
  } else {
    theme = FlexThemeData.light(
      colors: override ? null : color,
      colorScheme: override ? overridden : null,
      useMaterial3: true,
      appBarElevation: 0,
      scaffoldBackground: isMumuDefault ? MumuPalette.warmCanvasBg : null,
      surface: isMumuDefault ? MumuPalette.warmPaperSurface : null,
      fontFamily: 'Comfortaa',
      visualDensity: density,
      lightIsWhite: highContrast,
      fontFamilyFallback: const ['Noto Sans SC', 'Noto Sans Arabic', 'Roboto'],
    );
  }
  final brandPrimary = dark
      ? const Color(0xFF5FA895)
      : MumuPalette.primaryAccent;
  final brandBorder = dark
      ? MumuPalette.darkSlateBorder
      : const Color(0xFFD9D8CF);
  theme = theme.copyWith(
    colorScheme: theme.colorScheme.copyWith(
      primary: brandPrimary,
      onPrimary: dark ? const Color(0xFF05201B) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF174A42)
          : const Color(0xFFD9EFE9),
      onPrimaryContainer: dark
          ? const Color(0xFFD3F3EA)
          : const Color(0xFF12332D),
      secondary: dark ? const Color(0xFFC79A6B) : MumuPalette.oliveAccent,
      onSecondary: dark ? const Color(0xFF2B1B09) : Colors.white,
      secondaryContainer: dark
          ? const Color(0xFF4A3624)
          : const Color(0xFFF4E8D7),
      onSecondaryContainer: dark
          ? const Color(0xFFF5E3CD)
          : const Color(0xFF3B2A18),
      surface: dark
          ? MumuPalette.darkSlateSurface
          : MumuPalette.warmPaperSurface,
      onSurface: dark ? const Color(0xFFE5E7EB) : MumuPalette.inkPrimary,
      onSurfaceVariant: dark
          ? const Color(0xFFB6C2D1)
          : MumuPalette.inkSecondary,
      surfaceContainerLowest: dark
          ? MumuPalette.darkSlateBg
          : const Color(0xFFFFFFFF),
      surfaceContainerLow: dark
          ? const Color(0xFF131D2E)
          : const Color(0xFFF5F4EE),
      surfaceContainer: dark
          ? const Color(0xFF172235)
          : const Color(0xFFF2F1EA),
      surfaceContainerHigh: dark
          ? const Color(0xFF1E2A3B)
          : const Color(0xFFF0EFE8),
      surfaceContainerHighest: dark
          ? const Color(0xFF263244)
          : const Color(0xFFEDECE3),
      outline: dark ? const Color(0xFF64748B) : const Color(0xFF8C8B82),
      outlineVariant: brandBorder,
    ),
    sliderTheme: theme.sliderTheme.copyWith(
      activeTrackColor: brandPrimary,
      inactiveTrackColor: brandBorder,
      thumbColor: brandPrimary,
    ),
  );
  return theme.copyWith(
    cardTheme: CardThemeData(
      elevation: dark ? 6 : 2,
      color: dark
          ? MumuPalette.darkSlateSurface.withValues(alpha: 0.94)
          : MumuPalette.warmPaperSurface.withValues(alpha: 0.96),
      shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: BorderSide(
          color: dark
              ? MumuPalette.darkSlateBorder.withValues(alpha: 0.75)
              : MumuPalette.warmCardBorder,
          width: 1,
        ),
      ),
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      backgroundColor: dark
          ? MumuPalette.darkSlateSurface.withValues(alpha: 0.95)
          : MumuPalette.warmPaperSurface.withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: dark
          ? MumuPalette.darkSlateSurface
          : MumuPalette.warmPaperSurface,
      surfaceTintColor: Colors.transparent,
      elevation: dark ? 10 : 6,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: dark ? MumuPalette.darkSlateCard : MumuPalette.warmPaperSurface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark
          ? MumuPalette.darkSlateSurface
          : MumuPalette.warmPaperSurface,
      surfaceTintColor: Colors.transparent,
    ),
    tabBarTheme: const TabBarThemeData(tabAlignment: TabAlignment.center),
    dropdownMenuTheme: DropdownMenuThemeData(
      inputDecorationTheme: defaultDropdownInputDecorationTheme(),
    ),
    sliderTheme: theme.sliderTheme.copyWith(year2023: false),
    progressIndicatorTheme: theme.progressIndicatorTheme.copyWith(
      year2023: false,
    ),
  );
}

InputDecorationTheme defaultDropdownInputDecorationTheme() {
  return const InputDecorationTheme(
    filled: true,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
      borderSide: BorderSide.none,
    ),
  );
}

FlexSchemeColor getFlexThemeColor(String name, bool dark) {
  final color = FlexColor.schemesList.firstWhere(
    (scheme) => scheme.name == name,
    orElse: () => kClassicThemeData,
  );
  if (dark) return color.dark;
  return color.light;
}

List<String> getThemes() {
  return ['Classic', ...FlexColor.schemesList.map((e) => e.name)];
}
