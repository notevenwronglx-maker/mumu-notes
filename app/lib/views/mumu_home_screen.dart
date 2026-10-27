import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:butterfly/api/file_system.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/models/defaults.dart';
import 'package:butterfly/services/import.dart';
import 'package:butterfly/services/palm_guard_service.dart';
import 'package:butterfly/theme.dart';
import 'package:butterfly/views/mumu_workspace_ui.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:dart_leap/dart_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:butterfly/api/open.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 木木笔记书架主页
class MumuBookshelfHomeScreen extends StatefulWidget {
  final AssetLocation? selectedAsset;

  const MumuBookshelfHomeScreen({super.key, this.selectedAsset});

  @override
  State<MumuBookshelfHomeScreen> createState() =>
      _MumuBookshelfHomeScreenState();
}

typedef MumuHomeScreen = MumuBookshelfHomeScreen;

enum _HomeNavSection { all, infinite, favorites, trash }

enum _HomeCategoryTab { all, pdf, note, folder }

enum _HomeSortOption {
  modifiedDesc('最新修改'),
  modifiedAsc('最早修改'),
  createdDesc('最新创建'),
  createdAsc('最早创建'),
  nameAsc('名称（A–Z）'),
  nameDesc('名称（Z–A）');

  final String label;
  const _HomeSortOption(this.label);
}

class _MumuLabelItem {
  final String id;
  final String name;
  final int colorValue;

  const _MumuLabelItem({
    required this.id,
    required this.name,
    required this.colorValue,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'colorValue': colorValue,
  };

  factory _MumuLabelItem.fromJson(Map<String, dynamic> json) =>
      _MumuLabelItem(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '标签',
        colorValue: json['colorValue'] as int? ?? 0xFF2F7D6E,
      );
}

class _MumuNotebookMeta {
  final bool isFavorite;
  final bool inTrash;
  final List<String> labelIds;
  final String mode; // 'standard' | 'infinite' | 'pdf'
  final String spec; // 'A4', 'A3', 'A5', 'Letter', 'B5', 'Tablet', 'Infinite'
  final String templateId;
  final int paperColor;
  final String coverStyle;
  final int coverColor;

  const _MumuNotebookMeta({
    this.isFavorite = false,
    this.inTrash = false,
    this.labelIds = const [],
    this.mode = 'standard',
    this.spec = 'A4',
    this.templateId = 'ruled',
    this.paperColor = 0xFFFEF9EF,
    this.coverStyle = 'classic_blue',
    this.coverColor = 0xFF2F7D6E,
  });

  _MumuNotebookMeta copyWith({
    bool? isFavorite,
    bool? inTrash,
    List<String>? labelIds,
    String? mode,
    String? spec,
    String? templateId,
    int? paperColor,
    String? coverStyle,
    int? coverColor,
  }) => _MumuNotebookMeta(
    isFavorite: isFavorite ?? this.isFavorite,
    inTrash: inTrash ?? this.inTrash,
    labelIds: labelIds ?? this.labelIds,
    mode: mode ?? this.mode,
    spec: spec ?? this.spec,
    templateId: templateId ?? this.templateId,
    paperColor: paperColor ?? this.paperColor,
    coverStyle: coverStyle ?? this.coverStyle,
    coverColor: coverColor ?? this.coverColor,
  );

  Map<String, dynamic> toJson() => {
    'isFavorite': isFavorite,
    'inTrash': inTrash,
    'labelIds': labelIds,
    'mode': mode,
    'spec': spec,
    'templateId': templateId,
    'paperColor': paperColor,
    'coverStyle': coverStyle,
    'coverColor': coverColor,
  };

  factory _MumuNotebookMeta.fromJson(Map<String, dynamic> json) =>
      _MumuNotebookMeta(
        isFavorite: json['isFavorite'] as bool? ?? false,
        inTrash: json['inTrash'] as bool? ?? false,
        labelIds:
            (json['labelIds'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        mode: json['mode'] as String? ?? 'standard',
        spec: json['spec'] as String? ?? 'A4',
        templateId: json['templateId'] as String? ?? 'ruled',
        paperColor: json['paperColor'] as int? ?? 0xFFFEF9EF,
        coverStyle: json['coverStyle'] as String? ?? 'classic_blue',
        coverColor: json['coverColor'] as int? ?? 0xFF2F7D6E,
      );
}

class _MumuBookshelfHomeScreenState extends State<MumuBookshelfHomeScreen> {
  static const String _metaPrefsKey = 'mumu_bookshelf_meta_v2';
  static const String _labelsPrefsKey = 'mumu_bookshelf_labels_v2';
  static const String _folderColorsPrefsKey = 'mumu_folder_colors_v2';
  static const String _starredTemplatePrefsKey = 'mumu_starred_template_v2';

  static const Color _brandGreen = Color(0xFF2F7D6E);
  static const Color _fabDark = Color(0xFF2D3139);

  static const List<int> _eightTagColors = [
    0xFFEF4444, // 红色
    0xFFF97316, // 橙色
    0xFFEAB308, // 黄色
    0xFF06B6D4, // 青色
    0xFF2F7D6E, // 蓝色
    0xFF8B5CF6, // 紫色
    0xFF10B981, // 翡翠绿
    0xFF1E293B, // 墨黑
  ];

  late DocumentFileSystem _documentSystem;
  bool _sidebarOpen = true;
  bool _searchExpanded = false;
  bool _batchMode = false;
  bool _isGridView = true;
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedPaths = {};
  // D19 文档长按 400ms 拾起拖放状态（拖入文件夹 / 拖文档到文档建文件夹 / 拖到屏幕右侧进分屏）
  String? _draggingNotebookPath;

  String _currentFolder = '';
  _HomeNavSection _navSection = _HomeNavSection.all;
  _HomeCategoryTab _categoryTab = _HomeCategoryTab.all;
  _HomeSortOption _sortOption = _HomeSortOption.modifiedDesc;
  String? _activeLabelFilterId;

  List<FileSystemEntity<NoteFile>> _entities = [];
  List<String> _allDirectories = [];
  bool _loading = true;

  Map<String, _MumuNotebookMeta> _metaByPath = {};
  final Map<String, DateTime> _timeCache = {};
  Map<String, int> _folderColors = {};
  List<_MumuLabelItem> _labels = const [
    _MumuLabelItem(id: 'lbl_class', name: '课堂笔记', colorValue: 0xFF2F7D6E),
    _MumuLabelItem(id: 'lbl_math', name: '考研数学', colorValue: 0xFFEF4444),
    _MumuLabelItem(id: 'lbl_pdf', name: 'PDF 文献批注', colorValue: 0xFF10B981),
    _MumuLabelItem(id: 'lbl_mind', name: '思维导图', colorValue: 0xFF8B5CF6),
  ];
  String _starredQuickTemplateId = 'ruled';

  @override
  void initState() {
    super.initState();
    PalmGuardService.instance.setCanvasInteractive(false);
    final fileSystem = context.read<ButterflyFileSystem>();
    final remote = context.read<SettingsCubit>().state.getDefaultRemote();
    _documentSystem = fileSystem.buildDocumentSystem(remote);
    _initBookshelf();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _initBookshelf() async {
    await _loadPrefs();
    await _upgradeStarterGuide();
    await _reloadFiles(seedIfEmpty: true);
  }

  /// Upgrade the old blank two-page starter guide to the ten-page manual once.
  /// A marker in the page extra prevents overwriting notes the user made later.
  Future<void> _upgradeStarterGuide() async {
    try {
      final root = await _documentSystem.getAsset('', readData: true);
      if (root is! FileSystemDirectory<NoteFile>) return;
      final guide = root.assets
          .whereType<FileSystemFile<NoteFile>>()
          .where((file) => file.path.endsWith('快速入门指南 · 木木笔记.bfly'))
          .firstOrNull;
      if (guide == null) return;
      final raw = guide.data;
      if (raw == null) return;
      final note = NoteData.fromData(raw.data);
      final pages = note.getPages();
      if (pages.isEmpty) return;
      final firstPage = note.getPage(pages.first);
      if (firstPage == null) return;
      final guideMarker = firstPage.extra['mumu:guideVersion'];
      if (guideMarker == 3) return;
      // If the old two-page starter guide already has handwriting, keep it
      // as a separate annotated copy. Our generated text guide (marker 2) is
      // replaced directly by the PDF manual.
      if (guideMarker != 2 &&
          firstPage.layers.any((layer) => layer.content.isNotEmpty)) {
        final slash = guide.path.lastIndexOf('/');
        final parent = slash >= 0 ? guide.path.substring(0, slash) : '';
        final backupPath = '$parent/快速入门指南（旧版批注）.bfly';
        final moved = await _documentSystem.moveAsset(guide.path, backupPath);
        if (moved == null) return;
        await _documentSystem.updateFile(
          backupPath,
          note.setName('快速入门指南（旧版批注）').toFile(),
        );
        final metaKey = _metaByPath.keys
            .where((key) => key.endsWith('快速入门指南 · 木木笔记.bfly'))
            .firstOrNull;
        if (metaKey != null) {
          final oldMeta = _metaByPath.remove(metaKey);
          if (oldMeta != null) {
            _metaByPath[backupPath.startsWith('/')
                ? backupPath
                : '/$backupPath'] = oldMeta;
          }
        }
        final manual = await _buildPdfGuideDocument();
        final created = await _documentSystem.createFileWithName(
          name: '快速入门指南 · 木木笔记',
          suffix: '.bfly',
          manual.toFile(),
        );
        _metaByPath[created.path] = const _MumuNotebookMeta(
          isFavorite: true,
          mode: 'standard',
          spec: 'A4',
          templateId: 'blank',
          paperColor: 0xFFFDF8EE,
          coverStyle: 'fighter_sketch',
          coverColor: 0xFF2F7D6E,
          labelIds: ['lbl_class'],
        );
        await _savePrefs();
        return;
      }
      final upgraded = await _buildPdfGuideDocument();
      await _documentSystem.updateFile(guide.path, upgraded.toFile());
      final metaKey = _metaByPath.keys
          .where((key) => key.endsWith('快速入门指南 · 木木笔记.bfly'))
          .firstOrNull;
      if (metaKey != null) {
        _metaByPath[metaKey] = _metaByPath[metaKey]!.copyWith(
          templateId: 'blank',
          paperColor: 0xFFFFFFFF,
        );
        await _savePrefs();
      }
    } catch (_) {
      // A broken or read-only starter file must not block the bookshelf.
    }
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawMeta = prefs.getString(_metaPrefsKey);
      if (rawMeta != null && rawMeta.isNotEmpty) {
        final decoded = jsonDecode(rawMeta) as Map<String, dynamic>;
        _metaByPath = decoded.map(
          (k, v) => MapEntry(
            k,
            _MumuNotebookMeta.fromJson(Map<String, dynamic>.from(v as Map)),
          ),
        );
      }
      final rawLabels = prefs.getString(_labelsPrefsKey);
      if (rawLabels != null && rawLabels.isNotEmpty) {
        final list = jsonDecode(rawLabels) as List<dynamic>;
        _labels = list
            .map(
              (e) =>
                  _MumuLabelItem.fromJson(Map<String, dynamic>.from(e as Map)),
            )
            .toList();
      }
      final rawFolderColors = prefs.getString(_folderColorsPrefsKey);
      if (rawFolderColors != null && rawFolderColors.isNotEmpty) {
        final map = jsonDecode(rawFolderColors) as Map<String, dynamic>;
        _folderColors = map.map((k, v) => MapEntry(k, (v as num).toInt()));
      }
      _starredQuickTemplateId =
          prefs.getString(_starredTemplatePrefsKey) ?? 'ruled';
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _metaPrefsKey,
        jsonEncode(_metaByPath.map((k, v) => MapEntry(k, v.toJson()))),
      );
      await prefs.setString(
        _labelsPrefsKey,
        jsonEncode(_labels.map((e) => e.toJson()).toList()),
      );
      await prefs.setString(_folderColorsPrefsKey, jsonEncode(_folderColors));
      await prefs.setString(_starredTemplatePrefsKey, _starredQuickTemplateId);
    } catch (_) {}
  }

  Future<void> _reloadFiles({bool seedIfEmpty = false}) async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final rootAsset = await _documentSystem.getAsset('', readData: true);
      final rootChildren = rootAsset is FileSystemDirectory<NoteFile>
          ? rootAsset.assets
          : <FileSystemEntity<NoteFile>>[];

      if (seedIfEmpty && rootChildren.isEmpty) {
        await _seedStarterNotebooks();
      }

      final targetAsset = await _documentSystem.getAsset(
        _currentFolder,
        readData: true,
      );
      final list = targetAsset is FileSystemDirectory<NoteFile>
          ? List<FileSystemEntity<NoteFile>>.from(targetAsset.assets)
          : <FileSystemEntity<NoteFile>>[];

      final dirs = <String>[];
      if (rootAsset is FileSystemDirectory<NoteFile>) {
        for (final item in rootAsset.assets) {
          if (item is FileSystemDirectory<NoteFile>) {
            dirs.add(item.path);
          }
        }
      }

      // 读取每个笔记本的真实创建/修改时间，供「最新修改 / 最早修改 / 最新创建 / 最早创建」排序使用
      for (final entity in list) {
        if (entity is! FileSystemFile<NoteFile>) continue;
        final raw = entity.data;
        if (raw == null) continue;
        try {
          final note = NoteData.fromData(raw.data);
          final meta = note.getMetadata();
          final stamp = meta?.updatedAt ?? meta?.createdAt;
          if (stamp != null) _timeCache[entity.path] = stamp.toLocal();
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _entities = list;
        _allDirectories = dirs;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _seedStarterNotebooks() async {
    try {
      // 1. 创建《快速入门指南 · 标准笔记（A4 纵向分页 · 下滑自动加页）》
      final guideDoc = await _buildPdfGuideDocument();
      final createdGuide = await _documentSystem.createFileWithName(
        name: '快速入门指南 · 木木笔记',
        suffix: '.bfly',
        guideDoc.toFile(),
      );
      _metaByPath[createdGuide.path] = const _MumuNotebookMeta(
        isFavorite: true,
        mode: 'standard',
        spec: 'A4',
        templateId: 'blank',
        paperColor: 0xFFFFFFFF,
        coverStyle: 'fighter_sketch',
        coverColor: 0xFF2F7D6E,
        labelIds: ['lbl_class'],
      );

      // 2. 创建《高等数学推导与课堂笔记 · A4方格》（方便直接测试双文档并排分屏）
      final mathDoc = _buildMumuDocument(
        title: '高等数学推导与课堂笔记',
        isInfinite: false,
        spec: 'A4',
        isLandscape: false,
        paperColorValue: 0xFFFFFFFF,
        templateId: 'grid',
        initialPageCount: 2,
      );
      final createdMath = await _documentSystem.createFileWithName(
        name: '高等数学推导与课堂笔记',
        suffix: '.bfly',
        mathDoc.toFile(),
      );
      _metaByPath[createdMath.path] = const _MumuNotebookMeta(
        isFavorite: true,
        mode: 'standard',
        spec: 'A4',
        templateId: 'grid',
        paperColor: 0xFFFFFFFF,
        coverStyle: 'royal_indigo',
        coverColor: 0xFF1E3A8A,
        labelIds: ['lbl_math'],
      );

      // 3. 创建《无界头脑风暴 · 无限画布》
      final infDoc = _buildMumuDocument(
        title: '无界头脑风暴 · 无限画布',
        isInfinite: true,
        spec: 'Infinite',
        isLandscape: true,
        paperColorValue: 0xFFFFFFFF,
        templateId: 'dots',
      );
      final createdInf = await _documentSystem.createFileWithName(
        name: '无界头脑风暴 · 无限画布',
        suffix: '.bfly',
        infDoc.toFile(),
      );
      _metaByPath[createdInf.path] = const _MumuNotebookMeta(
        isFavorite: false,
        mode: 'infinite',
        spec: 'Infinite',
        templateId: 'dots',
        paperColor: 0xFFFFFFFF,
        coverStyle: 'geometry_modern',
        coverColor: 0xFF059669,
        labelIds: ['lbl_mind'],
      );
      await _savePrefs();
    } catch (_) {}
  }

  static Future<NoteData> _buildPdfGuideDocument() async {
    final data = await rootBundle.load('defaults/manual.pdf');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    return _buildPdfNotebook(
      bytes,
      '快速入门指南 · 木木笔记',
      guide: true,
    );
  }

  /// Build a regular notebook from a PDF. Every PDF page becomes an Area in
  /// the same DocumentPage, with the PDF in an original-content layer and the
  /// user's ink in a separate annotation layer.
  static Future<NoteData> _buildPdfNotebook(
    Uint8List bytes,
    String title, {
    bool guide = false,
  }) async {
    final pdf = await PdfDocument.openData(bytes);
    final sizes = pdf.pages
        .map((page) => (page.width.toDouble(), page.height.toDouble()))
        .toList(growable: false);
    await pdf.dispose();

    var document = DocumentDefaults.createDocument(
      name: title,
      createDefaultPage: false,
    );
    final (withPdf, source) = document.importPdf(bytes);
    final elements = <PadElement>[];
    final areas = <Area>[];
    var y = 0.0;
    for (var i = 0; i < sizes.length; i++) {
      final (width, height) = sizes[i];
      areas.add(
        Area(
          name: '第 ${i + 1} 页',
          width: width,
          height: height,
          position: math.Point<double>(0, y),
        ),
      );
      elements.add(
        PdfElement(
          id: createUniqueId(),
          source: source,
          page: i,
          width: width,
          height: height,
          position: math.Point<double>(0, y),
          background: SRGBColor(0xFFFFFFFF),
        ),
      );
      y += height + 32.0;
    }
    final page = DocumentPage(
      layers: [
        DocumentLayer(
          id: createUniqueId(),
          name: guide ? '指南原文层' : 'PDF 原文层',
          content: elements,
        ),
        DocumentLayer(
          id: createUniqueId(),
          name: guide ? '我的批注层' : '手写批注层',
        ),
      ],
      backgrounds: [
        Background.texture(
          texture: PatternTexture(boxColor: SRGBColor(0xFFFFFFFF)),
        ),
      ],
      areas: areas,
      extra: {
        'mumu:mode': 'standard',
        'mumu:spec': guide ? 'A4' : 'PDF',
        'mumu:template': 'blank',
        'mumu:paperColor': 0xFFFFFFFF,
        'mumu:landscape': false,
        'mumu:scrollDirection': 'vertical',
        'mumu:pullToAddPage': false,
        if (guide) 'mumu:guideVersion': 3,
        if (guide) 'mumu:guidePdf': true,
      },
    );
    var result = withPdf.setPage(page, '第 1 页').$1;
    final info = result.getInfo() ?? DocumentDefaults.createInfo();
    return result.setInfo(
      info.copyWith(
        tools: DocumentDefaults.createTools(SRGBColor(0xFFFFFFFF)),
        extra: {
          ...info.extra,
          'mumu:mode': 'standard',
          'mumu:spec': guide ? 'A4' : 'PDF',
          'mumu:template': 'blank',
        },
      ),
    );
  }

  static NoteData _buildMumuDocument({
    required String title,
    required bool isInfinite,
    required String spec,
    required bool isLandscape,
    required int paperColorValue,
    required String templateId,
    double customWidth = 840,
    double customHeight = 1188,
    int initialPageCount = 1,
    String firstLayerName = '图层 1 · 正文手写层',
    String secondLayerName = '图层 2 · 重点批注层',
  }) {
    final bgTexture = _createPatternTextureForTemplate(
      templateId,
      paperColorValue,
    );
    final backgrounds = <Background>[
      Background.texture(texture: bgTexture),
      if (templateId == 'cornell' || templateId == 'legal')
        Background.texture(
          texture: const PatternTexture(
            boxColor: SRGBColor.transparent,
            boxXColor: SRGBColor(0x48EF4444),
            boxWidth: 240,
            boxXCount: 1,
            boxXStroke: 1.5,
          ),
        ),
    ];

    final (double w, double h) = switch (spec) {
      'A3' => (1188.0, 1680.0),
      'A4' => (840.0, 1188.0),
      'A5' => (595.0, 840.0),
      'Letter' => (816.0, 1056.0),
      'B5' => (708.0, 1000.0),
      'Phone' => (480.0, 960.0),
      'Tablet' => (960.0, 1360.0),
      'Custom' => (customWidth, customHeight),
      _ => (840.0, 1188.0),
    };
    final pageW = isLandscape ? math.max(w, h) : math.min(w, h);
    final pageH = isLandscape ? math.min(w, h) : math.max(w, h);

    final count = math.max(1, initialPageCount);
    final page = DocumentPage(
      layers: [
        DocumentLayer(
          id: createUniqueId(),
          name: firstLayerName,
        ),
        DocumentLayer(id: createUniqueId(), name: secondLayerName),
      ],
      backgrounds: backgrounds,
      areas: isInfinite
          ? const []
          : [
              for (int i = 0; i < count; i++)
                Area(
                  name: '第 ${i + 1} 页',
                  width: pageW,
                  height: pageH,
                  position: math.Point<double>(0.0, i * (pageH + 32.0)),
                ),
            ],
      extra: {
        'mumu:mode': isInfinite ? 'infinite' : 'standard',
        'mumu:spec': isInfinite ? 'Infinite' : spec,
        'mumu:template': templateId,
        'mumu:paperColor': paperColorValue,
        'mumu:landscape': isLandscape,
        'mumu:scrollDirection': 'vertical',
        'mumu:pullToAddPage': true,
      },
    );

    final doc = DocumentDefaults.createDocument(name: title, page: page);
    final info = doc.getInfo() ?? DocumentDefaults.createInfo();
    return doc.setInfo(
      info.copyWith(
        tools: DocumentDefaults.createTools(SRGBColor(paperColorValue)),
        extra: {
          ...info.extra,
          'mumu:mode': isInfinite ? 'infinite' : 'standard',
          'mumu:spec': isInfinite ? 'Infinite' : spec,
          'mumu:template': templateId,
        },
      ),
    );
  }

  static PatternTexture _createPatternTextureForTemplate(
    String templateId,
    int paperColorValue,
  ) {
    final isDark = paperColorValue == 0xFF1E293B;
    final lineColor = isDark
        ? const SRGBColor(0x3894A3B8)
        : const SRGBColor(0x3864748B);
    final boxColor = SRGBColor(paperColorValue);

    return switch (templateId) {
      'blank' || '2col_plain' => PatternTexture(boxColor: boxColor),
      'ruled' || 'legal' || '2col_lined' || 'daily' => PatternTexture(
        boxColor: boxColor,
        boxHeight: 38,
        boxYColor: lineColor,
        boxYStroke: 0.9,
      ),
      'grid' || '2col_grid' || 'weekly' || 'monthly' => PatternTexture(
        boxColor: boxColor,
        boxWidth: 34,
        boxHeight: 34,
        boxXColor: lineColor,
        boxYColor: lineColor,
        boxXStroke: 0.8,
        boxYStroke: 0.8,
      ),
      'dots' || '2col_dot' => PatternTexture(
        boxColor: boxColor,
        boxWidth: 32,
        boxHeight: 32,
        boxXCount: 1,
        boxYCount: 2,
        boxXStroke: 4,
        boxYStroke: 28,
        boxXColor: lineColor,
        boxYColor: boxColor,
      ),
      'cornell' => PatternTexture(
        boxColor: boxColor,
        boxHeight: 38,
        boxYColor: lineColor,
        boxYStroke: 0.9,
      ),
      'music' => PatternTexture(
        boxColor: boxColor,
        boxHeight: 14,
        boxYSpace: 56,
        boxYCount: 5,
        boxYColor: lineColor,
        boxYStroke: 1.0,
      ),
      _ => PatternTexture(
        boxColor: boxColor,
        boxHeight: 38,
        boxYColor: lineColor,
        boxYStroke: 0.9,
      ),
    };
  }

  _MumuNotebookMeta _metaFor(String path) =>
      _metaByPath[path] ?? const _MumuNotebookMeta();

  String _sanitizeSafeFileName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '未命名笔记';
    // 移除 Android 外部存储禁止的非法字符 (< > : " / \ | ? *)
    final cleaned = trimmed.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    return cleaned.isEmpty ? '未命名笔记' : cleaned;
  }

  Future<void> _createQuickNote() async {
    final now = DateTime.now();
    // 注意：Android 外部存储严禁文件名含冒号 ":"，使用 "-" 分隔时分秒
    final timeStr =
        '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}';
    final title = _sanitizeSafeFileName('快速笔记_$timeStr');
    final doc = _buildMumuDocument(
      title: title,
      isInfinite: false,
      spec: 'A4',
      isLandscape: false,
      paperColorValue: 0xFFFEF9EF,
      templateId: _starredQuickTemplateId,
    );
    try {
      final noteFile = doc.toFile();
      final created = await _documentSystem.createFileWithName(
        directory: _currentFolder,
        name: title,
        suffix: '.bfly',
        noteFile,
      );
      _metaByPath[created.path] = _MumuNotebookMeta(
        mode: 'standard',
        spec: 'A4',
        templateId: _starredQuickTemplateId,
        paperColor: 0xFFFEF9EF,
        coverStyle: 'classic_blue',
        coverColor: 0xFF2F7D6E,
      );
      await _savePrefs();
      await _reloadFiles();
      if (!mounted) return;
      await _openNotebookPath(created.path, created.data ?? noteFile);
    } catch (e) {
      if (!mounted) return;
      await GoRouter.of(context).pushNamed('new', extra: doc);
      if (mounted) await _reloadFiles();
    }
  }

  Future<void> _createInstantPresetNote({
    required String namePrefix,
    required bool isInfinite,
    required String templateId,
    int paperColorValue = 0xFFFEF9EF,
  }) async {
    final now = DateTime.now();
    final timeStr =
        '${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final title = _sanitizeSafeFileName('${namePrefix}_$timeStr');
    final doc = _buildMumuDocument(
      title: title,
      isInfinite: isInfinite,
      spec: isInfinite ? 'Infinite' : 'A4',
      isLandscape: isInfinite,
      paperColorValue: paperColorValue,
      templateId: templateId,
    );
    try {
      final noteFile = doc.toFile();
      final created = await _documentSystem.createFileWithName(
        directory: _currentFolder,
        name: title,
        suffix: '.bfly',
        noteFile,
      );
      _metaByPath[created.path] = _MumuNotebookMeta(
        mode: isInfinite ? 'infinite' : 'standard',
        spec: isInfinite ? 'Infinite' : 'A4',
        templateId: templateId,
        paperColor: paperColorValue,
        coverStyle: isInfinite ? 'geometry_modern' : 'classic_blue',
        coverColor: isInfinite ? 0xFF059669 : 0xFF2F7D6E,
      );
      await _savePrefs();
      await _reloadFiles();
      if (!mounted) return;
      await _openNotebookPath(created.path, created.data ?? noteFile);
    } catch (_) {
      if (!mounted) return;
      await GoRouter.of(context).pushNamed('new', extra: doc);
      if (mounted) await _reloadFiles();
    }
  }

  void _showQuickCreateSheet(BuildContext context, bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            children: [
              const ListTile(
                title: Text(
                  '快速新建笔记',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                dense: true,
              ),
              ListTile(
                leading: const Icon(Icons.notes_rounded, color: _brandGreen),
                title: const Text('A4 横线笔记（适合课堂记录）'),
                subtitle: const Text('护眼米黄 · 标准 38pt 行距'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createInstantPresetNote(
                    namePrefix: '横线笔记',
                    isInfinite: false,
                    templateId: 'ruled',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.grid_4x4_rounded, color: _brandGreen),
                title: const Text('A4 方格笔记（适合数学推导/作图）'),
                subtitle: const Text('工程方格 · 支持一笔成型与标尺磁吸'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createInstantPresetNote(
                    namePrefix: '数学方格笔记',
                    isInfinite: false,
                    templateId: 'grid',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.view_sidebar_outlined, color: _brandGreen),
                title: const Text('A4 康奈尔笔记（适合重点提炼与总结）'),
                subtitle: const Text('左右分栏线索区 + 底部总结区'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createInstantPresetNote(
                    namePrefix: '康奈尔笔记',
                    isInfinite: false,
                    templateId: 'cornell',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.all_inclusive_rounded, color: Color(0xFF059669)),
                title: const Text('无边界无限画布'),
                subtitle: const Text('四向无界延展 · 适合思维导图与推演草稿'),
                onTap: () {
                  Navigator.pop(ctx);
                  _createInstantPresetNote(
                    namePrefix: '无限画布',
                    isInfinite: true,
                    templateId: 'grid',
                    paperColorValue: 0xFFFFFFFF,
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined, color: Color(0xFF8B5CF6)),
                title: const Text('打开完整纸张模板与封面库...'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSelectTemplateModal(initialInfinite: false, isDark: isDark);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openNotebookPath(String rawPath, [NoteFile? fileData]) async {
    final clean = rawPath.startsWith('/') ? rawPath.substring(1) : rawPath;
    final remoteId = _documentSystem.storage?.identifier ?? '';
    if (remoteId.isNotEmpty) {
      await GoRouter.of(context).pushNamed(
        'remote',
        pathParameters: {'remote': remoteId, 'path': clean},
        extra: fileData,
      );
    } else {
      await GoRouter.of(context).pushNamed(
        'local',
        pathParameters: {'path': clean},
        extra: fileData,
      );
    }
    if (mounted) {
      await _reloadFiles();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final screenW = MediaQuery.sizeOf(context).width;
    final isCompact = screenW < 820;

    return Scaffold(
      backgroundColor: isDark
          ? const Color(0xFF0F172A)
          : const Color(0xFFF6F7FB),
      drawer: isCompact
          ? Drawer(width: 280, child: SafeArea(child: _buildLeftSidebar(isDark, true)))
          : null,
      body: SafeArea(
        child: Row(
          children: [
            if (!isCompact && _sidebarOpen)
              SizedBox(width: 264, child: _buildLeftSidebar(isDark, false)),
            Expanded(
              child: Stack(
                children: [
                  Column(
                    children: [
                      _buildTopBar(isDark, isCompact),
                      if (_batchMode) _buildBatchActionBar(isDark),
                      Expanded(child: _buildBookshelfBody(isDark)),
                    ],
                  ),
                  // 右下角标志性双悬浮按钮：上方深灰「快速笔记」+ 下方宝蓝「+ 新建菜单」
                  Positioned(
                    right: 26,
                    bottom: 26,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 1.4 快速笔记一键直达按钮
                        Tooltip(
                          message: '快速笔记：无需选模板，一键进入书写',
                          child: Material(
                            color: _fabDark,
                            shape: const CircleBorder(),
                            elevation: 6,
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: _createQuickNote,
                              child: const SizedBox(
                                width: 46,
                                height: 46,
                                child: Icon(
                                  Icons.edit_note_rounded,
                                  color: Colors.white,
                                  size: 21,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // 1.1 + 新建笔记本/无限画布/导入文档按钮
                        Builder(
                          builder: (fabCtx) => Tooltip(
                            message: '新建标准笔记 / 无限画布 / 文件夹 / 导入 PDF',
                            child: Material(
                              color: _brandGreen,
                              shape: const CircleBorder(),
                              elevation: 8,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => _showPlusNewMenu(fabCtx, isDark),
                                child: const SizedBox(
                                  width: 58,
                                  height: 58,
                                  child: Icon(
                                    Icons.add_rounded,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 左侧可折叠导航栏（对应 PDF 第 5、7、8、9 章）
  // ===========================================================================
  Widget _buildLeftSidebar(bool isDark, bool inDrawer) {
    final bg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderCol = isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB);
    final trashCount = _metaByPath.values.where((m) => m.inTrash).length;
    final favCount = _metaByPath.values
        .where((m) => m.isFavorite && !m.inTrash)
        .length;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        border: Border(right: BorderSide(color: borderCol)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(height: 1, color: borderCol),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _brandGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      if (inDrawer) Navigator.pop(context);
                      _showQuickCreateSheet(context, isDark);
                    },
                    icon: const Icon(Icons.add_rounded, size: 19),
                    label: const Text(
                      '新建笔记',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                    ),
                  ),
                ),
                _buildSidebarNavTile(
                  icon: Icons.book_outlined,
                  activeIcon: Icons.book_rounded,
                  label: '全部笔记',
                  selected:
                      _navSection == _HomeNavSection.all &&
                      _activeLabelFilterId == null &&
                      _currentFolder.isEmpty,
                  onTap: () {
                    setState(() {
                      _navSection = _HomeNavSection.all;
                      _activeLabelFilterId = null;
                      _currentFolder = '';
                    });
                    _reloadFiles();
                    if (inDrawer) Navigator.pop(context);
                  },
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.all_inclusive_rounded,
                  activeIcon: Icons.all_inclusive_rounded,
                  label: '无限画布',
                  selected: _navSection == _HomeNavSection.infinite,
                  onTap: () {
                    setState(() {
                      _navSection = _HomeNavSection.infinite;
                      _activeLabelFilterId = null;
                    });
                    if (inDrawer) Navigator.pop(context);
                  },
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.dashboard_customize_outlined,
                  activeIcon: Icons.dashboard_customize_rounded,
                  label: '纸张模板库',
                  selected: false,
                  onTap: () {
                    if (inDrawer) Navigator.pop(context);
                    _showSelectTemplateModal(
                      initialInfinite: false,
                      isDark: isDark,
                    );
                  },
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.star_border_rounded,
                  activeIcon: Icons.star_rounded,
                  label: '我的收藏',
                  badge: favCount > 0 ? '$favCount' : null,
                  selected: _navSection == _HomeNavSection.favorites,
                  onTap: () {
                    setState(() {
                      _navSection = _HomeNavSection.favorites;
                      _activeLabelFilterId = null;
                    });
                    if (inDrawer) Navigator.pop(context);
                  },
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.delete_outline_rounded,
                  activeIcon: Icons.delete_rounded,
                  label: '回收站',
                  badge: trashCount > 0 ? '$trashCount' : null,
                  selected: _navSection == _HomeNavSection.trash,
                  onTap: () {
                    setState(() {
                      _navSection = _HomeNavSection.trash;
                      _activeLabelFilterId = null;
                    });
                    if (inDrawer) Navigator.pop(context);
                  },
                  isDark: isDark,
                ),

                const SizedBox(height: 14),
                // 5.1 文件夹
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '文件夹',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6B7280),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _showCreateFolderDialog(isDark),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.add_rounded,
                            size: 14,
                            color: _brandGreen,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                for (final dirPath in _allDirectories)
                  _buildSidebarNavTile(
                    icon: Icons.folder_rounded,
                    activeIcon: Icons.folder_open_rounded,
                    iconColor: Color(
                      _folderColors[dirPath] ?? _brandGreen.toARGB32(),
                    ),
                    label: dirPath.split('/').where((s) => s.isNotEmpty).last,
                    selected:
                        _navSection == _HomeNavSection.all &&
                        _currentFolder == dirPath,
                    onTap: () {
                      setState(() {
                        _navSection = _HomeNavSection.all;
                        _activeLabelFilterId = null;
                        _currentFolder = dirPath;
                      });
                      _reloadFiles();
                      if (inDrawer) Navigator.pop(context);
                    },
                    isDark: isDark,
                  ),

                const SizedBox(height: 14),
                // 5.3 我的标签
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '我的标签',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6B7280),
                        ),
                      ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _showCreateLabelDialog(isDark),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.add_rounded,
                            size: 14,
                            color: _brandGreen,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                for (final lbl in _labels)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    selected: _activeLabelFilterId == lbl.id,
                    selectedTileColor: _brandGreen.withValues(alpha: 0.12),
                    leading: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Color(lbl.colorValue),
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text(
                      lbl.name,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: _activeLabelFilterId == lbl.id
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    onTap: () {
                      setState(() {
                        _navSection = _HomeNavSection.all;
                        _activeLabelFilterId =
                            _activeLabelFilterId == lbl.id ? null : lbl.id;
                      });
                      if (inDrawer) Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ),

          Divider(height: 1, color: borderCol),
          // 底部：云同步备份 + 防误触校准台 + 设置
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                _buildSidebarNavTile(
                  icon: Icons.cloud_upload_outlined,
                  activeIcon: Icons.cloud_upload_rounded,
                  label: '我的数据 · 云同步与备份',
                  selected: false,
                  onTap: () => _showMumuAppSettingsSheet(isDark),
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.verified_user_outlined,
                  activeIcon: Icons.verified_user_rounded,
                  iconColor: MumuPalette.emeraldGuard,
                  label: '电容笔防误触与笔尖校准',
                  selected: false,
                  onTap: () => showMumuCalibrationModal(context),
                  isDark: isDark,
                ),
                _buildSidebarNavTile(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings_rounded,
                  label: '应用设置',
                  selected: false,
                  onTap: () => _showMumuSettingsModal(isDark),
                  isDark: isDark,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarNavTile({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required bool isDark,
    Color? iconColor,
    String? badge,
  }) {
    final fg = selected
        ? _brandGreen
        : (isDark ? Colors.white70 : const Color(0xFF374151));
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected
            ? _brandGreen.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? activeIcon : icon,
                  size: 18,
                  color: iconColor ?? fg,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: fg,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF334155)
                          : const Color(0xFFE5E7EB),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      badge,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 顶部导航栏与分类切换
  // ===========================================================================
  Future<void> _handleTopBarAction(
    String action,
    bool isDark,
    bool isCompact,
  ) async {
    switch (action) {
      case 'new':
        _showSelectTemplateModal(initialInfinite: false, isDark: isDark);
        break;
      case 'import_pdf':
        await _handleImportExternalFile(isPdf: true);
        break;
      case 'import_image':
        await _handleImportImageAsNote();
        break;
      case 'cloud':
        _showMumuAppSettingsSheet(isDark);
        break;
      case 'manual':
        _showOfficialManualGuideModal(isDark);
        break;
      case 'material':
        _showMaterialCenterModal(isDark);
        break;
      case 'settings':
        _showMumuAppSettingsSheet(isDark);
        break;
      case 'account':
        _showAccountAndVipModal(isDark);
        break;
      case 'view':
        setState(() => _isGridView = !_isGridView);
        break;
      case 'batch':
        setState(() {
          _batchMode = !_batchMode;
          _selectedPaths.clear();
        });
        break;
    }
  }

  Widget _buildTopBar(bool isDark, bool isCompact) {
    final surface = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderCol = isDark ? const Color(0xFF334155) : const Color(0xFFE5E7EB);

    // 窄屏（平板竖屏/手机）只保留菜单、标题、搜索、更多；其余入口全部进入「更多」菜单，
    // 避免像旧版那样把“导入 PDF / 素材中心 / 设置”直接挤出屏幕导致点不到。
    final topBarMenu = PopupMenuButton<String>(
      tooltip: '更多（导入 / 素材 / 云同步 / 设置）',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (value) => _handleTopBarAction(value, isDark, isCompact),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 'import_pdf',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.picture_as_pdf_outlined, size: 18),
            title: Text('导入本地 PDF', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuItem(
          value: 'import_image',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.image_outlined, size: 18),
            title: Text('导入图片批注', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuItem(
          value: 'material',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.widgets_outlined, size: 18),
            title: Text('素材中心', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuItem(
          value: 'cloud',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.cloud_upload_outlined, size: 18),
            title: Text('云同步与备份', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuItem(
          value: 'manual',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.help_outline_rounded, size: 18),
            title: Text('操作手册', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuItem(
          value: 'account',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.workspace_premium_outlined, size: 18),
            title: Text('账号与版本信息', style: TextStyle(fontSize: 12)),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'settings',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.settings_outlined, size: 18),
            title: Text('应用设置', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: borderCol)),
      ),
      child: Column(
        children: [
          // 第一行：菜单 + 标题 + 搜索/更多
          SizedBox(
            height: 46,
            child: Row(
              children: [
                Builder(
                  builder: (ctx) => IconButton(
                    tooltip: '展开/收起侧边目录栏',
                    icon: const Icon(Icons.menu_rounded, size: 22),
                    onPressed: () {
                      if (isCompact) {
                        Scaffold.of(ctx).openDrawer();
                      } else {
                        setState(() => _sidebarOpen = !_sidebarOpen);
                      }
                    },
                  ),
                ),
                if (!isCompact) ...[
                  IconButton(
                    tooltip: '云同步与备份',
                    icon: const Icon(Icons.cloud_done_outlined, size: 20),
                    onPressed: () => _showMumuAppSettingsSheet(isDark),
                  ),
                  IconButton(
                    tooltip: '操作手册与教程',
                    icon: const Icon(Icons.help_outline_rounded, size: 20),
                    onPressed: () => _showOfficialManualGuideModal(isDark),
                  ),
                ],
                Expanded(
                  child: _searchExpanded
                      ? SizedBox(
                          height: 36,
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: '搜索笔记或文件夹...',
                              prefixIcon: const Icon(
                                Icons.search_rounded,
                                size: 16,
                              ),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.close_rounded, size: 14),
                                onPressed: () {
                                  setState(() {
                                    _searchController.clear();
                                    _searchExpanded = false;
                                  });
                                },
                              ),
                              contentPadding:
                                  const EdgeInsets.symmetric(vertical: 0),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.home_rounded,
                              size: 20,
                              color: _brandGreen,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '木木笔记',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF111827),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  icon: const Icon(Icons.note_add_outlined, size: 16),
                  label: const Text(
                    '新建',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  onPressed: () => _showSelectTemplateModal(
                    initialInfinite: false,
                    isDark: isDark,
                  ),
                ),
                if (!isCompact) ...[
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                    ),
                    icon: const Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 16,
                      color: Color(0xFFEF4444),
                    ),
                    label: const Text(
                      '导入 PDF',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: () => _handleImportExternalFile(isPdf: true),
                  ),
                  IconButton(
                    tooltip: '素材中心',
                    icon: const Icon(
                      Icons.widgets_outlined,
                      size: 20,
                      color: _brandGreen,
                    ),
                    onPressed: () => _showMaterialCenterModal(isDark),
                  ),
                ],
                IconButton(
                  tooltip: _searchExpanded ? '关闭搜索' : '搜索笔记名称',
                  icon: Icon(
                    _searchExpanded
                        ? Icons.search_off_rounded
                        : Icons.search_rounded,
                    size: 20,
                  ),
                  onPressed: () => setState(
                    () => _searchExpanded = !_searchExpanded,
                  ),
                ),
                IconButton(
                  tooltip: isDark ? '切换为浅色主题' : '切换为深色主题',
                  icon: Icon(
                    isDark ? Icons.palette_outlined : Icons.palette_outlined,
                    size: 20,
                  ),
                  onPressed: () {
                    final settingsCubit = context.read<SettingsCubit>();
                    settingsCubit.changeTheme(
                      isDark ? ThemeMode.light : ThemeMode.dark,
                    );
                  },
                ),
                if (!isCompact)
                  IconButton(
                    tooltip: _isGridView ? '切换为列表视图' : '切换为网格视图',
                    icon: Icon(
                      _isGridView
                          ? Icons.view_list_rounded
                          : Icons.grid_view_rounded,
                      size: 20,
                    ),
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                  ),
                if (isCompact)
                  topBarMenu
                else
                  IconButton(
                    tooltip: '木木笔记设置',
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    onPressed: () => _showMumuSettingsModal(isDark),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 2),
          // 第二行：可滚动分类标签 + 批量/排序（窄屏只留图标，绝不裁切）
          SizedBox(
            height: 40,
            child: Row(
              children: [
                if (_currentFolder.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        setState(() => _currentFolder = '');
                        _reloadFiles();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.arrow_back_rounded,
                              size: 14,
                              color: _brandGreen,
                            ),
                            const SizedBox(width: 3),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 90),
                              child: Text(
                                _currentFolder
                                    .split('/')
                                    .where((e) => e.isNotEmpty)
                                    .last,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _brandGreen,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildCategoryTabItem(
                          _HomeCategoryTab.all,
                          '全部',
                          isDark,
                        ),
                        _buildCategoryTabItem(
                          _HomeCategoryTab.pdf,
                          'PDF',
                          isDark,
                        ),
                        _buildCategoryTabItem(
                          _HomeCategoryTab.note,
                          '笔记',
                          isDark,
                        ),
                        _buildCategoryTabItem(
                          _HomeCategoryTab.folder,
                          '文件夹',
                          isDark,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '批量操作 (多选复制/移动/删除)',
                  icon: Icon(
                    _batchMode
                        ? Icons.checklist_rtl_rounded
                        : Icons.checklist_rounded,
                    size: 19,
                    color: _batchMode ? _brandGreen : null,
                  ),
                  onPressed: () {
                    setState(() {
                      _batchMode = !_batchMode;
                      _selectedPaths.clear();
                    });
                  },
                ),
                PopupMenuButton<_HomeSortOption>(
                  tooltip: '排序方式',
                  initialValue: _sortOption,
                  onSelected: (val) => setState(() => _sortOption = val),
                  itemBuilder: (ctx) => [
                    for (final opt in _HomeSortOption.values)
                      PopupMenuItem(
                        value: opt,
                        child: Row(
                          children: [
                            Icon(
                              _sortOption == opt
                                  ? Icons.check_rounded
                                  : null,
                              size: 15,
                              color: _brandGreen,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              opt.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.tune_rounded, size: 15),
                        if (!isCompact) ...[
                          const SizedBox(width: 4),
                          Text(
                            _sortOption.label,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabItem(
    _HomeCategoryTab tab,
    String title,
    bool isDark,
  ) {
    final active = _categoryTab == tab;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _categoryTab = tab),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active
                    ? _brandGreen
                    : (isDark ? Colors.white60 : const Color(0xFF6B7280)),
              ),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 2.5,
              width: active ? 26 : 0,
              decoration: BoxDecoration(
                color: _brandGreen,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // 5.7 批量多选操作工具栏
  // ===========================================================================
  Widget _buildBatchActionBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: _brandGreen.withValues(alpha: 0.12),
      child: Row(
        children: [
          Text(
            '已选择 ${_selectedPaths.length} 个项目',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: _brandGreen,
            ),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: () {
              setState(() {
                for (final e in _entities) {
                  if (e is FileSystemFile<NoteFile>) {
                    _selectedPaths.add(e.path);
                  }
                }
              });
            },
            icon: const Icon(Icons.checklist_rounded, size: 16),
            label: const Text('全选', style: TextStyle(fontSize: 12)),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _selectedPaths.isEmpty
                ? null
                : () async {
                    for (final p in _selectedPaths) {
                      await _duplicateNotebook(p);
                    }
                    setState(() {
                      _selectedPaths.clear();
                      _batchMode = false;
                    });
                  },
            icon: const Icon(Icons.copy_rounded, size: 16),
            label: const Text('创建副本', style: TextStyle(fontSize: 12)),
          ),
          TextButton.icon(
            onPressed: _selectedPaths.isEmpty
                ? null
                : () {
                    setState(() {
                      for (final p in _selectedPaths) {
                        _metaByPath[p] = _metaFor(p).copyWith(inTrash: true);
                      }
                      _selectedPaths.clear();
                      _batchMode = false;
                    });
                    _savePrefs();
                  },
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 16,
              color: Colors.redAccent,
            ),
            label: const Text(
              '移至回收站',
              style: TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 书架主区域：文件夹卡片与竖版笔记本封面网格
  // ===========================================================================
  Widget _buildBookshelfBody(bool isDark) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final query = _searchController.text.trim().toLowerCase();
    final filtered = <FileSystemEntity<NoteFile>>[];

    for (final entity in _entities) {
      final meta = _metaFor(entity.path);
      if (_navSection == _HomeNavSection.trash) {
        if (!meta.inTrash) continue;
      } else {
        if (meta.inTrash) continue;
      }
      if (_navSection == _HomeNavSection.favorites && !meta.isFavorite) {
        continue;
      }
      if (_navSection == _HomeNavSection.infinite && meta.mode != 'infinite') {
        continue;
      }
      if (_activeLabelFilterId != null &&
          !meta.labelIds.contains(_activeLabelFilterId)) {
        continue;
      }
      if (entity is FileSystemDirectory<NoteFile>) {
        if (_categoryTab == _HomeCategoryTab.pdf ||
            _categoryTab == _HomeCategoryTab.note) {
          continue;
        }
      } else if (entity is FileSystemFile<NoteFile>) {
        if (_categoryTab == _HomeCategoryTab.folder) continue;
        if (_categoryTab == _HomeCategoryTab.pdf && meta.mode != 'pdf') {
          continue;
        }
        if (_categoryTab == _HomeCategoryTab.note && meta.mode == 'pdf') {
          continue;
        }
      }
      final displayName = entity.fileNameWithoutExtension.toLowerCase();
      if (query.isNotEmpty && !displayName.contains(query)) {
        continue;
      }
      filtered.add(entity);
    }

    // 排序：文件夹置顶，其余按所选规则（时间排序使用笔记本内真实时间戳）
    filtered.sort((a, b) {
      if (a is FileSystemDirectory && b is! FileSystemDirectory) return -1;
      if (a is! FileSystemDirectory && b is FileSystemDirectory) return 1;
      final nameA = a.fileNameWithoutExtension.toLowerCase();
      final nameB = b.fileNameWithoutExtension.toLowerCase();
      final timeA = _timeCache[a.path];
      final timeB = _timeCache[b.path];
      switch (_sortOption) {
        case _HomeSortOption.nameAsc:
          return nameA.compareTo(nameB);
        case _HomeSortOption.nameDesc:
          return nameB.compareTo(nameA);
        case _HomeSortOption.createdAsc:
        case _HomeSortOption.modifiedAsc:
          if (timeA == null || timeB == null) {
            return nameA.compareTo(nameB);
          }
          return timeA.compareTo(timeB);
        case _HomeSortOption.createdDesc:
        case _HomeSortOption.modifiedDesc:
          if (timeA == null || timeB == null) {
            return nameB.compareTo(nameA);
          }
          return timeB.compareTo(timeA);
      }
    });

    const quickActionHeader = SizedBox.shrink();

    if (filtered.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          quickActionHeader,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _navSection == _HomeNavSection.trash
                        ? Icons.delete_outline_rounded
                        : Icons.menu_book_outlined,
                    size: 64,
                    color: Colors.grey.withValues(alpha: 0.5),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _navSection == _HomeNavSection.trash
                        ? '回收站为空（删除的笔记可在 30 天内恢复）'
                        : '暂无笔记，点击右下角 + 新建第一篇手写笔记',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            quickActionHeader,
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 110),
                gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: _isGridView ? 200 : 560,
                  mainAxisSpacing: _isGridView ? 24 : 14,
                  crossAxisSpacing: 24,
                  childAspectRatio: _isGridView ? 0.68 : 2.6,
                ),
                itemCount: filtered.length,
                itemBuilder: (ctx, index) {
                  final item = filtered[index];
                  if (item is FileSystemDirectory<NoteFile>) {
                    return _buildFolderCard(item, isDark);
                  } else if (item is FileSystemFile<NoteFile>) {
                    return _buildNotebookCard(item, isDark);
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
        // D19 拖文档到屏幕右侧边缘 = 进入分屏视图阅读
        if (_draggingNotebookPath != null)
          Positioned(
            right: 12,
            top: 24,
            bottom: 110,
            width: 112,
            child: DragTarget<String>(
              onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
              onAcceptWithDetails: (details) {
                final path = details.data;
                setState(() => _draggingNotebookPath = null);
                final otherFiles = _entities
                    .whereType<FileSystemFile<NoteFile>>()
                    .where((e) => e.path != path && !_metaFor(e.path).inTrash)
                    .toList();
                final primaryPath = otherFiles.isNotEmpty ? otherFiles.first.path : path;
                MumuSplitLaunchQueue.requestOpenInSplit(
                  secondaryPath: path,
                  vertical: true,
                );
                _openNotebookPath(primaryPath);
              },
              builder: (ctx, candidate, _) {
                final hovering = candidate.isNotEmpty;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    color: hovering
                        ? _brandGreen.withValues(alpha: 0.26)
                        : _brandGreen.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: hovering
                          ? _brandGreen
                          : _brandGreen.withValues(alpha: 0.45),
                      width: hovering ? 2.4 : 1.4,
                    ),
                  ),
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.vertical_split_rounded,
                        size: 30,
                        color: hovering ? _brandGreen : Colors.blueGrey,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "拖到此处\n分屏打开",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : const Color(0xFF1E293B),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildQuickActionCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.48),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: _brandGreen.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 17, color: _brandGreen),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '· $subtitle',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _moveNotebookIntoFolder(
    String sourceFilePath,
    String targetFolderPath,
  ) async {
    final fileName = sourceFilePath.split('/').where((s) => s.isNotEmpty).last;
    final destPath = targetFolderPath.isEmpty
        ? fileName
        : '$targetFolderPath/$fileName';
    if (destPath == sourceFilePath) return;
    final moved = await _documentSystem.moveAsset(sourceFilePath, destPath);
    if (moved != null) {
      final oldMeta = _metaByPath.remove(sourceFilePath);
      if (oldMeta != null) {
        _metaByPath[moved.path] = oldMeta;
      }
      await _savePrefs();
      await _reloadFiles();
    }
  }

  Future<void> _mergeTwoNotebooksIntoNewFolder(
    String firstFilePath,
    String secondFilePath,
  ) async {
    if (firstFilePath == secondFilePath) return;
    final folderName = "合并文件夹_${DateTime.now().millisecondsSinceEpoch % 10000}";
    final folderPath = _currentFolder.isEmpty
        ? folderName
        : "$_currentFolder/$folderName";
    final createdDir = await _documentSystem.createDirectory(folderPath);
    _folderColors[createdDir.path] = _eightTagColors[4];
    await _moveNotebookIntoFolder(firstFilePath, createdDir.path);
    await _moveNotebookIntoFolder(secondFilePath, createdDir.path);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("已自动创建「$folderName」并归档 2 本笔记（D19 拖文档到文档自动建夹）"),
          duration: const Duration(milliseconds: 1800),
        ),
      );
    }
  }

  Widget _buildFolderCard(FileSystemDirectory<NoteFile> dir, bool isDark) {
    final folderName = dir.path.split('/').where((s) => s.isNotEmpty).last;
    final folderColor = Color(
      _folderColors[dir.path] ?? _brandGreen.toARGB32(),
    );

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data.isNotEmpty && details.data != dir.path,
      onAcceptWithDetails: (details) async {
        setState(() => _draggingNotebookPath = null);
        await _moveNotebookIntoFolder(details.data, dir.path);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("已将笔记移入文件夹「$folderName」"),
              duration: const Duration(milliseconds: 1400),
            ),
          );
        }
      },
      builder: (ctx, candidate, _) {
        final isHovering = candidate.isNotEmpty;
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () {
            setState(() => _currentFolder = dir.path);
            _reloadFiles();
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: isHovering ? const EdgeInsets.all(3) : EdgeInsets.zero,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: isHovering
                  ? Border.all(color: _brandGreen, width: 2.2)
                  : null,
            ),
            child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: folderColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: folderColor.withValues(alpha: 0.38),
                  width: 1.2,
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Icon(
                      Icons.folder_rounded,
                      size: 72,
                      color: folderColor,
                    ),
                  ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: PopupMenuButton<String>(
                      icon: const Icon(
                        Icons.drag_indicator_rounded,
                        size: 16,
                      ),
                      onSelected: (action) async {
                        if (action == 'color') {
                          _showChangeFolderColorDialog(dir.path, isDark);
                        } else if (action == 'delete') {
                          await _documentSystem.deleteAsset(dir.path);
                          _reloadFiles();
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'color', child: Text('更改文件夹封面颜色')),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(
                            '删除文件夹',
                            style: TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            folderName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white : const Color(0xFF111827),
            ),
          ),
          Text(
            isHovering
                ? '松手移入文件夹'
                : '${dir.assets.length} 项 · 文件夹',
            style: TextStyle(
              fontSize: 11,
              fontWeight: isHovering ? FontWeight.w700 : FontWeight.normal,
              color: isHovering
                  ? _brandGreen
                  : (isDark ? Colors.white54 : const Color(0xFF6B7280)),
            ),
          ),
        ],
      ),
          ),
        );
      },
    );
  }

  Widget _buildNotebookCard(FileSystemFile<NoteFile> file, bool isDark) {
    final meta = _metaFor(file.path);
    final selected = _selectedPaths.contains(file.path);
    NoteData? noteData;
    int pageCount = 1;
    String displayName = file.fileNameWithoutExtension;
    String dateText = '刚刚更新';
    try {
      if (file.data != null) {
        noteData = NoteData.fromData(file.data!.data);
        final pages = noteData.getPages();
        final firstPage = pages.isNotEmpty ? noteData.getPage(pages.first) : null;
        final areaCount = firstPage?.areas.where((a) => a.width > 80 && a.height > 80).length ?? 0;
        pageCount = math.max(pages.isEmpty ? 1 : pages.length, areaCount);
        final fileMeta = noteData.getMetadata();
        if (fileMeta != null && fileMeta.name.trim().isNotEmpty) {
          displayName = fileMeta.name.trim();
        }
        if (fileMeta?.updatedAt != null) {
          final dt = fileMeta!.updatedAt!.toLocal();
          dateText =
              '${(dt.year % 100).toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}';
        }
      }
    } catch (_) {}

    Widget buildCardBody({bool isMergeHover = false}) {
      return GestureDetector(
        onTap: () {
          if (_batchMode) {
            setState(() {
              if (selected) {
                _selectedPaths.remove(file.path);
              } else {
                _selectedPaths.add(file.path);
              }
            });
            return;
          }
          if (meta.inTrash) {
            _showTrashItemDialog(file.path, displayName, isDark);
            return;
          }
          _openNotebookPath(file.path);
        },
        onDoubleTap: () {
          setState(() {
            _batchMode = true;
            _selectedPaths.add(file.path);
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: isMergeHover ? const EdgeInsets.all(3) : EdgeInsets.zero,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: isMergeHover
                ? Border.all(color: const Color(0xFF10B981), width: 2.4)
                : null,
          ),
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 笔记本竖向封面缩略图
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected
                      ? _brandGreen
                      : (isDark
                            ? const Color(0xFF334155)
                            : const Color(0xFFE2E8F0)),
                  width: selected ? 2.4 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.07),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: _MumuBookCoverPainter(
                        coverStyle: meta.coverStyle,
                        coverColor: Color(meta.coverColor),
                        paperColor: Color(meta.paperColor),
                        templateId: meta.templateId,
                        title: displayName,
                      ),
                    ),
                    // 左上角模式徽标（A4 标准 / 无限画布 / PDF + 云同步绿点）
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.58),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: Color(0xFF10B981),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              meta.mode == 'infinite'
                                  ? '无限画布'
                                  : (meta.mode == 'pdf' ? 'PDF' : meta.spec),
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 右上角爱心收藏图标 (5.4 Favorites)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () {
                          setState(() {
                            _metaByPath[file.path] = meta.copyWith(
                              isFavorite: !meta.isFavorite,
                            );
                          });
                          _savePrefs();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.85),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            meta.isFavorite
                                ? Icons.star_rounded
                                : Icons.star_border_rounded,
                            size: 14,
                            color: meta.isFavorite
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ),
                    if (_batchMode)
                      Positioned(
                        left: 8,
                        bottom: 8,
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: _brandGreen,
                          size: 22,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 标题与 ··· 上下文菜单
          Row(
            children: [
              Expanded(
                child: Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : const Color(0xFF1F2937),
                  ),
                ),
              ),
              Builder(
                builder: (btnCtx) => InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => _showDocumentContextMenu(
                    btnCtx,
                    file,
                    displayName,
                    pageCount,
                    dateText,
                    isDark,
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 15,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          // 页数、日期与彩色标签圆点
          Row(
            children: [
              Text(
                meta.mode == 'infinite'
                    ? '无界画布  $dateText'
                    : '$pageCount 页  $dateText',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark ? Colors.white54 : const Color(0xFF6B7280),
                ),
              ),
              const Spacer(),
              for (final lid in meta.labelIds.take(3))
                Builder(
                  builder: (_) {
                    final lbl = _labels
                        .where((l) => l.id == lid)
                        .firstOrNull;
                    if (lbl == null) return const SizedBox.shrink();
                    return Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(left: 3),
                      decoration: BoxDecoration(
                        color: Color(lbl.colorValue),
                        shape: BoxShape.circle,
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
          ),
        ),
      );
    }

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) =>
          details.data.isNotEmpty && details.data != file.path && !meta.inTrash,
      onAcceptWithDetails: (details) async {
        setState(() => _draggingNotebookPath = null);
        await _mergeTwoNotebooksIntoNewFolder(details.data, file.path);
      },
      builder: (ctx, candidate, _) {
        final isMergeHover = candidate.isNotEmpty;
        final cardWidget = buildCardBody(isMergeHover: isMergeHover);
        if (meta.inTrash || _batchMode) return cardWidget;
        return LongPressDraggable<String>(
          data: file.path,
          delay: const Duration(milliseconds: 400),
          onDragStarted: () {
            setState(() => _draggingNotebookPath = file.path);
          },
          onDragEnd: (_) {
            if (_draggingNotebookPath != null) {
              setState(() => _draggingNotebookPath = null);
            }
          },
          onDraggableCanceled: (_, _) {
            if (_draggingNotebookPath != null) {
              setState(() => _draggingNotebookPath = null);
            }
          },
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: 145,
              height: 205,
              child: Opacity(opacity: 0.88, child: cardWidget),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: cardWidget),
          child: cardWidget,
        );
      },
    );
  }

  // ===========================================================================
  // 1.1 右下角 `+` 新建弹出菜单
  // ===========================================================================
  void _showPlusNewMenu(BuildContext fabContext, bool isDark) {
    final box = fabContext.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = (box != null && overlay != null)
        ? RelativeRect.fromRect(
            Rect.fromPoints(
              box.localToGlobal(const Offset(-200, -320), ancestor: overlay),
              box.localToGlobal(Offset.zero, ancestor: overlay),
            ),
            Offset.zero & overlay.size,
          )
        : const RelativeRect.fromLTRB(200, 200, 24, 90);

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 12,
      items: [
        _buildPlusMenuItem(
          'standard',
          Icons.description_outlined,
          '标准笔记',
          subtitle: 'A4/A3/A5/平板多页结构化笔记',
        ),
        _buildPlusMenuItem(
          'infinite',
          Icons.open_with_rounded,
          '无限画布',
          subtitle: '四向无界自由延展导图白板',
        ),
        _buildPlusMenuItem(
          'folder',
          Icons.create_new_folder_outlined,
          '新建文件夹',
        ),
        const PopupMenuDivider(),
        _buildPlusMenuItem(
          'import_pdf',
          Icons.picture_as_pdf_outlined,
          '导入本地 PDF',
          subtitle: '从设备存储选择 PDF 文件进行多页手写批注',
          iconColor: const Color(0xFFEF4444),
        ),
        _buildPlusMenuItem(
          'sample_pdf',
          Icons.menu_book_rounded,
          '新建多页 PDF 讲义批注本',
          subtitle: '无需本地文件，一键生成多页 PDF 批注笔记',
          iconColor: const Color(0xFFDC2626),
        ),
        _buildPlusMenuItem(
          'import_doc',
          Icons.description_outlined,
          '导入文档（BFLY / MD / TXT）',
          iconColor: _brandGreen,
        ),
        _buildPlusMenuItem(
          'import_image',
          Icons.image_outlined,
          '添加图片',
          iconColor: const Color(0xFF10B981),
        ),
        _buildPlusMenuItem(
          'scan_text',
          Icons.document_scanner_outlined,
          '扫描 / 拍照图片批注',
          subtitle: '把扫描件或照片作为底图直接手写批注',
          iconColor: const Color(0xFFF59E0B),
        ),
      ],
    ).then((selected) async {
      if (selected == null || !mounted) return;
      switch (selected) {
        case 'standard':
          _showSelectTemplateModal(initialInfinite: false, isDark: isDark);
        case 'infinite':
          _showSelectTemplateModal(initialInfinite: true, isDark: isDark);
        case 'folder':
          _showCreateFolderDialog(isDark);
        case 'import_pdf':
          await _handleImportExternalFile(isPdf: true);
        case 'sample_pdf':
          await _createSamplePdfLectureNote();
        case 'import_doc':
          await _handleImportExternalFile(isPdf: false);
        case 'import_image':
          await _handleImportImageAsNote();
        case 'scan_text':
          await _handleImportImageAsNote();
      }
    });
  }

  PopupMenuItem<String> _buildPlusMenuItem(
    String value,
    IconData icon,
    String title, {
    String? subtitle,
    Color? iconColor,
  }) {
    return PopupMenuItem<String>(
      value: value,
      child: SizedBox(
        width: 248,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: iconColor),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // 1.1 / 1.5 / 1.7「选择模板」全屏弹窗
  // ===========================================================================
  void _showSelectTemplateModal({
    required bool initialInfinite,
    required bool isDark,
  }) {
    bool isInfinite = initialInfinite;
    bool isLandscape = false;
    bool editingCover = false; // false = Paper tab, true = Cover tab
    String selectedSpec = 'A4';
    int selectedPaperColor = 0xFFFEF9EF;
    String selectedTemplateId = _starredQuickTemplateId;
    String selectedCoverStyle = 'fighter_sketch';
    int selectedCoverColor = 0xFF2F7D6E;
    double customW = 840;
    double customH = 1188;
    final titleCtrl = TextEditingController();

    const paperColors = [
      (0xFFFEF9EF, '护眼米黄'),
      (0xFFFFFFFF, '纯白纸'),
      (0xFFECFDF5, '豆沙绿'),
      (0xFFFDF2F8, '樱花粉'),
      (0xFFF0F9FF, '晴空蓝'),
      (0xFF1E293B, '暗夜黑'),
    ];

    const paperTemplates = [
      ('blank', '空白', '基础'),
      ('ruled', '横线', '基础'),
      ('grid', '方格', '基础'),
      ('dots', '点阵', '基础'),
      ('cornell', '康奈尔', '双栏与学习'),
      ('legal', '法务线', '双栏与学习'),
      ('2col_lined', '双栏横线', '双栏与学习'),
      ('2col_plain', '双栏空白', '双栏与学习'),
      ('2col_grid', '双栏方格', '双栏与学习'),
      ('daily', '日程时间轴', '规划与专业'),
      ('weekly', '周计划看板', '规划与专业'),
      ('monthly', '月计划矩阵', '规划与专业'),
      ('music', '五线谱', '规划与专业'),
    ];

    const coverPresets = [
      ('blank', '无封面', 0xFFFFFFFF),
      ('fighter_sketch', '素描手绘', 0xFF2F7D6E),
      ('geometry_modern', '几何艺术', 0xFF059669),
      ('morandi_olive', '莫兰迪橄榄', 0xFFA8794B),
      ('sunset_coral', '落日珊瑚', 0xFFDC2626),
      ('royal_indigo', '学术深蓝', 0xFF1E3A8A),
      ('vintage_kraft', '复古牛皮纸', 0xFFB45309),
      ('night_slate', '极客暗夜', 0xFF0F172A),
    ];

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Dialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 20,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880, maxHeight: 740),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 顶部栏：取消、选择模板、创建按钮
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        OutlinedButton(
                          onPressed: () => Navigator.pop(ctx),
                          style: OutlinedButton.styleFrom(
                            shape: const StadiumBorder(),
                          ),
                          child: const Text('取消'),
                        ),
                        const Flexible(
                          child: Text(
                            '选择模板',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: _brandGreen,
                            shape: const StadiumBorder(),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 10,
                            ),
                          ),
                          onPressed: () async {
                            final now = DateTime.now();
                            final fallbackTitle = isInfinite
                                ? '无限画布_${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}'
                                : '标准笔记_${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}';
                            final title = _sanitizeSafeFileName(
                              titleCtrl.text.trim().isEmpty
                                  ? fallbackTitle
                                  : titleCtrl.text.trim(),
                            );
                            final doc = _buildMumuDocument(
                              title: title,
                              isInfinite: isInfinite,
                              spec: selectedSpec,
                              isLandscape: isLandscape,
                              paperColorValue: selectedPaperColor,
                              templateId: selectedTemplateId,
                              customWidth: customW,
                              customHeight: customH,
                            );
                            if (ctx.mounted) {
                              Navigator.pop(ctx);
                            }
                            try {
                              final noteFile = doc.toFile();
                              final created = await _documentSystem
                                  .createFileWithName(
                                    directory: _currentFolder,
                                    name: title,
                                    suffix: '.bfly',
                                    noteFile,
                                  );
                              _metaByPath[created.path] = _MumuNotebookMeta(
                                mode: isInfinite ? 'infinite' : 'standard',
                                spec: isInfinite ? 'Infinite' : selectedSpec,
                                templateId: selectedTemplateId,
                                paperColor: selectedPaperColor,
                                coverStyle: selectedCoverStyle,
                                coverColor: selectedCoverColor,
                              );
                              await _savePrefs();
                              await _reloadFiles();
                              if (!mounted) return;
                              await _openNotebookPath(
                                created.path,
                                created.data ?? noteFile,
                              );
                            } catch (_) {
                              if (!mounted) return;
                              await GoRouter.of(
                                context,
                              ).pushNamed('new', extra: doc);
                              if (mounted) await _reloadFiles();
                            }
                          },
                          child: const Text(
                            '创建',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // 上半部：封面与纸张并排实时预览
                    SizedBox(
                      height: 185,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // 左侧：封面预览卡片
                          if (!isInfinite) ...[
                            GestureDetector(
                              onTap: () =>
                                  setModalState(() => editingCover = true),
                              child: Column(
                                children: [
                                  Text(
                                    '封面',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: editingCover
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: editingCover
                                          ? _brandGreen
                                          : Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Expanded(
                                    child: Container(
                                      width: isLandscape ? 165 : 118,
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: editingCover
                                            ? _brandGreen.withValues(
                                                alpha: 0.10,
                                              )
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: editingCover
                                              ? _brandGreen
                                              : Colors.grey.withValues(
                                                  alpha: 0.3,
                                                ),
                                          width: editingCover ? 2 : 1,
                                        ),
                                      ),
                                      child: CustomPaint(
                                        painter: _MumuBookCoverPainter(
                                          coverStyle: selectedCoverStyle,
                                          coverColor: Color(selectedCoverColor),
                                          paperColor: Color(selectedPaperColor),
                                          templateId: selectedTemplateId,
                                          title: titleCtrl.text.trim().isEmpty
                                              ? '木木笔记'
                                              : titleCtrl.text.trim(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 28),
                          ],
                          // 右侧：纸张预览卡片
                          GestureDetector(
                            onTap: () =>
                                setModalState(() => editingCover = false),
                            child: Column(
                              children: [
                                Text(
                                  '纸张',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: !editingCover
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: !editingCover
                                        ? _brandGreen
                                        : Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: Container(
                                    width: isLandscape ? 165 : 118,
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: !editingCover
                                          ? _brandGreen.withValues(
                                              alpha: 0.10,
                                            )
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: !editingCover
                                            ? _brandGreen
                                            : Colors.grey.withValues(
                                                alpha: 0.3,
                                              ),
                                        width: !editingCover ? 2 : 1,
                                      ),
                                    ),
                                    child: CustomPaint(
                                      painter: _MumuPaperPreviewPainter(
                                        paperColor: Color(selectedPaperColor),
                                        templateId: selectedTemplateId,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 中部控制栏：竖版/横版切换 + Spec 下拉 + Infinite 切换 + 标题输入框
                    // 窄屏（平板竖屏/手机）自动折行，避免按钮被裁到弹窗外
                    LayoutBuilder(
                      builder: (context, controlConstraints) {
                        final narrow = controlConstraints.maxWidth < 720;
                        final orientationButtons = Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton.outlined(
                              tooltip: '竖向纸张',
                              isSelected: !isLandscape,
                              onPressed: () =>
                                  setModalState(() => isLandscape = false),
                              icon: const Icon(
                                Icons.crop_portrait_rounded,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton.outlined(
                              tooltip: '横向纸张',
                              isSelected: isLandscape,
                              onPressed: () =>
                                  setModalState(() => isLandscape = true),
                              icon: Transform.rotate(
                                angle: math.pi / 2,
                                child: const Icon(
                                  Icons.crop_portrait_rounded,
                                  size: 16,
                                ),
                              ),
                            ),
                          ],
                        );
                        final specSelector = Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: Colors.grey.withValues(alpha: 0.4),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                '规格：',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  value: isInfinite ? 'A4' : selectedSpec,
                                  isDense: true,
                                  items: [
                                    DropdownMenuItem(
                                      value: 'A4',
                                      child: Text(
                                        narrow ? 'A4' : 'A4 (210x297mm)',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'A3',
                                      child: Text(
                                        narrow ? 'A3' : 'A3 (297x420mm)',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'A5',
                                      child: Text(
                                        narrow ? 'A5' : 'A5 (148x210mm)',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Letter',
                                      child: Text(
                                        narrow
                                            ? 'Letter'
                                            : 'Letter (216x279mm)',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'B5',
                                      child: Text(
                                        narrow ? 'B5' : 'B5 (176x250mm)',
                                      ),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Tablet',
                                      child: Text(narrow ? '平板' : '平板'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Phone',
                                      child: Text(narrow ? '手机' : '手机'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Custom',
                                      child: Text(
                                        narrow ? '自定义' : '自定义尺寸 (200~5000pt)',
                                      ),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v == null) return;
                                    setModalState(() {
                                      isInfinite = false;
                                      selectedSpec = v;
                                    });
                                  },
                                ),
                              ),
                            ],
                          ),
                        );
                        final infiniteChip = ChoiceChip(
                          label: const Text(
                            '无限画布',
                            style: TextStyle(fontSize: 11.5),
                          ),
                          selected: isInfinite,
                          selectedColor: _brandGreen,
                          labelStyle: TextStyle(
                            color: isInfinite ? Colors.white : null,
                          ),
                          onSelected: (val) => setModalState(() {
                            isInfinite = val;
                            if (val) editingCover = false;
                          }),
                        );
                        final titleField = SizedBox(
                          height: 38,
                          child: TextField(
                            controller: titleCtrl,
                            onChanged: (_) => setModalState(() {}),
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: '请输入笔记本标题...',
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 0,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        );

                        if (narrow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  orientationButtons,
                                  const Spacer(),
                                  Flexible(
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      alignment: Alignment.centerRight,
                                      child: infiniteChip,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  specSelector,
                                  const SizedBox(width: 8),
                                  Expanded(child: titleField),
                                ],
                              ),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            orientationButtons,
                            const SizedBox(width: 12),
                            specSelector,
                            const SizedBox(width: 8),
                            infiniteChip,
                            const SizedBox(width: 12),
                            Expanded(child: titleField),
                          ],
                        );
                      },
                    ),

                    // 纸张颜色选择器（仅在纸张模式下展示）
                    if (!editingCover)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                '纸张颜色: ',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              for (final (colVal, colName) in paperColors)
                                Tooltip(
                                  message: colName,
                                  child: InkWell(
                                    onTap: () => setModalState(
                                      () => selectedPaperColor = colVal,
                                    ),
                                    child: Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        color: Color(colVal),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: selectedPaperColor == colVal
                                              ? _brandGreen
                                              : Colors.grey.withValues(
                                                  alpha: 0.5,
                                                ),
                                          width: selectedPaperColor == colVal
                                              ? 2.4
                                              : 1,
                                        ),
                                      ),
                                      child: selectedPaperColor == colVal
                                          ? Icon(
                                              Icons.check_rounded,
                                              size: 13,
                                              color: colVal == 0xFF1E293B
                                                  ? Colors.white
                                                  : _brandGreen,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '💡 点击模板右上角 ★ 可设为「快速笔记」默认模板',
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    const SizedBox(height: 10),

                    // 下半部：模板网格 或 封面网格
                    Expanded(
                      child: editingCover
                          ? GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 145,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 0.75,
                                  ),
                              itemCount: coverPresets.length,
                              itemBuilder: (_, idx) {
                                final (cid, cname, ccol) = coverPresets[idx];
                                final isSel = selectedCoverStyle == cid;
                                return GestureDetector(
                                  onTap: () => setModalState(() {
                                    selectedCoverStyle = cid;
                                    selectedCoverColor = ccol;
                                  }),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: Container(
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              10,
                                            ),
                                            border: Border.all(
                                              color: isSel
                                                  ? _brandGreen
                                                  : Colors.grey.withValues(
                                                      alpha: 0.3,
                                                    ),
                                              width: isSel ? 2.4 : 1,
                                            ),
                                          ),
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                            child: CustomPaint(
                                              size: Size.infinite,
                                              painter: _MumuBookCoverPainter(
                                                coverStyle: cid,
                                                coverColor: Color(ccol),
                                                paperColor: Color(
                                                  selectedPaperColor,
                                                ),
                                                templateId: selectedTemplateId,
                                                title: cname.split(' ').first,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        cname,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: isSel
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: isSel
                                              ? _brandGreen
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            )
                          : GridView.builder(
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 145,
                                    mainAxisSpacing: 12,
                                    crossAxisSpacing: 12,
                                    childAspectRatio: 0.76,
                                  ),
                              itemCount: paperTemplates.length,
                              itemBuilder: (_, idx) {
                                final (tid, tname, _) = paperTemplates[idx];
                                final isSel = selectedTemplateId == tid;
                                final isStarred =
                                    _starredQuickTemplateId == tid;
                                return GestureDetector(
                                  onTap: () => setModalState(
                                    () => selectedTemplateId = tid,
                                  ),
                                  child: Column(
                                    children: [
                                      Expanded(
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            Container(
                                              decoration: BoxDecoration(
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isSel
                                                      ? _brandGreen
                                                      : Colors.grey.withValues(
                                                          alpha: 0.3,
                                                        ),
                                                  width: isSel ? 2.4 : 1,
                                                ),
                                              ),
                                              child: ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                child: CustomPaint(
                                                  painter:
                                                      _MumuPaperPreviewPainter(
                                                        paperColor: Color(
                                                          selectedPaperColor,
                                                        ),
                                                        templateId: tid,
                                                      ),
                                                ),
                                              ),
                                            ),
                                            // 右上角星标（设为快速笔记默认模板，PDF 1.4）
                                            Positioned(
                                              right: 6,
                                              top: 6,
                                              child: InkWell(
                                                onTap: () {
                                                  setModalState(() {
                                                    _starredQuickTemplateId =
                                                        tid;
                                                  });
                                                  _savePrefs();
                                                },
                                                child: Icon(
                                                  isStarred
                                                      ? Icons.star_rounded
                                                      : Icons.star_border_rounded,
                                                  size: 16,
                                                  color: isStarred
                                                      ? const Color(0xFFF59E0B)
                                                      : Colors.grey,
                                                ),
                                              ),
                                            ),
                                            if (isSel)
                                              const Positioned(
                                                left: 0,
                                                right: 0,
                                                bottom: 8,
                                                child: Center(
                                                  child: CircleAvatar(
                                                    radius: 10,
                                                    backgroundColor:
                                                        _brandGreen,
                                                    child: Icon(
                                                      Icons.check_rounded,
                                                      size: 12,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        tname,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight: isSel
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: isSel
                                              ? _brandGreen
                                              : null,
                                        ),
                                      ),
                                    ],
                                  ),
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

  // ===========================================================================
  // 5.2 文档上下文菜单
  // ===========================================================================
  void _showDocumentContextMenu(
    BuildContext btnCtx,
    FileSystemFile<NoteFile> file,
    String displayName,
    int pageCount,
    String dateText,
    bool isDark,
  ) {
    final meta = _metaFor(file.path);
    final box = btnCtx.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final pos = (box != null && overlay != null)
        ? RelativeRect.fromRect(
            Rect.fromPoints(
              box.localToGlobal(Offset.zero, ancestor: overlay),
              box.localToGlobal(
                box.size.bottomRight(Offset.zero),
                ancestor: overlay,
              ),
            ),
            Offset.zero & overlay.size,
          )
        : const RelativeRect.fromLTRB(200, 200, 100, 100);

    showMenu<String>(
      context: context,
      position: pos,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      items: [
        const PopupMenuItem(
          value: 'split_vertical',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.vertical_split_rounded, size: 18, color: _brandGreen),
            title: Text('垂直分屏打开（左右并排）'),
          ),
        ),
        const PopupMenuItem(
          value: 'split_horizontal',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.horizontal_split_rounded, size: 18, color: _brandGreen),
            title: Text('水平分屏打开（上下并排）'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'rename',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined, size: 18),
            title: Text('重命名'),
          ),
        ),
        const PopupMenuItem(
          value: 'labels',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.bookmark_border_rounded, size: 18),
            title: Text('添加标签'),
          ),
        ),
        const PopupMenuItem(
          value: 'duplicate',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.copy_rounded, size: 18),
            title: Text('创建副本'),
          ),
        ),
        const PopupMenuItem(
          value: 'info',
          child: ListTile(
            dense: true,
            leading: Icon(Icons.info_outline_rounded, size: 18),
            title: Text('文档信息与版本历史'),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'trash',
          child: ListTile(
            dense: true,
            leading: Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: Colors.redAccent,
            ),
            title: Text(
              '移至回收站',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ),
      ],
    ).then((action) async {
      if (action == null || !mounted) return;
      switch (action) {
        case 'split_vertical':
        case 'split_horizontal':
          final otherFiles = _entities
              .whereType<FileSystemFile<NoteFile>>()
              .where((e) => e.path != file.path && !_metaFor(e.path).inTrash)
              .toList();
          final primaryPath = otherFiles.isNotEmpty ? otherFiles.first.path : file.path;
          MumuSplitLaunchQueue.requestOpenInSplit(
            secondaryPath: file.path,
            vertical: action == 'split_vertical',
          );
          await _openNotebookPath(primaryPath);
        case 'rename':
          _showRenameDialog(file, displayName);
        case 'labels':
          _showAssignLabelsDialog(file.path, meta);
        case 'duplicate':
          await _duplicateNotebook(file.path);
          _reloadFiles();
        case 'info':
          _showDocumentInfoDialog(file, displayName, pageCount, dateText);
        case 'trash':
          setState(() {
            _metaByPath[file.path] = meta.copyWith(inTrash: true);
          });
          await _savePrefs();
      }
    });
  }

  Future<void> _duplicateNotebook(String path) async {
    try {
      final asset = await _documentSystem.getAsset(path, readData: true);
      if (asset is FileSystemFile<NoteFile> && asset.data != null) {
        final orig = NoteData.fromData(asset.data!.data);
        final copyName = '${orig.name} (副本)';
        final copyDoc = orig.setMetadata(
          (orig.getMetadata() ?? DocumentDefaults.createMetadata()).copyWith(
            name: copyName,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        final created = await _documentSystem.createFileWithName(
          directory: _currentFolder,
          name: copyName,
          suffix: '.bfly',
          copyDoc.toFile(),
        );
        _metaByPath[created.path] = _metaFor(path);
        await _savePrefs();
      }
    } catch (_) {}
  }

  void _showRenameDialog(FileSystemFile<NoteFile> file, String currentName) {
    final ctrl = TextEditingController(text: currentName);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名笔记本'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty && file.data != null) {
                final doc = NoteData.fromData(file.data!.data);
                final updated = doc.setMetadata(
                  (doc.getMetadata() ?? DocumentDefaults.createMetadata())
                      .copyWith(
                        name: newName,
                        updatedAt: DateTime.now().toUtc(),
                      ),
                );
                await _documentSystem.updateFile(file.path, updated.toFile());
              }
              if (ctx.mounted) Navigator.pop(ctx);
              _reloadFiles();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showAssignLabelsDialog(String path, _MumuNotebookMeta meta) {
    final selectedIds = Set<String>.from(meta.labelIds);
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('为笔记本添加彩色标签'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final lbl in _labels)
                  CheckboxListTile(
                    value: selectedIds.contains(lbl.id),
                    title: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: Color(lbl.colorValue),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(lbl.name),
                      ],
                    ),
                    onChanged: (v) {
                      setModal(() {
                        if (v == true) {
                          selectedIds.add(lbl.id);
                        } else {
                          selectedIds.remove(lbl.id);
                        }
                      });
                    },
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _metaByPath[path] = meta.copyWith(
                    labelIds: selectedIds.toList(),
                  );
                });
                _savePrefs();
                Navigator.pop(ctx);
              },
              child: const Text('应用标签'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDocumentInfoDialog(
    FileSystemFile<NoteFile> file,
    String displayName,
    int pageCount,
    String dateText,
  ) {
    final meta = _metaFor(file.path);
    final sizeKb = ((file.data?.data.length ?? 2048) / 1024).toStringAsFixed(1);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('文档信息与版本历史 · $displayName'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• 笔记本类型：${meta.mode == 'infinite' ? '无限画布' : '标准笔记 (${meta.spec})'}'),
            const SizedBox(height: 6),
            Text('• 总页数：$pageCount 页'),
            const SizedBox(height: 6),
            Text('• 存储体积：$sizeKb KB'),
            const SizedBox(height: 6),
            Text('• 最后修改：$dateText (自动保存已开启)'),
            const SizedBox(height: 6),
            Text('• 存储路径：${file.path}'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showTrashItemDialog(String path, String displayName, bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('回收站项目：$displayName'),
        content: const Text('你可以将此笔记本还原到原始文件夹，或将其从设备中彻底永久删除。'),
        actions: [
          TextButton(
            onPressed: () async {
              await _documentSystem.deleteAsset(path);
              _metaByPath.remove(path);
              await _savePrefs();
              if (ctx.mounted) Navigator.pop(ctx);
              _reloadFiles();
            },
            child: const Text(
              '永久删除',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
          FilledButton(
            onPressed: () {
              setState(() {
                _metaByPath[path] = _metaFor(path).copyWith(inTrash: false);
              });
              _savePrefs();
              Navigator.pop(ctx);
            },
            child: const Text('恢复到原位置'),
          ),
        ],
      ),
    );
  }

  void _showCreateFolderDialog(bool isDark) {
    final ctrl = TextEditingController();
    int chosenColor = _eightTagColors[4];
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('新建文件夹'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '输入文件夹名称（如：专业课笔记）'),
              ),
              const SizedBox(height: 14),
              const Text(
                '选择文件夹封面颜色：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (final c in _eightTagColors)
                    GestureDetector(
                      onTap: () => setModal(() => chosenColor = c),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(c),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: chosenColor == c
                                ? Colors.white
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = ctrl.text.trim();
                if (name.isNotEmpty) {
                  final folderPath = _currentFolder.isEmpty
                      ? name
                      : '$_currentFolder/$name';
                  final dir = await _documentSystem.createDirectory(folderPath);
                  _folderColors[dir.path] = chosenColor;
                  await _savePrefs();
                  _reloadFiles();
                }
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  void _showChangeFolderColorDialog(String dirPath, bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('更改文件夹封面颜色'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in _eightTagColors)
              InkWell(
                onTap: () {
                  setState(() => _folderColors[dirPath] = c);
                  _savePrefs();
                  Navigator.pop(ctx);
                },
                child: CircleAvatar(backgroundColor: Color(c), radius: 18),
              ),
          ],
        ),
      ),
    );
  }

  void _showCreateLabelDialog(bool isDark) {
    final ctrl = TextEditingController();
    int chosenColor = _eightTagColors[0];
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('新建标签'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(hintText: '输入标签名称（如：期末重点）'),
              ),
              const SizedBox(height: 14),
              const Text(
                '选择标签颜色（8 色标记系统）：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                children: [
                  for (final c in _eightTagColors)
                    GestureDetector(
                      onTap: () => setModal(() => chosenColor = c),
                      child: CircleAvatar(
                        backgroundColor: Color(c),
                        radius: 13,
                        child: chosenColor == c
                            ? const Icon(
                                Icons.check_rounded,
                                size: 13,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final name = ctrl.text.trim();
                if (name.isNotEmpty) {
                  setState(() {
                    _labels = [
                      ..._labels,
                      _MumuLabelItem(
                        id: 'lbl_${DateTime.now().millisecondsSinceEpoch}',
                        name: name,
                        colorValue: chosenColor,
                      ),
                    ];
                  });
                  _savePrefs();
                }
                Navigator.pop(ctx);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleImportExternalFile({required bool isPdf}) async {
    try {
      final (bytes, ext, pickedName) = await importFile(
        context,
        isPdf ? [AssetFileType.pdf] : null,
      );
      if (bytes == null || !mounted) {
        if (mounted && isPdf) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('未选择本地 PDF 文件，是否一键创建多页 PDF 讲义批注笔记本？'),
              action: SnackBarAction(
                label: '立即创建 PDF 讲义',
                onPressed: _createSamplePdfLectureNote,
              ),
              duration: const Duration(seconds: 4),
            ),
          );
        }
        return;
      }
      final cleanPickedName = _sanitizeSafeFileName(
        (pickedName == null || pickedName.trim().isEmpty)
            ? (isPdf ? 'PDF 讲义批注' : '导入的笔记')
            : pickedName,
      );
      final isPdfImport = isPdf || (ext?.toLowerCase() == 'pdf');
      NoteData? importedDocument;
      if (isPdfImport) {
        importedDocument = await _buildPdfNotebook(bytes, cleanPickedName);
      } else {
        final importService = ImportService(
          context,
          storage: context.read<SettingsCubit>().state.getDefaultRemote(),
          path: _currentFolder,
          useDefaultStorage: false,
        );
        final hostDoc = _buildMumuDocument(
          title: cleanPickedName,
          isInfinite: false,
          spec: 'A4',
          isLandscape: false,
          paperColorValue: 0xFFFFFFFF,
          templateId: 'blank',
        );
        final imported = await importService.load(
          type: (ext == null || ext.isEmpty) ? 'note' : ext,
          data: bytes,
          document: hostDoc,
          preserveEncrypted: true,
        );
        if (imported != null) importedDocument = await imported.export();
      }

      if (importedDocument != null && mounted) {
        var exported = importedDocument;
        final info = exported.getInfo() ?? DocumentDefaults.createInfo();
        exported = exported.setInfo(
          info.copyWith(
            tools: DocumentDefaults.createTools(const SRGBColor(0xFFFFFFFF)),
          ),
        );
        final docName = _sanitizeSafeFileName(
          (exported.name?.trim().isEmpty ?? true)
              ? cleanPickedName
              : exported.name!,
        );
        final noteFile = exported.toFile();
        final created = await _documentSystem.createFileWithName(
          directory: _currentFolder,
          name: docName,
          suffix: '.bfly',
          noteFile,
        );
        _metaByPath[created.path] = _MumuNotebookMeta(
          mode: isPdfImport ? 'pdf' : 'standard',
          spec: isPdfImport ? 'PDF' : 'A4',
          coverStyle: 'royal_indigo',
          coverColor: 0xFFDC2626,
          labelIds: const ['lbl_pdf'],
        );
        await _savePrefs();
        await _reloadFiles();
        if (mounted) {
          await _openNotebookPath(created.path, created.data ?? noteFile);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导入文件失败 ($e)，可点击右侧一键创建 PDF 讲义笔记本'),
            action: SnackBarAction(
              label: '创建 PDF 讲义',
              onPressed: _createSamplePdfLectureNote,
            ),
          ),
        );
      }
    }
  }

  Future<void> _createSamplePdfLectureNote() async {
    final now = DateTime.now();
    final title = _sanitizeSafeFileName(
      'PDF 文献精读讲义_${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}',
    );
    var doc = _buildMumuDocument(
      title: title,
      isInfinite: false,
      spec: 'A4',
      isLandscape: false,
      paperColorValue: 0xFFFFFFFF,
      templateId: 'ruled',
    );
    // 添加第 2 页与第 3 页作为跨页连续 PDF 讲义批注页
    final page2 = DocumentPage(
      layers: [
        DocumentLayer(id: createUniqueId(), name: '图层 1 · PDF 原文层'),
        DocumentLayer(id: createUniqueId(), name: '图层 2 · 手写批注层'),
      ],
      backgrounds: [
        Background.texture(
          texture: _createPatternTextureForTemplate('ruled', 0xFFFFFFFF),
        ),
      ],
      areas: const [
        Area(
          name: '第 2 页（PDF 讲义）',
          width: 840.0,
          height: 1188.0,
          position: math.Point<double>(0.0, 0.0),
        ),
      ],
    );
    (doc, _) = doc.addPage(page2, '第 2 页');
    final noteFile = doc.toFile();
    final created = await _documentSystem.createFileWithName(
      directory: _currentFolder,
      name: title,
      suffix: '.bfly',
      noteFile,
    );
    _metaByPath[created.path] = const _MumuNotebookMeta(
      mode: 'pdf',
      spec: 'PDF',
      coverStyle: 'royal_indigo',
      coverColor: 0xFFDC2626,
      labelIds: ['lbl_pdf'],
    );
    await _savePrefs();
    await _reloadFiles();
    if (mounted) {
      await _openNotebookPath(created.path, created.data ?? noteFile);
    }
  }

  Future<void> _handleImportImageAsNote() async {
    try {
      final (bytes, _, pickedName) = await importFile(
        context,
        [AssetFileType.image],
      );
      final now = DateTime.now();
      final title = _sanitizeSafeFileName(
        (pickedName != null && pickedName.trim().isNotEmpty)
            ? pickedName
            : '图片批注笔记_${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}',
      );
      var doc = _buildMumuDocument(
        title: title,
        isInfinite: false,
        spec: 'A4',
        isLandscape: false,
        paperColorValue: 0xFFFFFFFF,
        templateId: 'blank',
      );
      if (bytes != null && mounted) {
        final importService = ImportService(
          context,
          storage: context.read<SettingsCubit>().state.getDefaultRemote(),
          path: _currentFolder,
          useDefaultStorage: false,
        );
        final res = await importService.import(
          AssetFileType.image,
          bytes,
          document: doc,
          position: const Offset(60, 60),
          advanced: false,
        );
        if (res != null) {
          doc = await res.export();
        }
      }
      final noteFile = doc.toFile();
      final created = await _documentSystem.createFileWithName(
        directory: _currentFolder,
        name: title,
        suffix: '.bfly',
        noteFile,
      );
      _metaByPath[created.path] = const _MumuNotebookMeta(
        mode: 'standard',
        spec: 'A4',
        templateId: 'blank',
        paperColor: 0xFFFFFFFF,
        coverStyle: 'geometry_modern',
        coverColor: 0xFF10B981,
      );
      await _savePrefs();
      await _reloadFiles();
      if (mounted) {
        await _openNotebookPath(created.path, created.data ?? noteFile);
      }
    } catch (_) {}
  }

  // ===========================================================================
  // 6.1 素材中心 弹窗（包含模板、贴纸、字体、色彩集 4 个标签页）
  // ===========================================================================
  void _showMaterialCenterModal(bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => DefaultTabController(
        length: 4,
        child: Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 740, maxHeight: 580),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.widgets_rounded,
                        color: _brandGreen,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '素材中心',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const TabBar(
                    tabs: [
                      Tab(text: '📄 模板'),
                      Tab(text: '✨ 贴纸'),
                      Tab(text: '🔤 字体'),
                      Tab(text: '🎨 色彩集'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: TabBarView(
                      children: [
                        // 1. 模板
                        GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 240,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 1.25,
                              ),
                          itemCount: [
                            ('康奈尔高效课堂模板', 'cornell', 'A4 竖版 · 含线索栏与总结区'),
                            ('艾宾浩斯复习周计划', 'weekly', 'A4 横版 · 7日记忆追踪'),
                            ('考研数学错题本双栏', '2col_grid', 'A4 竖版 · 左右题干与解析'),
                            ('学术文献阅读精要', 'legal', 'Letter · 带左侧批注边距'),
                            ('日程时间轴手帐', 'daily', 'A5 · 07:00~22:00 时间轴'),
                            ('音乐作曲五线谱', 'music', 'A4 · 标准 5 线谱表'),
                          ].length,
                          itemBuilder: (context, index) {
                            final item = [
                              ('康奈尔高效课堂模板', 'cornell', 'A4 竖版 · 含线索栏与总结区'),
                              ('艾宾浩斯复习周计划', 'weekly', 'A4 横版 · 7日记忆追踪'),
                              ('考研数学错题本双栏', '2col_grid', 'A4 竖版 · 左右题干与解析'),
                              ('学术文献阅读精要', 'legal', 'Letter · 带左侧批注边距'),
                              ('日程时间轴手帐', 'daily', 'A5 · 07:00~22:00 时间轴'),
                              ('音乐作曲五线谱', 'music', 'A4 · 标准 5 线谱表'),
                            ][index];
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      item.$1,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                    Text(
                                      item.$3,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey,
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: FilledButton.tonal(
                                        onPressed: () {
                                          setState(
                                            () => _starredQuickTemplateId =
                                                item.$2,
                                          );
                                          _savePrefs();
                                          Navigator.pop(ctx);
                                          _createQuickNote();
                                        },
                                        child: const Text(
                                          '立即创建',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                        // 2. 贴纸
                        const Center(
                          child: Text(
                            '已内置「重点标记」「考试必考」「便利贴」「手绘胶带」等贴纸合集，可在编辑器顶部【插入 > 添加贴纸】中直接使用。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        // 3. 字体
                        const Center(
                          child: Text(
                            '已内置 Roboto、Comfortaa、Noto Sans/Serif 等多语种字体，可在编辑器【文本框】底部格式栏中一键切换。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        // 4. 色彩集
                        ListView(
                          children: [
                            for (final palette in [
                              (
                                '经典墨水',
                                [
                                  0xFF1E293B,
                                  0xFF2F7D6E,
                                  0xFFDC2626,
                                  0xFF059669,
                                  0xFFD97706,
                                  0xFF7C3AED,
                                ],
                              ),
                              (
                                '莫兰迪色系',
                                [
                                  0xFF5C6B73,
                                  0xFF9DB4C0,
                                  0xFFC2DFE3,
                                  0xFF8F754F,
                                  0xFFA3B18A,
                                  0xFFB5838D,
                                ],
                              ),
                              (
                                '马卡龙色系',
                                [
                                  0xFFFFADAD,
                                  0xFFFFD6A5,
                                  0xFFCAFFBF,
                                  0xFF9BF6FF,
                                  0xFFA0C4FF,
                                  0xFFBDB2FF,
                                ],
                              ),
                              (
                                '复古手帐',
                                [
                                  0xFF264653,
                                  0xFF2A9D8F,
                                  0xFFE9C46A,
                                  0xFFF4A261,
                                  0xFFE76F51,
                                  0xFF6D597A,
                                ],
                              ),
                            ])
                              ListTile(
                                title: Text(
                                  palette.$1,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Row(
                                    children: [
                                      for (final c in palette.$2)
                                        Container(
                                          width: 22,
                                          height: 22,
                                          margin: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Color(c),
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                trailing: const Chip(label: Text('已安装至笔盒')),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showCloudSyncAndBackupModal(bool isDark) {
    final remotes = context.read<SettingsCubit>().state.getRemoteIdentifiers();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.cloud_upload_rounded, color: Color(0xFF10B981)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '云同步与备份中心',
                style: TextStyle(fontSize: 16),
                maxLines: 2,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '1. 自动保存：已启用。每一笔手写、插入图片或页面整理均在后台实时持久化至本地存储。',
              ),
              const SizedBox(height: 10),
              Text(
                remotes.isEmpty
                    ? '2. 云同步状态：当前未配置任何远端连接，笔记仅保存在本机（数据不会外传，也不会被自动上传）。'
                    : '2. 云同步状态：已配置 ${remotes.length} 个远端连接 (${remotes.join("、")})。打开远端笔记本时按远端设置同步。',
              ),
              const SizedBox(height: 10),
              const Text(
                '3. 本地备份：可在编辑器「更多 > 导出与分享」中导出标准 .bfly / PDF / SVG / PNG 备份文件。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showMumuAppSettingsSheet(isDark);
            },
            child: const Text('打开木木笔记设置'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  /// 木木笔记自己的设置页（不再跳转 Butterfly 原生设置页）。
  void _showMumuAppSettingsSheet(bool isDark) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final cubit = context.read<SettingsCubit>();
          final settings = cubit.state;
          final pg = PalmGuardService.instance;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.settings_rounded, color: _brandGreen),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '木木笔记 · 设置',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: _brandGreen,
                    activeTrackColor: _brandGreen.withValues(alpha: 0.35),
                    secondary: const Icon(Icons.edit_rounded),
                    title: const Text('仅手写笔输入（单指防误触）'),
                    subtitle: const Text('开启后单指只翻页，不会画线；关闭后手指也可书写'),
                    value: settings.penOnlyInput ?? pg.state.penOnlyMode,
                    onChanged: (v) {
                      cubit.changePenOnlyInput(v);
                      pg.setPenOnlyMode(v);
                      setModal(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: _brandGreen,
                    activeTrackColor: _brandGreen.withValues(alpha: 0.35),
                    secondary: const Icon(Icons.shield_outlined),
                    title: const Text('防误触引擎（手掌 / 小指误触拦截）'),
                    subtitle: const Text('关闭后手指可直接书写，适合无笔尖尺寸数据的设备'),
                    value: pg.state.enabled,
                    onChanged: (v) {
                      unawaited(pg.setEnabled(v));
                      setModal(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: _brandGreen,
                    activeTrackColor: _brandGreen.withValues(alpha: 0.35),
                    secondary: const Icon(Icons.back_hand_outlined),
                    title: const Text('底部虚拟防误触手垫'),
                    subtitle: const Text('在屏幕下方搭放手掌，避免误触书写'),
                    value: pg.telemetry.shieldEnabled,
                    onChanged: (v) {
                      pg.setPalmShield(enabled: v);
                      setModal(() {});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeThumbColor: _brandGreen,
                    activeTrackColor: _brandGreen.withValues(alpha: 0.35),
                    secondary: const Icon(Icons.grid_view_rounded),
                    title: const Text('书架网格视图'),
                    subtitle: const Text('关闭后使用紧凑列表视图'),
                    value: _isGridView,
                    onChanged: (v) {
                      setState(() => _isGridView = v);
                      setModal(() {});
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.brightness_6_rounded),
                    title: const Text('主题模式'),
                    trailing: DropdownButton<ThemeMode>(
                      value: settings.theme,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
                        DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                        DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        cubit.changeTheme(v);
                        setModal(() {});
                      },
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(
                      Icons.verified_user_outlined,
                      color: MumuPalette.emeraldGuard,
                    ),
                    title: const Text('电容笔防误触与笔尖校准'),
                    subtitle: const Text('灵敏度、握姿、双框实测校准'),
                    onTap: () {
                      Navigator.pop(ctx);
                      showMumuCalibrationModal(context);
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.cloud_upload_outlined),
                    title: const Text('云同步与本地备份'),
                    subtitle: Text(
                      settings.getRemoteIdentifiers().isEmpty
                          ? '当前仅保存在本机（未配置远端）'
                          : '已配置 ${settings.getRemoteIdentifiers().length} 个远端',
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showCloudSyncAndBackupModal(isDark);
                    },
                  ),
                  const Divider(height: 16),
                  const Text(
                    '木木笔记 2.6.4',
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showMumuSettingsModal(bool isDark) {
    _showMumuAppSettingsSheet(isDark);
  }

  void _showAccountAndVipModal(bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('账号与 VIP 永久会员权益'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('当前状态：全部功能已解锁'),
            SizedBox(height: 8),
            Text('✅ 全部笔刷解锁：钢笔、圆珠笔、铅笔、彩虹笔、荧光笔、图形笔、胶带笔、激光笔'),
            Text('✅ 通用电容笔自研 7 维面积/运动学防误触与无压感笔锋模拟'),
            Text('✅ 应用内双开分屏 与跨页双向链接'),
            Text('✅ 无限笔记本配额、无限层级文件夹、素材中心模板全免费'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('太棒了'),
          ),
        ],
      ),
    );
  }

  void _showOfficialManualGuideModal(bool isDark) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('木木笔记 · 核心操作速览'),
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1. 浮动笔盒：进入编辑器后，笔盒支持自由拖动并自动吸附屏幕左、右、上、下四边，也可随时最小化为角落浮标；再次点击当前画笔可弹出压感/流量/粗细/一笔成型设置面板。',
                ),
                SizedBox(height: 8),
                Text(
                  '2. 笔的收藏：在画笔设置面板点击右上角 ★，可将当前笔刷加入屏幕侧边的独立悬浮笔夹（最多 12 个预设），即使关闭主笔盒也能一键切换。',
                ),
                SizedBox(height: 8),
                Text(
                  '3. 应用内分屏：在编辑器左上角打开「文档列表」侧边栏或右上角「•••」菜单，即可开启左右垂直分屏或上下水平分屏对照笔记。',
                ),
                SizedBox(height: 8),
                Text(
                  '4. 缩放锁定：点击画布顶部中央的缩放胶囊（100% 🔒 ★），开启小锁即可锁定当前缩放级别，防止手掌误触导致页面意外缩放。',
                ),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('我知道了'),
          ),
        ],
      ),
    );
  }
}

/// 绘制仿真实笔记本封面缩略图（素描、几何插画、莫兰迪封面）
class _MumuBookCoverPainter extends CustomPainter {
  final String coverStyle;
  final Color coverColor;
  final Color paperColor;
  final String templateId;
  final String title;

  const _MumuBookCoverPainter({
    required this.coverStyle,
    required this.coverColor,
    required this.paperColor,
    required this.templateId,
    required this.title,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    if (coverStyle == 'blank') {
      _MumuPaperPreviewPainter(
        paperColor: paperColor,
        templateId: templateId,
      ).paint(canvas, size);
      return;
    }

    // 纸张底色与封面装饰
    final bgPaint = Paint()..color = paperColor;
    canvas.drawRect(rect, bgPaint);

    // 左侧书脊装订带
    final spinePaint = Paint()..color = coverColor;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width * 0.11, size.height), spinePaint);

    if (coverStyle == 'fighter_sketch') {
      // 几何线条艺术封面
      final linePaint = Paint()
        ..color = coverColor.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      final cx = size.width * 0.54;
      final cy = size.height * 0.44;
      final r = math.min(size.width, size.height) * 0.28;
      final path = Path()
        ..moveTo(cx, cy - r)
        ..lineTo(cx + r * 0.85, cy + r * 0.7)
        ..lineTo(cx, cy + r * 0.35)
        ..lineTo(cx - r * 0.85, cy + r * 0.7)
        ..close();
      canvas.drawPath(path, linePaint);
      canvas.drawCircle(
        Offset(cx, cy),
        r * 0.65,
        Paint()
          ..color = coverColor.withValues(alpha: 0.12)
          ..style = PaintingStyle.fill,
      );
    } else if (coverStyle == 'geometry_modern') {
      canvas.drawCircle(
        Offset(size.width * 0.65, size.height * 0.35),
        size.width * 0.28,
        Paint()..color = coverColor.withValues(alpha: 0.22),
      );
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * 0.25,
          size.height * 0.45,
          size.width * 0.45,
          size.height * 0.28,
        ),
        Paint()..color = const Color(0xFFF59E0B).withValues(alpha: 0.22),
      );
    } else {
      // 经典纯色块封面
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * 0.11,
          0,
          size.width * 0.89,
          size.height * 0.38,
        ),
        Paint()..color = coverColor.withValues(alpha: 0.85),
      );
    }

    // 书脊立体压痕线与右侧多层纸页边缘
    canvas.drawLine(
      Offset(size.width * 0.11, 0),
      Offset(size.width * 0.11, size.height),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.16)
        ..strokeWidth = 1.2,
    );
    canvas.drawLine(
      Offset(size.width - 2.5, 4),
      Offset(size.width - 2.5, size.height - 4),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.08)
        ..strokeWidth = 1.0,
    );

    // 底部简洁标牌 + 封面标题文字
    final labelRect = Rect.fromLTWH(
      size.width * 0.17,
      size.height * 0.68,
      size.width * 0.74,
      size.height * 0.20,
    );
    final labelBg = Paint()..color = Colors.white.withValues(alpha: 0.92);
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
      labelBg,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = coverColor.withValues(alpha: 0.25),
    );
    final tp = TextPainter(
      text: TextSpan(
        text: title,
        style: const TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1E293B),
          height: 1.2,
        ),
      ),
      maxLines: 2,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: labelRect.width - 12);
    tp.paint(
      canvas,
      Offset(labelRect.left + 6, labelRect.top + (labelRect.height - tp.height) / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _MumuBookCoverPainter oldDelegate) =>
      oldDelegate.coverStyle != coverStyle ||
      oldDelegate.coverColor != coverColor ||
      oldDelegate.paperColor != paperColor ||
      oldDelegate.templateId != templateId;
}

/// 绘制 Mumu 纸张模板预览缩略图（空白、横线、方格、点阵、康奈尔、双栏、五线谱）
class _MumuPaperPreviewPainter extends CustomPainter {
  final Color paperColor;
  final String templateId;

  const _MumuPaperPreviewPainter({
    required this.paperColor,
    required this.templateId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = paperColor);
    final isDark = paperColor.toARGB32() == 0xFF1E293B;
    final linePaint = Paint()
      ..color = isDark
          ? Colors.white.withValues(alpha: 0.18)
          : const Color(0xFF64748B).withValues(alpha: 0.28)
      ..strokeWidth = 0.9;
    final redLinePaint = Paint()
      ..color = const Color(0xFFEF4444).withValues(alpha: 0.45)
      ..strokeWidth = 1.1;

    if (templateId.contains('ruled') ||
        templateId == 'legal' ||
        templateId == 'cornell' ||
        templateId == '2col_lined' ||
        templateId == 'daily') {
      for (double y = 18; y < size.height - 10; y += 11) {
        canvas.drawLine(Offset(8, y), Offset(size.width - 8, y), linePaint);
      }
      if (templateId == 'cornell' || templateId == 'legal') {
        canvas.drawLine(
          Offset(size.width * 0.28, 12),
          Offset(size.width * 0.28, size.height - 12),
          redLinePaint,
        );
      }
      if (templateId == '2col_lined') {
        canvas.drawLine(
          Offset(size.width * 0.5, 10),
          Offset(size.width * 0.5, size.height - 10),
          redLinePaint,
        );
      }
    } else if (templateId.contains('grid') ||
        templateId == 'weekly' ||
        templateId == 'monthly') {
      for (double x = 10; x < size.width - 6; x += 11) {
        canvas.drawLine(Offset(x, 8), Offset(x, size.height - 8), linePaint);
      }
      for (double y = 10; y < size.height - 6; y += 11) {
        canvas.drawLine(Offset(8, y), Offset(size.width - 8, y), linePaint);
      }
      if (templateId == '2col_grid') {
        canvas.drawLine(
          Offset(size.width * 0.5, 8),
          Offset(size.width * 0.5, size.height - 8),
          redLinePaint,
        );
      }
    } else if (templateId.contains('dot')) {
      final dotPaint = Paint()..color = linePaint.color;
      for (double x = 12; x < size.width - 8; x += 11) {
        for (double y = 12; y < size.height - 8; y += 11) {
          canvas.drawCircle(Offset(x, y), 1.1, dotPaint);
        }
      }
    } else if (templateId == '2col_plain') {
      canvas.drawLine(
        Offset(size.width * 0.5, 8),
        Offset(size.width * 0.5, size.height - 8),
        redLinePaint,
      );
    } else if (templateId == 'music') {
      for (double block = 20; block < size.height - 20; block += 28) {
        for (int i = 0; i < 5; i++) {
          final y = block + i * 3.2;
          canvas.drawLine(Offset(10, y), Offset(size.width - 10, y), linePaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MumuPaperPreviewPainter oldDelegate) =>
      oldDelegate.paperColor != paperColor ||
      oldDelegate.templateId != templateId;
}
