import 'dart:async';
import 'dart:math' as math;

import 'package:butterfly/actions/pdf_export.dart';
import 'package:butterfly/api/file_system.dart';
import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/dialogs/pages.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/actions/background.dart';
import 'package:butterfly/actions/select.dart';
import 'package:butterfly/dialogs/import/add.dart';
import 'package:butterfly/helpers/page.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly/models/defaults.dart';
import 'package:butterfly/models/viewport.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly/services/asset.dart';
import 'package:butterfly/services/network.dart';
import 'package:material_leap/material_leap.dart';
import 'package:butterfly/services/export.dart';
import 'package:butterfly/services/import.dart';
import 'package:butterfly/services/palm_guard_service.dart';
import 'package:butterfly/theme.dart';
import 'package:butterfly/views/view.dart';
import 'package:butterfly/widgets/document_page_preview.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:dart_leap/dart_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:lw_file_system/lw_file_system.dart';

/// 跨路由分屏启动队列：支持从书架主页拖拽文档到右侧分屏热区或从文档菜单直接以分屏模式打开。
class MumuSplitLaunchQueue {
  static String? pendingSecondaryPath;
  static bool pendingVertical = true;

  static void requestOpenInSplit({
    required String secondaryPath,
    bool vertical = true,
  }) {
    pendingSecondaryPath = secondaryPath;
    pendingVertical = vertical;
  }
}

/// 应用内分屏第二窗口独立文档运行时：
/// 挂载真实的 DocumentBloc + TransformCubit + EditorController + MainViewViewport，
/// 支持并排打开另一篇笔记本或同木木笔记本的不同页面，两侧独立滚动、独立缩放、独立手写编辑与自动保存！
class _SplitSecondaryDocumentRuntime {
  final String? filePath;
  final String displayTitle;
  final DocumentBloc bloc;
  final TransformCubit transformCubit;
  final EditorController editorController;
  final ImportService importService;
  final ExportService exportService;
  final AssetService assetService;
  final NetworkingService networkingService;
  final GlobalKey<MainViewViewportState> viewportKey = GlobalKey();
  StreamSubscription<DocumentState>? _saveSub;
  Timer? _debounceSaveTimer;
  bool _closed = false;

  _SplitSecondaryDocumentRuntime({
    required this.filePath,
    required this.displayTitle,
    required this.bloc,
    required this.transformCubit,
    required this.editorController,
    required this.importService,
    required this.exportService,
    required this.assetService,
    required this.networkingService,
  });

  void attachAutoSave(ButterflyFileSystem fileSystem) {
    final targetPath = filePath;
    if (targetPath == null || targetPath.isEmpty) return;
    _saveSub?.cancel();
    _saveSub = bloc.stream.listen((state) {
      if (_closed || state is! DocumentLoadSuccess) return;
      _debounceSaveTimer?.cancel();
      _debounceSaveTimer = Timer(const Duration(milliseconds: 650), () async {
        if (_closed) return;
        try {
          await fileSystem
              .buildDocumentSystem()
              .updateFile(targetPath, state.data.toFile());
        } catch (_) {}
      });
    });
  }

  Future<void> saveAndClose(ButterflyFileSystem fileSystem) async {
    if (_closed) return;
    _closed = true;
    _debounceSaveTimer?.cancel();
    await _saveSub?.cancel();
    final targetPath = filePath;
    final st = bloc.state;
    if (targetPath != null &&
        targetPath.isNotEmpty &&
        st is DocumentLoadSuccess) {
      try {
        await fileSystem
            .buildDocumentSystem()
            .updateFile(targetPath, st.data.toFile());
      } catch (_) {}
    }
    clearDocumentPagePreviewCache(bloc);
    if (!bloc.isClosed) await bloc.close();
    if (!transformCubit.isClosed) await transformCubit.close();
    await assetService.dispose();
    if (!networkingService.isClosed) await networkingService.close();
  }
}

// ============================================================================
// 1. 顶部防误触实时遥测胶囊
// ============================================================================

/// Mumu 风格顶部防误触实时遥测胶囊（点击直接唤出双框实测校准与 7 维监控台）。
class MumuTelemetryPill extends StatelessWidget {
  final bool compact;

  const MumuTelemetryPill({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PalmGuardService.instance,
      builder: (context, _) {
        final pgState = PalmGuardService.instance.state;
        return IconButton(
          icon: Icon(
            Icons.back_hand_outlined,
            size: 19,
            color: pgState.enabled ? Theme.of(context).colorScheme.primary : null,
          ),
          tooltip: '防误触握姿与灵敏度设置（${pgState.posture.label}）',
          onPressed: () => showMumuPalmGuardModal(context),
        );
      },
    );
  }
}

/// Mumu 风格握笔姿势与防误触灵敏度设置底部弹窗（取代原本杂乱的画布常驻调试悬浮窗）
Future<void> showMumuPalmGuardModal(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      return ListenableBuilder(
        listenable: PalmGuardService.instance,
        builder: (context, _) {
          final svc = PalmGuardService.instance;
          final state = svc.state;
          final tele = svc.telemetry;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.shield_outlined),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '智能防误触与握姿设置',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                      Switch(value: state.enabled, onChanged: (v) => svc.setEnabled(v)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前状态：${state.enabled ? "防误触无感运行中" : "已暂停"} · 握姿：${state.posture.label}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: PalmPosturePreset.values.map((preset) {
                      final selected = state.posture == preset;
                      return ChoiceChip(
                        label: Text(preset.label),
                        selected: selected,
                        onSelected: (_) => svc.setPosture(preset),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text('手掌拒识灵敏度'),
                      Expanded(
                        child: Slider(
                          value: state.sensitivity.clamp(0.1, 1.0),
                          min: 0.1,
                          max: 1.0,
                          divisions: 9,
                          label: '${(state.sensitivity * 100).round()}%',
                          onChanged: (v) => svc.setSensitivity(v),
                        ),
                      ),
                      SizedBox(
                        width: 44,
                        child: Text(
                          '${(state.sensitivity * 100).round()}%',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('底部可拖拽虚拟防误触手垫'),
                    subtitle: const Text('开启后可在屏幕下方搭放手掌，随时上下拖动高度'),
                    value: tele.shieldEnabled,
                    onChanged: (v) => svc.setPalmShield(enabled: v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.tune_rounded, size: 16),
                        label: const Text('双框实测笔尖校准实验室'),
                        onPressed: () {
                          Navigator.pop(ctx);
                          showMumuCalibrationModal(context);
                        },
                      ),
                      const SizedBox(width: 8),
                      FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('完成')),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

/// Mumu 风格极简书写工作台覆盖层（包含 48dp 一体式顶栏 + 磁吸灵动笔盒 + 隐藏式防误触设置弹窗）
class MumuWorkspaceOverlay extends StatefulWidget {
  final VoidCallback? onBackToHome;
  final String documentTitle;

  const MumuWorkspaceOverlay({super.key, this.onBackToHome, this.documentTitle = '未命名笔记'});

  @override
  State<MumuWorkspaceOverlay> createState() => _MumuWorkspaceOverlayState();
}

class _MumuWorkspaceOverlayState extends State<MumuWorkspaceOverlay> {
  static const List<int> _inkColors = [
    0xFF1E1E1E, // 碳素黑
    0xFF1A5FB4, // 钢笔蓝
    0xFFE01B24, // 批注红
    0xFF26A269, // 翠竹绿
    0xFF9141AC, // 丁香紫
    0xFFE66100, // 琥珀橙
    0xFFF5C211, // 荧光黄
    0xFF613583, // 深靛蓝
  ];

  static const List<double> _strokeSizes = [2.0, 4.5, 9.0];

  int _selectedColor = 0xFF1E1E1E;
  int _selectedSizeIndex = 0;
  bool _showPenSettingsPopup = false;

  @override
  void initState() {
    super.initState();
    PalmGuardService.instance.init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncInputModeWithButterfly(PalmGuardService.instance.state.penOnlyMode);
    });
  }

  void _syncInputModeWithButterfly(bool penOnly) {
    if (!mounted) return;
    context.read<SettingsCubit>().changePenOnlyInput(penOnly);
    context.read<EditorController>().inputCubit.setSessionPenOnlyInput(penOnly);
  }

  void _applyTool(Tool newTool, {required bool Function(Tool) matcher}) {
    final bloc = context.read<DocumentBloc>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;
    final controller = context.read<EditorController>();
    final tools = List<Tool>.from(docState.info.tools);
    int targetIdx = tools.indexWhere(matcher);
    final toolWithId = newTool.copyWith(
      id: targetIdx != -1 ? (tools[targetIdx].id ?? createUniqueId()) : createUniqueId(),
    );
    if (targetIdx != -1) {
      tools[targetIdx] = toolWithId;
    } else {
      targetIdx = tools.length;
      tools.add(toolWithId);
    }
    bloc.add(ToolsReplaced(tools));
    controller.toolCubit.setIndex(targetIdx);
    controller.toolCubit.updateTool(controller, bloc, toolWithId);
  }

  void _selectPen({bool isHighlighter = false}) {
    final size = isHighlighter
        ? _strokeSizes[_selectedSizeIndex] * 3.2
        : _strokeSizes[_selectedSizeIndex];
    final color = isHighlighter ? (_selectedColor & 0x00FFFFFF) | 0x66000000 : _selectedColor;
    _applyTool(
      PenTool(
        name: isHighlighter ? '荧光笔' : '钢笔',
        shapeDetectionEnabled: true,
        property: PenProperty(
          strokeWidth: size,
          smoothing: 0.65,
          paint: ElementPaint.solid(color: SRGBColor(color)),
        ),
      ),
      matcher: (t) =>
          t is PenTool &&
          (isHighlighter
              ? t.name.contains('荧光')
              : (!t.name.contains('荧光') && !t.name.contains('圆珠'))),
    );
  }

  void _selectEraser({bool pathEraser = true}) {
    final size = _strokeSizes[_selectedSizeIndex] * 4.0;
    _applyTool(
      EraserTool(
        name: '橡皮擦',
        mode: pathEraser ? EraserMode.stroke : EraserMode.path,
        strokeWidth: size,
      ),
      matcher: (t) => t is EraserTool,
    );
  }

  void _selectLasso() {
    _applyTool(
      SelectTool(name: '套索', mode: SelectMode.lasso),
      matcher: (t) => t is SelectTool,
    );
  }

  void _selectShape() {
    _applyTool(
      ShapeTool(
        name: '图形',
        property: ShapeProperty(
          shape: const RectangleShape(),
          strokeWidth: _strokeSizes[_selectedSizeIndex],
          paint: ElementPaint.solid(color: SRGBColor(_selectedColor)),
        ),
      ),
      matcher: (t) => t is ShapeTool,
    );
  }

  void _selectLaser() {
    _applyTool(
      LaserTool(
        name: '激光笔',
        strokeWidth: _strokeSizes[_selectedSizeIndex] * 1.5,
        color: const SRGBColor(0xFFE01B24),
        duration: 2.0,
      ),
      matcher: (t) => t is LaserTool,
    );
  }

  void _selectText() {
    _applyTool(LabelTool(name: '文本'), matcher: (t) => t is LabelTool);
  }

  void _selectHand() {
    _applyTool(HandTool(name: '抓手'), matcher: (t) => t is HandTool);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark
        ? const Color(0xFF242426).withValues(alpha: 0.94)
        : Colors.white.withValues(alpha: 0.95);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: surfaceColor,
          elevation: 1,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                      tooltip: '返回主页',
                      onPressed: widget.onBackToHome ?? () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        widget.documentTitle,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    BlocBuilder<DocumentBloc, DocumentState>(
                      builder: (context, docState) {
                        final bloc = context.read<DocumentBloc>();
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.undo_rounded, size: 20),
                              tooltip: '撤销 (双指轻点)',
                              onPressed: bloc.canSendUndo ? () => bloc.sendUndo() : null,
                            ),
                            IconButton(
                              icon: const Icon(Icons.redo_rounded, size: 20),
                              tooltip: '重做',
                              onPressed: bloc.canSendRedo ? () => bloc.sendRedo() : null,
                            ),
                          ],
                        );
                      },
                    ),
                    const VerticalDivider(width: 16, indent: 12, endIndent: 12),
                    BlocBuilder<TransformCubit, CameraTransform>(
                      builder: (context, transform) {
                        final zoomPercent = (transform.size * 100).round();
                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => context.read<TransformCubit>().reset(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Text(
                              '$zoomPercent%',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                        );
                      },
                    ),
                    ListenableBuilder(
                      listenable: PalmGuardService.instance,
                      builder: (context, _) {
                        final pgState = PalmGuardService.instance.state;
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                pgState.penOnlyMode ? Icons.edit_rounded : Icons.touch_app_rounded,
                                size: 20,
                                color: pgState.penOnlyMode ? theme.colorScheme.primary : null,
                              ),
                              tooltip: pgState.penOnlyMode ? '当前：仅手写笔书写（单指防误触，双指缩放）' : '当前：允许手指书写',
                              onPressed: () {
                                final next = !pgState.penOnlyMode;
                                PalmGuardService.instance.setPenOnlyMode(next);
                                _syncInputModeWithButterfly(next);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.back_hand_outlined, size: 19),
                              tooltip: '防误触握姿与灵敏度设置',
                              onPressed: () => showMumuPalmGuardModal(context),
                            ),
                          ],
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.grid_view_rounded, size: 19),
                      tooltip: '页面管理',
                      onPressed: () {
                        final bloc = context.read<DocumentBloc>();
                        final docState = bloc.state;
                        if (docState is DocumentLoadSuccess) {
                          final pages = docState.data.getPages(true);
                          showDialog(
                            context: context,
                            builder: (_) => SelectPagesDialog(
                              pages: [
                                for (int i = 0; i < pages.length; i++)
                                  (
                                    NoteData.getPageNameFromRealName(pages[i]).isEmpty
                                        ? '第 ${i + 1} 页'
                                        : NoteData.getPageNameFromRealName(pages[i]),
                                    pages[i],
                                  ),
                              ],
                              initialSelected: [docState.pageName],
                            ),
                          );
                        }
                      },
                    ),
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz_rounded, size: 20),
                      tooltip: '更多功能',
                      onSelected: (value) {
                        final bloc = context.read<DocumentBloc>();
                        final docState = bloc.state;
                        switch (value) {
                          case 'background':
                            Actions.maybeInvoke(context, BackgroundIntent());
                            break;
                          case 'export_pdf':
                            Actions.maybeInvoke(context, PdfExportIntent());
                            break;
                          case 'clear_page':
                            if (docState is DocumentLoadSuccess) {
                              final ids = docState.page.layers
                                  .expand((l) => l.content)
                                  .map((e) => e.id)
                                  .whereType<String>()
                                  .toList();
                              if (ids.isNotEmpty) {
                                bloc.add(ElementsRemoved(ids));
                              }
                            }
                            break;
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem(
                          value: 'background',
                          child: ListTile(
                            leading: Icon(Icons.texture_rounded),
                            title: Text('更换纸张模板/背景'),
                            dense: true,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'export_pdf',
                          child: ListTile(
                            leading: Icon(Icons.picture_as_pdf_rounded),
                            title: Text('导出为 PDF 文档'),
                            dense: true,
                          ),
                        ),
                        PopupMenuItem(
                          value: 'clear_page',
                          child: ListTile(
                            leading: Icon(Icons.delete_sweep_rounded, color: Colors.redAccent),
                            title: Text('清空当前页笔迹'),
                            dense: true,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        BlocBuilder<ToolCubit, ToolRuntimeState>(
          builder: (context, toolState) {
            final currentTool = toolState.handler.data;
            final isPen =
                currentTool is PenTool &&
                ((currentTool.property.paint.previewColor.value >> 24) & 0xFF) > 200;
            final isHighlighter =
                currentTool is PenTool &&
                ((currentTool.property.paint.previewColor.value >> 24) & 0xFF) <= 200;
            final isEraser = currentTool is EraserTool;
            final isLasso = currentTool is SelectTool;
            final isShape = currentTool is ShapeTool;
            final isLaser = currentTool is LaserTool;
            final isText = currentTool is LabelTool;
            final isHand = currentTool is HandTool;

            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: surfaceColor,
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _PenDockButton(
                        icon: Icons.create_rounded,
                        label: '钢笔',
                        selected: isPen,
                        activeColor: Color(_selectedColor),
                        onTap: () {
                          if (isPen) {
                            setState(() => _showPenSettingsPopup = !_showPenSettingsPopup);
                          } else {
                            _selectPen(isHighlighter: false);
                          }
                        },
                      ),
                      _PenDockButton(
                        icon: Icons.border_color_rounded,
                        label: '荧光笔',
                        selected: isHighlighter,
                        activeColor: Color(_selectedColor),
                        onTap: () => _selectPen(isHighlighter: true),
                      ),
                      _PenDockButton(
                        icon: Icons.auto_fix_normal_rounded,
                        label: '橡皮擦',
                        selected: isEraser,
                        onTap: () => _selectEraser(pathEraser: true),
                      ),
                      _PenDockButton(
                        icon: Icons.gesture_rounded,
                        label: '套索',
                        selected: isLasso,
                        onTap: _selectLasso,
                      ),
                      _PenDockButton(
                        icon: Icons.category_outlined,
                        label: '图形',
                        selected: isShape,
                        onTap: _selectShape,
                      ),
                      _PenDockButton(
                        icon: Icons.flare_rounded,
                        label: '激光笔',
                        selected: isLaser,
                        onTap: _selectLaser,
                      ),
                      _PenDockButton(
                        icon: Icons.text_fields_rounded,
                        label: '文本',
                        selected: isText,
                        onTap: _selectText,
                      ),
                      _PenDockButton(
                        icon: Icons.pan_tool_alt_outlined,
                        label: '抓手',
                        selected: isHand,
                        onTap: _selectHand,
                      ),
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () => setState(() => _showPenSettingsPopup = !_showPenSettingsPopup),
                        child: Container(
                          width: 24,
                          height: 24,
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(
                            color: Color(_selectedColor),
                            shape: BoxShape.circle,
                            border: Border.all(color: theme.colorScheme.outlineVariant, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_showPenSettingsPopup)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: surfaceColor,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 12),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int i = 0; i < _strokeSizes.length; i++)
                          GestureDetector(
                            onTap: () {
                              setState(() => _selectedSizeIndex = i);
                              _selectPen(isHighlighter: isHighlighter);
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              margin: const EdgeInsets.only(right: 4),
                              decoration: BoxDecoration(
                                color: _selectedSizeIndex == i
                                    ? theme.colorScheme.primaryContainer
                                    : Colors.transparent,
                                shape: BoxShape.circle,
                              ),
                              child: Container(
                                width: 6.0 + i * 4.0,
                                height: 6.0 + i * 4.0,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.onSurface,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 10),
                        for (final colorValue in _inkColors)
                          GestureDetector(
                            onTap: () {
                              setState(() => _selectedColor = colorValue);
                              _selectPen(isHighlighter: isHighlighter);
                            },
                            child: Container(
                              width: 22,
                              height: 22,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(
                                color: Color(colorValue),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _selectedColor == colorValue
                                      ? theme.colorScheme.primary
                                      : Colors.transparent,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PenDockButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final Color? activeColor;
  final VoidCallback onTap;

  const _PenDockButton({
    required this.icon,
    required this.label,
    required this.selected,
    this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? (activeColor ?? theme.colorScheme.primary)
        : theme.colorScheme.onSurfaceVariant;
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(icon, size: 20, color: color),
        ),
      ),
    );
  }
}

// ============================================================================
// 2. 兼容保留组件：MumuSecondaryPenBoxCapsule
// ============================================================================

class MumuSecondaryPenBoxCapsule extends StatelessWidget {
  const MumuSecondaryPenBoxCapsule({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }
}

// ============================================================================
// 3. Mumu 2.0 完整编辑器工作台
//    覆盖功能手册第 2~4 章的编辑界面
// ============================================================================

enum MumuPenCaseDock { bottom, top, left, right, fixedTopBar, minimizedCorner }

enum MumuInputMode {
  stylusOnly, // A1 触控笔模式 (笔=写，指=导航，支持单指双击适配宽度)
  fingerWrite, // A2 手指书写模式 (手指直接书写，双指滚动翻页，禁用单指双击适配)
  capacitivePen, // A3 被动电容笔专属模式 (自动收紧接触面积与椭圆偏心率阈值，强化无压感防误触)
}

class _MumuFavoritePenPreset {
  final String id;
  final String label;
  final String penKind; // 'fountain', 'ballpoint', 'pencil', 'rainbow', 'highlighter', 'tape'
  final Color color;
  final double strokeWidth;

  const _MumuFavoritePenPreset({
    required this.id,
    required this.label,
    required this.penKind,
    required this.color,
    required this.strokeWidth,
  });
}

class MumuEditorWorkspace extends StatefulWidget {
  final GlobalKey<MainViewViewportState> viewportKey;
  final Object? searchController;

  const MumuEditorWorkspace({super.key, required this.viewportKey, this.searchController});

  @override
  State<MumuEditorWorkspace> createState() => _MumuEditorWorkspaceState();
}

class _MumuEditorWorkspaceState extends State<MumuEditorWorkspace> {
  // 视图模式 (Ch. 3.14 & C1 沉浸式工具栏)
  bool _readingMode = false; // 阅读模式 (隐藏所有编辑工具，仅保留导航)
  bool _focusZenMode = false; // 专注模式 (全屏无干扰，右上角保留小胶囊恢复)
  bool _tabBarMode = false; // 标签页模式 (顶部显示多文档切换标签栏)
  bool _immersiveToolbarMode = false; // C1 沉浸式工具栏 (极简收起，点击顶部胶囊呼出)
  bool _immersiveToolbarExpanded = false; // 沉浸式模式下临时呼出展开态

  // A4/A6 临时橡皮恢复记忆 & D1 套索三模式 & D6 记忆胶带 & B8 可拖动缩放胶囊
  int? _savedToolIndexBeforeTempEraser;
  int _lassoMode = 0; // 0: 自由套索, 1: 矩形套索, 2: 截图与双向链接
  bool _showLassoBar = false;
  int? _lastToolIndexBeforeLasso;
  double _rulerGestureStartAngle = 0.0;
  bool _hideAllMemoryTapes = false;
  final List<({String id, Offset pos, Size size, String answer, bool revealed, Color color})>
  _memoryTapes = [];

  // 笔盒停靠状态与拖拽位置：默认吸附在底部中央，不遮挡顶部主工具栏；可由顶栏「笔盒」图标一键显隐
  MumuPenCaseDock _penCaseDock = MumuPenCaseDock.bottom;
  bool _showFloatingPenCase = false;
  Offset? _floatingPenCaseOffset;
  bool _showPenSettingsPopover = false;

  // 笔的收藏侧边悬浮条 (Ch. 2.2 & Video _lPiEBDHbPY)
  bool _showPenFavoritesStrip = false;
  Offset _favoritesStripOffset = const Offset(14, 150);
  final List<_MumuFavoritePenPreset> _favoritePresets = [
    const _MumuFavoritePenPreset(
      id: 'fav_1',
      label: '钢笔·墨黑',
      penKind: 'fountain',
      color: Color(0xFF1E293B),
      strokeWidth: 2.8,
    ),
    const _MumuFavoritePenPreset(
      id: 'fav_2',
      label: '圆珠·睿智蓝',
      penKind: 'ballpoint',
      color: Color(0xFF2F7D6E),
      strokeWidth: 2.2,
    ),
    const _MumuFavoritePenPreset(
      id: 'fav_3',
      label: '批注·朱砂红',
      penKind: 'fountain',
      color: Color(0xFFDC2626),
      strokeWidth: 2.5,
    ),
    const _MumuFavoritePenPreset(
      id: 'fav_4',
      label: '荧光·暖黄',
      penKind: 'highlighter',
      color: Color(0xFFF59E0B),
      strokeWidth: 14.0,
    ),
    const _MumuFavoritePenPreset(
      id: 'fav_5',
      label: '胶带·森绿',
      penKind: 'tape',
      color: Color(0xFF10B981),
      strokeWidth: 16.0,
    ),
  ];

  // 顶部中央工具栏可自定义快捷工具集合
  final Set<String> _starredTopTools = {
    'pen_case',
    'pen',
    'highlighter',
    'eraser',
    'lasso',
    'textbox',
    'shape',
    'tape_mask',
    'insert',
    'ruler',
    'layers',
    'laser',
    'pan',
  };

  // 侧边抽屉与浮层开关
  bool _showLeftDocListDrawer = false; // 3.13 文档列表侧边栏
  String _docListSearchQuery = '';
  bool _draggingDocFromList = false;
  bool _showRightSidebar = false; // 3.18 右侧边栏 (页面/大纲/批注)
  int _rightSidebarTab = 0; // 0: 页面缩略图, 1: 大纲, 2: 标注与双链
  bool _showFloatingLayersPanel = false; // 3.9 图层面板
  bool _showSimulationRuler = false; // 3.11 仿真可旋转标尺
  double _rulerAngleDeg = 0.0;
  Offset _rulerOffset = const Offset(8, 150);

  // 点击朗读模式状态
  int? _savedToolIndexBeforeReading;
  bool _showStarredQuickTools = false;

  // 应用内分屏状态（支持双文档并排分屏与同文档双页对照）
  bool _splitViewOpen = false;
  bool _splitVertical = true; // true: 左右垂直分屏, false: 上下水平分屏
  bool _splitSwapped = false; // 是否互换左右/上下主副窗口位置
  double _splitRatio = 0.50;
  int _activeSplitPane = 0; // 0: 主窗口激活, 1: 分屏副窗口激活
  String? _splitSecondaryFilePath; // null 表示同文档双页分屏；非 null 表示打开另一篇笔记本
  String? _splitSecondaryPageName;
  _SplitSecondaryDocumentRuntime? _splitSecondaryRuntime;
  bool _splitSecondaryLoading = false;
  final TextEditingController _splitNoteController = TextEditingController();

  // 页面缩放浮动胶囊与缩放锁定 (Ch. 4.7 & 10.6)
  bool _zoomLocked = false;

  // 输入模式 (Ch. 3.17)
  MumuInputMode _inputMode = MumuInputMode.stylusOnly;

  // 笔盒内部状态：当前调色板颜色集 (Ch. 2.11) 与三档粗细预设 (Ch. 2.12)
  int _activeColorSetIndex = 0;
  final List<double> _thicknessPresets = [1.2, 2.8, 5.5];
  int _activeThicknessPresetIdx = 1;
  double _pressureSensitivity = 3.5;
  double _inkFlow = 0.82;
  bool _autoShapeRecognition = true;

  static const List<({String name, List<Color> colors})> _colorSets = [
    (
      name: '经典墨水',
      colors: [
        Color(0xFF1E293B),
        Color(0xFF2F7D6E),
        Color(0xFFDC2626),
        Color(0xFF059669),
        Color(0xFFD97706),
        Color(0xFF7C3AED),
        Color(0xFF0891B2),
        Color(0xFFDB2777),
        Color(0xFF4B5563),
        Color(0xFFF59E0B),
      ],
    ),
    (
      name: '莫兰迪色系',
      colors: [
        Color(0xFF4A5568),
        Color(0xFF5A7D9A),
        Color(0xFFB86B6B),
        Color(0xFF6B8E78),
        Color(0xFFC89D7C),
        Color(0xFF8C7A9E),
        Color(0xFF7A9A95),
        Color(0xFFB5838D),
        Color(0xFF6D6875),
        Color(0xFFD4A373),
      ],
    ),
    (
      name: '马卡龙色系',
      colors: [
        Color(0xFF334155),
        Color(0xFF60A5FA),
        Color(0xFFF87171),
        Color(0xFF34D399),
        Color(0xFFFBBF24),
        Color(0xFFA78BFA),
        Color(0xFF38BDF8),
        Color(0xFFF472B6),
        Color(0xFFFB923C),
        Color(0xFF4ADE80),
      ],
    ),
    (
      name: '复古手帐',
      colors: [
        Color(0xFF2C1E18),
        Color(0xFF1D3557),
        Color(0xFF9B2226),
        Color(0xFF2D6A4F),
        Color(0xFFBB3E03),
        Color(0xFF5F0F40),
        Color(0xFF005F73),
        Color(0xFFCA6702),
        Color(0xFF3D405B),
        Color(0xFFE07A5F),
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    final svc = PalmGuardService.instance;
    svc.init();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncInputModeWithButterfly(svc.state.penOnlyMode);
      final pendingSplitPath = MumuSplitLaunchQueue.pendingSecondaryPath;
      if (pendingSplitPath != null) {
        final vert = MumuSplitLaunchQueue.pendingVertical;
        MumuSplitLaunchQueue.pendingSecondaryPath = null;
        unawaited(
          _openSecondaryNotebookInSplit(
            pendingSplitPath,
            vertical: vert,
          ),
        );
      }
    });
    svc.onTwoFingerUndo = _handleGestureUndo;
    svc.onThreeFingerRedo = _handleGestureRedo;
    svc.onDoubleTapFitWidth = _handleDoubleTapFitWidth;
    svc.onEnterTemporaryEraser = _handleEnterTempEraser;
    svc.onExitTemporaryEraser = _handleExitTempEraser;
    svc.onQuickShapeHoldRecognized = _handleQuickShapeHold;
    svc.onRequestAddPageFromBottom = _handlePullUpAddPage;
  }

  DocumentBloc _getActiveBloc(BuildContext context) {
    final sec = _splitSecondaryRuntime;
    if (_splitViewOpen && _activeSplitPane == 1 && sec != null && !sec.bloc.isClosed) {
      return sec.bloc;
    }
    return context.read<DocumentBloc>();
  }

  TransformCubit _getActiveTransformCubit(BuildContext context) {
    final sec = _splitSecondaryRuntime;
    if (_splitViewOpen && _activeSplitPane == 1 && sec != null && !sec.transformCubit.isClosed) {
      return sec.transformCubit;
    }
    return context.read<TransformCubit>();
  }

  EditorController _getActiveEditorController(BuildContext context) {
    final sec = _splitSecondaryRuntime;
    if (_splitViewOpen && _activeSplitPane == 1 && sec != null) {
      return sec.editorController;
    }
    return context.read<EditorController>();
  }

  void _syncInputModeWithButterfly(bool penOnly) {
    if (!mounted) return;
    context.read<SettingsCubit>().changePenOnlyInput(penOnly);
    context.read<EditorController>().inputCubit.setSessionPenOnlyInput(penOnly);
  }

  void _showQuickInteractionToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg, style: const TextStyle(fontSize: 12)),
          duration: const Duration(milliseconds: 1300),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  void _handleGestureUndo() {
    if (!mounted) return;
    final bloc = _getActiveBloc(context);
    if (bloc.canSendUndo) {
      bloc.sendUndo();
      _showQuickInteractionToast('🖐 已触发快捷撤销');
    }
  }

  void _handleGestureRedo() {
    if (!mounted) return;
    final bloc = _getActiveBloc(context);
    if (bloc.canSendRedo) {
      bloc.sendRedo();
      _showQuickInteractionToast('🖐 已触发三指轻触重做');
    }
  }

  void _handleDoubleTapFitWidth() {
    if (!mounted || _zoomLocked) return;
    final bloc = _getActiveBloc(context);
    final st = bloc.state;
    final tc = _getActiveTransformCubit(context);
    final renderBox = context.findRenderObject();
    final vpSize = renderBox is RenderBox ? renderBox.size : const Size(800, 600);
    if (st is DocumentLoadSuccess) {
      final curIdx = st.page.activeSheetIndexForGlobalPoint(
        tc.state.localToGlobal(vpSize.center(Offset.zero)),
      );
      tc.fitMumuStandardPage(
        page: st.page,
        info: st.info,
        viewportSize: vpSize,
        sheetIndex: curIdx,
      );
    } else {
      tc.reset();
    }
    _showQuickInteractionToast('↔ 已自动居中适配标准页面宽度');
  }

  void _handleEnterTempEraser() {
    if (!mounted) return;
    final docState = context.read<DocumentBloc>().state;
    if (docState is! DocumentLoadSuccess) return;
    final controller = context.read<EditorController>();
    final bloc = context.read<DocumentBloc>();
    _savedToolIndexBeforeTempEraser = controller.toolCubit.state.index;
    final tools = docState.info.tools;
    final eraserIdx = tools.indexWhere((t) => t is EraserTool);
    if (eraserIdx != -1) {
      controller.toolCubit.changeTool(controller, bloc, index: eraserIdx, context: context);
    } else {
      final created = EraserTool(name: '临时橡皮', strokeWidth: 16);
      bloc.add(ToolCreated(created));
      controller.toolCubit.changeTool(controller, bloc, index: tools.length, context: context);
    }
    setState(() {});
    _showQuickInteractionToast('🧹 已进入临时橡皮模式（擦完抬笔自动恢复原画笔）');
  }

  void _handleExitTempEraser() {
    if (!mounted) return;
    final savedIdx = _savedToolIndexBeforeTempEraser;
    _savedToolIndexBeforeTempEraser = null;
    if (savedIdx != null) {
      final controller = context.read<EditorController>();
      final bloc = context.read<DocumentBloc>();
      controller.toolCubit.changeTool(controller, bloc, index: savedIdx, context: context);
      setState(() {});
    }
  }

  void _handleQuickShapeHold(List<Offset> pts) {
    if (!mounted || pts.length < 4) return;
    final first = pts.first;
    final last = pts.last;
    double pathLen = 0;
    for (int i = 1; i < pts.length; i++) {
      pathLen += (pts[i] - pts[i - 1]).distance;
    }
    final directDist = (last - first).distance;
    String shapeName = '规则折线/多边形';
    if (directDist / math.max(1.0, pathLen) > 0.84) {
      shapeName = '标准直线';
    } else if (directDist < pathLen * 0.25) {
      shapeName = pts.length.isEven ? '标准矩形' : '标准椭圆/圆';
    } else {
      shapeName = '标准三角形';
    }
    _showQuickInteractionToast('📐 停笔按住识别：已自动规整为 $shapeName');
  }

  void _handlePullUpAddPage() {
    if (!mounted) return;
    final bloc = _getActiveBloc(context);
    final docState = bloc.state;
    if (docState is DocumentLoadSuccess) {
      _addNewPage(
        context,
        docState,
        scrollToNewPage: false,
        targetBloc: bloc,
        targetTransform: _getActiveTransformCubit(context),
      );
      _showQuickInteractionToast('📄 页底下滑自动加页：已新增空白页（继承当前纸张模板）');
    }
  }

  @override
  void dispose() {
    final sec = _splitSecondaryRuntime;
    _splitSecondaryRuntime = null;
    if (sec != null) {
      try {
        final fs = context.read<ButterflyFileSystem>();
        unawaited(sec.saveAndClose(fs));
      } catch (_) {}
    }
    final svc = PalmGuardService.instance;
    if (svc.onTwoFingerUndo == _handleGestureUndo) svc.onTwoFingerUndo = null;
    if (svc.onThreeFingerRedo == _handleGestureRedo) svc.onThreeFingerRedo = null;
    if (svc.onDoubleTapFitWidth == _handleDoubleTapFitWidth) {
      svc.onDoubleTapFitWidth = null;
    }
    if (svc.onEnterTemporaryEraser == _handleEnterTempEraser) {
      svc.onEnterTemporaryEraser = null;
    }
    if (svc.onExitTemporaryEraser == _handleExitTempEraser) {
      svc.onExitTemporaryEraser = null;
    }
    if (svc.onQuickShapeHoldRecognized == _handleQuickShapeHold) {
      svc.onQuickShapeHoldRecognized = null;
    }
    if (svc.onRequestAddPageFromBottom == _handlePullUpAddPage) {
      svc.onRequestAddPageFromBottom = null;
    }
    _splitNoteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BlocBuilder<DocumentBloc, DocumentState>(
      builder: (context, docState) {
        if (docState is! DocumentLoadSuccess) {
          return const Material(child: Center(child: CircularProgressIndicator()));
        }
        return BlocBuilder<ToolCubit, ToolRuntimeState>(
          builder: (context, toolState) {
            return BlocBuilder<EditorInputCubit, EditorInputState>(
              builder: (context, inputState) {
                final hideAllUi = _focusZenMode;

                return Scaffold(
                  backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFE8E9EE),
                  body: SafeArea(
                    child: Column(
                      children: [
                        // 顶部导航栏与固定笔盒独立合成层（RepaintBoundary + Material 确保绝不被底层画布覆盖）
                        RepaintBoundary(
                          child: Material(
                            elevation: 3,
                            color: isDark ? const Color(0xFF1E293B) : Colors.white,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // C1 沉浸式工具栏模式：平时收起为顶部极简呼出条，点击才展开完整工具栏 (P2-3)
                                if (!hideAllUi &&
                                    _immersiveToolbarMode &&
                                    !_immersiveToolbarExpanded)
                                  _buildImmersiveCollapsedHeaderBar(context, docState, isDark)
                                else ...[
                                  // 1. 顶部标签页栏 (3.14 标签页模式)
                                  if (!hideAllUi && !_readingMode && _tabBarMode)
                                    _buildDocumentTabBar(context, docState, isDark),

                                  // 2. Mumu 顶部圆形图标主工具栏 (3.1 工具栏)
                                  if (!hideAllUi)
                                    _buildMumuTopToolbar(context, docState, toolState, isDark),

                                  // 3. 若开启“固定顶部工具栏”模式，笔盒直接嵌入在顶部主栏下方 (Video mkcLMr0zj3g 00:50)
                                  if (!hideAllUi &&
                                      !_readingMode &&
                                      _penCaseDock == MumuPenCaseDock.fixedTopBar)
                                    _buildFixedTopPenCaseBar(context, docState, toolState, isDark),
                                ],

                              ],
                            ),
                          ),
                        ),

                        // 5. 主画布舞台区 (+ 应用内分屏 + 浮动笔盒 + 收藏笔架 + 标尺 + 侧边栏)
                        Expanded(
                          child: ClipRect(
                            child: LayoutBuilder(
                              builder: (context, stageConstraints) {
                                // 关键：必须 expand。否则画布/工具栏全是 Positioned 子组件时，
                                // Stack 会按非定位子组件（收缩为 0）计算尺寸，画布宽度会变成 0。
                                return Stack(
                                  fit: StackFit.expand,
                                  clipBehavior: Clip.hardEdge,
                                  children: [
                                    // 5.1 底层主画布或应用内双开分屏容器
                                    Positioned.fill(
                                      child: ClipRect(
                                        child: _buildCanvasAndSplitHost(
                                          context,
                                          docState,
                                          stageConstraints,
                                          isDark,
                                        ),
                                      ),
                                    ),

                                    // 5.2 手掌误触拦截红色波纹视觉反馈层
                                    const MumuPalmRejectRippleLayer(),

                                    // 5.2b 底部可拖拽虚拟防误触手垫：位于所有工具栏/按钮之下，
                                    //      只吸收画布上的手掌误触，绝不遮挡笔盒与页码等 UI
                                    const MumuVirtualPalmShieldOverlay(),

                                    // 5.3 选中元素点击空白取消监听（铺满画布，之前因无尺寸而完全失效）
                                    Positioned.fill(
                                      child: _buildSelectionResetListener(context, toolState),
                                    ),

                                    // 5.3b D6 记忆胶带背诵遮盖层（支持点击单条显隐 & 顶栏全局显隐）
                                    if (_memoryTapes.isNotEmpty && !_hideAllMemoryTapes)
                                      ..._buildMemoryTapeOverlays(context, isDark),

                                    // 缩放比例显示与一键复位已集成至顶部 48dp 极简一体栏，不再遮挡画布左上角

                                    // 5.4b D1/D2 套索三模式与浮动选区操作栏 (自由/矩形/分屏双链 + 一键解锁锁定对象)
                                    if (!hideAllUi &&
                                        (_showLassoBar ||
                                            _isToolSelectedByType<SelectTool>(
                                              docState,
                                              toolState,
                                            ) ||
                                            toolState.selection != null))
                                      Positioned(
                                        // 顶栏笔盒固定在上方时，把套索工具条下移，避免被笔盒遮住
                                        top:
                                            (_penCaseDock == MumuPenCaseDock.top ||
                                                _penCaseDock == MumuPenCaseDock.fixedTopBar ||
                                                _penCaseDock == MumuPenCaseDock.minimizedCorner)
                                            ? 108
                                            : 12,
                                        left: 0,
                                        right: 0,
                                        child: Center(
                                          child: _buildLassoThreeModeFloatingBar(
                                            context,
                                            docState,
                                            toolState,
                                            isDark,
                                          ),
                                        ),
                                      ),

                                    // 5.4c B9 页底上滑添加新页实时预览提示横幅
                                    Positioned(
                                      bottom: 56,
                                      left: 0,
                                      right: 0,
                                      child: _buildBottomPullUpPageAddBanner(context, isDark),
                                    ),

                                    // 5.5 左下角页码角标与快速加页胶囊 (4.1 添加新页面)
                                    if (!hideAllUi)
                                      Positioned(
                                        bottom: 14,
                                        left: 16,
                                        child: _buildBottomPageNavigatorPill(
                                          context,
                                          docState,
                                          stageConstraints,
                                          isDark,
                                        ),
                                      ),

                                    // 5.5b 右侧纵向连续分页快速滚动条与一键下滑加页器 (标准分页模式专属)
                                    if (!hideAllUi &&
                                        !_showRightSidebar &&
                                        !docState.page.isMumuInfiniteCanvas(docState.info))
                                      Positioned(
                                        right: 8,
                                        top: 18,
                                        bottom: 68,
                                        child: _buildVerticalPageScrubber(
                                          context,
                                          docState,
                                          stageConstraints,
                                          isDark,
                                        ),
                                      ),

                                    // 5.6 仿真可旋转磁吸标尺 (3.11 标尺 Ruler)
                                    if (_showSimulationRuler && !hideAllUi)
                                      Positioned(
                                        left: _rulerOffset.dx,
                                        top: _rulerOffset.dy,
                                        child: _buildSimulationRulerOverlay(context),
                                      ),

                                    // 5.7 独立侧边「笔的收藏」悬浮条 (2.2 & Video _lPiEBDHbPY)
                                    if (!hideAllUi && !_readingMode && _showPenFavoritesStrip)
                                      Positioned(
                                        left: _favoritesStripOffset.dx.clamp(
                                          6.0,
                                          math.max(12.0, stageConstraints.maxWidth - 68.0),
                                        ),
                                        top: _favoritesStripOffset.dy.clamp(
                                          12.0,
                                          math.max(24.0, stageConstraints.maxHeight - 280.0),
                                        ),
                                        child: _buildPenFavoritesSideStrip(
                                          context,
                                          docState,
                                          toolState,
                                          stageConstraints,
                                          isDark,
                                        ),
                                      ),

                                    // 5.8 Mumu 标志性可拖拽四边磁吸「笔盒」(点击顶栏笔盒按钮展开/收起)
                                    if (!hideAllUi &&
                                        !_readingMode &&
                                        _showFloatingPenCase &&
                                        _penCaseDock != MumuPenCaseDock.fixedTopBar)
                                      _buildDockableFloatingPenCase(
                                        context,
                                        docState,
                                        toolState,
                                        stageConstraints,
                                        isDark,
                                      ),

                                    // 5.9 二次点击笔刷弹出的「笔刷参数与压感/墨水流量设置面板」
                                    if (!hideAllUi && !_readingMode && _showPenSettingsPopover)
                                      _buildPenSettingsPopoverCard(
                                        context,
                                        docState,
                                        toolState,
                                        stageConstraints,
                                        isDark,
                                      ),

                                    // 5.10 浮动图层面板 (3.9 图层系统 Layer System)
                                    if (!hideAllUi && _showFloatingLayersPanel)
                                      Positioned(
                                        top: 12,
                                        right: _showRightSidebar ? 304 : 16,
                                        child: _buildFloatingLayersCard(context, docState, isDark),
                                      ),

                                    // 5.11 左侧滑出「文档列表」侧边栏 (3.13 & Video Krk8JtQNWmw)
                                    if (_showLeftDocListDrawer && !hideAllUi)
                                      Positioned(
                                        top: 0,
                                        bottom: 0,
                                        left: 0,
                                        width: 300,
                                        child: _buildLeftDocumentListDrawer(
                                          context,
                                          docState,
                                          isDark,
                                        ),
                                      ),

                                    // 5.12 右侧滑出「页面概览 / 大纲 / 批注与双向链接」侧边栏 (3.18)
                                    if (_showRightSidebar && !hideAllUi)
                                      Positioned(
                                        top: 0,
                                        bottom: 0,
                                        right: 0,
                                        width: 292,
                                        child: _buildRightSidebarDrawer(context, docState, isDark),
                                      ),

                                    // 5.13 底部防误触手垫已上移到画布之上、工具栏之下（见 5.2b）

                                    // 5.14 专注模式右上角恢复胶囊 (3.14 专注模式)
                                    if (hideAllUi)
                                      Positioned(
                                        top: 12,
                                        right: 14,
                                        child: _buildExitZenFloatingButton(context),
                                      ),
                                  ],
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSelectionResetListener(BuildContext context, ToolRuntimeState toolState) {
    return Listener(
      behavior: toolState.pinned || toolState.selection == null
          ? HitTestBehavior.translucent
          : HitTestBehavior.opaque,
      onPointerUp: (_) {
        if (_showPenSettingsPopover) {
          setState(() => _showPenSettingsPopover = false);
        }
        if (toolState.pinned) return;
        context.read<ToolCubit>().resetSelection();
      },
    );
  }

  // --------------------------------------------------------------------------
  // 1. 顶部多文档与多页标签栏 (3.14 标签页模式 · 支持一键分屏)
  // --------------------------------------------------------------------------
  Widget _buildDocumentTabBar(BuildContext context, DocumentLoadSuccess docState, bool isDark) {
    final docName = docState.metadata.name.isEmpty ? '未命名笔记' : docState.metadata.name;
    final isInfinite = docState.page.isMumuInfiniteCanvas(docState.info);
    final sheets = docState.page.resolvedPageSheets;
    final secRuntime = _splitSecondaryRuntime;

    return BlocBuilder<TransformCubit, CameraTransform>(
      builder: (context, transform) {
        final curSheetIdx = isInfinite
            ? 0
            : docState.page.activeSheetIndexForGlobalPoint(
                transform.localToGlobal(const Offset(400, 300)),
              );
        return Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F4F9),
            border: Border(
              bottom: BorderSide(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
              ),
            ),
          ),
          child: Row(
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _saveAndExitToHome(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.menu_book_rounded, size: 14, color: Color(0xFF2F7D6E)),
                      const SizedBox(width: 4),
                      Text(
                        '书架',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white70 : const Color(0xFF374151),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    // 主文档与各分页快捷标签
                    for (int i = 0; i < (isInfinite ? 1 : sheets.length); i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 4, top: 4),
                        child: InkWell(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          onTap: () {
                            setState(() => _activeSplitPane = 0);
                            if (!isInfinite) {
                              _scrollToSheetIndex(context, docState, i);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: (i == curSheetIdx && _activeSplitPane == 0)
                                  ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                                  : (isDark
                                        ? const Color(0xFF1E293B).withValues(alpha: 0.45)
                                        : const Color(0xFFE5E9F2)),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isInfinite
                                      ? Icons.all_inclusive_rounded
                                      : Icons.description_outlined,
                                  size: 12,
                                  color: i == curSheetIdx
                                      ? const Color(0xFF2F7D6E)
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  isInfinite
                                      ? '$docName · 无限画布'
                                      : (i == 0 ? '$docName · 第 1 页' : '第 ${i + 1} 页'),
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: i == curSheetIdx
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: i == curSheetIdx
                                        ? (isDark ? Colors.white : const Color(0xFF111827))
                                        : Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // 若已开启分屏且打开了第二篇文档，显示分屏副文档标签
                    if (_splitViewOpen && secRuntime != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 4, top: 4),
                        child: InkWell(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          onTap: () => setState(() => _activeSplitPane = 1),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: _activeSplitPane == 1
                                  ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                                  : const Color(0xFF2F7D6E).withValues(alpha: 0.12),
                              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.vertical_split_rounded,
                                  size: 12,
                                  color: Color(0xFF2F7D6E),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '分屏：${secRuntime.displayTitle}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF2F7D6E),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (!isInfinite)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                          tooltip: '添加新页面',
                          icon: const Icon(Icons.add, size: 15),
                          onPressed: () => _addNewPage(context, docState),
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                tooltip: '打开文档列表或分屏打开其他笔记',
                icon: const Icon(Icons.note_add_outlined, size: 15, color: Color(0xFF2F7D6E)),
                onPressed: () => setState(() => _showLeftDocListDrawer = true),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                tooltip: '隐藏标签栏',
                icon: const Icon(Icons.keyboard_arrow_up, size: 16),
                onPressed: () => setState(() => _tabBarMode = false),
              ),
            ],
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // 2. 顶部主工具栏（左侧导航与文档侧栏，中间圆形笔刷工具坞，右侧防误触、分屏、页面侧栏与更多）
  // --------------------------------------------------------------------------
  Future<void> _runToolbarAction(
    String action,
    BuildContext context,
    DocumentLoadSuccess docState,
  ) async {
    final activeBloc = _getActiveBloc(context);
    final activeState = activeBloc.state is DocumentLoadSuccess
        ? activeBloc.state as DocumentLoadSuccess
        : docState;

    switch (action) {
      case 'pen_case':
        setState(() {
          if (_penCaseDock == MumuPenCaseDock.fixedTopBar) {
            _penCaseDock = MumuPenCaseDock.bottom;
            _showFloatingPenCase = true;
          } else {
            _showFloatingPenCase = !_showFloatingPenCase;
            if (_showFloatingPenCase &&
                _penCaseDock == MumuPenCaseDock.minimizedCorner) {
              _penCaseDock = MumuPenCaseDock.bottom;
            }
          }
          _showPenSettingsPopover = false;
        });
        _showQuickInteractionToast(
          _showFloatingPenCase ? '✏️ 已展开悬浮笔盒（可拖拽吸附四边）' : '已收起悬浮笔盒',
        );
        break;
      case 'pen':
        _activateOrConfigureNamedPen(
          context,
          activeState,
          preferredKeywords: const ['钢笔', '圆珠', '铅笔', '彩虹'],
          fallbackFactory: () => PenTool(
            id: createUniqueId(),
            name: '钢笔',
            shapeDetectionEnabled: true,
            property: const PenProperty(
              strokeWidth: 2.8,
              thinning: 0.55,
              smoothing: 0.55,
              paint: ElementPaint.solid(color: SRGBColor(0xFF1E293B)),
            ),
          ),
        );
        break;
      case 'highlighter':
        _activateOrConfigureNamedPen(
          context,
          activeState,
          preferredKeywords: const ['荧光', 'highlight'],
          fallbackFactory: () => PenTool(
            id: createUniqueId(),
            name: '荧光笔',
            shapeDetectionEnabled: true,
            property: const PenProperty(
              strokeWidth: 14.0,
              thinning: 0.0,
              smoothing: 0.70,
              paint: ElementPaint.solid(color: SRGBColor(0x58F59E0B)),
            ),
          ),
        );
        break;
      case 'eraser':
        _activateOrConfigureToolByType<EraserTool>(
          context,
          activeState,
          () => EraserTool(
            id: createUniqueId(),
            name: '橡皮擦',
            mode: EraserMode.stroke,
            strokeWidth: 12.0,
          ),
        );
        break;
      case 'shape':
        _activateOrConfigureToolByType<ShapeTool>(
          context,
          activeState,
          () => ShapeTool(
            id: createUniqueId(),
            name: '图形笔',
            property: const ShapeProperty(
              strokeWidth: 3.0,
              shape: RectangleShape(),
              paint: ElementPaint.solid(color: SRGBColor(0xFF2F7D6E)),
            ),
          ),
        );
        break;
      case 'laser':
        _selectOrCreateToolByType<LaserTool>(
          context,
          activeState,
          () => LaserTool(
            id: createUniqueId(),
            name: '激光笔',
            duration: 3.0,
            strokeWidth: 4.5,
            color: BasicColors.red,
          ),
        );
        _showQuickInteractionToast('🔴 激光笔已开启：在页面上划动可展示演示轨迹');
        break;
      case 'pan':
        _selectOrCreateToolByType<HandTool>(
          context,
          activeState,
          () => HandTool(id: createUniqueId(), name: '漫游'),
        );
        _showQuickInteractionToast('✋ 漫游翻页模式：单指上下滑动即可连续翻页，下滑到底部自动加页');
        break;
      case 'lasso':
        final controller = _getActiveEditorController(context);
        final toolState = controller.toolCubit.state;
        final tools = activeState.info.tools;
        final idx = toolState.index;
        final isLassoSelected = idx != null &&
            idx >= 0 &&
            idx < tools.length &&
            tools[idx] is SelectTool;
        if (isLassoSelected) {
          // 再次点击套索：退出套索并恢复进入前的画笔（符合 Mumu 的再次点击取消）
          final restoreIdx = _lastToolIndexBeforeLasso ??
              tools.indexWhere((t) => t is PenTool);
          _lastToolIndexBeforeLasso = null;
          setState(() => _showLassoBar = false);
          controller.toolCubit.resetSelection(force: true);
          if (restoreIdx != null && restoreIdx >= 0 && restoreIdx < tools.length) {
            controller.toolCubit.setIndex(restoreIdx);
            unawaited(
              controller.toolCubit.changeTool(
                controller,
                activeBloc,
                index: restoreIdx,
                context: context,
              ),
            );
            unawaited(
              controller.toolCubit.updateTool(
                controller,
                activeBloc,
                tools[restoreIdx],
              ),
            );
            _showQuickInteractionToast('已退出套索，恢复画笔工具');
          } else {
            _showQuickInteractionToast('已退出套索选择');
          }
        } else {
          _lastToolIndexBeforeLasso = idx;
          _selectOrCreateToolByType<SelectTool>(
            context,
            activeState,
            () => SelectTool(name: '套索', mode: SelectMode.lasso),
          );
          setState(() => _showLassoBar = true);
          _showQuickInteractionToast('套索已开启：圈选笔迹后可删除、缩放或移动');
        }
        break;
      case 'textbox':
        _selectOrCreateToolByType<LabelTool>(
          context,
          activeState,
          () => LabelTool(name: '文本'),
        );
        _showQuickInteractionToast('🔤 文本工具已选中：轻点页面任意位置输入文字');
        break;
      case 'insert':
        await _showMumuInsertMenuDialog(context, activeState);
        break;
      case 'layers':
        setState(() => _showFloatingLayersPanel = !_showFloatingLayersPanel);
        break;
      case 'ruler':
        setState(() => _showSimulationRuler = !_showSimulationRuler);
        break;
      case 'memory_tape':
      case 'tape_mask':
        _addMemoryTapeStrip(context);
        break;
      case 'smart_ai':
        await _showMumuAiAndHandwritingDialog(context, activeState);
        break;
      case 'split':
        await _showMumuSplitViewModal(context, docState);
        break;
      case 'tiled':
        await _openTiledPageOverviewModal(context, activeState);
        break;
      case 'customize':
        await _showToolbarCustomizePopover(context);
        break;
      case 'input_mode':
        await _showInputModeSelectorMenu(context);
        break;
      case 'immersive':
        setState(() {
          _immersiveToolbarMode = !_immersiveToolbarMode;
          _immersiveToolbarExpanded = false;
        });
        _showQuickInteractionToast(
          _immersiveToolbarMode ? '✨ 已进入沉浸式工具栏：顶部收起为极简胶囊' : '已退出沉浸式工具栏',
        );
        break;
      case 'zoom_reset':
        _handleDoubleTapFitWidth();
        break;
      case 'background':
        Actions.maybeInvoke(context, BackgroundIntent());
        break;
      case 'export':
        Actions.maybeInvoke(context, PdfExportIntent());
        break;
      case 'palm_calib':
        await showMumuCalibrationModal(context);
        break;
      case 'more':
        await _showMumuMoreMenuSheet(context, activeState);
        break;
    }
  }

  void _activateOrConfigureNamedPen(
    BuildContext context,
    DocumentLoadSuccess docState, {
    required List<String> preferredKeywords,
    required PenTool Function() fallbackFactory,
  }) {
    final bloc = _getActiveBloc(context);
    final controller = _getActiveEditorController(context);
    final tools = List<Tool>.from(docState.info.tools);
    final activeIdx = controller.toolCubit.state.index;

    int matchIdx = -1;
    if (activeIdx != null &&
        activeIdx >= 0 &&
        activeIdx < tools.length &&
        tools[activeIdx] is PenTool) {
      final curName = tools[activeIdx].name.toLowerCase();
      if (preferredKeywords.any((k) => curName.contains(k.toLowerCase()))) {
        // 再次点击当前已选中的笔刷：直接弹出 Mumu 笔刷参数与颜色设置气泡！
        setState(() => _showPenSettingsPopover = !_showPenSettingsPopover);
        return;
      }
    }

    for (var i = 0; i < tools.length; i++) {
      final t = tools[i];
      if (t is PenTool) {
        final n = t.name.toLowerCase();
        if (preferredKeywords.any((k) => n.contains(k.toLowerCase()))) {
          matchIdx = i;
          break;
        }
      }
    }

    late final Tool targetTool;
    if (matchIdx != -1) {
      targetTool = tools[matchIdx];
    } else {
      matchIdx = tools.length;
      targetTool = fallbackFactory();
      tools.add(targetTool);
      bloc.add(ToolsReplaced(tools));
    }

    controller.toolCubit.setIndex(matchIdx);
    unawaited(
      controller.toolCubit.changeTool(
        controller,
        bloc,
        index: matchIdx,
        context: context,
      ),
    );
    unawaited(controller.toolCubit.updateTool(controller, bloc, targetTool));
    _syncToolToSecondarySplitIfNeeded(matchIdx, targetTool);
    setState(() => _showPenSettingsPopover = false);
  }

  void _activateOrConfigureToolByType<T extends Tool>(
    BuildContext context,
    DocumentLoadSuccess docState,
    T Function() factory,
  ) {
    final controller = _getActiveEditorController(context);
    final tools = docState.info.tools;
    final activeIdx = controller.toolCubit.state.index;
    if (activeIdx != null &&
        activeIdx >= 0 &&
        activeIdx < tools.length &&
        tools[activeIdx] is T) {
      setState(() => _showPenSettingsPopover = !_showPenSettingsPopover);
      return;
    }
    _selectOrCreateToolByType<T>(context, docState, factory);
    setState(() => _showPenSettingsPopover = false);
  }

  void _syncToolToSecondarySplitIfNeeded(int toolIdx, Tool tool) {
    final sec = _splitSecondaryRuntime;
    if (sec == null || sec.bloc.isClosed) return;
    final secState = sec.bloc.state;
    if (secState is! DocumentLoadSuccess) return;
    final secTools = secState.info.tools;
    if (toolIdx >= 0 && toolIdx < secTools.length) {
      sec.editorController.toolCubit.setIndex(toolIdx);
      unawaited(
        sec.editorController.toolCubit.updateTool(
          sec.editorController,
          sec.bloc,
          secTools[toolIdx],
        ),
      );
    }
  }

  /// 顶部三段式导航与圆形图标主工具栏
  Widget _buildMumuTopToolbar(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    bool isDark,
  ) {
    final activeBloc = _getActiveBloc(context);
    final activeController = _getActiveEditorController(context);
    final activeDocState = activeBloc.state is DocumentLoadSuccess
        ? activeBloc.state as DocumentLoadSuccess
        : docState;
    final activeToolState = activeController.toolCubit.state;
    final docTitle = activeDocState.metadata.name.isEmpty
        ? '未命名笔记'
        : activeDocState.metadata.name;
    final isInfinite = activeDocState.page.isMumuInfiniteCanvas(activeDocState.info);
    final sheets = activeDocState.page.resolvedPageSheets;

    final tools = activeDocState.info.tools;
    final activeIdx = activeToolState.index;
    final activeTool = (activeIdx != null && activeIdx >= 0 && activeIdx < tools.length)
        ? tools[activeIdx]
        : null;

    // 解析当前书写笔与荧光笔的实时颜色，用于在顶部工具栏图标下方显示 Mumu 标志性彩条
    Color writingPenColor = const Color(0xFF1E293B);
    Color highlighterColor = const Color(0xFFF59E0B);
    bool isWritingPenActive = false;
    bool isHighlighterActive = false;
    for (final t in tools) {
      if (t is PenTool) {
        final isHl = t.name.contains('荧光') || t.name.toLowerCase().contains('highlight');
        if (isHl) {
          highlighterColor = Color(t.property.paint.previewColor.value).withValues(alpha: 1.0);
        } else if (t.name.contains('钢笔') || t.name.contains('圆珠')) {
          writingPenColor = Color(t.property.paint.previewColor.value);
        }
      }
    }
    if (activeTool is PenTool) {
      final isHl = activeTool.name.contains('荧光') ||
          activeTool.name.toLowerCase().contains('highlight');
      if (isHl) {
        isHighlighterActive = true;
        highlighterColor =
            Color(activeTool.property.paint.previewColor.value).withValues(alpha: 1.0);
      } else {
        isWritingPenActive = true;
        writingPenColor = Color(activeTool.property.paint.previewColor.value);
      }
    }

    return BlocBuilder<TransformCubit, CameraTransform>(
      builder: (context, transform) {
        final curSheetIdx = isInfinite
            ? 0
            : activeDocState.page.activeSheetIndexForGlobalPoint(
                transform.localToGlobal(const Offset(400, 300)),
              );
        final zoomPercent = (transform.size * 100).round().clamp(25, 1600);

        return LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 740;
            final showTitleText = constraints.maxWidth >= 880;
            const brandGreen = Color(0xFF2F7D6E);

            return Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : Colors.white,
                border: Border(
                  bottom: BorderSide(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB),
                  ),
                ),
              ),
              child: Row(
                children: [
                  // ==================== 1. 左侧区：返回书架 + 文档列表侧栏 + 标题页码 + 撤销/重做 ====================
                  _buildTopBarIconBtn(
                    icon: Icons.arrow_back_ios_new_rounded,
                    tooltip: '返回书架主页 (自动保存)',
                    isDark: isDark,
                    onTap: () => _saveAndExitToHome(context),
                  ),
                  _buildTopBarIconBtn(
                    icon: Icons.view_sidebar_outlined,
                    tooltip: '文档列表侧边栏 (可拖拽文档或点 ··· 分屏双开)',
                    active: _showLeftDocListDrawer,
                    isDark: isDark,
                    onTap: () => setState(() => _showLeftDocListDrawer = !_showLeftDocListDrawer),
                  ),
                  if (showTitleText) ...[
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 148),
                      child: Text(
                        docTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : const Color(0xFF1E293B),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  // 页码胶囊（点击打开平铺页面概览）
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _openTiledPageOverviewModal(context, activeDocState),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                        ),
                      ),
                      child: Text(
                        isInfinite ? '∞ 无界' : '${curSheetIdx + 1}/${sheets.length}页',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white70 : const Color(0xFF334155),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  _buildTopBarIconBtn(
                    icon: Icons.undo_rounded,
                    tooltip: '撤销 (双指轻点)',
                    enabled: activeBloc.canUndo,
                    isDark: isDark,
                    onTap: activeBloc.canSendUndo ? () => activeBloc.sendUndo() : null,
                  ),
                  _buildTopBarIconBtn(
                    icon: Icons.redo_rounded,
                    tooltip: '重做 (三指轻点)',
                    enabled: activeBloc.canRedo,
                    isDark: isDark,
                    onTap: activeBloc.canSendRedo ? () => activeBloc.sendRedo() : null,
                  ),

                  const SizedBox(width: 6),

                  // ==================== 2. 中央区：圆形图标可滑动工具坞 ====================
                  Expanded(
                    child: Center(
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF3F5F9),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 2.1 笔盒展开/收起开关
                              if (_starredTopTools.contains('pen_case'))
                                _buildCenterDockToolButton(
                                  icon: Icons.dashboard_customize_rounded,
                                  label: '笔盒',
                                  tooltip: '展开/收起拟真悬浮笔盒',
                                  selected: _showFloatingPenCase ||
                                      _penCaseDock == MumuPenCaseDock.fixedTopBar,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('pen_case', context, docState),
                                ),

                              // 2.2 钢笔/圆珠笔 (再次点击弹出笔刷设置)
                              if (_starredTopTools.contains('pen'))
                                _buildCenterDockToolButton(
                                  icon: Icons.edit_rounded,
                                  label: '钢笔',
                                  tooltip: '钢笔/圆珠笔 (再次点击调节粗细/颜色/笔锋)',
                                  selected: isWritingPenActive,
                                  accentColor: writingPenColor,
                                  showColorIndicator: true,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('pen', context, docState),
                                ),

                              // 2.3 荧光笔 (再次点击弹出荧光笔设置)
                              if (_starredTopTools.contains('highlighter'))
                                _buildCenterDockToolButton(
                                  icon: Icons.border_color_rounded,
                                  label: '荧光',
                                  tooltip: '荧光标记笔 (再次点击换色/粗细)',
                                  selected: isHighlighterActive,
                                  accentColor: highlighterColor,
                                  showColorIndicator: true,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('highlighter', context, docState),
                                ),

                              // 2.4 橡皮擦 (再次点击切换点擦/笔触擦/清页)
                              if (_starredTopTools.contains('eraser'))
                                _buildCenterDockToolButton(
                                  icon: Icons.auto_fix_normal_rounded,
                                  label: '橡皮',
                                  tooltip: '橡皮擦 (再次点击切换点擦/笔触擦除/清页)',
                                  selected: activeTool is EraserTool,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('eraser', context, docState),
                                ),

                              // 2.5 套索工具 (自由/矩形/双链)
                              if (_starredTopTools.contains('lasso'))
                                _buildCenterDockToolButton(
                                  icon: Icons.gesture_rounded,
                                  label: '套索',
                                  tooltip: '套索选择与双向链接工具',
                                  selected: activeTool is SelectTool || _showLassoBar,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('lasso', context, docState),
                                ),

                              // 2.6 文本框
                              if (_starredTopTools.contains('textbox'))
                                _buildCenterDockToolButton(
                                  icon: Icons.text_fields_rounded,
                                  label: '文本',
                                  tooltip: '插入文本框',
                                  selected: activeTool is LabelTool,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('textbox', context, docState),
                                ),

                              // 2.7 图形笔 / 一笔成型
                              if (_starredTopTools.contains('shape'))
                                _buildCenterDockToolButton(
                                  icon: Icons.category_outlined,
                                  label: '图形',
                                  tooltip: '几何图形与直线工具',
                                  selected: activeTool is ShapeTool,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('shape', context, docState),
                                ),

                              // 2.8 记忆背诵胶带
                              if (_starredTopTools.contains('tape_mask'))
                                _buildCenterDockToolButton(
                                  icon: Icons.healing_outlined,
                                  label: '胶带',
                                  tooltip: '添加遮盖背诵记忆胶带',
                                  selected: _memoryTapes.isNotEmpty && !_hideAllMemoryTapes,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('tape_mask', context, docState),
                                ),

                              // 2.9 插入菜单 (图片/贴纸/音频/批注/双链)
                              if (_starredTopTools.contains('insert'))
                                _buildCenterDockToolButton(
                                  icon: Icons.add_box_outlined,
                                  label: '插入',
                                  tooltip: '插入图片 / PDF / 贴纸 / 双向链接',
                                  selected: false,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('insert', context, docState),
                                ),

                              // 2.10 仿真标尺
                              if (_starredTopTools.contains('ruler'))
                                _buildCenterDockToolButton(
                                  icon: Icons.straighten_rounded,
                                  label: '标尺',
                                  tooltip: '显示/隐藏可旋转直尺',
                                  selected: _showSimulationRuler,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('ruler', context, docState),
                                ),

                              // 2.12 图层管理
                              if (_starredTopTools.contains('layers'))
                                _buildCenterDockToolButton(
                                  icon: Icons.layers_outlined,
                                  label: '图层',
                                  tooltip: '多图层系统管理',
                                  selected: _showFloatingLayersPanel,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('layers', context, docState),
                                ),

                              // 2.13 激光笔
                              if (_starredTopTools.contains('laser'))
                                _buildCenterDockToolButton(
                                  icon: Icons.flare_rounded,
                                  label: '激光',
                                  tooltip: '演示激光笔',
                                  selected: activeTool is LaserTool,
                                  accentColor: const Color(0xFFEF4444),
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('laser', context, docState),
                                ),

                              // 2.14 单指漫游翻页抓手
                              if (_starredTopTools.contains('pan'))
                                _buildCenterDockToolButton(
                                  icon: Icons.pan_tool_alt_outlined,
                                  label: '翻页',
                                  tooltip: '单指上下滑动连续翻页 (下滑到底部自动加页)',
                                  selected: activeTool is HandTool,
                                  isDark: isDark,
                                  onTap: () => _runToolbarAction('pan', context, docState),
                                ),

                              // 2.15 末尾圆点图标：打开完整工具列表与自定义排序 (对齐 Mumu 官网规范)
                              _buildCenterDockToolButton(
                                icon: Icons.tune_rounded,
                                label: '管理',
                                tooltip: '工具更多菜单与自定义顶栏工具',
                                selected: false,
                                isDark: isDark,
                                onTap: () => _runToolbarAction('customize', context, docState),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SizedBox(width: 6),

                  // ==================== 3. 右侧区：手写笔防误触 + 应用内分屏 + 页面侧栏 + 更多 ====================
                  // 3.1 手写笔/手指模式切换（带防误触绿点状态，长按进入防误触实验室）
                  ListenableBuilder(
                    listenable: PalmGuardService.instance,
                    builder: (context, _) {
                      final pgState = PalmGuardService.instance.state;
                      return Tooltip(
                        message: pgState.penOnlyMode
                            ? '当前：手写笔专属模式（单指滑动翻页 · 防误触已启用 · 长按打开校准台）'
                            : '当前：允许手指直接书写（双指滑动翻页 · 长按打开防误触校准台）',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            final next = !pgState.penOnlyMode;
                            PalmGuardService.instance.setPenOnlyMode(next);
                            _syncInputModeWithButterfly(next);
                            setState(() {
                              _inputMode = next
                                  ? MumuInputMode.stylusOnly
                                  : MumuInputMode.fingerWrite;
                            });
                            _showQuickInteractionToast(
                              next
                                  ? '✍️ 已开启「手写笔模式」：笔写字 · 单指上下滑动翻页 · 双指缩放'
                                  : '👆 已切换「手指书写模式」：单指画线 · 双指上下滑动翻页',
                            );
                          },
                          onLongPress: () => showMumuCalibrationModal(context),
                          child: Container(
                            width: 34,
                            height: 34,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: pgState.penOnlyMode
                                  ? brandGreen.withValues(alpha: 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                Icon(
                                  pgState.penOnlyMode
                                      ? Icons.edit_rounded
                                      : Icons.touch_app_outlined,
                                  size: 19,
                                  color: pgState.penOnlyMode
                                      ? brandGreen
                                      : (isDark ? Colors.white70 : const Color(0xFF475569)),
                                ),
                                if (pgState.enabled)
                                  Positioned(
                                    right: -2,
                                    top: -2,
                                    child: Container(
                                      width: 7,
                                      height: 7,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF10B981),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                          width: 1.2,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),

                  // 3.2 应用内分屏按钮 (In-App Split View：支持打开其他笔记或同文档双页对照)
                  _buildTopBarIconBtn(
                    icon: _splitViewOpen && !_splitVertical
                        ? Icons.horizontal_split_rounded
                        : Icons.vertical_split_rounded,
                    tooltip: '应用内分屏（并排打开两个笔记本或同文档双页对照）',
                    active: _splitViewOpen,
                    isDark: isDark,
                    onTap: () => _showMumuSplitViewModal(context, docState),
                  ),

                  if (!isNarrow) ...[
                    // 3.3 缩放比例胶囊（单击居中适配页宽，长按锁定缩放）
                    InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: _handleDoubleTapFitWidth,
                      onLongPress: () {
                        setState(() => _zoomLocked = !_zoomLocked);
                        PalmGuardService.instance.setZoomLocked(_zoomLocked);
                        _showQuickInteractionToast(
                          _zoomLocked ? '🔒 已锁定缩放比例 ($zoomPercent%)' : '🔓 已解锁缩放比例',
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_zoomLocked)
                              const Padding(
                                padding: EdgeInsets.only(right: 2),
                                child: Icon(
                                  Icons.lock_rounded,
                                  size: 11,
                                  color: brandGreen,
                                ),
                              ),
                            Text(
                              '$zoomPercent%',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white70 : const Color(0xFF475569),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],

                  // 3.4 右侧边栏开关（页面缩略图 / 大纲 / 批注与双向链接）
                  _buildTopBarIconBtn(
                    icon: Icons.chrome_reader_mode_outlined,
                    tooltip: '右侧边栏 (页面缩略图 / 大纲 / 批注与双向链接)',
                    active: _showRightSidebar,
                    isDark: isDark,
                    onTap: () => setState(() => _showRightSidebar = !_showRightSidebar),
                  ),

                  // 3.5 更多菜单 (···)
                  _buildTopBarIconBtn(
                    icon: Icons.more_horiz_rounded,
                    tooltip: '更多菜单 (视图模式 / 滚动方向 / 更换纸张模板 / 导出分享 / 防误触校准)',
                    isDark: isDark,
                    onTap: () => _showMumuMoreMenuSheet(context, activeDocState),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTopBarIconBtn({
    required IconData icon,
    required String tooltip,
    required bool isDark,
    VoidCallback? onTap,
    bool active = false,
    bool enabled = true,
  }) {
    const brandGreen = Color(0xFF2F7D6E);
    final fg = !enabled
        ? (isDark ? Colors.white24 : Colors.black26)
        : active
        ? brandGreen
        : (isDark ? Colors.white70 : const Color(0xFF334155));
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 34,
          height: 34,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? brandGreen.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18.5, color: fg),
        ),
      ),
    );
  }

  Widget _buildCenterDockToolButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required bool selected,
    required bool isDark,
    required VoidCallback onTap,
    Color accentColor = const Color(0xFF2F7D6E),
    bool showColorIndicator = false,
  }) {
    const brandGreen = Color(0xFF2F7D6E);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: selected
                ? (isDark ? const Color(0xFF1E293B) : Colors.white)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? brandGreen.withValues(alpha: 0.45)
                  : Colors.transparent,
              width: 1.1,
            ),
            boxShadow: [
              if (selected)
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 16.5,
                    color: selected
                        ? (showColorIndicator ? accentColor : brandGreen)
                        : (isDark ? Colors.white70 : const Color(0xFF475569)),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? brandGreen
                          : (isDark ? Colors.white70 : const Color(0xFF475569)),
                    ),
                  ),
                ],
              ),
              if (showColorIndicator) ...[
                const SizedBox(height: 2),
                Container(
                  width: 20,
                  height: 2.6,
                  decoration: BoxDecoration(
                    color: accentColor,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 3. Mumu 标志性可拖拽四边吸附「笔盒」(2.1 & Video mkcLMr0zj3g)
  // --------------------------------------------------------------------------
  Widget _buildDockableFloatingPenCase(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    // 最小化到角落状态：显示为一个精致圆角笔盒浮标
    if (_penCaseDock == MumuPenCaseDock.minimizedCorner) {
      return Positioned(
        right: 18,
        bottom: 18,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: () => setState(() => _penCaseDock = MumuPenCaseDock.bottom),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF2F7D6E), Color(0xFF1E40AF)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2F7D6E).withValues(alpha: 0.38),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(Icons.edit_rounded, color: Colors.white, size: 24),
            ),
          ),
        ),
      );
    }

    final isVertical =
        _penCaseDock == MumuPenCaseDock.left || _penCaseDock == MumuPenCaseDock.right;

    final boxWidth = isVertical ? 92.0 : math.min(stageConstraints.maxWidth - 24.0, 690.0);
    final boxHeight = isVertical ? math.min(stageConstraints.maxHeight - 36.0, 560.0) : 88.0;

    // 计算默认或磁吸后的坐标
    double left;
    double top;
    if (_floatingPenCaseOffset != null) {
      left = _floatingPenCaseOffset!.dx.clamp(
        8.0,
        math.max(8.0, stageConstraints.maxWidth - boxWidth - 8.0),
      );
      top = _floatingPenCaseOffset!.dy.clamp(
        8.0,
        math.max(8.0, stageConstraints.maxHeight - boxHeight - 8.0),
      );
    } else {
      switch (_penCaseDock) {
        case MumuPenCaseDock.bottom:
          left = (stageConstraints.maxWidth - boxWidth) / 2;
          top = stageConstraints.maxHeight - boxHeight - 14;
        case MumuPenCaseDock.top:
          left = (stageConstraints.maxWidth - boxWidth) / 2;
          top = 12;
        case MumuPenCaseDock.left:
          left = 14;
          top = (stageConstraints.maxHeight - boxHeight) / 2;
        case MumuPenCaseDock.right:
          left = stageConstraints.maxWidth - boxWidth - 14;
          top = (stageConstraints.maxHeight - boxHeight) / 2;
        default:
          left = (stageConstraints.maxWidth - boxWidth) / 2;
          top = stageConstraints.maxHeight - boxHeight - 14;
      }
    }

    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            final cur = _floatingPenCaseOffset ?? Offset(left, top);
            _floatingPenCaseOffset = cur + details.delta;
          });
        },
        onPanEnd: (_) {
          // 松手时根据落点自动吸附到上、下、左、右四边 (Ch. 2.1)
          final cur = _floatingPenCaseOffset;
          if (cur == null) return;
          final cx = cur.dx + boxWidth / 2;
          final cy = cur.dy + boxHeight / 2;
          final distLeft = cx;
          final distRight = stageConstraints.maxWidth - cx;
          final distTop = cy;
          final distBottom = stageConstraints.maxHeight - cy;
          final minDist = [distLeft, distRight, distTop, distBottom].reduce(math.min);

          setState(() {
            _floatingPenCaseOffset = null;
            if (minDist == distLeft && distLeft < 150) {
              _penCaseDock = MumuPenCaseDock.left;
            } else if (minDist == distRight && distRight < 150) {
              _penCaseDock = MumuPenCaseDock.right;
            } else if (minDist == distTop && distTop < 140) {
              _penCaseDock = MumuPenCaseDock.top;
            } else {
              _penCaseDock = MumuPenCaseDock.bottom;
            }
          });
        },
        child: _buildPenCaseSurface(
          context,
          docState,
          toolState,
          isVertical: isVertical,
          width: boxWidth,
          height: boxHeight,
          isDark: isDark,
        ),
      ),
    );
  }

  Widget _buildFixedTopPenCaseBar(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    bool isDark,
  ) {
    return Container(
      height: 76,
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF151F32) : const Color(0xFFF9FAFB),
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB)),
        ),
      ),
      child: _buildPenCaseInnerContent(
        context,
        docState,
        toolState,
        isVertical: false,
        isDark: isDark,
        isFixedBar: true,
      ),
    );
  }

  Widget _buildPenCaseSurface(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState, {
    required bool isVertical,
    required double width,
    required double height,
    required bool isDark,
  }) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: width,
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF1E293B).withValues(alpha: 0.96)
              : Colors.white.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: _buildPenCaseInnerContent(
          context,
          docState,
          toolState,
          isVertical: isVertical,
          isDark: isDark,
          isFixedBar: false,
        ),
      ),
    );
  }

  Widget _buildPenCaseInnerContent(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState, {
    required bool isVertical,
    required bool isDark,
    required bool isFixedBar,
  }) {
    final bloc = _getActiveBloc(context);
    final controller = _getActiveEditorController(context);
    final activeDocState = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;
    final tools = activeDocState.info.tools;
    final activeIdx = controller.toolCubit.state.index;
    final activeTool = (activeIdx != null && activeIdx >= 0 && activeIdx < tools.length)
        ? tools[activeIdx]
        : null;

    Color activeColor = const Color(0xFF1E293B);
    double activeWidth = 2.8;
    if (activeTool is PenTool) {
      activeColor = Color(activeTool.property.paint.previewColor.value);
      activeWidth = activeTool.property.strokeWidth;
    } else if (activeTool is ShapeTool) {
      activeColor = Color(activeTool.property.paint.previewColor.value);
      activeWidth = activeTool.property.strokeWidth;
    } else if (activeTool is LaserTool) {
      activeColor = Color(activeTool.color.value);
      activeWidth = activeTool.strokeWidth;
    } else if (activeTool is EraserTool) {
      activeWidth = activeTool.strokeWidth;
    }

    final dragHandle = Container(
      width: isVertical ? 28 : 4,
      height: isVertical ? 4 : 28,
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: isDark ? Colors.white24 : Colors.black26,
        borderRadius: BorderRadius.circular(999),
      ),
    );

    // 1. 拟真矢量笔尖列表 (钢笔/圆珠笔/铅笔/彩虹笔/荧光笔/橡皮擦/图形笔/胶带笔/激光笔/套索)
    final penNibItems = <Widget>[
      for (int i = 0; i < tools.length; i++)
        _buildRealisticPenTipItem(
          context,
          tool: tools[i],
          index: i,
          selected: activeIdx == i,
          isVertical: isVertical,
          isDark: isDark,
          onTap: () {
            if (activeIdx == i) {
              setState(() => _showPenSettingsPopover = !_showPenSettingsPopover);
            } else {
              controller.toolCubit.setIndex(i);
              unawaited(
                controller.toolCubit.changeTool(controller, bloc, index: i, context: context),
              );
              unawaited(controller.toolCubit.updateTool(controller, bloc, tools[i]));
              setState(() => _showPenSettingsPopover = false);
            }
          },
        ),
    ];

    // 2. 10 色快捷槽位 (2×5 矩阵) + 3 档粗细快捷按钮 (Ch. 2.11 & 2.12)
    final currentColors = _colorSets[_activeColorSetIndex].colors;
    final colorAndThicknessCluster = isVertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 5,
                runSpacing: 5,
                alignment: WrapAlignment.center,
                children: [
                  for (final c in currentColors)
                    _buildColorSlotDot(
                      context,
                      color: c,
                      selected: activeColor.toARGB32() == c.toARGB32(),
                      onTap: () => _applyColorToActiveTool(bloc, tools, activeIdx, activeTool, c),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              // 3 个粗细预设槽位
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int p = 0; p < _thicknessPresets.length; p++)
                    _buildThicknessPresetButton(
                      presetIndex: p,
                      widthVal: _thicknessPresets[p],
                      selected: (activeWidth - _thicknessPresets[p]).abs() < 0.4,
                      isDark: isDark,
                      onTap: () {
                        setState(() => _activeThicknessPresetIdx = p);
                        _applyWidthToActiveTool(
                          bloc,
                          tools,
                          activeIdx,
                          activeTool,
                          _thicknessPresets[p],
                        );
                      },
                    ),
                ],
              ),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 2x5 10个颜色槽位
              SizedBox(
                width: 118,
                child: Wrap(
                  spacing: 5,
                  runSpacing: 5,
                  children: [
                    for (final c in currentColors)
                      _buildColorSlotDot(
                        context,
                        color: c,
                        selected: activeColor.toARGB32() == c.toARGB32(),
                        onTap: () => _applyColorToActiveTool(bloc, tools, activeIdx, activeTool, c),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 3个粗细预设 + 颜色集切换按钮
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (int p = 0; p < _thicknessPresets.length; p++)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: _buildThicknessPresetButton(
                            presetIndex: p,
                            widthVal: _thicknessPresets[p],
                            selected: (activeWidth - _thicknessPresets[p]).abs() < 0.4,
                            isDark: isDark,
                            onTap: () {
                              setState(() => _activeThicknessPresetIdx = p);
                              _applyWidthToActiveTool(
                                bloc,
                                tools,
                                activeIdx,
                                activeTool,
                                _thicknessPresets[p],
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      setState(() {
                        _activeColorSetIndex = (_activeColorSetIndex + 1) % _colorSets.length;
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2F7D6E).withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '🎨 ${_colorSets[_activeColorSetIndex].name}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2F7D6E),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );

    // 最小化/切换固定栏按钮
    final dockActionBtn = IconButton(
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      tooltip: isFixedBar ? '切换为浮动笔盒' : '最小化笔盒或切换顶部固定栏',
      icon: Icon(
        isFixedBar ? Icons.close_fullscreen_rounded : Icons.keyboard_arrow_down_rounded,
        size: 15,
        color: Colors.grey,
      ),
      onPressed: () {
        setState(() {
          if (isFixedBar) {
            _penCaseDock = MumuPenCaseDock.bottom;
          } else {
            _penCaseDock = MumuPenCaseDock.minimizedCorner;
            _showPenSettingsPopover = false;
          }
        });
      },
    );

    if (isVertical) {
      return Column(
        children: [
          dragHandle,
          Expanded(
            child: SingleChildScrollView(child: Column(children: penNibItems)),
          ),
          const Divider(height: 10),
          colorAndThicknessCluster,
          dockActionBtn,
        ],
      );
    }

    final divider = Container(
      width: 1,
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 窄屏（平板竖屏/手机）：整条笔盒横向滚动，保证笔尖、调色板、粗细与收起按钮都能点到
        if (constraints.maxWidth < 460) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!isFixedBar) dragHandle,
                ...penNibItems,
                divider,
                colorAndThicknessCluster,
                const SizedBox(width: 4),
                dockActionBtn,
              ],
            ),
          );
        }
        return Row(
          children: [
            if (!isFixedBar) dragHandle,
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: penNibItems),
              ),
            ),
            divider,
            colorAndThicknessCluster,
            const SizedBox(width: 4),
            dockActionBtn,
          ],
        );
      },
    );
  }

  Widget _buildRealisticPenTipItem(
    BuildContext context, {
    required Tool tool,
    required int index,
    required bool selected,
    required bool isVertical,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final info = _classifyMumuToolVisual(tool);

    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: '${info.label} (再次点击打开笔刷设置)',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          margin: EdgeInsets.symmetric(
            horizontal: isVertical ? 0 : 3,
            vertical: isVertical ? 3 : 0,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          transform: Matrix4.translationValues(
            isVertical ? (selected ? 5.0 : 0.0) : 0.0,
            isVertical ? 0.0 : (selected ? -6.0 : 2.0),
            0.0,
          ),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2F7D6E).withValues(alpha: 0.10) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 30,
                height: 46,
                child: CustomPaint(
                  painter: _MumuRealisticPenTipPainter(
                    kind: info.kind,
                    color: info.color,
                    selected: selected,
                    isDark: isDark,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                info.shortLabel,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? const Color(0xFF2F7D6E)
                      : (isDark ? Colors.white70 : const Color(0xFF4B5563)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({String kind, String label, String shortLabel, Color color}) _classifyMumuToolVisual(
    Tool tool,
  ) {
    final name = tool.name;
    if (tool is PenTool) {
      final c = Color(tool.property.paint.previewColor.value);
      if (name.contains('圆珠')) {
        return (kind: 'ballpoint', label: name, shortLabel: '圆珠', color: c);
      }
      if (name.contains('铅笔')) {
        return (kind: 'pencil', label: name, shortLabel: '铅笔', color: c);
      }
      if (name.contains('彩虹')) {
        return (kind: 'rainbow', label: name, shortLabel: '彩虹', color: c);
      }
      if (name.contains('荧光') || name.toLowerCase().contains('highlight')) {
        return (kind: 'highlighter', label: name, shortLabel: '荧光', color: c);
      }
      if (name.contains('胶带')) {
        return (kind: 'tape', label: name, shortLabel: '胶带', color: c);
      }
      return (kind: 'fountain', label: name, shortLabel: '钢笔', color: c);
    }
    if (tool is EraserTool) {
      return (
        kind: 'eraser',
        label: name.isEmpty ? '橡皮擦' : name,
        shortLabel: '橡皮',
        color: const Color(0xFF3B82F6),
      );
    }
    if (tool is ShapeTool) {
      return (
        kind: 'shape',
        label: name.isEmpty ? '图形笔' : name,
        shortLabel: '图形',
        color: Color(tool.property.paint.previewColor.value),
      );
    }
    if (tool is LaserTool) {
      return (
        kind: 'laser',
        label: name.isEmpty ? '激光笔' : name,
        shortLabel: '激光',
        color: Color(tool.color.value),
      );
    }
    if (tool is SelectTool) {
      return (
        kind: 'lasso',
        label: name.isEmpty ? '套索' : name,
        shortLabel: '套索',
        color: const Color(0xFF2F7D6E),
      );
    }
    if (tool is HandTool) {
      return (
        kind: 'pan',
        label: name.isEmpty ? '漫游' : name,
        shortLabel: '漫游',
        color: const Color(0xFF64748B),
      );
    }
    return (
      kind: 'other',
      label: name.isEmpty ? '工具' : name,
      shortLabel: name.length > 2 ? name.substring(0, 2) : name,
      color: const Color(0xFF64748B),
    );
  }

  Widget _buildColorSlotDot(
    BuildContext context, {
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      onDoubleTap: () => _showCustomColorHexDialog(context, color),
      child: Tooltip(
        message: '单击选色 · 双击自定义 Hex 与不透明度',
        child: Container(
          width: 19,
          height: 19,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? const Color(0xFF2F7D6E) : Colors.white,
              width: selected ? 2.4 : 1.2,
            ),
            boxShadow: [
              if (selected) BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThicknessPresetButton({
    required int presetIndex,
    required double widthVal,
    required bool selected,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final dotRadius = (2.5 + presetIndex * 2.0).clamp(2.5, 7.0);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF2F7D6E).withValues(alpha: 0.15)
              : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF3F4F6)),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? const Color(0xFF2F7D6E) : Colors.transparent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: dotRadius * 1.4,
              height: dotRadius * 1.4,
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0xFF2F7D6E)
                    : (isDark ? Colors.white70 : const Color(0xFF374151)),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              widthVal.toStringAsFixed(1),
              style: TextStyle(
                fontSize: 9.5,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                color: selected
                    ? const Color(0xFF2F7D6E)
                    : (isDark ? Colors.white70 : const Color(0xFF374151)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 4. 二次点击笔刷弹出的「Mumu 笔刷设置面板」(Ch. 2.3~2.12 & Video mkcLMr0zj3g 00:34)
  // --------------------------------------------------------------------------
  Widget _buildPenSettingsPopoverCard(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    final bloc = _getActiveBloc(context);
    final controller = _getActiveEditorController(context);
    final activeDocState = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;
    final tools = activeDocState.info.tools;
    final activeIdx = controller.toolCubit.state.index;
    if (activeIdx == null || activeIdx < 0 || activeIdx >= tools.length) {
      return const SizedBox.shrink();
    }
    final activeTool = tools[activeIdx];
    final vis = _classifyMumuToolVisual(activeTool);

    double currentWidth = 2.8;
    Color currentColor = vis.color;
    if (activeTool is PenTool) {
      currentWidth = activeTool.property.strokeWidth;
      currentColor = Color(activeTool.property.paint.previewColor.value);
    } else if (activeTool is EraserTool) {
      currentWidth = activeTool.strokeWidth;
    } else if (activeTool is ShapeTool) {
      currentWidth = activeTool.property.strokeWidth;
      currentColor = Color(activeTool.property.paint.previewColor.value);
    } else if (activeTool is LaserTool) {
      currentWidth = activeTool.strokeWidth;
      currentColor = Color(activeTool.color.value);
    }

    return Positioned(
      bottom: _penCaseDock == MumuPenCaseDock.bottom ? 110 : null,
      top: _penCaseDock == MumuPenCaseDock.top || _penCaseDock == MumuPenCaseDock.fixedTopBar
          ? 96
          : null,
      left: (stageConstraints.maxWidth - 340) / 2,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 340,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E293B) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部栏：工具名称 + ☆ 加入笔的收藏按钮 (Video _lPiEBDHbPY) + 关闭
              Row(
                children: [
                  Text(
                    vis.label,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
                  if (activeTool is PenTool)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: const Icon(Icons.star_rounded, size: 14, color: Color(0xFFF59E0B)),
                      label: const Text(
                        '加入收藏笔架',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF2F7D6E),
                        ),
                      ),
                      onPressed: () {
                        if (_favoritePresets.length >= 12) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(const SnackBar(content: Text('笔的收藏最多保存 12 个预设')));
                          return;
                        }
                        setState(() {
                          _favoritePresets.add(
                            _MumuFavoritePenPreset(
                              id: 'fav_${DateTime.now().millisecondsSinceEpoch}',
                              label: '${vis.shortLabel}·${currentWidth.toStringAsFixed(1)}',
                              penKind: vis.kind,
                              color: currentColor,
                              strokeWidth: currentWidth,
                            ),
                          );
                          _showPenFavoritesStrip = true;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已添加到屏幕侧边「笔的收藏」'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                    ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => setState(() => _showPenSettingsPopover = false),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // 若是橡皮擦：显示三种模式（点擦 / 笔触擦除 / 圈选擦除）与「清除当前页面」(Ch. 2.6)
              if (activeTool is EraserTool) ...[
                const Text(
                  '橡皮擦模式',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('点擦 (像素)', style: TextStyle(fontSize: 11)),
                        selected: activeTool.mode == EraserMode.stroke,
                        onSelected: (_) {
                          final updated = List<Tool>.from(tools);
                          updated[activeIdx] = activeTool.copyWith(
                            name: '橡皮擦',
                            mode: EraserMode.stroke,
                            strokeWidth: currentWidth,
                          );
                          bloc.add(ToolsReplaced(updated));
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: ChoiceChip(
                        label: const Text('笔触擦除', style: TextStyle(fontSize: 11)),
                        selected: activeTool.mode == EraserMode.path,
                        onSelected: (_) {
                          final updated = List<Tool>.from(tools);
                          updated[activeIdx] = activeTool.copyWith(
                            name: '笔触橡皮',
                            mode: EraserMode.path,
                            strokeWidth: currentWidth,
                          );
                          bloc.add(ToolsReplaced(updated));
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(
                      Icons.delete_outline_rounded,
                      size: 15,
                      color: Color(0xFFEF4444),
                    ),
                    label: const Text(
                      '清除当前页面所有内容',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFEF4444),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () {
                      final elementIds = docState.page.layers
                          .expand((l) => l.content)
                          .map((e) => e.id)
                          .whereType<String>()
                          .toList();
                      if (elementIds.isNotEmpty) {
                        bloc.add(ElementsRemoved(elementIds));
                      }
                      setState(() => _showPenSettingsPopover = false);
                    },
                  ),
                ),
              ],

              // 若是钢笔 / 圆珠笔 / 荧光笔：显示笔锋强度与笔迹平滑滑块 (Ch. 2.3 & Video mkcLMr0zj3g 00:34)
              if (activeTool is PenTool) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '笔锋模拟强度',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      _pressureSensitivity.toStringAsFixed(1),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _pressureSensitivity,
                  min: 1.0,
                  max: 5.0,
                  divisions: 8,
                  onChanged: (v) {
                    setState(() => _pressureSensitivity = v);
                    final strength = 0.4 + (v - 1.0) / 4.0 * 1.2;
                    PalmGuardService.instance.setTaperStrength(strength);
                    PalmGuardService.instance.setSimulatedTaperEnabled(v > 1.2);
                  },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '笔迹平滑',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${(_inkFlow * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _inkFlow.clamp(0.0, 1.0),
                  min: 0.0,
                  max: 1.0,
                  onChanged: (v) {
                    setState(() => _inkFlow = v);
                    final updated = List<Tool>.from(tools);
                    updated[activeIdx] = activeTool.copyWith(
                      property: activeTool.property.copyWith(smoothing: v),
                    );
                    bloc.add(ToolsReplaced(updated));
                    unawaited(
                      controller.toolCubit.updateTool(controller, bloc, updated[activeIdx]),
                    );
                  },
                ),
              ],

              // 笔刷粗细调节滑块 (Ch. 2.12) —— 仅对画笔/橡皮/图形/激光有效
              if (activeTool is PenTool ||
                  activeTool is EraserTool ||
                  activeTool is ShapeTool ||
                  activeTool is LaserTool)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '笔刷粗细',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${currentWidth.toStringAsFixed(1)} pt',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              if (activeTool is PenTool ||
                  activeTool is EraserTool ||
                  activeTool is ShapeTool ||
                  activeTool is LaserTool)
                Slider(
                  value: currentWidth.clamp(0.5, 24.0),
                  min: 0.5,
                  max: 24.0,
                  onChanged: (v) {
                    setState(() {
                      _thicknessPresets[_activeThicknessPresetIdx] = v;
                    });
                    _applyWidthToActiveTool(bloc, tools, activeIdx, activeTool, v);
                  },
                ),

              // 停顿自动形状识别开关 (Ch. 2.3 & 2.7) —— 直接写入当前 PenTool 的真实属性
              if (activeTool is PenTool)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '停顿自动识别标准形状',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text('手绘图形后短暂按住即可自动整理为规则形状', style: TextStyle(fontSize: 10)),
                  value: _autoShapeRecognition,
                  onChanged: (v) {
                    setState(() => _autoShapeRecognition = v);
                    if (activeTool is PenTool) {
                      final updated = List<Tool>.from(tools);
                      updated[activeIdx] = activeTool.copyWith(shapeDetectionEnabled: v);
                      bloc.add(ToolsReplaced(updated));
                      unawaited(
                        controller.toolCubit.updateTool(controller, bloc, updated[activeIdx]),
                      );
                    }
                    _showQuickInteractionToast(v ? '📐 已开启一笔成型：手绘图形后停顿即自动规整为标准形状' : '已关闭自动形状识别');
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 5. 独立侧边「笔的收藏」悬浮条 (Ch. 2.2 & Video _lPiEBDHbPY)
  // --------------------------------------------------------------------------
  Widget _buildPenFavoritesSideStrip(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    final bloc = context.read<DocumentBloc>();
    final controller = context.read<EditorController>();
    final tools = docState.info.tools;

    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _favoritesStripOffset += details.delta;
        });
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 48,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1E293B).withValues(alpha: 0.94)
                : Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽手柄
              Container(
                width: 18,
                height: 3.5,
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : Colors.black26,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              for (int i = 0; i < _favoritePresets.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: GestureDetector(
                    onTap: () =>
                        _applyFavoritePenPreset(bloc, controller, tools, _favoritePresets[i]),
                    onLongPress: () {
                      setState(() => _favoritePresets.removeAt(i));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已从笔的收藏中移除该预设'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                    child: Tooltip(
                      message: '${_favoritePresets[i].label} (长按移除)',
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _favoritePresets[i].color.withValues(alpha: 0.14),
                          shape: BoxShape.circle,
                          border: Border.all(color: _favoritePresets[i].color, width: 1.8),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _favoritePresets[i].penKind == 'highlighter'
                                  ? Icons.border_color_rounded
                                  : Icons.edit_rounded,
                              size: 13,
                              color: _favoritePresets[i].color,
                            ),
                            Text(
                              _favoritePresets[i].strokeWidth.toStringAsFixed(1),
                              style: TextStyle(
                                fontSize: 8.5,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w800,
                                color: isDark ? Colors.white : const Color(0xFF1F2937),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              // + 新增当前笔刷到收藏
              InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  setState(() => _showPenSettingsPopover = true);
                },
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF3F4F6),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, size: 16, color: Color(0xFF2F7D6E)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applyFavoritePenPreset(
    DocumentBloc bloc,
    EditorController controller,
    List<Tool> tools,
    _MumuFavoritePenPreset preset,
  ) {
    int targetIdx = tools.indexWhere((t) => t is PenTool);
    if (targetIdx == -1) return;
    final currentPen = tools[targetIdx] as PenTool;
    final updated = List<Tool>.from(tools);
    updated[targetIdx] = currentPen.copyWith(
      name: preset.label,
      property: currentPen.property.copyWith(
        strokeWidth: preset.strokeWidth,
        paint: ElementPaint.solid(
          color: SRGBColor(
            preset.penKind == 'highlighter'
                ? preset.color.withValues(alpha: 0.42).toARGB32()
                : preset.color.toARGB32(),
          ),
        ),
      ),
    );
    bloc.add(ToolsReplaced(updated));
    controller.toolCubit.setIndex(targetIdx);
    unawaited(controller.toolCubit.updateTool(controller, bloc, updated[targetIdx]));
  }

  // --------------------------------------------------------------------------
  // 7. 左下角页码导航与右侧纵向连续分页快速滚动条 (Ch. 4.1 & 4.6)
  // --------------------------------------------------------------------------
  void _scrollToSheetIndex(
    BuildContext context,
    DocumentLoadSuccess docState,
    int sheetIndex, {
    TransformCubit? customTransformCubit,
    Size? customViewportSize,
  }) {
    final tc = customTransformCubit ?? _getActiveTransformCubit(context);
    final renderBox = context.findRenderObject();
    final vpSize = customViewportSize ??
        (renderBox is RenderBox ? renderBox.size : const Size(800, 600));
    tc.fitMumuStandardPage(
      page: docState.page,
      info: docState.info,
      viewportSize: vpSize,
      sheetIndex: sheetIndex,
    );
  }

  Widget _buildBottomPageNavigatorPill(
    BuildContext context,
    DocumentLoadSuccess docState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    final activeBloc = _getActiveBloc(context);
    final activeTransformCubit = _getActiveTransformCubit(context);
    final activeDocState = activeBloc.state is DocumentLoadSuccess
        ? activeBloc.state as DocumentLoadSuccess
        : docState;
    final isInfinite = activeDocState.page.isMumuInfiniteCanvas(activeDocState.info);
    final sheets = activeDocState.page.resolvedPageSheets;
    final vpSize = Size(stageConstraints.maxWidth, stageConstraints.maxHeight);

    return BlocBuilder<TransformCubit, CameraTransform>(
      bloc: activeTransformCubit,
      builder: (context, transform) {
        final curIdx = isInfinite
            ? 0
            : activeDocState.page.activeSheetIndexForGlobalPoint(
                transform.localToGlobal(vpSize.center(Offset.zero)),
              );

        return Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B).withValues(alpha: 0.92)
                  : Colors.white.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isInfinite) ...[
                  InkWell(
                    onTap: curIdx > 0
                        ? () => _scrollToSheetIndex(
                              context,
                              activeDocState,
                              curIdx - 1,
                              customTransformCubit: activeTransformCubit,
                              customViewportSize: vpSize,
                            )
                        : null,
                    child: Icon(
                      Icons.chevron_left,
                      size: 16,
                      color: curIdx > 0 ? null : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
                InkWell(
                  onTap: () => _openTiledPageOverviewModal(context, activeDocState),
                  child: Text(
                    isInfinite ? '∞ 无限画布' : '${curIdx + 1} / ${sheets.length} 页',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (!isInfinite) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () {
                      if (curIdx < sheets.length - 1) {
                        _scrollToSheetIndex(
                          context,
                          activeDocState,
                          curIdx + 1,
                          customTransformCubit: activeTransformCubit,
                          customViewportSize: vpSize,
                        );
                      } else {
                        _addNewPage(
                          context,
                          activeDocState,
                          scrollToNewPage: true,
                          targetBloc: activeBloc,
                          targetTransform: activeTransformCubit,
                        );
                      }
                    },
                    child: const Tooltip(
                      message: '下一页 / 在末尾自动新增页面',
                      child: Icon(Icons.chevron_right, size: 16),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => _addNewPage(
                      context,
                      activeDocState,
                      scrollToNewPage: true,
                      targetBloc: activeBloc,
                      targetTransform: activeTransformCubit,
                    ),
                    child: const Tooltip(
                      message: '立即在下方添加新页面',
                      child: Icon(
                        Icons.add_circle_outline,
                        size: 15,
                        color: Color(0xFF2F7D6E),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// 右侧纵向连续分页快速滚动条与一键下滑加页器（即使在单指直接写字模式下也可单指拖动快速跨页滚动）
  Widget _buildVerticalPageScrubber(
    BuildContext context,
    DocumentLoadSuccess docState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    final activeBloc = _getActiveBloc(context);
    final activeTransformCubit = _getActiveTransformCubit(context);
    final activeDocState = activeBloc.state is DocumentLoadSuccess
        ? activeBloc.state as DocumentLoadSuccess
        : docState;
    final sheets = activeDocState.page.resolvedPageSheets;
    final totalBounds = activeDocState.page.totalSheetsBounds;
    final vpSize = Size(stageConstraints.maxWidth, stageConstraints.maxHeight);

    return BlocBuilder<TransformCubit, CameraTransform>(
      bloc: activeTransformCubit,
      builder: (context, transform) {
        final scale = transform.size <= 0 ? 1.0 : transform.size;
        final viewHGlobal = vpSize.height / scale;
        final maxScrollY = math.max(1.0, totalBounds.bottom - viewHGlobal + 60.0);
        final progress = ((transform.position.dy - totalBounds.top) / maxScrollY)
            .clamp(0.0, 1.0);
        final curIdx = activeDocState.page.activeSheetIndexForGlobalPoint(
          transform.localToGlobal(vpSize.center(Offset.zero)),
        );

        return Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, trackConstraints) {
                  final trackH = math.max(60.0, trackConstraints.maxHeight);
                  const thumbH = 56.0;
                  final thumbTop = progress * (trackH - thumbH);

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (details) {
                      final ratioDelta = details.delta.dy / math.max(1.0, trackH - thumbH);
                      final globalDeltaY = ratioDelta * maxScrollY;
                      activeTransformCubit.moveConstrained(
                        Offset(0, globalDeltaY),
                        runtime: _getActiveEditorController(context),
                        bloc: activeBloc,
                      );
                    },
                    child: SizedBox(
                      width: 28,
                      child: Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          // 轨道细线
                          Positioned(
                            top: 8,
                            bottom: 8,
                            child: Container(
                              width: 3,
                              decoration: BoxDecoration(
                                color: (isDark ? Colors.white : Colors.black)
                                    .withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          // 当前页滑块
                          Positioned(
                            top: thumbTop.clamp(0.0, trackH - thumbH),
                            child: Container(
                              width: 24,
                              height: thumbH,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isDark
                                    ? const Color(0xFF1E293B).withValues(alpha: 0.92)
                                    : Colors.white.withValues(alpha: 0.94),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: const Color(0xFF2F7D6E).withValues(alpha: 0.55),
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.10),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${curIdx + 1}',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      height: 1.0,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF2F7D6E),
                                    ),
                                  ),
                                  Container(
                                    width: 12,
                                    height: 1,
                                    margin: const EdgeInsets.symmetric(vertical: 2),
                                    color: const Color(0xFF2F7D6E).withValues(alpha: 0.45),
                                  ),
                                  Text(
                                    '${sheets.length}',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      height: 1.0,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF2F7D6E),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: '在底部新增下一页 (或直接下滑到底部自动加页)',
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _addNewPage(
                  context,
                  activeDocState,
                  scrollToNewPage: true,
                  targetBloc: activeBloc,
                  targetTransform: activeTransformCubit,
                ),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2F7D6E),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF2F7D6E).withValues(alpha: 0.35),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.add, size: 15, color: Colors.white),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // 8. Mumu 应用内分屏宿主与双文档/双页独立交互引擎 (Ch. 4.8 In-App Split View)
  // --------------------------------------------------------------------------
  Future<void> _openSecondaryNotebookInSplit(
    String? filePath, {
    bool? vertical,
    int? initialSheetIndex,
  }) async {
    if (!mounted) return;
    final fileSystem = context.read<ButterflyFileSystem>();
    final settingsCubit = context.read<SettingsCubit>();
    final windowCubit = context.read<WindowCubit>();
    final primaryBloc = context.read<DocumentBloc>();
    final primaryState = primaryBloc.state;
    if (primaryState is! DocumentLoadSuccess) return;

    setState(() {
      _splitViewOpen = true;
      if (vertical != null) _splitVertical = vertical;
      _splitSecondaryFilePath = filePath;
      _splitSecondaryLoading = true;
    });

    final oldRuntime = _splitSecondaryRuntime;
    _splitSecondaryRuntime = null;
    if (oldRuntime != null) {
      await oldRuntime.saveAndClose(fileSystem);
    }

    try {
      NoteData targetNoteData;
      String displayTitle;
      AssetLocation location;

      if (filePath != null && filePath.isNotEmpty) {
        final asset = await fileSystem
            .buildDocumentSystem()
            .getAsset(filePath, readData: true);
        if (asset is FileSystemFile<NoteFile> && asset.data != null) {
          targetNoteData = NoteData.fromData(asset.data!.data);
          final metaName = targetNoteData.getMetadata()?.name ?? '';
          displayTitle = metaName.trim().isNotEmpty
              ? metaName.trim()
              : asset.fileNameWithoutExtension;
          location = AssetLocation.local(filePath);
        } else {
          targetNoteData = primaryState.data;
          displayTitle = '${primaryState.metadata.name} (对照视图)';
          location = primaryBloc.editorController.saveCubit.state.location;
        }
      } else {
        // 同文档双页对照：若当前只有 1 页，自动为其补齐第 2 页以便左右/上下双页对照！
        var currentData = primaryState.data;
        var currentPage = primaryState.page;
        if (!currentPage.isMumuInfiniteCanvas(primaryState.info) &&
            currentPage.resolvedPageSheets.length < 2) {
          final firstSheet = currentPage.resolvedPageSheets.first;
          final secondSheet = currentPage.buildNextPageSheet();
          primaryBloc.add(
            AreasCreated([
              if (currentPage.areas.isEmpty) AreaPreset(area: firstSheet),
              AreaPreset(area: secondSheet),
            ]),
          );
          currentPage = currentPage.copyWith(
            areas: [firstSheet, secondSheet],
          );
          currentData = currentData.setPage(currentPage, primaryState.pageName).$1;
        }
        targetNoteData = currentData;
        final baseTitle = primaryState.metadata.name.isEmpty
            ? '当前笔记'
            : primaryState.metadata.name;
        displayTitle = '$baseTitle · 双页对照';
        location = primaryBloc.editorController.saveCubit.state.location;
      }

      final pageNames = targetNoteData.getPages(true);
      final targetPageName = (_splitSecondaryPageName != null &&
              pageNames.contains(_splitSecondaryPageName))
          ? _splitSecondaryPageName!
          : (pageNames.firstOrNull ?? '第 1 页');
      final targetPage =
          targetNoteData.getPage(targetPageName) ?? DocumentDefaults.createPage();

      final pixelRatio = MediaQuery.devicePixelRatioOf(context);
      final transformCubit = TransformCubit(pixelRatio);
      final assetService = AssetService();
      final networkingService = NetworkingService();

      final renderers = targetPage.layers
          .expand(
            (layer) => layer.content.map(
              (element) => Renderer.fromInstance(element, layer.id),
            ),
          )
          .toList();
      final backgrounds =
          targetPage.backgrounds.map(Renderer.fromInstance).toList();

      await Future.wait(
        renderers.map(
          (e) async =>
              await e.setup(
                transformCubit,
                targetNoteData,
                assetService,
                targetPage,
              ),
        ),
      );
      await Future.wait(
        backgrounds.map(
          (e) async =>
              await e.setup(
                transformCubit,
                targetNoteData,
                assetService,
                targetPage,
              ),
        ),
      );

      final editorController = EditorController(
        settingsCubit,
        transformCubit,
        CameraViewport.unbaked(
          backgrounds: backgrounds,
          unbakedElements: renderers,
          visibleElements: renderers,
          visibleUnbakedElements: renderers,
        ),
        networkingService: networkingService,
      );

      final secBloc = DocumentBloc(
        fileSystem,
        editorController,
        windowCubit,
        targetNoteData,
        location,
        assetService,
        targetPage,
        targetPageName,
        false,
      );
      final importService = ImportService(context, bloc: secBloc);
      final exportService = ExportService(context, secBloc);

      final runtime = _SplitSecondaryDocumentRuntime(
        filePath: filePath,
        displayTitle: displayTitle,
        bloc: secBloc,
        transformCubit: transformCubit,
        editorController: editorController,
        importService: importService,
        exportService: exportService,
        assetService: assetService,
        networkingService: networkingService,
      );
      runtime.attachAutoSave(fileSystem);
      secBloc.load();

      if (!mounted) {
        await runtime.saveAndClose(fileSystem);
        return;
      }

      setState(() {
        _splitSecondaryRuntime = runtime;
        _splitSecondaryLoading = false;
        _activeSplitPane = 1;
      });

      // 默认将分屏副窗口定位到目标页（如同文档双开则默认定位到第 2 页）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || runtime.transformCubit.isClosed) return;
        final sheetIdx = initialSheetIndex ??
            ((filePath == null || filePath.isEmpty) &&
                    targetPage.resolvedPageSheets.length > 1
                ? 1
                : 0);
        runtime.transformCubit.fitMumuStandardPage(
          page: targetPage,
          info: targetNoteData.getInfo() ?? DocumentDefaults.createInfo(),
          viewportSize: const Size(520, 680),
          sheetIndex: sheetIdx,
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() => _splitSecondaryLoading = false);
        _showQuickInteractionToast('打开分屏文档失败：$e');
      }
    }
  }

  Future<void> _createAndOpenNewNoteInSplit({required bool vertical}) async {
    final fileSystem = context.read<ButterflyFileSystem>();
    final docSystem = fileSystem.buildDocumentSystem();
    final now = DateTime.now();
    final title =
        '分屏笔记_${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}';
    final newDoc = DocumentDefaults.createDocument(name: title);
    try {
      final created = await docSystem.createFileWithName(
        name: title,
        suffix: '.bfly',
        newDoc.toFile(),
      );
      if (!mounted) return;
      await _openSecondaryNotebookInSplit(created.path, vertical: vertical);
      _showQuickInteractionToast('🪟 已新建《$title》并在分屏视图中打开');
    } catch (e) {
      if (mounted) {
        _showQuickInteractionToast('新建分屏笔记失败：$e');
      }
    }
  }

  /// Mumu 官方风格「应用内分屏」入口与文档选择弹窗
  Future<void> _showMumuSplitViewModal(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) async {
    final fileSystem = context.read<ButterflyFileSystem>();
    final docSystem = fileSystem.buildDocumentSystem();
    bool chosenVertical = _splitVertical;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.vertical_split_rounded,
                          color: Color(0xFF2F7D6E),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '应用内分屏',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                        ),
                        if (_splitViewOpen)
                          TextButton.icon(
                            icon: const Icon(
                              Icons.close_fullscreen_rounded,
                              size: 15,
                              color: Color(0xFFEF4444),
                            ),
                            label: const Text(
                              '关闭分屏',
                              style: TextStyle(
                                fontSize: 12,
                                color: Color(0xFFEF4444),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              setState(() {
                                _splitViewOpen = false;
                                _activeSplitPane = 0;
                              });
                            },
                          ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Text(
                      '无需退出编辑器，在应用内并排打开两个不同笔记本，或同一笔记本的不同页面，两侧独立滚动、缩放与手写编辑。',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey, height: 1.35),
                    ),
                    const SizedBox(height: 12),

                    // 1. 分屏方向选择：垂直分屏（左右） vs 水平分屏（上下）
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            avatar: const Icon(Icons.vertical_split_rounded, size: 16),
                            label: const Text('垂直分屏（左右并排）', style: TextStyle(fontSize: 12)),
                            selected: chosenVertical,
                            onSelected: (_) {
                              setModalState(() => chosenVertical = true);
                              if (_splitViewOpen) {
                                setState(() => _splitVertical = true);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ChoiceChip(
                            avatar: const Icon(Icons.horizontal_split_rounded, size: 16),
                            label: const Text('水平分屏（上下并排）', style: TextStyle(fontSize: 12)),
                            selected: !chosenVertical,
                            onSelected: (_) {
                              setModalState(() => chosenVertical = false);
                              if (_splitViewOpen) {
                                setState(() => _splitVertical = false);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // 2. 快捷分屏模式：同文档双页分屏对照 & 新建空白笔记分屏
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            icon: const Icon(Icons.copy_rounded, size: 16),
                            label: const Text('当前笔记双页对照', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              Navigator.pop(ctx);
                              unawaited(
                                _openSecondaryNotebookInSplit(
                                  null,
                                  vertical: chosenVertical,
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF2F7D6E),
                            ),
                            icon: const Icon(Icons.add_circle_outline_rounded, size: 16),
                            label: const Text('新建空白分屏笔记', style: TextStyle(fontSize: 12)),
                            onPressed: () {
                              Navigator.pop(ctx);
                              unawaited(
                                _createAndOpenNewNoteInSplit(vertical: chosenVertical),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 22),

                    // 3. 选择书架中的其他笔记本并排打开
                    const Text(
                      '从书架选择第二个笔记本并排打开（或从左侧文档列表直接拖放到屏幕）：',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: FutureBuilder<FileSystemEntity<NoteFile>?>(
                        future: docSystem.getAsset('', readData: true),
                        builder: (context, snapshot) {
                          final dir = snapshot.data;
                          final assets = dir is FileSystemDirectory<NoteFile>
                              ? dir.assets
                              : const <FileSystemEntity<NoteFile>>[];
                          final files =
                              assets.whereType<FileSystemFile<NoteFile>>().toList();

                          if (files.isEmpty) {
                            return const Center(
                              child: Text('书架暂无其他笔记本，可点击上方「新建空白分屏笔记」'),
                            );
                          }

                          return ListView.separated(
                            itemCount: files.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 6),
                            itemBuilder: (ctx, i) {
                              final f = files[i];
                              final isCurrentPrimary =
                                  f.path == (_currentDocumentPath());
                              return ListTile(
                                dense: true,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                tileColor: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest
                                    .withValues(alpha: 0.45),
                                leading: const Icon(
                                  Icons.book_rounded,
                                  color: Color(0xFF2F7D6E),
                                  size: 20,
                                ),
                                title: Text(
                                  f.fileNameWithoutExtension,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                subtitle: Text(
                                  isCurrentPrimary ? '当前主窗口笔记（点击可开启双页对照）' : f.path,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                trailing: FilledButton.tonal(
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    unawaited(
                                      _openSecondaryNotebookInSplit(
                                        isCurrentPrimary ? null : f.path,
                                        vertical: chosenVertical,
                                      ),
                                    );
                                  },
                                  child: Text(
                                    chosenVertical ? '左右分屏' : '上下分屏',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  unawaited(
                                    _openSecondaryNotebookInSplit(
                                      isCurrentPrimary ? null : f.path,
                                      vertical: chosenVertical,
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCanvasAndSplitHost(
    BuildContext context,
    DocumentLoadSuccess docState,
    BoxConstraints stageConstraints,
    bool isDark,
  ) {
    final primaryViewport = MainViewViewport(key: widget.viewportKey);

    // 支持从左侧「文档列表」直接拖拽任意笔记本到画布上自动开启分屏 (Mumu 官方分屏手势)
    Widget wrapWithSplitDropZone(Widget child) {
      return DragTarget<String>(
        onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
        onAcceptWithDetails: (details) {
          setState(() {
            _draggingDocFromList = false;
            _showLeftDocListDrawer = false;
          });
          unawaited(
            _openSecondaryNotebookInSplit(
              details.data,
              vertical: stageConstraints.maxWidth >= stageConstraints.maxHeight,
            ),
          );
        },
        builder: (context, candidate, _) {
          final hovering = candidate.isNotEmpty;
          return Stack(
            fit: StackFit.expand,
            children: [
              child,
              if (_draggingDocFromList || hovering)
                Positioned(
                  right: 16,
                  top: 16,
                  bottom: 16,
                  width: math.min(360, stageConstraints.maxWidth * 0.46),
                  child: IgnorePointer(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2F7D6E)
                            .withValues(alpha: hovering ? 0.22 : 0.10),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: const Color(0xFF2F7D6E),
                          width: hovering ? 2.5 : 1.5,
                        ),
                      ),
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.vertical_split_rounded,
                              size: 38,
                              color: Color(0xFF2F7D6E),
                            ),
                            SizedBox(height: 8),
                            Text(
                              '松手在此处开启分屏视图',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF2F7D6E),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }

    if (!_splitViewOpen) {
      return wrapWithSplitDropZone(primaryViewport);
    }

    if (_splitSecondaryRuntime == null && !_splitSecondaryLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _splitViewOpen && _splitSecondaryRuntime == null) {
          unawaited(_openSecondaryNotebookInSplit(_splitSecondaryFilePath));
        }
      });
    }

    final primaryPane = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_activeSplitPane != 0) {
          setState(() => _activeSplitPane = 0);
        }
      },
      child: Column(
        children: [
          _buildPrimarySplitPaneHeader(context, docState, isDark),
          Expanded(child: primaryViewport),
        ],
      ),
    );

    final secondaryPane = Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (_activeSplitPane != 1) {
          setState(() => _activeSplitPane = 1);
        }
      },
      child: _buildSplitSecondaryPane(context, docState, isDark),
    );

    final firstPane = _splitSwapped ? secondaryPane : primaryPane;
    final secondPane = _splitSwapped ? primaryPane : secondaryPane;

    final dividerHandle = GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          if (_splitVertical) {
            _splitRatio =
                (_splitRatio + details.delta.dx / stageConstraints.maxWidth)
                    .clamp(0.26, 0.74);
          } else {
            _splitRatio =
                (_splitRatio + details.delta.dy / stageConstraints.maxHeight)
                    .clamp(0.26, 0.74);
          }
        });
      },
      onDoubleTap: () => setState(() => _splitRatio = 0.50),
      child: Container(
        width: _splitVertical ? 12 : double.infinity,
        height: _splitVertical ? double.infinity : 12,
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFD8DEE9),
        child: Center(
          child: Container(
            width: _splitVertical ? 4 : 44,
            height: _splitVertical ? 44 : 4,
            decoration: BoxDecoration(
              color: const Color(0xFF2F7D6E),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );

    final splitLayout = _splitVertical
        ? Row(
            children: [
              Expanded(flex: (_splitRatio * 100).round(), child: firstPane),
              dividerHandle,
              Expanded(
                flex: ((1.0 - _splitRatio) * 100).round(),
                child: secondPane,
              ),
            ],
          )
        : Column(
            children: [
              Expanded(flex: (_splitRatio * 100).round(), child: firstPane),
              dividerHandle,
              Expanded(
                flex: ((1.0 - _splitRatio) * 100).round(),
                child: secondPane,
              ),
            ],
          );

    return wrapWithSplitDropZone(splitLayout);
  }

  Widget _buildPrimarySplitPaneHeader(
    BuildContext context,
    DocumentLoadSuccess docState,
    bool isDark,
  ) {
    final isActive = _activeSplitPane == 0;
    final title = docState.metadata.name.isEmpty ? '主笔记本' : docState.metadata.name;
    final sheets = docState.page.resolvedPageSheets;

    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF162033) : const Color(0xFFF8FAFC),
        border: Border(
          top: BorderSide(
            color: isActive ? const Color(0xFF2F7D6E) : Colors.transparent,
            width: 2.2,
          ),
          bottom: BorderSide(
            color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF2F7D6E) : Colors.grey,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$title (${sheets.length}页)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive
                    ? const Color(0xFF2F7D6E)
                    : (isDark ? Colors.white70 : const Color(0xFF475569)),
              ),
            ),
          ),
          TextButton.icon(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const Icon(Icons.add, size: 13),
            label: const Text('加页', style: TextStyle(fontSize: 10.5)),
            onPressed: () => _addNewPage(
              context,
              docState,
              targetBloc: context.read<DocumentBloc>(),
              targetTransform: context.read<TransformCubit>(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSplitSecondaryPane(
    BuildContext context,
    DocumentLoadSuccess primaryDocState,
    bool isDark,
  ) {
    final runtime = _splitSecondaryRuntime;
    final isActive = _activeSplitPane == 1;

    if (_splitSecondaryLoading || runtime == null) {
      return Container(
        color: isDark ? const Color(0xFF0B1120) : const Color(0xFFE4E7EE),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    return MultiBlocProvider(
      providers: [
        BlocProvider<DocumentBloc>.value(value: runtime.bloc),
        BlocProvider<TransformCubit>.value(value: runtime.transformCubit),
        BlocProvider<RendererCubit>.value(
          value: runtime.editorController.rendererCubit,
        ),
        BlocProvider<ToolCubit>.value(
          value: runtime.editorController.toolCubit,
        ),
        BlocProvider<EditorInputCubit>.value(
          value: runtime.editorController.inputCubit,
        ),
        BlocProvider<DocumentSaveCubit>.value(
          value: runtime.editorController.saveCubit,
        ),
        BlocProvider<EditorViewCubit>.value(
          value: runtime.editorController.viewCubit,
        ),
      ],
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<EditorController>.value(
            value: runtime.editorController,
          ),
          RepositoryProvider<ImportService>.value(value: runtime.importService),
          RepositoryProvider<ExportService>.value(value: runtime.exportService),
        ],
        child: BlocBuilder<DocumentBloc, DocumentState>(
          bloc: runtime.bloc,
          builder: (secCtx, secState) {
            final loaded = secState is DocumentLoadSuccess ? secState : null;
            final sheets = loaded?.page.resolvedPageSheets ?? const <Area>[];

            return Column(
              children: [
                // 分屏副窗口紧凑控制栏：激活态蓝条、切换文档、切换页码、加页、互换位置、切换上下/左右分屏、双向链接、关闭
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF162033)
                        : const Color(0xFFF8FAFC),
                    border: Border(
                      top: BorderSide(
                        color: isActive
                            ? const Color(0xFF2F7D6E)
                            : Colors.transparent,
                        width: 2.2,
                      ),
                      bottom: BorderSide(
                        color: isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFE2E8F0),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: isActive
                              ? const Color(0xFF2F7D6E)
                              : Colors.grey,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: InkWell(
                          onTap: () => _showMumuSplitViewModal(
                            context,
                            primaryDocState,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  runtime.displayTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: isActive
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: isActive
                                        ? const Color(0xFF2F7D6E)
                                        : (isDark
                                              ? Colors.white70
                                              : const Color(0xFF475569)),
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.keyboard_arrow_down_rounded,
                                size: 16,
                                color: Color(0xFF2F7D6E),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (loaded != null && sheets.isNotEmpty)
                        PopupMenuButton<int>(
                          tooltip: '跳转分屏窗口页面',
                          padding: EdgeInsets.zero,
                          onSelected: (idx) {
                            runtime.transformCubit.fitMumuStandardPage(
                              page: loaded.page,
                              info: loaded.info,
                              viewportSize: const Size(520, 680),
                              sheetIndex: idx,
                            );
                          },
                          itemBuilder: (_) => [
                            for (int i = 0; i < sheets.length; i++)
                              PopupMenuItem(
                                value: i,
                                child: Text(
                                  '跳转至第 ${i + 1} 页',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF2F7D6E)
                                  .withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '共${sheets.length}页',
                              style: const TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2F7D6E),
                              ),
                            ),
                          ),
                        ),
                      if (loaded != null)
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 24,
                            minHeight: 24,
                          ),
                          tooltip: '在分屏副窗口新增一页',
                          icon: const Icon(Icons.add, size: 14),
                          onPressed: () => _addNewPage(
                            context,
                            loaded,
                            targetBloc: runtime.bloc,
                            targetTransform: runtime.transformCubit,
                          ),
                        ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        tooltip: '左右/上下互换分屏窗口位置',
                        icon: const Icon(Icons.open_with_rounded, size: 14),
                        onPressed: () =>
                            setState(() => _splitSwapped = !_splitSwapped),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        tooltip: _splitVertical ? '切换为上下水平分屏' : '切换为左右垂直分屏',
                        icon: Icon(
                          _splitVertical
                              ? Icons.horizontal_split_rounded
                              : Icons.vertical_split_rounded,
                          size: 14,
                        ),
                        onPressed: () =>
                            setState(() => _splitVertical = !_splitVertical),
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        tooltip: '建立左右跨文档双向链接',
                        icon: const Icon(
                          Icons.add_link_rounded,
                          size: 15,
                          color: Color(0xFF2F7D6E),
                        ),
                        onPressed: () {
                          final targetLabel = runtime.filePath ?? runtime.displayTitle;
                          context.read<DocumentBloc>().add(
                            WaypointCreated(
                              Waypoint(
                                '🔗 [[双向链接 -> $targetLabel]]',
                                const math.Point<double>(120.0, 120.0),
                                1.0,
                              ),
                            ),
                          );
                          _showQuickInteractionToast(
                            '🔗 已建立与《${runtime.displayTitle}》的跨屏双向链接',
                          );
                        },
                      ),
                      IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                        tooltip: '关闭分屏',
                        icon: const Icon(Icons.close, size: 14),
                        onPressed: () => setState(() {
                          _splitViewOpen = false;
                          _activeSplitPane = 0;
                        }),
                      ),
                    ],
                  ),
                ),

                // 分屏副窗口真实手写画布（独立滚动、独立缩放、独立落笔与自动保存）
                Expanded(
                  child: MainViewViewport(key: runtime.viewportKey),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 9. 左侧滑出「文档列表」侧边栏（对齐 Mumu 官网：支持长按拖拽分屏 & ··· 菜单垂直/水平分屏）
  // --------------------------------------------------------------------------
  Widget _buildLeftDocumentListDrawer(
    BuildContext context,
    DocumentLoadSuccess docState,
    bool isDark,
  ) {
    final fileSystem = context.read<ButterflyFileSystem>();
    final docSystem = fileSystem.buildDocumentSystem();

    return Material(
      elevation: 16,
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.library_books_rounded,
                      size: 18,
                      color: Color(0xFF2F7D6E),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '文档列表',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _showLeftDocListDrawer = false),
                    ),
                  ],
                ),
                const Text(
                  '💡 长按拖动任意文档到右侧画布，或点击 ··· 菜单即可开启分屏双开',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFF2F7D6E)),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 32,
                  child: TextField(
                    style: const TextStyle(fontSize: 12),
                    decoration: InputDecoration(
                      hintText: '搜索笔记本...',
                      prefixIcon: const Icon(Icons.search_rounded, size: 15),
                      contentPadding: EdgeInsets.zero,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    onChanged: (v) => setState(() => _docListSearchQuery = v.trim()),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: FutureBuilder<FileSystemEntity<NoteFile>?>(
              future: docSystem.getAsset('', readData: true),
              builder: (context, snapshot) {
                final dir = snapshot.data;
                final assets = dir is FileSystemDirectory<NoteFile>
                    ? dir.assets
                    : const <FileSystemEntity<NoteFile>>[];
                final allFiles =
                    assets.whereType<FileSystemFile<NoteFile>>().toList();
                final q = _docListSearchQuery.toLowerCase();
                final files = q.isEmpty
                    ? allFiles
                    : allFiles
                          .where(
                            (f) => f.fileNameWithoutExtension
                                .toLowerCase()
                                .contains(q),
                          )
                          .toList();

                if (files.isEmpty) {
                  return const Center(
                    child: Text(
                      '暂无匹配的笔记本',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(10),
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (ctx, idx) {
                    final f = files[idx];
                    final isCurrent = f.path == (_currentDocumentPath());

                    final tile = ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(
                          color: isCurrent
                              ? const Color(0xFF2F7D6E)
                              : Colors.transparent,
                        ),
                      ),
                      tileColor: isDark
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFF8FAFC),
                      leading: Container(
                        width: 32,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2F7D6E).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: const Color(0xFF2F7D6E).withValues(alpha: 0.4),
                          ),
                        ),
                        child: const Icon(
                          Icons.book_rounded,
                          size: 16,
                          color: Color(0xFF2F7D6E),
                        ),
                      ),
                      title: Text(
                        f.fileNameWithoutExtension,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      subtitle: Text(
                        isCurrent ? '当前打开 · 可开启双页分屏' : '长按拖出或点 ··· 分屏打开',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 10),
                      ),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 16),
                        onSelected: (act) {
                          if (act == 'split_v') {
                            setState(() => _showLeftDocListDrawer = false);
                            unawaited(
                              _openSecondaryNotebookInSplit(
                                isCurrent ? null : f.path,
                                vertical: true,
                              ),
                            );
                          } else if (act == 'split_h') {
                            setState(() => _showLeftDocListDrawer = false);
                            unawaited(
                              _openSecondaryNotebookInSplit(
                                isCurrent ? null : f.path,
                                vertical: false,
                              ),
                            );
                          } else if (act == 'open') {
                            setState(() => _showLeftDocListDrawer = false);
                            context.go(
                              Uri(
                                path: '/new',
                                queryParameters: {'path': f.path},
                              ).toString(),
                            );
                          } else if (act == 'rename') {
                            _showRenameNotebookDialog(f);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'split_v',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.vertical_split_rounded,
                                  size: 16,
                                  color: Color(0xFF2F7D6E),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '垂直分屏（左右并排打开）',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuItem(
                            value: 'split_h',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.horizontal_split_rounded,
                                  size: 16,
                                  color: Color(0xFF2F7D6E),
                                ),
                                SizedBox(width: 8),
                                Text(
                                  '水平分屏（上下并排打开）',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'open',
                            child: Text(
                              '在当前窗口切换打开',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'rename',
                            child: Text(
                              '重命名此笔记本',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        setState(() => _showLeftDocListDrawer = false);
                        if (isCurrent) {
                          unawaited(
                            _openSecondaryNotebookInSplit(null, vertical: true),
                          );
                        } else {
                          context.go(
                            Uri(
                              path: '/new',
                              queryParameters: {'path': f.path},
                            ).toString(),
                          );
                        }
                      },
                    );

                    return LongPressDraggable<String>(
                      data: f.path,
                      delay: const Duration(milliseconds: 280),
                      onDragStarted: () =>
                          setState(() => _draggingDocFromList = true),
                      onDragEnd: (_) =>
                          setState(() => _draggingDocFromList = false),
                      onDraggableCanceled: (_, __) =>
                          setState(() => _draggingDocFromList = false),
                      feedback: Material(
                        elevation: 10,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: 240,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2F7D6E),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.vertical_split_rounded,
                                color: Colors.white,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '拖到画布分屏打开《${f.fileNameWithoutExtension}》',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: tile,
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.vertical_split_rounded, size: 15),
                    label: const Text('新建并分屏', style: TextStyle(fontSize: 11.5)),
                    onPressed: () {
                      setState(() => _showLeftDocListDrawer = false);
                      unawaited(_createAndOpenNewNoteInSplit(vertical: true));
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.add, size: 15),
                    label: const Text('新建笔记', style: TextStyle(fontSize: 11.5)),
                    onPressed: () {
                      setState(() => _showLeftDocListDrawer = false);
                      context.go('/new');
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 10. 右侧边栏 (3.18 Right Sidebar：页面缩略图 / 大纲 / 批注与双向链接)
  // --------------------------------------------------------------------------
  Widget _buildRightSidebarDrawer(
    BuildContext context,
    DocumentLoadSuccess docState,
    bool isDark,
  ) {
    final bloc = _getActiveBloc(context);
    final activeTransform = _getActiveTransformCubit(context);
    final activeDocState = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;
    final sheets = activeDocState.page.resolvedPageSheets;
    final waypoints = activeDocState.page.waypoints;

    return BlocBuilder<TransformCubit, CameraTransform>(
      bloc: activeTransform,
      builder: (context, transform) {
        final curSheetIdx = activeDocState.page.activeSheetIndexForGlobalPoint(
          transform.localToGlobal(const Offset(400, 300)),
        );

        return Material(
          elevation: 16,
          color: isDark ? const Color(0xFF1E293B) : Colors.white,
          child: Column(
            children: [
              // 顶部三标签切换：页面概览 | 大纲 | 标注
              Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 6, 8),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE5E7EB),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    for (final entry in [(0, '缩略图'), (1, '大纲'), (2, '批注/双链')])
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: ChoiceChip(
                          label: Text(
                            entry.$2,
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: _rightSidebarTab == entry.$1,
                          onSelected: (_) =>
                              setState(() => _rightSidebarTab = entry.$1),
                        ),
                      ),
                    const Spacer(),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _showRightSidebar = false),
                    ),
                  ],
                ),
              ),

              // 标签页内容区
              Expanded(
                child: switch (_rightSidebarTab) {
                  // Tab 0: 标准分页缩略图列表（点击直接纵向滚动跳转到对应页面）
                  0 => ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: sheets.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (ctx, idx) {
                      final sheet = sheets[idx];
                      final isCurrent = idx == curSheetIdx;

                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _scrollToSheetIndex(
                          context,
                          activeDocState,
                          idx,
                          customTransformCubit: activeTransform,
                        ),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? const Color(0xFF2F7D6E).withValues(alpha: 0.10)
                                : (isDark
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFF9FAFB)),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isCurrent
                                  ? const Color(0xFF2F7D6E)
                                  : Colors.transparent,
                              width: 1.6,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              AspectRatio(
                                aspectRatio: 0.72,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: DocumentPagePreview(
                                    state: activeDocState,
                                    pageName: activeDocState.pageName,
                                    page: activeDocState.page,
                                    area: sheet,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isCurrent
                                          ? const Color(0xFF2F7D6E)
                                          : Colors.grey.withValues(alpha: 0.25),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '${idx + 1}',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: isCurrent
                                            ? Colors.white
                                            : Colors.grey,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      sheet.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(Icons.more_horiz, size: 16),
                                    onSelected: (act) {
                                      if (act == 'outline') {
                                        bloc.add(
                                          WaypointCreated(
                                            Waypoint(
                                              '第 ${idx + 1} 页：${sheet.name}',
                                              sheet.position,
                                              1.0,
                                            ),
                                          ),
                                        );
                                      } else if (act == 'split') {
                                        setState(() => _showRightSidebar = false);
                                        unawaited(
                                          _openSecondaryNotebookInSplit(
                                            null,
                                            vertical: true,
                                            initialSheetIndex: idx,
                                          ),
                                        );
                                      } else if (act == 'del' &&
                                          sheets.length > 1) {
                                        bloc.add(
                                          AreasRemoved([
                                            AreaPreset(
                                              page: docState.pageName,
                                              name: sheet.name,
                                            ),
                                          ]),
                                        );
                                      }
                                    },
                                    itemBuilder: (_) => [
                                      const PopupMenuItem(
                                        value: 'split',
                                        child: Text(
                                          '在分屏视图中对照此页',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'outline',
                                        child: Text(
                                          '将此页加入大纲',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      if (sheets.length > 1)
                                        const PopupMenuItem(
                                          value: 'del',
                                          child: Text(
                                            '删除此页',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Colors.redAccent,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  // Tab 1: 大纲 (Outline, Ch. 3.18)
                  1 => Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add, size: 15),
                            label: const Text(
                              '将当前页位置添加为大纲章节',
                              style: TextStyle(fontSize: 11),
                            ),
                            onPressed: () => _promptAddOutlineWaypoint(context),
                          ),
                        ),
                      ),
                      Expanded(
                        child: waypoints.isEmpty
                            ? const Center(
                                child: Text(
                                  '暂无大纲条目\n可点击上方按钮或从页面菜单添加',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey,
                                  ),
                                ),
                              )
                            : ListView.builder(
                                itemCount: waypoints.length,
                                itemBuilder: (ctx, i) {
                                  final wp = waypoints[i];
                                  return ListTile(
                                    dense: true,
                                    leading: const Icon(
                                      Icons.bookmark_rounded,
                                      size: 16,
                                      color: Color(0xFF2F7D6E),
                                    ),
                                    title: Text(
                                      wp.name ?? '大纲节点 #${i + 1}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    trailing: IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 15,
                                      ),
                                      onPressed: () =>
                                          bloc.add(WaypointRemoved(wp.name)),
                                    ),
                                    onTap: () {
                                      activeTransform.teleportToWaypoint(wp);
                                    },
                                  );
                                },
                              ),
                      ),
                    ],
                  ),

                  // Tab 2: 标注与双向链接
                  _ => ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2F7D6E).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '🔗 跨页与跨文档双向链接',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF2F7D6E),
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '点击下方页面标签即可创建双向链接并自动开启应用内分屏对照：',
                              style: TextStyle(fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (int i = 0; i < sheets.length; i++)
                                  ActionChip(
                                    avatar: const Icon(
                                      Icons.add_link_rounded,
                                      size: 14,
                                    ),
                                    label: Text(
                                      '双链至第 ${i + 1} 页',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    onPressed: () {
                                      bloc.add(
                                        WaypointCreated(
                                          Waypoint(
                                            '🔗 [[双向链接 -> 第 ${i + 1} 页]]',
                                            sheets[i].position,
                                            1.0,
                                          ),
                                        ),
                                      );
                                      unawaited(
                                        _openSecondaryNotebookInSplit(
                                          null,
                                          vertical: true,
                                          initialSheetIndex: i,
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '已建立的双向链接（点击自动开启分屏并跳转）',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF059669),
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...() {
                              final links = waypoints
                                  .where(
                                    (w) => (w.name ?? '').contains('双向链接 ->'),
                                  )
                                  .toList();
                              if (links.isEmpty) {
                                return const [
                                  Text(
                                    '暂无链接。可在分屏控制栏或点击上方页面标签一键建立。',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ];
                              }
                              return [
                                for (final link in links)
                                  ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const Icon(
                                      Icons.link_rounded,
                                      size: 16,
                                      color: Color(0xFF059669),
                                    ),
                                    title: Text(
                                      link.name ?? '双向链接',
                                      style: const TextStyle(fontSize: 11.5),
                                    ),
                                    trailing: const Icon(
                                      Icons.vertical_split_rounded,
                                      size: 14,
                                      color: Color(0xFF059669),
                                    ),
                                    onTap: () {
                                      final name = link.name ?? '';
                                      final target = name
                                          .split('-> ')
                                          .last
                                          .replaceAll(']', '')
                                          .trim();
                                      final matchedSheetIdx = sheets.indexWhere(
                                        (s) => s.name == target,
                                      );
                                      if (matchedSheetIdx != -1) {
                                        unawaited(
                                          _openSecondaryNotebookInSplit(
                                            null,
                                            vertical: true,
                                            initialSheetIndex: matchedSheetIdx,
                                          ),
                                        );
                                      } else {
                                        unawaited(
                                          _openSecondaryNotebookInSplit(
                                            target.endsWith('.bfly')
                                                ? target
                                                : null,
                                            vertical: true,
                                          ),
                                        );
                                      }
                                    },
                                  ),
                              ];
                            }(),
                          ],
                        ),
                      ),
                    ],
                  ),
                },
              ),

              // 底部平铺缩略图与新建页面按钮
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE5E7EB),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.grid_view_outlined, size: 15),
                        label: const Text(
                          '平铺缩略图',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: () {
                          setState(() => _showRightSidebar = false);
                          _openTiledPageOverviewModal(context, activeDocState);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.icon(
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          '添加页面',
                          style: TextStyle(fontSize: 11),
                        ),
                        onPressed: () => _addNewPage(
                          context,
                          activeDocState,
                          targetBloc: bloc,
                          targetTransform: activeTransform,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --------------------------------------------------------------------------
  // 11. 浮动图层面板 (Ch. 3.9 图层系统 Layer System)
  // --------------------------------------------------------------------------
  Widget _buildFloatingLayersCard(BuildContext context, DocumentLoadSuccess docState, bool isDark) {
    final bloc = context.read<DocumentBloc>();
    final layers = docState.page.layers;

    return Material(
      elevation: 16,
      borderRadius: BorderRadius.circular(18),
      color: isDark ? const Color(0xFF1E293B) : Colors.white,
      child: Container(
        width: 268,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.layers_rounded, size: 16, color: Color(0xFF2F7D6E)),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text(
                    '图层系统',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.add, size: 14),
                  label: const Text('新图层', style: TextStyle(fontSize: 11)),
                  onPressed: () {
                    bloc.add(LayerCreated(name: '图层 ${layers.length + 1}'));
                  },
                ),
                IconButton(
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                  icon: const Icon(Icons.close, size: 15),
                  onPressed: () => setState(() => _showFloatingLayersPanel = false),
                ),
              ],
            ),
            const Divider(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: layers.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (ctx, i) {
                  final layer = layers[i];
                  final isCurrent = layer.id == docState.currentLayer;
                  final isVisible = docState.isLayerVisible(layer.id);

                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      final id = layer.id;
                      if (id != null) bloc.add(CurrentLayerChanged(id));
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? const Color(0xFF2F7D6E).withValues(alpha: 0.12)
                            : (isDark ? const Color(0xFF0F172A) : const Color(0xFFF9FAFB)),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isCurrent ? const Color(0xFF2F7D6E) : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                            tooltip: isVisible ? '隐藏图层' : '显示图层',
                            icon: Icon(
                              isVisible ? Icons.visibility_rounded : Icons.visibility_off_outlined,
                              size: 15,
                              color: isVisible ? const Color(0xFF2F7D6E) : Colors.grey,
                            ),
                            onPressed: () {
                              final id = layer.id;
                              if (id != null) {
                                bloc.add(LayerVisibilityChanged(id, !isVisible));
                              }
                            },
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              layer.name.isEmpty
                                  ? '图层 ${i + 1} (${layer.content.length}笔)'
                                  : '${layer.name} (${layer.content.length}笔)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                              ),
                            ),
                          ),
                          if (layers.length > 1)
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                              tooltip: '删除图层',
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 15,
                                color: Colors.redAccent,
                              ),
                              onPressed: () {
                                final id = layer.id;
                                if (id != null) bloc.add(LayerRemoved(id));
                              },
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 12. 仿真可旋转标尺辅助工具 (Ch. 3.11 标尺 Ruler)
  // --------------------------------------------------------------------------
  Widget _buildSimulationRulerOverlay(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onScaleStart: (details) {
        _rulerGestureStartAngle = _rulerAngleDeg;
      },
      onScaleUpdate: (details) {
        setState(() {
          // D7 作用域仲裁：单指拖动平移标尺；双指在标尺上旋转时直接旋转标尺角度（屏蔽底层画布缩放）
          _rulerOffset = Offset(
            (_rulerOffset.dx + details.focalPointDelta.dx).clamp(0.0, 300.0),
            (_rulerOffset.dy + details.focalPointDelta.dy).clamp(0.0, 1600.0),
          );
          if (details.pointerCount >= 2 && details.rotation.abs() > 0.01) {
            _rulerAngleDeg = (_rulerGestureStartAngle + details.rotation * 180.0 / math.pi) % 360.0;
          }
        });
      },
      child: Transform.rotate(
        angle: _rulerAngleDeg * math.pi / 180.0,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 460,
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7).withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFD97706), width: 1.8),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.14), blurRadius: 14)],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 顶部厘米刻度线
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (int cm = 0; cm <= 16; cm += 2)
                      Text(
                        '${cm}cm',
                        style: const TextStyle(
                          fontSize: 9,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF78350F),
                        ),
                      ),
                  ],
                ),
                // 底部角度控制与关闭
                Row(
                  children: [
                    const Icon(Icons.straighten_rounded, size: 14, color: Color(0xFF92400E)),
                    const SizedBox(width: 6),
                    Text(
                      '标尺辅助 (${_rulerAngleDeg.toStringAsFixed(0)}° · 拖动平移)',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF78350F),
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => setState(() => _rulerAngleDeg = (_rulerAngleDeg - 15) % 360),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '-15°',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => _rulerAngleDeg = (_rulerAngleDeg + 15) % 360),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '+15°',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF92400E),
                          ),
                        ),
                      ),
                    ),
                    InkWell(
                      onTap: () => setState(() => _showSimulationRuler = false),
                      child: const Icon(Icons.close, size: 15, color: Color(0xFF92400E)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExitZenFloatingButton(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          setState(() => _focusZenMode = false);
          context.read<EditorInputCubit>().exitHideUI();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xD80F172A),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0xFF334155)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: Color(0xFF60A5FA)),
              SizedBox(width: 6),
              Text(
                '退出专注模式 (呼出工具栏)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // 14. 弹窗与菜单动作方法：插入菜单、工具栏自定义、输入模式、更多菜单、平铺概览
  // --------------------------------------------------------------------------

  /// 对话框会被推入路由层，默认取不到编辑器作用域里的 Provider。
  /// 需要 DocumentBloc（页面缩略图 / 导入导出）的对话框统一用这个包装器补上作用域。
  Widget _editorDialogScope(Widget child) {
    final controller = context.read<EditorController>();
    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<EditorController>.value(value: controller),
        RepositoryProvider<ImportService>.value(value: context.read<ImportService>()),
        RepositoryProvider<ExportService>.value(value: context.read<ExportService>()),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider<DocumentBloc>.value(value: context.read<DocumentBloc>()),
          BlocProvider<TransformCubit>.value(value: context.read<TransformCubit>()),
          BlocProvider<ToolCubit>.value(value: controller.toolCubit),
          BlocProvider<EditorInputCubit>.value(value: controller.inputCubit),
          BlocProvider<DocumentSaveCubit>.value(value: controller.saveCubit),
          BlocProvider<EditorViewCubit>.value(value: controller.viewCubit),
          BlocProvider<RendererCubit>.value(value: controller.rendererCubit),
        ],
        child: child,
      ),
    );
  }

  /// 当前主文档的保存路径（DocumentLoadSuccess 本身不含 location，需要从 SaveCubit 读取）。
  String _currentDocumentPath() => context
      .read<DocumentBloc>()
      .editorController
      .saveCubit
      .state
      .location
      .path;

  Future<void> _saveAndExitToHome(BuildContext context) async {
    final bloc = context.read<DocumentBloc>();
    final sec = _splitSecondaryRuntime;
    _splitSecondaryRuntime = null;
    if (sec != null) {
      try {
        await sec.saveAndClose(context.read<ButterflyFileSystem>());
      } catch (_) {}
    }
    try {
      if (!bloc.isClosed) {
        await bloc.save();
      }
    } catch (_) {}
    if (!context.mounted) return;
    if (GoRouter.of(context).canPop()) {
      context.pop();
    } else {
      context.go('/');
    }
  }

  Future<void> _showRenameNotebookDialog(FileSystemFile<NoteFile> file) async {
    final data = file.data;
    if (data == null) {
      _showQuickInteractionToast('⚠️ 该文件尚未读取完成，暂时无法重命名');
      return;
    }
    final ctrl = TextEditingController(text: file.fileNameWithoutExtension);
    final fileSystem = context.read<ButterflyFileSystem>();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名笔记本', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新的笔记本名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              Navigator.pop(ctx);
              if (name.isEmpty) return;
              try {
                final note = NoteData.fromData(data.data);
                final updated = note.setMetadata(
                  (note.getMetadata() ?? DocumentDefaults.createMetadata()).copyWith(
                    name: name,
                    updatedAt: DateTime.now().toUtc(),
                  ),
                );
                await fileSystem.buildDocumentSystem().updateFile(file.path, updated.toFile());
                if (!mounted) return;
                _showQuickInteractionToast('✅ 已重命名为《$name》');
              } catch (e) {
                if (!mounted) return;
                _showQuickInteractionToast('重命名失败：$e');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _addNewPage(
    BuildContext context,
    DocumentLoadSuccess docState, {
    bool scrollToNewPage = true,
    DocumentBloc? targetBloc,
    TransformCubit? targetTransform,
  }) {
    final bloc = targetBloc ?? _getActiveBloc(context);
    final tc = targetTransform ?? _getActiveTransformCubit(context);
    final st = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;

    if (st.page.isMumuInfiniteCanvas(st.info)) {
      _showQuickInteractionToast('当前为无边界无限画布，可向四周无限书写，无需添加分页');
      return;
    }

    final existingSheets = st.page.resolvedPageSheets;
    final nextSheet = st.page.buildNextPageSheet();
    final presets = <AreaPreset>[
      if (st.page.areas.isEmpty) AreaPreset(area: existingSheets.first),
      AreaPreset(area: nextSheet),
    ];
    bloc.add(AreasCreated(presets));

    if (scrollToNewPage) {
      final newIndex = existingSheets.length;
      final updatedPage = st.page.copyWith(
        areas: [...existingSheets, nextSheet],
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || tc.isClosed) return;
        final renderBox = context.findRenderObject();
        final vpSize =
            renderBox is RenderBox ? renderBox.size : const Size(800, 600);
        tc.fitMumuStandardPage(
          page: updatedPage,
          info: st.info,
          viewportSize: vpSize,
          sheetIndex: newIndex,
        );
      });
    }
  }

  String _uniqueSheetName(DocumentPage page) {
    final existing = page.areas.map((a) => a.name).toSet();
    var num = page.resolvedPageSheets.length + 1;
    var name = '第 $num 页';
    while (existing.contains(name)) {
      num++;
      name = '第 $num 页';
    }
    return name;
  }

  Offset? _elementAnchor(PadElement element) {
    if (element is PenElement) {
      if (element.points.isEmpty) return null;
      return Offset(element.points.first.x, element.points.first.y);
    }
    if (element is PolygonElement) {
      if (element.points.isEmpty) return null;
      return Offset(element.points.first.x, element.points.first.y);
    }
    if (element is TextElement) {
      return Offset(element.position.x, element.position.y);
    }
    if (element is MarkdownElement) {
      return Offset(element.position.x, element.position.y);
    }
    if (element is ImageElement) {
      return Offset(element.position.x, element.position.y);
    }
    if (element is PdfElement) {
      return Offset(element.position.x, element.position.y);
    }
    if (element is SvgElement) {
      return Offset(element.position.x, element.position.y);
    }
    if (element is ShapeElement) {
      return Offset(element.firstPosition.x, element.firstPosition.y);
    }
    if (element is TableElement) {
      return Offset(element.firstPosition.x, element.firstPosition.y);
    }
    if (element is TextureElement) {
      return Offset(element.firstPosition.x, element.firstPosition.y);
    }
    return null;
  }

  PadElement _shiftElement(PadElement element, Offset delta) {
    if (element is PenElement) {
      return element.copyWith(
        points: [
          for (final p in element.points)
            PathPoint(p.x + delta.dx, p.y + delta.dy, p.pressure),
        ],
      );
    }
    if (element is PolygonElement) {
      return element.copyWith(
        points: [
          for (final p in element.points)
            PolygonPoint(
              p.x + delta.dx,
              p.y + delta.dy,
              handleIn: p.handleIn,
              handleOut: p.handleOut,
            ),
        ],
      );
    }
    math.Point<double> moved(math.Point<double> point) =>
        math.Point<double>(point.x + delta.dx, point.y + delta.dy);
    if (element is TextElement) {
      return element.copyWith(position: moved(element.position));
    }
    if (element is MarkdownElement) {
      return element.copyWith(position: moved(element.position));
    }
    if (element is ImageElement) {
      return element.copyWith(position: moved(element.position));
    }
    if (element is PdfElement) {
      return element.copyWith(position: moved(element.position));
    }
    if (element is SvgElement) {
      return element.copyWith(position: moved(element.position));
    }
    if (element is ShapeElement) {
      return element.copyWith(
        firstPosition: moved(element.firstPosition),
        secondPosition: moved(element.secondPosition),
      );
    }
    if (element is TableElement) {
      return element.copyWith(
        firstPosition: moved(element.firstPosition),
        secondPosition: moved(element.secondPosition),
      );
    }
    if (element is TextureElement) {
      return element.copyWith(
        firstPosition: moved(element.firstPosition),
        secondPosition: moved(element.secondPosition),
      );
    }
    return element;
  }

  /// 在当前页之后插入一张新纸页；后续页面与 PDF 内容整体后移，适用于任意两页之间。
  void _insertPageAfterCurrent(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) {
    final bloc = _getActiveBloc(context);
    final tc = _getActiveTransformCubit(context);
    final st = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;
    if (st.page.isMumuInfiniteCanvas(st.info)) {
      _showQuickInteractionToast('无限画布无需插入分页');
      return;
    }
    final sheets = st.page.resolvedPageSheets;
    if (sheets.isEmpty) {
      _addNewPage(context, st, targetBloc: bloc, targetTransform: tc);
      return;
    }
    final renderBox = context.findRenderObject();
    final viewportSize =
        renderBox is RenderBox ? renderBox.size : const Size(800, 600);
    final idx = st.page
        .activeSheetIndexForGlobalPoint(
          tc.state.localToGlobal(viewportSize.center(Offset.zero)),
        )
        .clamp(0, sheets.length - 1);
    final current = sheets[idx];
    final horizontal = st.page.isMumuHorizontalScroll;
    const gap = kMumuPageGap;
    final newSheet = Area(
      name: _uniqueSheetName(st.page),
      width: current.width,
      height: current.height,
      position: horizontal
          ? math.Point<double>(
              current.position.x + current.width + gap,
              current.position.y,
            )
          : math.Point<double>(
              current.position.x,
              current.position.y + current.height + gap,
            ),
    );
    final delta = horizontal
        ? Offset(current.width + gap, 0)
        : Offset(0, current.height + gap);

    final updated = <Area>[];
    for (var i = 0; i < sheets.length; i++) {
      final area = sheets[i];
      if (i <= idx) {
        updated.add(area);
        continue;
      }
      final moved = area.copyWith(
        position: horizontal
            ? math.Point<double>(area.position.x + delta.dx, area.position.y)
            : math.Point<double>(area.position.x, area.position.y + delta.dy),
      );
      updated.add(moved);
      bloc.add(AreaChanged(area.name, moved));
    }

    // 后续页面的笔迹/PDF 元素同步后移，避免与插入的新页重叠
    final changed = <String, List<PadElement>>{};
    for (final layer in st.page.layers) {
      final layerId = layer.id;
      if (layerId == null) continue;
      var modified = false;
      final content = <PadElement>[];
      for (final element in layer.content) {
        final anchor = _elementAnchor(element);
        final belongsToLaterPage = anchor != null &&
            (horizontal
                ? anchor.dx >= current.position.x + current.width - 2
                : anchor.dy >= current.position.y + current.height - 2);
        if (belongsToLaterPage) {
          modified = true;
          content.add(_shiftElement(element, delta));
        } else {
          content.add(element);
        }
      }
      if (modified) changed[layerId] = content;
    }
    if (changed.isNotEmpty) bloc.add(ElementsChanged(changed));

    bloc.add(AreasCreated([AreaPreset(area: newSheet)]));
    final newSheetIndex = idx + 1;
    final finalAreas = <Area>[...updated]..insert(newSheetIndex, newSheet);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || tc.isClosed) return;
      tc.fitMumuStandardPage(
        page: st.page.copyWith(areas: finalAreas),
        info: st.info,
        viewportSize: viewportSize,
        sheetIndex: newSheetIndex,
      );
    });
    _showQuickInteractionToast(
      '已在第 ${idx + 1} 页之后插入新页（PDF 讲义同样适用）',
    );
  }

  /// 真正把当前页顺时针旋转 90°：页面尺寸、笔迹坐标、文本/图片/形状位置与自身角度全部同步旋转。
  void _rotateCurrentPage90(BuildContext context, DocumentLoadSuccess docState) {
    final bloc = context.read<DocumentBloc>();
    final areas = docState.page.areas;
    if (areas.isEmpty) {
      _showQuickInteractionToast('无限画布没有固定页面边界，无需旋转');
      return;
    }
    final pageHeight = areas.map((a) => a.height).reduce((a, b) => math.max(a, b));

    double mapX(double x, double y) => pageHeight - y;
    double mapY(double x) => x;
    double rotatedAngle(double angle) => angle + math.pi / 2;

    PadElement rotateElement(PadElement element) {
      if (element is PenElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          points: [
            for (final p in element.points) PathPoint(mapX(p.x, p.y), mapY(p.x), p.pressure),
          ],
        );
      }
      if (element is PolygonElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          points: [
            for (final p in element.points)
              PolygonPoint(
                mapX(p.x, p.y),
                mapY(p.x),
                handleIn: p.handleIn == null ? null : SimplePoint(-p.handleIn!.y, p.handleIn!.x),
                handleOut: p.handleOut == null
                    ? null
                    : SimplePoint(-p.handleOut!.y, p.handleOut!.x),
              ),
          ],
        );
      }
      if (element is TextElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          position: math.Point<double>(
            mapX(element.position.x, element.position.y),
            mapY(element.position.x),
          ),
        );
      }
      if (element is MarkdownElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          position: math.Point<double>(
            mapX(element.position.x, element.position.y),
            mapY(element.position.x),
          ),
        );
      }
      if (element is ImageElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          position: math.Point<double>(
            mapX(element.position.x, element.position.y),
            mapY(element.position.x),
          ),
        );
      }
      if (element is PdfElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          position: math.Point<double>(
            mapX(element.position.x, element.position.y),
            mapY(element.position.x),
          ),
        );
      }
      if (element is SvgElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          position: math.Point<double>(
            mapX(element.position.x, element.position.y),
            mapY(element.position.x),
          ),
        );
      }
      if (element is ShapeElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          firstPosition: math.Point<double>(
            mapX(element.firstPosition.x, element.firstPosition.y),
            mapY(element.firstPosition.x),
          ),
          secondPosition: math.Point<double>(
            mapX(element.secondPosition.x, element.secondPosition.y),
            mapY(element.secondPosition.x),
          ),
        );
      }
      if (element is TableElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          firstPosition: math.Point<double>(
            mapX(element.firstPosition.x, element.firstPosition.y),
            mapY(element.firstPosition.x),
          ),
          secondPosition: math.Point<double>(
            mapX(element.secondPosition.x, element.secondPosition.y),
            mapY(element.secondPosition.x),
          ),
          rowSizes: element.columnSizes,
          columnSizes: element.rowSizes,
        );
      }
      if (element is TextureElement) {
        return element.copyWith(
          rotation: rotatedAngle(element.rotation),
          firstPosition: math.Point<double>(
            mapX(element.firstPosition.x, element.firstPosition.y),
            mapY(element.firstPosition.x),
          ),
          secondPosition: math.Point<double>(
            mapX(element.secondPosition.x, element.secondPosition.y),
            mapY(element.secondPosition.x),
          ),
        );
      }
      return element;
    }

    for (final area in areas) {
      bloc.add(AreaChanged(area.name, area.copyWith(width: area.height, height: area.width)));
    }
    final backgrounds = <Background>[
      for (final bg in docState.page.backgrounds)
        if (bg is ImageBackground)
          bg.copyWith(width: bg.height, height: bg.width)
        else if (bg is SvgBackground)
          bg.copyWith(width: bg.height, height: bg.width)
        else
          bg,
    ];
    bloc.add(DocumentBackgroundsChanged(backgrounds));

    final changed = <String, List<PadElement>>{};
    for (final layer in docState.page.layers) {
      final id = layer.id;
      if (id == null) continue;
      changed[id] = [for (final e in layer.content) rotateElement(e)];
    }
    if (changed.isNotEmpty) {
      bloc.add(ElementsChanged(changed));
    }
    _showQuickInteractionToast('🔄 已将当前页连同笔迹旋转 90°');
  }

  bool _isToolSelectedByType<T extends Tool>(
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
  ) {
    final idx = toolState.index;
    if (idx == null || idx < 0 || idx >= docState.info.tools.length) {
      return false;
    }
    return docState.info.tools[idx] is T;
  }

  void _selectOrCreateToolByType<T extends Tool>(
    BuildContext context,
    DocumentLoadSuccess docState,
    T Function() factory,
  ) {
    final bloc = _getActiveBloc(context);
    final controller = _getActiveEditorController(context);
    final activeDocState = bloc.state is DocumentLoadSuccess
        ? bloc.state as DocumentLoadSuccess
        : docState;
    final tools = List<Tool>.from(activeDocState.info.tools);
    int existingIdx = tools.indexWhere((t) => t is T);
    late final Tool targetTool;
    if (existingIdx != -1) {
      targetTool = tools[existingIdx];
    } else {
      existingIdx = tools.length;
      final created = factory();
      targetTool = created.copyWith(id: created.id ?? createUniqueId());
      tools.add(targetTool);
      bloc.add(ToolsReplaced(tools));
    }
    controller.toolCubit.setIndex(existingIdx);
    unawaited(
      controller.toolCubit.changeTool(controller, bloc, index: existingIdx, context: context),
    );
    unawaited(controller.toolCubit.updateTool(controller, bloc, targetTool));
    _syncToolToSecondarySplitIfNeeded(existingIdx, targetTool);
  }

  void _applyColorToActiveTool(
    DocumentBloc bloc,
    List<Tool> tools,
    int? activeIdx,
    Tool? activeTool,
    Color color,
  ) {
    if (activeIdx == null || activeTool == null) return;
    final controller = _getActiveEditorController(context);
    final updated = List<Tool>.from(tools);
    Tool? modified;
    if (activeTool is PenTool) {
      final isHighlighter =
          activeTool.name.contains('荧光') || activeTool.name.toLowerCase().contains('highlight');
      modified = activeTool.copyWith(
        property: activeTool.property.copyWith(
          paint: ElementPaint.solid(
            color: SRGBColor(
              isHighlighter ? color.withValues(alpha: 0.42).toARGB32() : color.toARGB32(),
            ),
          ),
        ),
      );
    } else if (activeTool is ShapeTool) {
      modified = activeTool.copyWith(
        property: activeTool.property.copyWith(
          paint: ElementPaint.solid(color: SRGBColor(color.toARGB32())),
        ),
      );
    } else if (activeTool is LaserTool) {
      modified = activeTool.copyWith(color: SRGBColor(color.toARGB32()));
    }
    if (modified != null) {
      updated[activeIdx] = modified;
      bloc.add(ToolsReplaced(updated));
      controller.toolCubit.setIndex(activeIdx);
      unawaited(controller.toolCubit.updateTool(controller, bloc, modified));
    }
  }

  void _applyWidthToActiveTool(
    DocumentBloc bloc,
    List<Tool> tools,
    int? activeIdx,
    Tool? activeTool,
    double widthVal,
  ) {
    if (activeIdx == null || activeTool == null) return;
    final controller = _getActiveEditorController(context);
    final updated = List<Tool>.from(tools);
    Tool? modified;
    if (activeTool is PenTool) {
      modified = activeTool.copyWith(property: activeTool.property.copyWith(strokeWidth: widthVal));
    } else if (activeTool is EraserTool) {
      modified = activeTool.copyWith(strokeWidth: widthVal);
    } else if (activeTool is ShapeTool) {
      modified = activeTool.copyWith(property: activeTool.property.copyWith(strokeWidth: widthVal));
    } else if (activeTool is LaserTool) {
      modified = activeTool.copyWith(strokeWidth: widthVal);
    }
    if (modified != null) {
      updated[activeIdx] = modified;
      bloc.add(ToolsReplaced(updated));
      controller.toolCubit.setIndex(activeIdx);
      unawaited(controller.toolCubit.updateTool(controller, bloc, modified));
    }
  }

  // 3.3 插入菜单 (Insert Menu: 添加图片 / 拍照 / 添加贴纸 / 添加音频 / 添加批注 / 添加链接)
  Future<void> _showMumuInsertMenuDialog(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.add_circle_rounded, color: Color(0xFF2F7D6E)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '插入菜单',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.image_rounded, color: Color(0xFF10B981)),
                  title: const Text('添加图片 / 文档'),
                  subtitle: const Text('从相册或本地存储导入图片或 PDF 页面'),
                  onTap: () {
                    Navigator.pop(ctx);
                    showDialog(
                      context: context,
                      builder: (_) => _editorDialogScope(const AddDialog()),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.approval_rounded, color: Color(0xFFF59E0B)),
                  title: const Text('添加贴纸'),
                  subtitle: const Text('放置常用学科图章、重点标记或自定义贴纸'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _selectOrCreateToolByType<StampTool>(
                      context,
                      docState,
                      () => StampTool(name: '贴纸'),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.chat_bubble_rounded, color: Color(0xFF8B5CF6)),
                  title: const Text('添加批注卡片'),
                  subtitle: const Text('在当前页面创建批注节点并同步至右侧边栏'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _promptAddOutlineWaypoint(context, isAnnotation: true);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.link_rounded, color: Color(0xFF2F7D6E)),
                  title: const Text('添加跨页/分屏双向链接'),
                  subtitle: const Text('创建连接到同木木笔记本另一页或参考文档的双向链接'),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _showRightSidebar = true;
                      _rightSidebarTab = 2;
                    });
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 3.1 工具更多与星标自定义菜单 (Video mkcLMr0zj3g)
  Future<void> _showToolbarCustomizePopover(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Widget buildToolRow(String key, IconData icon, String title, String sub) {
            final starred = _starredTopTools.contains(key);
            return ListTile(
              dense: true,
              leading: Icon(icon, size: 20, color: const Color(0xFF2F7D6E)),
              title: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              subtitle: Text(sub, style: const TextStyle(fontSize: 11)),
              trailing: IconButton(
                icon: Icon(
                  starred ? Icons.star_rounded : Icons.star_border_rounded,
                  color: starred ? const Color(0xFF2F7D6E) : Colors.grey,
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    if (starred) {
                      _starredTopTools.remove(key);
                    } else {
                      _starredTopTools.add(key);
                    }
                  });
                  setDialogState(() {});
                },
              ),
            );
          }

          return Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 620),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '工具更多与工具栏自定义',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Text(
                      '点击右侧星标即可将工具固定在顶部工具栏或隐藏',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    const Divider(),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '核心工具',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                            buildToolRow(
                              'pen_case',
                              Icons.dashboard_customize_rounded,
                              '悬浮笔盒开关',
                              '展开或收起包含 10+ 拟真笔尖的悬浮笔盒',
                            ),
                            buildToolRow(
                              'pen',
                              Icons.edit_rounded,
                              '钢笔 / 圆珠笔',
                              '顶栏直接切换书写笔，再次点击调节粗细/颜色/笔锋',
                            ),
                            buildToolRow(
                              'highlighter',
                              Icons.border_color_rounded,
                              '荧光标记笔',
                              '顶栏直接切换荧光笔，再次点击调节颜色与粗细',
                            ),
                            buildToolRow(
                              'eraser',
                              Icons.auto_fix_normal_rounded,
                              '橡皮擦',
                              '点擦、笔触擦除与清除当前页面',
                            ),
                            buildToolRow(
                              'lasso',
                              Icons.gesture_rounded,
                              '套索工具',
                              '自由套索、矩形套索与跨页双向链接',
                            ),
                            buildToolRow(
                              'shape',
                              Icons.category_outlined,
                              '几何图形笔',
                              '标准矩形、圆形、直线与三角形绘制',
                            ),
                            buildToolRow(
                              'tape_mask',
                              Icons.healing_outlined,
                              '记忆背诵胶带',
                              '遮盖重点公式或考点，单击胶带显隐答案',
                            ),
                            buildToolRow(
                              'textbox',
                              Icons.text_fields_rounded,
                              '文本框',
                              '添加富文本批注框',
                            ),
                            buildToolRow(
                              'insert',
                              Icons.add_circle_outline_rounded,
                              '插入菜单',
                              '图片、拍照、贴纸、批注与超链接',
                            ),
                            buildToolRow(
                              'layers',
                              Icons.layers_outlined,
                              '图层系统',
                              '多图层独立显示、隐藏、重命名与管理',
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '实用工具',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: Colors.grey,
                              ),
                            ),
                            buildToolRow(
                              'ruler',
                              Icons.straighten_outlined,
                              '标尺',
                              '可旋转直边辅助画线标尺',
                            ),
                            buildToolRow(
                              'laser',
                              Icons.flare_rounded,
                              '演示激光笔',
                              '课堂或会议演示时展示激光轨迹',
                            ),
                            buildToolRow(
                              'pan',
                              Icons.pan_tool_alt_outlined,
                              '单指漫游翻页',
                              '单指上下滑动连续翻页，滑至页底自动加页',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // 3.17 输入模式切换菜单
  Future<void> _showInputModeSelectorMenu(BuildContext context) async {
    Widget buildModeOption({
      required MumuInputMode mode,
      required String title,
      required String subtitle,
      required VoidCallback onSelected,
    }) {
      final selected = _inputMode == mode;
      return ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? const Color(0xFF2F7D6E) : Colors.grey,
        ),
        title: Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        onTap: onSelected,
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380, maxHeight: 640),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '切换输入模式',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                buildModeOption(
                  mode: MumuInputMode.capacitivePen,
                  title: '被动/主动通用电容笔专属模式（推荐）',
                  subtitle: '针对无蓝牙协议电容笔自动收紧接触直径与椭圆偏心率阈值，双指滚动翻页，禁用单指双击误缩放',
                  onSelected: () {
                    setState(() => _inputMode = MumuInputMode.capacitivePen);
                    PalmGuardService.instance.setSingleFingerPanMode(false);
                    PalmGuardService.instance.setPenMaxThresholdMm(3.8);
                    Navigator.pop(ctx);
                  },
                ),
                buildModeOption(
                  mode: MumuInputMode.fingerWrite,
                  title: '手指直接书写模式',
                  subtitle: '放宽面积阈值允许手指在屏幕上直接书写批注，双指拖动翻页',
                  onSelected: () {
                    setState(() => _inputMode = MumuInputMode.fingerWrite);
                    PalmGuardService.instance.setSingleFingerPanMode(false);
                    PalmGuardService.instance.setPenMaxThresholdMm(5.4);
                    Navigator.pop(ctx);
                  },
                ),
                buildModeOption(
                  mode: MumuInputMode.stylusOnly,
                  title: '仅极细笔尖书写模式 (手指自动平移)',
                  subtitle: '仅小直径电容笔尖可出墨，单指触碰自动变为平移漫游',
                  onSelected: () {
                    setState(() => _inputMode = MumuInputMode.stylusOnly);
                    PalmGuardService.instance.setSingleFingerPanMode(true);
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 3.16 更多菜单 (More Menu: 视图模式、页面操作、文档设置、导出分享)
  Future<void> _showMumuMoreMenuSheet(BuildContext context, DocumentLoadSuccess docState) async {
    final bloc = context.read<DocumentBloc>();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '更多菜单',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const SizedBox(height: 8),

                // 1. 视图模式 (View Modes, Ch. 3.14)
                const Text(
                  '视图与工具栏模式',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      avatar: const Icon(Icons.chrome_reader_mode_outlined, size: 15),
                      label: const Text('阅读模式', style: TextStyle(fontSize: 12)),
                      selected: _readingMode,
                      onSelected: (v) {
                        setState(() => _readingMode = v);
                        final controller = context.read<EditorController>();
                        if (v) {
                          // 阅读模式：切到抓手工具，避免翻页时误画
                          _savedToolIndexBeforeReading = controller.toolCubit.state.index;
                          final handIdx = docState.info.tools.indexWhere((t) => t is HandTool);
                          if (handIdx != -1) {
                            unawaited(
                              controller.toolCubit.changeTool(
                                controller,
                                bloc,
                                index: handIdx,
                                context: context,
                              ),
                            );
                          }
                          _showQuickInteractionToast('📖 阅读模式：已切换抓手，仅翻页不落笔');
                        } else {
                          final saved = _savedToolIndexBeforeReading;
                          _savedToolIndexBeforeReading = null;
                          if (saved != null && saved >= 0 && saved < docState.info.tools.length) {
                            unawaited(
                              controller.toolCubit.changeTool(
                                controller,
                                bloc,
                                index: saved,
                                context: context,
                              ),
                            );
                          }
                          _showQuickInteractionToast('已退出阅读模式，恢复原书写工具');
                        }
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.open_in_full_rounded, size: 15),
                      label: const Text('专注模式', style: TextStyle(fontSize: 12)),
                      selected: _focusZenMode,
                      onSelected: (v) {
                        setState(() => _focusZenMode = v);
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.web_asset_rounded, size: 15),
                      label: const Text('标签页模式', style: TextStyle(fontSize: 12)),
                      selected: _tabBarMode,
                      onSelected: (v) {
                        setState(() => _tabBarMode = v);
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.vertical_align_top_rounded, size: 15),
                      label: const Text('固定顶部笔盒栏', style: TextStyle(fontSize: 12)),
                      selected: _penCaseDock == MumuPenCaseDock.fixedTopBar,
                      onSelected: (v) {
                        setState(() {
                          _penCaseDock = v
                              ? MumuPenCaseDock.fixedTopBar
                              : MumuPenCaseDock.bottom;
                        });
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.star_border_rounded, size: 15),
                      label: const Text('显示侧边收藏笔架', style: TextStyle(fontSize: 12)),
                      selected: _showPenFavoritesStrip,
                      onSelected: (v) {
                        setState(() => _showPenFavoritesStrip = v);
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.vertical_align_top_rounded, size: 15),
                      label: const Text('沉浸式工具栏', style: TextStyle(fontSize: 12)),
                      selected: _immersiveToolbarMode,
                      onSelected: (v) {
                        setState(() {
                          _immersiveToolbarMode = v;
                          _immersiveToolbarExpanded = false;
                        });
                        Navigator.pop(ctx);
                      },
                    ),
                    FilterChip(
                      avatar: const Icon(Icons.star_rounded, size: 15),
                      label: const Text('显示星标快捷条', style: TextStyle(fontSize: 12)),
                      selected: _showStarredQuickTools,
                      onSelected: (v) {
                        setState(() => _showStarredQuickTools = v);
                        Navigator.pop(ctx);
                      },
                    ),
                  ],
                ),
                const Divider(height: 24),

                // 2. 页面与滚动加页设置 (Page & Scroll Settings, Ch. 4.1 ~ 4.6)
                const Text(
                  '页面与下滑自动加页设置',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.note_add_outlined, color: Color(0xFF2F7D6E)),
                  title: const Text('立即在下方添加新页面'),
                  subtitle: const Text('或直接向页面底部下滑自动新增下一页'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addNewPage(context, docState);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.playlist_add_rounded, color: Color(0xFF10B981)),
                  title: const Text('在当前页后插入新页'),
                  subtitle: const Text('可插入到任意两页之间，PDF 讲义同样适用'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _insertPageAfterCurrent(context, docState);
                  },
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  secondary: const Icon(Icons.arrow_upward_rounded, color: Color(0xFF10B981)),
                  title: const Text('下滑至页底继续上拉自动加页'),
                  subtitle: const Text('纵向滑到底部继续下滑自动生成下一页'),
                  value: docState.page.isMumuPullToAddPageEnabled,
                  onChanged: (v) {
                    final updatedPage = docState.page.copyWith(
                      extra: {...docState.page.extra, 'mumu:pullToAddPage': v},
                    );
                    final updatedData =
                        docState.data.setPage(updatedPage, docState.pageName).$1;
                    bloc.add(DocumentRebuilt(updatedData.exportAsBytes()));
                    Navigator.pop(ctx);
                    _showQuickInteractionToast(
                      v ? '✅ 已开启「下滑至页底自动加页」' : '已关闭自动加页（仅手动点击 + 加页）',
                    );
                  },
                ),
                const Divider(height: 24),
                const Text(
                  '快捷操作（可单独开关）',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                ListenableBuilder(
                  listenable: PalmGuardService.instance,
                  builder: (context, _) {
                    final pg = PalmGuardService.instance;
                    final telemetry = pg.telemetry;
                    return Column(
                      children: [
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.undo_rounded, color: Color(0xFF2F7D6E)),
                          title: const Text('双指轻点撤销'),
                          subtitle: const Text('双指轻点一次，撤销上一步操作'),
                          value: telemetry.twoFingerTapUndoEnabled,
                          onChanged: pg.setTwoFingerTapUndoEnabled,
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.redo_rounded, color: Color(0xFF2F7D6E)),
                          title: const Text('三指轻点重做'),
                          subtitle: const Text('三指轻点一次，恢复刚撤销的内容'),
                          value: telemetry.threeFingerTapRedoEnabled,
                          onChanged: pg.setThreeFingerTapRedoEnabled,
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.fit_screen_rounded, color: Color(0xFF2F7D6E)),
                          title: const Text('单指双击适配页宽'),
                          subtitle: const Text('双击页面，自动缩放到适合屏幕宽度'),
                          value: telemetry.doubleTapFitWidthEnabled,
                          onChanged: pg.setDoubleTapFitWidthEnabled,
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.cleaning_services_outlined, color: Color(0xFFD8A45C)),
                          title: const Text('长按笔尖临时橡皮'),
                          subtitle: const Text('按住笔尖约 0.85 秒临时切橡皮，抬笔自动恢复'),
                          value: telemetry.holdToTempEraserEnabled,
                          onChanged: (v) => pg.setHoldToTempEraser(enabled: v),
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.auto_fix_high_rounded, color: Color(0xFFD8A45C)),
                          title: const Text('停笔 1 秒形状规整'),
                          subtitle: const Text('画完后停笔，自动修正为直线、圆、矩形等图形'),
                          value: telemetry.quickShapeHoldEnabled,
                          onChanged: (v) => pg.setQuickShapeHold(enabled: v),
                        ),
                        SwitchListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                          secondary: const Icon(Icons.touch_app_rounded, color: Color(0xFFD8A45C)),
                          title: const Text('压感临时橡皮'),
                          subtitle: const Text('用力按压笔尖直接擦除，松开恢复书写'),
                          value: telemetry.pressureEraserEnabled,
                          onChanged: (v) => pg.setPressureEraser(enabled: v),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
                          child: Text(
                            '关闭手势后，仍可使用工具栏的撤销 / 重做按钮。',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  leading: Icon(
                    docState.page.isMumuHorizontalScroll
                        ? Icons.open_with_rounded
                        : Icons.vertical_align_top_rounded,
                    color: const Color(0xFF2F7D6E),
                  ),
                  title: Text(
                    '切换页面滚动方向（当前：${docState.page.isMumuHorizontalScroll ? "水平横向滚动" : "垂直纵向连续滚动"}）',
                  ),
                  onTap: () {
                    final nextHoriz = !docState.page.isMumuHorizontalScroll;
                    final sheets = docState.page.resolvedPageSheets;
                    final relayoutSheets = <Area>[
                      for (int i = 0; i < sheets.length; i++)
                        sheets[i].copyWith(
                          position: nextHoriz
                              ? math.Point<double>(
                                  i * (sheets[i].width + 32.0),
                                  0.0,
                                )
                              : math.Point<double>(
                                  0.0,
                                  i * (sheets[i].height + 32.0),
                                ),
                        ),
                    ];
                    final updatedPage = docState.page.copyWith(
                      areas: relayoutSheets,
                      extra: {
                        ...docState.page.extra,
                        'mumu:scrollDirection': nextHoriz ? 'horizontal' : 'vertical',
                      },
                    );
                    final updatedData =
                        docState.data.setPage(updatedPage, docState.pageName).$1;
                    bloc.add(DocumentRebuilt(updatedData.exportAsBytes()));
                    Navigator.pop(ctx);
                    _showQuickInteractionToast(
                      nextHoriz ? '↔ 已切换为「水平横向页面滚动」' : '↕ 已切换为「垂直纵向连续页面滚动」',
                    );
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.vertical_split_rounded, color: Color(0xFF2F7D6E)),
                  title: const Text('开启应用内分屏'),
                  subtitle: const Text('左右或上下并排打开两篇笔记或同笔记双页对照'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMumuSplitViewModal(context, docState);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.add_circle_outline_rounded),
                  title: const Text('插入图片 / 贴纸 / 双向链接'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMumuInsertMenuDialog(context, docState);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.healing_outlined),
                  title: const Text('添加记忆背诵胶带'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addMemoryTapeStrip(context);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.select_all_rounded),
                  title: const Text('全选当前页笔迹'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Actions.maybeInvoke(context, SelectAllIntent());
                    _showQuickInteractionToast('已选中当前页全部笔迹');
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.dashboard_customize_outlined),
                  title: const Text('自定义顶栏快捷工具'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showToolbarCustomizePopover(context);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.touch_app_outlined),
                  title: const Text('切换手写笔 / 手指 / 朗读输入模式'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showInputModeSelectorMenu(context);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('更换页面模板与纸张底色'),
                  subtitle: const Text('切换横线/方格/点阵/康奈尔/空白模板或护眼纸张底色'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Actions.maybeInvoke(context, BackgroundIntent());
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.aspect_ratio_rounded, color: Color(0xFF2F7D6E)),
                  title: const Text('调整页面留白边距（蓝色手柄扩边）'),
                  subtitle: const Text('向外扩展页面上下左右留白区域，方便在 PDF 讲义四周补充手写批注'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showMarginAdjustDialog(context, docState);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.rotate_right_rounded),
                  title: const Text('旋转当前页面 90° (含笔迹与背景)'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _rotateCurrentPage90(context, docState);
                  },
                ),
                if (docState.data.getPages(true).length > 1)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent),
                    title: const Text(
                      '删除当前页面',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      bloc.add(PageRemoved(docState.pageName));
                    },
                  ),
                const Divider(height: 20),

                // 3. 文档设置与导出分享 (Document Settings & Export, Ch. 3.15~3.16)
                const Text(
                  '文档与导出分享',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.ios_share_rounded, color: Color(0xFF2F7D6E)),
                  title: const Text('导出 PDF（包含全部页面）'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Actions.maybeInvoke(context, PdfExportIntent());
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.pan_tool_outlined, color: MumuPalette.emeraldGuard),
                  title: const Text('防误触校准实验室与虚拟手垫设置'),
                  subtitle: const Text('调节通用电容笔触点直径阈值、160ms 回滚窗与底部悬浮手垫'),
                  onTap: () {
                    Navigator.pop(ctx);
                    showMumuCalibrationModal(context);
                  },
                ),
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.verified_user_outlined, color: Color(0xFF3B82F6)),
                  title: const Text('开启 / 关闭底部悬浮防误触手垫'),
                  onTap: () {
                    Navigator.pop(ctx);
                    final cur = PalmGuardService.instance.telemetry.shieldEnabled;
                    PalmGuardService.instance.setPalmShield(enabled: !cur);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 4.9 平铺视图与页面批量管理弹窗
  Future<void> _openTiledPageOverviewModal(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) async {
    final bloc = _getActiveBloc(context);
    final tc = _getActiveTransformCubit(context);
    final curSheetIdx = docState.page.activeSheetIndexForGlobalPoint(
      tc.state.localToGlobal(const Offset(400, 300)),
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final sheets = docState.page.resolvedPageSheets;
        return _editorDialogScope(
          Dialog(
            insetPadding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880, maxHeight: 680),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.grid_view_rounded, color: Color(0xFF2F7D6E)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '页面平铺概览 · 共 ${sheets.length} 页',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加新页面'),
                          onPressed: () {
                            _addNewPage(
                              context,
                              docState,
                              targetBloc: bloc,
                              targetTransform: tc,
                            );
                            Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const Divider(height: 20),
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 200,
                          mainAxisSpacing: 14,
                          crossAxisSpacing: 14,
                          childAspectRatio: 0.72,
                        ),
                        itemCount: sheets.length,
                        itemBuilder: (ctx, i) {
                          final sheet = sheets[i];
                          final isCur = i == curSheetIdx;
                          return InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              Navigator.pop(ctx);
                              _scrollToSheetIndex(
                                context,
                                docState,
                                i,
                                customTransformCubit: tc,
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: isCur
                                      ? const Color(0xFF2F7D6E)
                                      : Colors.grey.withValues(alpha: 0.3),
                                  width: isCur ? 2.2 : 1.0,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: LayoutBuilder(
                                      builder: (context, constraints) {
                                        final width = constraints.maxWidth
                                            .clamp(90.0, 210.0);
                                        final height = constraints.maxHeight
                                            .clamp(120.0, 280.0);
                                        return DocumentPagePreview(
                                          state: docState,
                                          pageName: docState.pageName,
                                          page: docState.page,
                                          area: sheet,
                                          previewWidth: width,
                                          previewHeight: height,
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          '第 ${i + 1} 页 · ${sheet.name}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: isCur ? const Color(0xFF2F7D6E) : null,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _promptAddOutlineWaypoint(BuildContext context, {bool isAnnotation = false}) async {
    final ctrl = TextEditingController();
    final bloc = context.read<DocumentBloc>();
    final transform = context.read<TransformCubit>().state;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isAnnotation ? '添加页面批注' : '添加大纲书签',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: isAnnotation ? '输入批注内容...' : '输入章节大纲标题...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final txt = ctrl.text.trim();
              if (txt.isNotEmpty) {
                bloc.add(
                  WaypointCreated(
                    Waypoint(
                      isAnnotation ? '💬 批注：$txt' : txt,
                      math.Point<double>(transform.position.dx, transform.position.dy),
                      transform.size,
                    ),
                  ),
                );
              }
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // 3.12 文本工具 / 翻译草稿弹窗（离线真实可用：文本工具插入 + 剪贴板）
  Future<void> _showMumuAiAndHandwritingDialog(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) async {
    final textCtrl = TextEditingController(
      text: docState.page.layers
          .expand((l) => l.content)
          .whereType<TextElement>()
          .map((e) => e.area.paragraph.text)
          .join('\n'),
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.text_snippet_outlined, color: Color(0xFF2F7D6E)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '文本工具与翻译草稿',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  '本构建为完全离线版本：不包含云端手写 OCR 与在线翻译接口。'
                  '你可以在下方整理/翻译好的文字，直接以内置「文本工具」放入页面，或复制到系统剪贴板粘贴到任意应用。',
                  style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.4),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: textCtrl,
                  maxLines: 5,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12),
                  decoration: InputDecoration(
                    labelText: '整理后的文本 / 译文',
                    hintText: '在此输入或粘贴要放到笔记里的文字...',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.copy_rounded, size: 15),
                      label: const Text('复制到剪贴板', style: TextStyle(fontSize: 11)),
                      onPressed: () async {
                        final text = textCtrl.text.trim();
                        if (text.isEmpty) return;
                        await Clipboard.setData(ClipboardData(text: text));
                        if (!ctx.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('已复制到系统剪贴板'),
                            duration: Duration(milliseconds: 1200),
                          ),
                        );
                      },
                    ),
                    FilledButton.icon(
                      icon: const Icon(Icons.add_box_outlined, size: 15),
                      label: const Text('选择文本工具并插入页面', style: TextStyle(fontSize: 11)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _selectOrCreateToolByType<LabelTool>(
                          context,
                          docState,
                          () => LabelTool(name: '文本'),
                        );
                        _showQuickInteractionToast('🔤 文本工具已选中：请在画布上点击位置放置文本');
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  // --------------------------------------------------------------------------
  // 15. 核心交互组件：
  //     C1 沉浸式工具栏胶囊、D1 套索三模式浮动栏(含解锁对象)、D6 记忆胶带、
  //     B9 页底上滑加页预览横幅、C6 双击颜色槽 Hex+Alpha 取色器、D13 边距蓝色手柄面板
  // --------------------------------------------------------------------------

  Widget _buildImmersiveCollapsedHeaderBar(
    BuildContext context,
    DocumentLoadSuccess docState,
    bool isDark,
  ) {
    final docName = docState.metadata.name.isEmpty ? '当前笔记' : docState.metadata.name;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
        border: Border(
          bottom: BorderSide(color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0)),
        ),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: () => _saveAndExitToHome(context),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_ios_new_rounded, size: 13),
                SizedBox(width: 4),
                Text('书架', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => setState(() => _immersiveToolbarExpanded = true),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2F7D6E).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 15,
                        color: Color(0xFF2F7D6E),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '✨ 沉浸全屏书写 ($docName) · 点击展开工具栏',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF2F7D6E),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          const MumuTelemetryPill(compact: true),
        ],
      ),
    );
  }

  Widget _buildLassoThreeModeFloatingBar(
    BuildContext context,
    DocumentLoadSuccess docState,
    ToolRuntimeState toolState,
    bool isDark,
  ) {
    final bloc = context.read<DocumentBloc>();

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isDark
              ? const Color(0xFF0F172A).withValues(alpha: 0.96)
              : Colors.white.withValues(alpha: 0.97),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF2F7D6E).withValues(alpha: 0.45), width: 1.3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.14),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // D1 套索三模式切换：自由圈选 / 矩形框选 / 截图与分屏双链
              for (final (idx, label, ic) in [
                (0, '自由套索', Icons.gesture_rounded),
                (1, '矩形套索', Icons.crop_free_rounded),
                (2, '双链/截图', Icons.add_link_rounded),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    avatar: Icon(ic, size: 13),
                    label: Text(label, style: const TextStyle(fontSize: 11)),
                    selected: _lassoMode == idx,
                    onSelected: (_) {
                      setState(() => _lassoMode = idx);
                      // 套索模式是真实工具属性：自由套索 / 矩形套索切换后立即生效
                      final controller = _getActiveEditorController(context);
                      final tools = List<Tool>.from(docState.info.tools);
                      final activeIdx = controller.toolCubit.state.index;
                      if (activeIdx != null &&
                          activeIdx >= 0 &&
                          activeIdx < tools.length &&
                          tools[activeIdx] is SelectTool) {
                        final mode =
                            idx == 1 ? SelectMode.rectangle : SelectMode.lasso;
                        final updated =
                            (tools[activeIdx] as SelectTool).copyWith(mode: mode);
                        tools[activeIdx] = updated;
                        bloc.add(ToolsReplaced(tools));
                        unawaited(
                          controller.toolCubit.updateTool(
                            controller,
                            bloc,
                            updated,
                          ),
                        );
                      }
                      if (idx == 2 && !_splitViewOpen) {
                        setState(() {
                          _splitViewOpen = true;
                          final pages = docState.data.getPages(true);
                          _splitSecondaryPageName = pages.length > 1
                              ? pages.last
                              : pages.firstOrNull;
                        });
                        _showQuickInteractionToast('🔗 已自动开启分屏视图以创建跨页双向链接 (官方规范 D3)');
                      }
                    },
                  ),
                ),
              const SizedBox(width: 4),
              // D2 套索选区快捷动作：文本工具 / 建双向链接 / 全选笔迹 / 删除最后笔迹
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.text_snippet_outlined, size: 14),
                label: const Text('文本/翻译', style: TextStyle(fontSize: 11)),
                onPressed: () => _showMumuAiAndHandwritingDialog(context, docState),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.link_rounded, size: 14),
                label: const Text('建双链', style: TextStyle(fontSize: 11)),
                onPressed: () {
                  final targetPage = _splitSecondaryPageName ?? docState.pageName;
                  if (targetPage == docState.pageName) {
                    _showQuickInteractionToast('⚠️ 请先在分屏/右侧边栏中选择一个「其他页面」作为双链目标');
                    return;
                  }
                  bloc.add(
                    WaypointCreated(
                      Waypoint(
                        '🔗 [[双向链接 -> $targetPage]]',
                        const math.Point<double>(140.0, 140.0),
                        1.0,
                      ),
                    ),
                  );
                  _showQuickInteractionToast('🔗 已创建双向链接：可在右侧边栏「批注/双链」中一键跳转《$targetPage》');
                },
              ),
              // 真实可用的选区动作：全选当前页笔迹（替代此前无对应底层能力的“解锁对象”）
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.select_all_rounded, size: 14, color: Color(0xFF2F7D6E)),
                label: const Text(
                  '全选笔迹',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF2F7D6E),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () {
                  Actions.maybeInvoke(context, SelectAllIntent());
                  _showQuickInteractionToast('已选中当前页全部笔迹，可直接拖动或删除');
                },
              ),
              TextButton.icon(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 14,
                  color: Color(0xFFEF4444),
                ),
                label: const Text(
                  '删除选中',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFFEF4444),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                onPressed: () => _deleteSelectedElements(context),
              ),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text(
                  'A-',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                onPressed: () => _scaleSelectedText(context, docState, 0.85),
              ),
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text(
                  'A+',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                onPressed: () => _scaleSelectedText(context, docState, 1.18),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                icon: const Icon(Icons.close, size: 15),
                onPressed: () {
                  setState(() => _showLassoBar = false);
                  context.read<ToolCubit>().resetSelection(force: true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<String> _selectedElementIds(ToolRuntimeState toolState) {
    final ids = <String>[];
    final activeHandler = toolState.handler is SelectHandler
        ? toolState.handler
        : toolState.temporaryHandler;
    if (activeHandler is SelectHandler) {
      for (final renderer in activeHandler.selectedRenderers) {
        final id = renderer.element.id;
        if (id != null) ids.add(id);
      }
    }
    if (ids.isEmpty) {
      final selection = toolState.selection;
      if (selection != null) {
        for (final item in selection.selected) {
          if (item is Renderer) {
            final element = item.element;
            if (element is PadElement && element.id != null) {
              ids.add(element.id!);
            }
          }
        }
      }
    }
    return ids;
  }

  void _deleteSelectedElements(BuildContext context) {
    final toolState = context.read<ToolCubit>().state;
    final ids = _selectedElementIds(toolState);
    if (ids.isEmpty) {
      _showQuickInteractionToast('请先用套索圈选要删除的笔迹或文本框');
      return;
    }
    final bloc = _getActiveBloc(context);
    bloc.add(ElementsRemoved(ids));
    for (final handler in [toolState.handler, toolState.temporaryHandler]) {
      if (handler is SelectHandler) handler.clearSelection(bloc);
    }
    context.read<ToolCubit>().resetSelection(force: true);
    _showQuickInteractionToast('已删除 ${ids.length} 个选中对象');
  }

  void _scaleSelectedText(
    BuildContext context,
    DocumentLoadSuccess docState,
    double factor,
  ) {
    final toolState = context.read<ToolCubit>().state;
    final ids = _selectedElementIds(toolState).toSet();
    if (ids.isEmpty) {
      _showQuickInteractionToast('请先用套索圈选要缩放的文本框');
      return;
    }
    final changed = <String, List<PadElement>>{};
    var count = 0;
    for (final layer in docState.page.layers) {
      final layerId = layer.id;
      if (layerId == null) continue;
      final content = <PadElement>[];
      var modified = false;
      for (final element in layer.content) {
        if (element is TextElement &&
            element.id != null &&
            ids.contains(element.id)) {
          modified = true;
          count++;
          content.add(
            element.copyWith(
              scale: (element.scale * factor).clamp(0.35, 8.0),
            ),
          );
        } else {
          content.add(element);
        }
      }
      if (modified) changed[layerId] = content;
    }
    if (changed.isEmpty) {
      _showQuickInteractionToast('选区内没有文本对象，请先圈选文本框');
      return;
    }
    _getActiveBloc(context).add(ElementsChanged(changed));
    _showQuickInteractionToast(
      '已${factor > 1 ? '放大' : '缩小'} $count 个文本框',
    );
  }

  void _addMemoryTapeStrip(BuildContext context) {
    final idx = _memoryTapes.length + 1;
    setState(() {
      _hideAllMemoryTapes = false;
      _memoryTapes.add((
        id: 'tape_${DateTime.now().millisecondsSinceEpoch}',
        pos: Offset(160.0 + (idx % 3) * 40.0, 140.0 + idx * 46.0),
        size: const Size(260, 36),
        answer: '核心公式/考点 #$idx（点击胶带显隐背诵）',
        revealed: false,
        color: const Color(0xFF10B981),
      ));
    });
    _showQuickInteractionToast('🩹 已添加记忆背诵胶带：单击胶带即可「显示答案 ↔ 遮盖背诵」');
  }

  List<Widget> _buildMemoryTapeOverlays(BuildContext context, bool isDark) {
    return [
      for (int i = 0; i < _memoryTapes.length; i++)
        Positioned(
          left: _memoryTapes[i].pos.dx,
          top: _memoryTapes[i].pos.dy,
          child: SizedBox(
            width: _memoryTapes[i].size.width,
            height: _memoryTapes[i].size.height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(() {
                        final cur = _memoryTapes[i];
                        _memoryTapes[i] = (
                          id: cur.id,
                          pos: cur.pos,
                          size: cur.size,
                          answer: cur.answer,
                          revealed: !cur.revealed,
                          color: cur.color,
                        );
                      });
                    },
                    onPanUpdate: (d) {
                      setState(() {
                        final cur = _memoryTapes[i];
                        _memoryTapes[i] = (
                          id: cur.id,
                          pos: Offset(
                            math.max(0, cur.pos.dx + d.delta.dx),
                            math.max(0, cur.pos.dy + d.delta.dy),
                          ),
                          size: cur.size,
                          answer: cur.answer,
                          revealed: cur.revealed,
                          color: cur.color,
                        );
                      });
                    },
                    onLongPress: () {
                      setState(() => _memoryTapes.removeAt(i));
                      _showQuickInteractionToast('已移除该条记忆胶带');
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        // 遮盖状态必须完全不透明，真正盖住下方内容
                        color: _memoryTapes[i].revealed
                            ? _memoryTapes[i].color.withValues(alpha: 0.20)
                            : _memoryTapes[i].color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _memoryTapes[i].color, width: 1.5),
                        boxShadow: [
                          if (!_memoryTapes[i].revealed)
                            BoxShadow(
                              color: _memoryTapes[i].color.withValues(alpha: 0.25),
                              blurRadius: 6,
                            ),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _memoryTapes[i].revealed
                                ? Icons.visibility_rounded
                                : Icons.visibility_off_outlined,
                            size: 14,
                            color: _memoryTapes[i].revealed
                                ? (isDark ? Colors.white : const Color(0xFF065F46))
                                : Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _memoryTapes[i].revealed
                                  ? _memoryTapes[i].answer
                                  : '🩹 记忆遮盖胶带 · 轻点显示答案',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: _memoryTapes[i].revealed
                                    ? (isDark ? Colors.white : const Color(0xFF065F46))
                                    : Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 删除按钮
                Positioned(
                  right: -9,
                  top: -9,
                  child: GestureDetector(
                    onTap: () {
                      setState(() => _memoryTapes.removeAt(i));
                      _showQuickInteractionToast('已删除该条记忆胶带');
                    },
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF334155) : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFEF4444), width: 1.4),
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: Color(0xFFEF4444),
                      ),
                    ),
                  ),
                ),
                // 右下角拖拽缩放
                Positioned(
                  right: -6,
                  bottom: -6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: (d) {
                      setState(() {
                        final cur = _memoryTapes[i];
                        _memoryTapes[i] = (
                          id: cur.id,
                          pos: cur.pos,
                          size: Size(
                            (cur.size.width + d.delta.dx).clamp(140.0, 640.0),
                            (cur.size.height + d.delta.dy).clamp(36.0, 260.0),
                          ),
                          answer: cur.answer,
                          revealed: cur.revealed,
                          color: cur.color,
                        );
                      });
                    },
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: _memoryTapes[i].color,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.4),
                      ),
                      child: const Icon(
                        Icons.open_in_full_rounded,
                        size: 13,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];
  }

  Widget _buildBottomPullUpPageAddBanner(BuildContext context, bool isDark) {
    return ListenableBuilder(
      listenable: PalmGuardService.instance,
      builder: (context, _) {
        final prog = PalmGuardService.instance.telemetry.pullUpProgress;
        if (prog <= 0.05) return const SizedBox.shrink();
        final ready = prog >= 0.88;
        return Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              color: ready
                  ? const Color(0xFF10B981)
                  : const Color(0xFF0F172A).withValues(alpha: 0.90),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 12)],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  ready ? Icons.check_circle_rounded : Icons.arrow_upward_rounded,
                  size: 15,
                  color: Colors.white,
                ),
                const SizedBox(width: 6),
                Text(
                  ready ? '松手立即新增空白页（继承当前模板）' : '↑ 继续上滑添加新页面（${(prog * 100).round()}%）',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showCustomColorHexDialog(BuildContext context, Color initialColor) async {
    final bloc = context.read<DocumentBloc>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;
    final toolState = context.read<ToolCubit>().state;
    final hexCtrl = TextEditingController(
      text: initialColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase(),
    );
    double alphaVal = initialColor.a;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text(
            '自定义颜色与透明度（双击颜色槽）',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: hexCtrl,
                decoration: const InputDecoration(labelText: '十六进制色值（6 位）', prefixText: '#'),
              ),
              const SizedBox(height: 12),
              Text(
                '不透明度：${(alphaVal * 100).round()}%',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              Slider(
                value: alphaVal.clamp(0.1, 1.0),
                min: 0.1,
                max: 1.0,
                onChanged: (v) => setModal(() => alphaVal = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final cleanHex = hexCtrl.text.trim().replaceAll('#', '');
                final rgb = int.tryParse(cleanHex, radix: 16);
                if (rgb != null) {
                  final customColor = Color(0xFF000000 | rgb).withValues(alpha: alphaVal);
                  final tools = docState.info.tools;
                  final activeIdx = toolState.index;
                  final activeTool =
                      (activeIdx != null && activeIdx >= 0 && activeIdx < tools.length)
                      ? tools[activeIdx]
                      : null;
                  _applyColorToActiveTool(bloc, tools, activeIdx, activeTool, customColor);
                }
                Navigator.pop(ctx);
              },
              child: const Text('应用颜色'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showMarginAdjustDialog(BuildContext context, DocumentLoadSuccess docState) async {
    final bloc = context.read<DocumentBloc>();
    double addTop = 0;
    double addBottom = 120;
    double addLeft = 0;
    double addRight = 120;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text(
            '调整页面留白边距（蓝色手柄扩边）',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '向外扩展当前页面四周边距，方便在 PDF 讲义或标准笔记旁留出大片空白写批注：',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 72, child: Text('右侧扩边:', style: TextStyle(fontSize: 12))),
                    Expanded(
                      child: Slider(
                        value: addRight,
                        min: 0,
                        max: 480,
                        activeColor: const Color(0xFF2F7D6E),
                        onChanged: (v) => setModal(() => addRight = v),
                      ),
                    ),
                    Text('+${addRight.round()}px', style: const TextStyle(fontSize: 11)),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 72, child: Text('底部扩边:', style: TextStyle(fontSize: 12))),
                    Expanded(
                      child: Slider(
                        value: addBottom,
                        min: 0,
                        max: 480,
                        activeColor: const Color(0xFF2F7D6E),
                        onChanged: (v) => setModal(() => addBottom = v),
                      ),
                    ),
                    Text('+${addBottom.round()}px', style: const TextStyle(fontSize: 11)),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 72, child: Text('左侧扩边:', style: TextStyle(fontSize: 12))),
                    Expanded(
                      child: Slider(
                        value: addLeft,
                        min: 0,
                        max: 320,
                        activeColor: const Color(0xFF2F7D6E),
                        onChanged: (v) => setModal(() => addLeft = v),
                      ),
                    ),
                    Text('+${addLeft.round()}px', style: const TextStyle(fontSize: 11)),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 72, child: Text('顶部扩边:', style: TextStyle(fontSize: 12))),
                    Expanded(
                      child: Slider(
                        value: addTop,
                        min: 0,
                        max: 320,
                        activeColor: const Color(0xFF2F7D6E),
                        onChanged: (v) => setModal(() => addTop = v),
                      ),
                    ),
                    Text('+${addTop.round()}px', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                for (final area in docState.page.areas) {
                  bloc.add(
                    AreaChanged(
                      area.name,
                      area.copyWith(
                        width: area.width + addLeft + addRight,
                        height: area.height + addTop + addBottom,
                      ),
                    ),
                  );
                }
                Navigator.pop(ctx);
                _showQuickInteractionToast(
                  '📐 已扩展当前页面留白边距（+${(addLeft + addRight).round()}×${(addTop + addBottom).round()}px）',
                );
              },
              child: const Text('应用边距扩展'),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// 4. Mumu 顶部圆形图标按钮与拟真矢量笔尖绘制器 (_MumuRealisticPenTipPainter)
// ============================================================================

/// 1:1 还原 Mumu 笔盒内升起式拟真矢量笔尖 (钢笔/圆珠笔/铅笔/彩虹笔/荧光笔/橡皮/胶带/图形/激光/套索)
class _MumuRealisticPenTipPainter extends CustomPainter {
  final String kind;
  final Color color;
  final bool selected;
  final bool isDark;

  const _MumuRealisticPenTipPainter({
    required this.kind,
    required this.color,
    required this.selected,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;

    final bodyColor = isDark ? const Color(0xFF334155) : const Color(0xFFF8FAFC);
    final strokeBorder = Paint()
      ..color = selected
          ? const Color(0xFF2F7D6E)
          : (isDark ? Colors.white38 : const Color(0xFFCBD5E1))
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 1.5 : 1.0;

    // 1. 绘制下部笔杆主体
    final barrelRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(w * 0.18, h * 0.44, w * 0.64, h * 0.54),
      topLeft: const Radius.circular(4),
      topRight: const Radius.circular(4),
      bottomLeft: const Radius.circular(6),
      bottomRight: const Radius.circular(6),
    );
    canvas.drawRRect(barrelRect, Paint()..color = bodyColor);
    canvas.drawRRect(barrelRect, strokeBorder);

    // 2. 绘制笔杆上的彩色墨水色环或彩虹色带
    final bandRect = Rect.fromLTWH(w * 0.20, h * 0.56, w * 0.60, h * 0.16);
    if (kind == 'rainbow') {
      final rainbowPaint = Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0xFFEF4444),
            Color(0xFFF59E0B),
            Color(0xFF10B981),
            Color(0xFF3B82F6),
            Color(0xFF8B5CF6),
          ],
        ).createShader(bandRect);
      canvas.drawRect(bandRect, rainbowPaint);
    } else if (kind == 'tape') {
      canvas.drawRect(bandRect, Paint()..color = color.withValues(alpha: 0.75));
      // 胶带斜纹
      final stripePaint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(bandRect.left + 3, bandRect.bottom),
        Offset(bandRect.left + 8, bandRect.top),
        stripePaint,
      );
      canvas.drawLine(
        Offset(bandRect.left + 10, bandRect.bottom),
        Offset(bandRect.left + 15, bandRect.top),
        stripePaint,
      );
    } else {
      canvas.drawRect(bandRect, Paint()..color = color);
    }

    // 3. 根据不同笔型绘制顶部笔尖几何形状
    final nibPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    switch (kind) {
      case 'fountain':
        // 钢笔金属五边形开缝笔尖
        final nibPath = Path()
          ..moveTo(cx, h * 0.06)
          ..lineTo(w * 0.74, h * 0.28)
          ..lineTo(w * 0.68, h * 0.44)
          ..lineTo(w * 0.32, h * 0.44)
          ..lineTo(w * 0.26, h * 0.28)
          ..close();
        canvas.drawPath(nibPath, Paint()..color = const Color(0xFF94A3B8));
        canvas.drawPath(nibPath, strokeBorder);
        // 笔尖彩色墨芯与呼吸孔
        canvas.drawLine(
          Offset(cx, h * 0.07),
          Offset(cx, h * 0.28),
          Paint()
            ..color = color
            ..strokeWidth = 1.5,
        );
        canvas.drawCircle(Offset(cx, h * 0.29), 2.0, nibPaint);

      case 'ballpoint':
        // 圆珠笔流线锥形笔头 + 滚珠圆点
        final conePath = Path()
          ..moveTo(cx - 2, h * 0.12)
          ..lineTo(cx + 2, h * 0.12)
          ..lineTo(w * 0.72, h * 0.44)
          ..lineTo(w * 0.28, h * 0.44)
          ..close();
        canvas.drawPath(conePath, Paint()..color = const Color(0xFFCBD5E1));
        canvas.drawPath(conePath, strokeBorder);
        canvas.drawCircle(Offset(cx, h * 0.10), 2.6, nibPaint);

      case 'pencil':
      case 'rainbow':
        // 铅笔木质削尖锥体 + 铅芯尖端
        final woodPath = Path()
          ..moveTo(cx, h * 0.06)
          ..lineTo(w * 0.76, h * 0.44)
          ..lineTo(w * 0.24, h * 0.44)
          ..close();
        canvas.drawPath(woodPath, Paint()..color = const Color(0xFFFDE68A));
        canvas.drawPath(woodPath, strokeBorder);
        final leadPath = Path()
          ..moveTo(cx, h * 0.06)
          ..lineTo(cx + 4.5, h * 0.22)
          ..lineTo(cx - 4.5, h * 0.22)
          ..close();
        canvas.drawPath(leadPath, nibPaint);

      case 'highlighter':
      case 'tape':
        // 荧光笔斜切扁头凿形笔尖
        final chiselPath = Path()
          ..moveTo(w * 0.28, h * 0.16)
          ..lineTo(w * 0.74, h * 0.08)
          ..lineTo(w * 0.74, h * 0.44)
          ..lineTo(w * 0.28, h * 0.44)
          ..close();
        canvas.drawPath(chiselPath, Paint()..color = color.withValues(alpha: 0.82));
        canvas.drawPath(chiselPath, strokeBorder);

      case 'eraser':
        // 橡皮擦白蓝双色块状擦头
        final eraserTop = RRect.fromRectAndCorners(
          Rect.fromLTWH(w * 0.22, h * 0.12, w * 0.56, h * 0.34),
          topLeft: const Radius.circular(6),
          topRight: const Radius.circular(6),
        );
        canvas.drawRRect(eraserTop, Paint()..color = Colors.white);
        canvas.drawRRect(eraserTop, strokeBorder);

      case 'lasso':
        // 套索虚线环笔头
        final loopPaint = Paint()
          ..color = const Color(0xFF2F7D6E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8;
        canvas.drawOval(
          Rect.fromCenter(center: Offset(cx, h * 0.25), width: w * 0.54, height: h * 0.26),
          loopPaint,
        );

      case 'shape':
        // 图形笔几何多边形笔头
        final shapePaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8;
        canvas.drawRect(
          Rect.fromCenter(center: Offset(cx, h * 0.25), width: w * 0.44, height: w * 0.44),
          shapePaint,
        );

      default:
        // 激光笔等发光圆头
        canvas.drawCircle(Offset(cx, h * 0.24), 5.0, Paint()..color = const Color(0xFFEF4444));
    }
  }

  @override
  bool shouldRepaint(covariant _MumuRealisticPenTipPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.color != color ||
        oldDelegate.selected != selected ||
        oldDelegate.isDark != isDark;
  }
}

// ============================================================================
// 5. 底部虚拟防误触手垫
//    & 手掌误触红色波纹图层
//    & 双框实测校准实验室弹窗
// ============================================================================

/// 可拖拽高度、支持切换「全宽 / 右下角」模式的底部虚拟防误触手垫。
class MumuVirtualPalmShieldOverlay extends StatelessWidget {
  const MumuVirtualPalmShieldOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PalmGuardService.instance,
      builder: (context, _) {
        final tele = PalmGuardService.instance.telemetry;
        if (!tele.shieldEnabled) return const SizedBox.shrink();

        final screenW = MediaQuery.sizeOf(context).width;
        final isCorner = tele.shieldMode == 'CORNER_RIGHT';

        return Align(
          alignment: Alignment.bottomRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) {},
            onPanStart: (_) {},
            onPanUpdate: (_) {},
            child: Container(
              width: isCorner ? screenW * 0.56 : screenW,
              height: tele.shieldHeightDp,
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.72),
                borderRadius: isCorner
                    ? const BorderRadius.only(topLeft: Radius.circular(20))
                    : BorderRadius.zero,
                border: Border(
                  top: const BorderSide(color: Color(0xFF3B82F6), width: 2.0),
                  left: isCorner
                      ? const BorderSide(color: Color(0xFF3B82F6), width: 2.0)
                      : BorderSide.none,
                ),
              ),
              child: Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (details) {
                      final nextH = tele.shieldHeightDp - details.delta.dy;
                      PalmGuardService.instance.setPalmShield(heightDp: nextH);
                    },
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                        borderRadius: isCorner
                            ? const BorderRadius.only(topLeft: Radius.circular(18))
                            : BorderRadius.zero,
                        border: const Border(bottom: BorderSide(color: Color(0xFF334155))),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.pan_tool_outlined, size: 15, color: Color(0xFF93C5FD)),
                          const SizedBox(width: 6),
                          const Expanded(
                            child: Text(
                              '虚拟防误触手垫已激活（手掌可随意搭在此区域 · 上下拖动调节高度）',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF93C5FD),
                              ),
                            ),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () {
                              PalmGuardService.instance.setPalmShield(
                                mode: isCorner ? 'FULL_WIDTH' : 'CORNER_RIGHT',
                              );
                            },
                            child: Text(
                              isCorner ? '切换全宽' : '切换右下角',
                              style: const TextStyle(fontSize: 11, color: Colors.white70),
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                            icon: const Icon(Icons.close, size: 15, color: Colors.white70),
                            onPressed: () {
                              PalmGuardService.instance.setPalmShield(enabled: false);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: CustomPaint(
                      painter: _PalmShieldDotPatternPainter(),
                      child: const Center(
                        child: Text(
                          '手掌静置防误触保护区',
                          style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w600,
                            color: Color(0x8894A3B8),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PalmShieldDotPatternPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x383B82F6)
      ..style = PaintingStyle.fill;
    const step = 18.0;
    for (double x = 12; x < size.width; x += step) {
      for (double y = 12; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.4, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 手掌误触拦截红色波纹视觉反馈图层
class MumuPalmRejectRippleLayer extends StatelessWidget {
  const MumuPalmRejectRippleLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PalmGuardService.instance,
      builder: (context, _) {
        final ripples = PalmGuardService.instance.ripples;
        if (ripples.isEmpty) return const SizedBox.shrink();
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (final r in ripples)
                Positioned(
                  left: r.localPosition.dx - 24,
                  top: r.localPosition.dy - 24,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: MumuPalette.roseReject.withValues(alpha: 0.16),
                      border: Border.all(
                        color: MumuPalette.roseReject.withValues(alpha: 0.85),
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 唤出 Mumu × 木木笔记「四重防误触引擎与双框实测校准实验室」弹窗
Future<void> showMumuCalibrationModal(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: const _MumuCalibrationLaboratory(),
      ),
    ),
  );
}

class _MumuCalibrationLaboratory extends StatefulWidget {
  const _MumuCalibrationLaboratory();

  @override
  State<_MumuCalibrationLaboratory> createState() => _MumuCalibrationLaboratoryState();
}

class _MumuCalibrationLaboratoryState extends State<_MumuCalibrationLaboratory> {
  final List<double> _penSamplesMm = [];
  final List<double> _palmSamplesMm = [];
  String _selectedTablet = 'pad6pro';
  String _selectedTip = 'pom_fine';
  String _lastMeasuredPenText = '实测笔尖直径: 2.2 mm';
  String _lastMeasuredPalmText = '实测手掌直径: 16.4 mm';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: PalmGuardService.instance,
      builder: (context, _) {
        final svc = PalmGuardService.instance;
        final tele = svc.telemetry;

        return Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: MumuPalette.emeraldGuard,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '通用电容笔四重防误触引擎与双框校准实验室',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '100% 面向非协议普通电容笔 · 多维触点几何与运动学实时过滤',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const Divider(height: 20),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? MumuPalette.darkSlateCard : const Color(0xFFEBEAE2),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        '主流平板与笔头预设：',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      DropdownButton<String>(
                        value: _selectedTablet,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(
                            value: 'pad6pro',
                            child: Text('小米平板 6 Pro (11" 309 PPI)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'pad6spro',
                            child: Text(
                              '小米平板 6S Pro (12.4" 294 PPI)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'matepad',
                            child: Text(
                              '华为 MatePad Pro / Air (280 PPI)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'vivopad',
                            child: Text(
                              'vivo Pad3 Pro (13" 309 PPI)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          DropdownMenuItem(
                            value: 'legion',
                            child: Text(
                              '联想拯救者 Y700 (8.8" 343 PPI)',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _selectedTablet = v);
                          svc.applyHardwarePreset(tabletPreset: v, tipPreset: _selectedTip);
                        },
                      ),
                      DropdownButton<String>(
                        value: _selectedTip,
                        isDense: true,
                        items: const [
                          DropdownMenuItem(
                            value: 'pom_fine',
                            child: Text('主动式 POM 极细笔头 (1.5~2.6mm)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'disc_metal',
                            child: Text('被动透明圆盘笔头 (2.8~3.8mm)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'fiber_soft',
                            child: Text('导电纤维/硅胶软头 (3.6~4.8mm)', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _selectedTip = v);
                          svc.applyHardwarePreset(tabletPreset: _selectedTablet, tipPreset: v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: Listener(
                        onPointerDown: (ev) {
                          final geom = svc.extractContactGeometry(ev);
                          final mm = geom.diameterMm.clamp(1.2, 5.2);
                          setState(() {
                            _penSamplesMm.add(mm);
                            _lastMeasuredPenText =
                                '实测笔尖直径: ${mm.toStringAsFixed(2)} mm (${_penSamplesMm.length}次)';
                          });
                          svc.calibrateFromSamples(
                            penSamplesMm: _penSamplesMm,
                            palmSamplesMm: _palmSamplesMm,
                          );
                        },
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 104),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: MumuPalette.primaryAccent.withValues(alpha: 0.10),
                            borderRadius: const BorderRadius.all(Radius.circular(14)),
                            border: Border.all(
                              color: MumuPalette.primaryAccent.withValues(alpha: 0.55),
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                '第 1 步：采集电容笔尖特征',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: MumuPalette.primaryAccent,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text('请用通用电容笔尖在此框内轻点 3~5 次', style: TextStyle(fontSize: 11)),
                              const SizedBox(height: 6),
                              Text(
                                _lastMeasuredPenText,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Listener(
                        onPointerDown: (ev) {
                          final geom = svc.extractContactGeometry(ev);
                          final mm = geom.diameterMm.clamp(11.0, 36.0);
                          setState(() {
                            _palmSamplesMm.add(mm);
                            _lastMeasuredPalmText =
                                '实测手掌直径: ${mm.toStringAsFixed(1)} mm (${_palmSamplesMm.length}次)';
                          });
                          svc.calibrateFromSamples(
                            penSamplesMm: _penSamplesMm,
                            palmSamplesMm: _palmSamplesMm,
                          );
                        },
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 104),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: MumuPalette.roseReject.withValues(alpha: 0.10),
                            borderRadius: const BorderRadius.all(Radius.circular(14)),
                            border: Border.all(
                              color: MumuPalette.roseReject.withValues(alpha: 0.55),
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text(
                                '第 2 步：采集手掌侧边特征',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: MumuPalette.roseReject,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text('请将手掌或小指侧边自然贴在此框内测试', style: TextStyle(fontSize: 11)),
                              const SizedBox(height: 6),
                              Text(
                                _lastMeasuredPalmText,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isDark
                        ? MumuPalette.darkSlateBg.withValues(alpha: 0.65)
                        : const Color(0xFFEBEAE2).withValues(alpha: 0.65),
                    borderRadius: const BorderRadius.all(Radius.circular(14)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '1. 笔尖物理直径上限阈值',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  '大于该直径或椭圆偏心率 > 1.75 的狭长侧掌触点将 0ms 拦截',
                                  style: TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 150,
                            child: Slider(
                              value: tele.penMaxThresholdMm.clamp(2.0, 8.5),
                              min: 2.0,
                              max: 8.5,
                              onChanged: svc.setPenMaxThresholdMm,
                            ),
                          ),
                          SizedBox(
                            width: 58,
                            child: Text(
                              '${tele.penMaxThresholdMm.toStringAsFixed(1)} mm',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 16),

                      Row(
                        children: [
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '2. 小指先落屏幽灵短笔迹自动回滚窗',
                                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                ),
                                Text(
                                  '若小指侧边比左上方真笔尖早落屏少于该毫秒数，自动抹除小指误触点',
                                  style: TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 150,
                            child: Slider(
                              value: tele.rollbackWindowMs.toDouble().clamp(40, 350),
                              min: 40,
                              max: 350,
                              divisions: 31,
                              onChanged: (v) => svc.setRollbackWindowMs(v.round()),
                            ),
                          ),
                          SizedBox(
                            width: 58,
                            child: Text(
                              '${tele.rollbackWindowMs} ms',
                              textAlign: TextAlign.right,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 16),

                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            '3. 灵敏度档位：',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          for (int lv = 1; lv <= 5; lv++)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text('$lv档', style: const TextStyle(fontSize: 11)),
                                selected: tele.sensitivityLevel == lv,
                                onSelected: (_) => svc.setSensitivity(lv),
                              ),
                            ),
                          const Spacer(),
                          DropdownButton<String>(
                            value: tele.handednessMode,
                            isDense: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'RIGHT_DIAGONAL',
                                child: Text('右手正常握笔 (手掌在右下)', style: TextStyle(fontSize: 12)),
                              ),
                              DropdownMenuItem(
                                value: 'RIGHT_HORIZONTAL',
                                child: Text('右手横握 (手掌在正右)', style: TextStyle(fontSize: 12)),
                              ),
                              DropdownMenuItem(
                                value: 'LEFT_DIAGONAL',
                                child: Text('左手正常握笔 (手掌在左下)', style: TextStyle(fontSize: 12)),
                              ),
                              DropdownMenuItem(
                                value: 'AREA_ONLY',
                                child: Text('仅按触点物理面积过滤', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) svc.setHandedness(v);
                            },
                          ),
                        ],
                      ),
                      const Divider(height: 16),

                      Wrap(
                        spacing: 12,
                        runSpacing: 6,
                        children: [
                          FilterChip(
                            label: const Text('书写锁定多点免疫', style: TextStyle(fontSize: 11)),
                            selected: tele.stylusLockEnabled,
                            onSelected: svc.setStylusLockEnabled,
                          ),
                          FilterChip(
                            label: const Text('无压感笔锋模拟 (入锋/出锋)', style: TextStyle(fontSize: 11)),
                            selected: tele.simulatedTaperEnabled,
                            onSelected: svc.setSimulatedTaperEnabled,
                          ),
                          FilterChip(
                            label: const Text('1€ Filter 慢写消抖', style: TextStyle(fontSize: 11)),
                            selected: tele.oneEuroFilterEnabled,
                            onSelected: svc.setOneEuroFilterEnabled,
                          ),
                          FilterChip(
                            label: const Text('在线 EMA 阈值自适应', style: TextStyle(fontSize: 11)),
                            selected: tele.emaAdaptiveEnabled,
                            onSelected: svc.setEmaAdaptiveEnabled,
                          ),
                          FilterChip(
                            label: const Text('拦截红色波纹反馈', style: TextStyle(fontSize: 11)),
                            selected: tele.showRejectRipple,
                            onSelected: svc.setShowRejectRipple,
                          ),
                          FilterChip(
                            label: const Text('双指轻触撤销', style: TextStyle(fontSize: 11)),
                            selected: tele.twoFingerTapUndoEnabled,
                            onSelected: svc.setTwoFingerTapUndoEnabled,
                          ),
                          FilterChip(
                            label: const Text('三指轻触重做', style: TextStyle(fontSize: 11)),
                            selected: tele.threeFingerTapRedoEnabled,
                            onSelected: svc.setThreeFingerTapRedoEnabled,
                          ),
                          FilterChip(
                            label: const Text('单指双击适配宽度', style: TextStyle(fontSize: 11)),
                            selected: tele.doubleTapFitWidthEnabled,
                            onSelected: svc.setDoubleTapFitWidthEnabled,
                          ),
                          FilterChip(
                            label: const Text(
                              '按住 1 秒临时切橡皮 · 抬笔恢复',
                              style: TextStyle(fontSize: 11),
                            ),
                            selected: tele.holdToTempEraserEnabled,
                            onSelected: (v) => svc.setHoldToTempEraser(enabled: v),
                          ),
                          FilterChip(
                            label: const Text('用力按压临时橡皮', style: TextStyle(fontSize: 11)),
                            selected: tele.pressureEraserEnabled,
                            onSelected: (v) => svc.setPressureEraser(enabled: v),
                          ),
                          FilterChip(
                            label: const Text('停笔 600 毫秒快速形状规整', style: TextStyle(fontSize: 11)),
                            selected: tele.quickShapeHoldEnabled,
                            onSelected: (v) => svc.setQuickShapeHold(enabled: v),
                          ),
                        ],
                      ),
                      const Divider(height: 16),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            '4. 页底加页模式：',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          ChoiceChip(
                            label: const Text('底部主动上滑加页 (防误加页)', style: TextStyle(fontSize: 11)),
                            selected: tele.pageAddMode == 'PULL_UP',
                            onSelected: (_) => svc.setPageAddMode('PULL_UP'),
                          ),
                          const SizedBox(width: 6),
                          ChoiceChip(
                            label: const Text('底部书写自动加页', style: TextStyle(fontSize: 11)),
                            selected: tele.pageAddMode == 'AUTO_BOTTOM_WRITE',
                            onSelected: (_) => svc.setPageAddMode('AUTO_BOTTOM_WRITE'),
                          ),
                          const SizedBox(width: 6),
                          ChoiceChip(
                            label: const Text('仅手动加页', style: TextStyle(fontSize: 11)),
                            selected: tele.pageAddMode == 'MANUAL_ONLY',
                            onSelected: (_) => svc.setPageAddMode('MANUAL_ONLY'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? MumuPalette.darkSlateCard : const Color(0xFFEBEAE2),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '📊 实时 7 维触点特征分析监控台',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: MumuPalette.emeraldGuard,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 18,
                        runSpacing: 6,
                        children: [
                          _TeleMetricItem(
                            '物理直径 D_mm',
                            '${tele.candidateDiameterMm.toStringAsFixed(2)} mm',
                          ),
                          _TeleMetricItem('椭圆偏心率 E', tele.eccentricity.toStringAsFixed(2)),
                          _TeleMetricItem(
                            '膨胀速率 dA/dt',
                            '${tele.areaExpansionRate.toStringAsFixed(2)}/ms',
                          ),
                          _TeleMetricItem(
                            '瞬时速度 v',
                            '${tele.velocityDpPerSec.toStringAsFixed(0)} dp/s',
                          ),
                          _TeleMetricItem('离散曲率 κ', '${tele.curvatureRad.toStringAsFixed(2)} rad'),
                          _TeleMetricItem('空间方位分 S', tele.postureScore.toStringAsFixed(1)),
                          _TeleMetricItem('EMA 在线均值', '${tele.emaMeanMm.toStringAsFixed(2)} mm'),
                          _TeleMetricItem('已拦截手掌', '${tele.rejectedPalmCount} 次'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _penSamplesMm.clear();
                          _palmSamplesMm.clear();
                        });
                        svc.resetToPreset();
                      },
                      child: const Text('恢复默认参数'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('应用防误触配置'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TeleMetricItem extends StatelessWidget {
  final String label;
  final String value;

  const _TeleMetricItem(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: Colors.grey),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
