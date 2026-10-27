import 'package:material_ui/material_ui.dart';

/// Mumu 极简架构：输入模式开关已统一集成在顶部 48dp 极简一体栏中，
/// 画布角落不再额外悬浮重复的 PenOnlyToggle 胶囊按钮，彻底消除界面遮挡与状态割裂。
class PenOnlyToggle extends StatelessWidget {
  const PenOnlyToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}
