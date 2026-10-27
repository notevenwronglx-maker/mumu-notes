import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:butterfly/helpers/color.dart';
import 'package:butterfly/helpers/page.dart';
import 'package:butterfly/visualizer/preset.dart';
import 'package:material_ui/material_ui.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:dart_leap/dart_leap.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:butterfly/src/generated/i18n/app_localizations.dart';
import 'package:material_leap/material_leap.dart';

class DocumentDefaults {
  static NoteData? _corePack;

  DocumentDefaults._();

  // ignore: unused_element
  static Future<Uint8List> _createPlainThumnail(SRGBColor color) async {
    final size = Size(kThumbnailWidth.toDouble(), kThumbnailHeight.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Color(color.value),
    );
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(size.width.toInt(), size.height.toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return bytes!.buffer.asUint8List();
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }

  /// 木木笔记 13 件标准手写与编辑工具箱预设
  static List<Tool> createTools([SRGBColor? background]) =>
      [
            PenTool(
              id: createUniqueId(),
              name: '钢笔',
              shapeDetectionEnabled: true,
              property: const PenProperty(
                strokeWidth: 3.2,
                thinning: 0.55,
                smoothing: 0.55,
                streamline: 0.35,
                paint: ElementPaint.solid(color: SRGBColor(0xFF1E293B)),
              ),
            ),
            PenTool(
              id: createUniqueId(),
              name: '圆珠笔',
              shapeDetectionEnabled: true,
              property: const PenProperty(
                strokeWidth: 2.6,
                thinning: 0.0,
                smoothing: 0.65,
                streamline: 0.45,
                paint: ElementPaint.solid(color: SRGBColor(0xFF2F7D6E)),
              ),
            ),
            PenTool(
              id: createUniqueId(),
              name: '铅笔',
              property: const PenProperty(
                strokeWidth: 3.0,
                thinning: 0.18,
                smoothing: 0.40,
                streamline: 0.20,
                paint: ElementPaint.solid(
                  color: SRGBColor(0xB8334155),
                  blur: 0.6,
                ),
              ),
            ),
            PenTool(
              id: createUniqueId(),
              name: '彩虹笔',
              property: const PenProperty(
                strokeWidth: 4.2,
                thinning: 0.22,
                paint: ElementPaint.gradient(
                  gradient: ElementGradient.linear(
                    stops: [
                      ElementGradientStop(
                        offset: 0.0,
                        color: SRGBColor(0xFFF43F5E),
                      ),
                      ElementGradientStop(
                        offset: 0.5,
                        color: SRGBColor(0xFFF59E0B),
                      ),
                      ElementGradientStop(
                        offset: 1.0,
                        color: SRGBColor(0xFF06B6D4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            PenTool(
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
            EraserTool(
              id: createUniqueId(),
              name: '橡皮擦',
              mode: EraserMode.stroke,
              strokeWidth: 12.0,
            ),
            ShapeTool(
              id: createUniqueId(),
              name: '图形笔',
              property: const ShapeProperty(
                strokeWidth: 3.0,
                shape: RectangleShape(),
                paint: ElementPaint.solid(color: SRGBColor(0xFF2F7D6E)),
              ),
            ),
            PenTool(
              id: createUniqueId(),
              name: '胶带笔',
              shapeDetectionEnabled: true,
              property: const PenProperty(
                strokeWidth: 22.0,
                thinning: 0.0,
                smoothing: 0.75,
                paint: ElementPaint.solid(color: SRGBColor(0xE60D9488)),
              ),
            ),
            LaserTool(
              id: createUniqueId(),
              name: '激光笔',
              duration: 3.0,
              strokeWidth: 4.5,
              color: BasicColors.red,
            ),
            SelectTool(
              id: createUniqueId(),
              name: '套索',
              mode: SelectMode.lasso,
            ),
            LabelTool(
              id: createUniqueId(),
              name: '文本框',
              mode: LabelMode.text,
              foreground: const SRGBColor(0xFF1E293B),
            ),
            RulerTool(
              id: createUniqueId(),
              name: '标尺',
              size: 160,
            ),
            HandTool(
              id: createUniqueId(),
              name: '漫游',
            ),
          ]
          .map(
            (e) =>
                background == null ? e : updateToolDefaultColor(e, background),
          )
          .toList();

  static List<Tool> createToolPresets() => [
    Tool.hand(),
    ...SelectMode.values.map((e) => Tool.select(mode: e)),
    Tool.pen(),
    Tool.laser(),
    Tool.label(),
    ...EraserMode.values.map((e) => Tool.eraser(mode: e)),
    Tool.area(),
    Tool.presentation(),
    Tool.polygon(),
    ...Axis2D.values.map((e) => Tool.spacer(axis: e)),
    Tool.stamp(),
    ...[
      PathShape.circle,
      PathShape.rectangle,
      PathShape.line,
      PathShape.triangle,
    ].map((e) => Tool.shape(property: ShapeProperty(shape: e()))),
    ...[SurfaceTexture.pattern].map((e) => TextureTool(texture: e())),
    Tool.undo(),
    Tool.redo(),
    Tool.fullScreen(),
    Tool.collection(),
    Tool.eyeDropper(),
    Tool.ruler(),
    Tool.grid(),
    ...BarcodeType.values.map((e) => Tool.barcode(barcodeType: e)),
    Tool.table(),
  ];

  static NoteData _addCoreToolPresets(NoteData pack) {
    final presets = createToolPresets();
    for (final (index, tool) in presets.indexed) {
      pack = pack.setToolPreset('core-$index', tool);
    }
    return pack;
  }

  static Future<List<NoteData>> getCoreTemplates(
    BuildContext context, {
    PatternBackground? background,
  }) async {
    PatternTexture createRedLinedPattern() {
      return const PatternTexture(
        boxColor: .transparent,
        boxXColor: BasicColors.red,
        boxWidth: 1200,
        boxXCount: 1,
        boxXStroke: 1,
      );
    }

    return Future.wait([
      ...PatternTemplate.values
          .where((e) => background == null || e.background == background)
          .map((e) async {
            final bg = Background.texture(texture: e.create());
            return createTemplate(
              name: e.getLocalizedName(context),
              thumbnail: Uint8List.sublistView(await rootBundle.load(e.asset)),
              backgrounds: [bg],
            );
          }),
      ...[
        (
          PatternTemplate.ruledSimple,
          'templates/red_lined_ruled.png',
          AppLocalizations.of(context).redLinedRuled,
        ),
        (
          PatternTemplate.ruledSimpleDark,
          'templates/red_lined_ruled_dark.png',
          AppLocalizations.of(context).redLinedRuledDark,
        ),
        (
          PatternTemplate.quadSimple,
          'templates/red_lined_quad.png',
          AppLocalizations.of(context).redLinedQuad,
        ),
        (
          PatternTemplate.quadSimpleDark,
          'templates/red_lined_quad_dark.png',
          AppLocalizations.of(context).redLinedQuadDark,
        ),
      ].where((e) => background == null || e.$1.background == background).map((
        e,
      ) async {
        final lined = Background.texture(texture: createRedLinedPattern());
        final bg = Background.texture(texture: e.$1.create());
        return createTemplate(
          name: e.$3,
          thumbnail: Uint8List.sublistView(await rootBundle.load(e.$2)),
          backgrounds: [bg, lined],
        );
      }),
    ]);
  }

  static Future<NoteData> _loadNoteData(String name) async => NoteData.fromData(
    Uint8List.sublistView(await rootBundle.load('defaults/$name.tbfly')),
  );

  static Future<NoteData> getCorePack() async {
    return _corePack ??= _addCoreToolPresets(await _loadNoteData('pack'));
  }

  static String translate(String key, Map<String, String> translations) {
    if (key.startsWith('\\/')) return key.substring(1);
    if (key.startsWith('\$')) {
      final keyWithoutDollar = key.substring(1);
      return translations[keyWithoutDollar] ?? keyWithoutDollar;
    }
    return translations[key] ?? key;
  }

  static Map<String, String> getParagraphTranslations(BuildContext context) => {
    'h1': AppLocalizations.of(context).headline(1),
    'h2': AppLocalizations.of(context).headline(2),
    'h3': AppLocalizations.of(context).headline(3),
    'h4': AppLocalizations.of(context).headline(4),
    'h5': AppLocalizations.of(context).headline(5),
    'h6': AppLocalizations.of(context).headline(6),
    'p': AppLocalizations.of(context).paragraph,
    'blockquote': AppLocalizations.of(context).quote,
    'math': AppLocalizations.of(context).math,
  };

  static String translateParagraph(String key, BuildContext context) =>
      translate(key, getParagraphTranslations(context));

  static Map<String, String> getSpanTranslations(BuildContext context) => {
    'a': AppLocalizations.of(context).link,
    'checkbox': AppLocalizations.of(context).checkbox,
    'del': AppLocalizations.of(context).deleted,
    'em': AppLocalizations.of(context).emphasis,
    'img': AppLocalizations.of(context).image,
    'listBullet': AppLocalizations.of(context).listBullet,
    'strong': AppLocalizations.of(context).strong,
    'code': AppLocalizations.of(context).code,
  };

  static String translateBlock(String key, BuildContext context) =>
      translate(key, getSpanTranslations(context));

  static NoteData createDocument({
    String name = '',
    DocumentPage? page,
    bool createDefaultPage = true,
  }) {
    final metadata = createMetadata(name: name);
    var data = NoteData(Archive()).setMetadata(metadata).setInfo(createInfo());
    if (createDefaultPage) {
      page ??= createPage();
      data = data.setPage(page, '第 1 页').$1;
    }
    return data;
  }

  static DocumentPage createPage({
    bool isInfinite = false,
    double width = kMumuDefaultPageWidth,
    double height = kMumuDefaultPageHeight,
    String spec = 'A4',
    String templateId = 'ruled',
    int paperColorValue = 0xFFFEF9EF,
  }) {
    return DocumentPage(
      layers: [
        DocumentLayer(id: createUniqueId(), name: '图层 1 · 正文手写层'),
        DocumentLayer(id: createUniqueId(), name: '图层 2 · 重点批注层'),
      ],
      backgrounds: [
        Background.texture(
          texture: PatternTexture(
            boxColor: SRGBColor(paperColorValue),
            boxHeight: 38,
            boxYColor: const SRGBColor(0x3864748B),
            boxYStroke: 0.85,
          ),
        ),
      ],
      areas: isInfinite
          ? const []
          : [
              Area(
                name: '第 1 页',
                width: width,
                height: height,
                position: const math.Point<double>(0.0, 0.0),
              ),
            ],
      extra: {
        'mumu:mode': isInfinite ? 'infinite' : 'standard',
        'mumu:spec': isInfinite ? 'Infinite' : spec,
        'mumu:template': templateId,
        'mumu:paperColor': paperColorValue,
        'mumu:scrollDirection': 'vertical',
        'mumu:pullToAddPage': true,
      },
    );
  }

  static DocumentInfo createInfo([SRGBColor? background]) {
    return DocumentInfo(
      tools: createTools(background),
      extra: const {
        'mumu:mode': 'standard',
        'mumu:spec': 'A4',
        'mumu:template': 'ruled',
      },
    );
  }

  static NoteData createPack() {
    final metadata = createMetadata(type: NoteFileType.pack);
    final data = NoteData(Archive()).setMetadata(metadata);
    return data;
  }

  static Future<NoteData> createTemplate({
    String name = '',
    Uint8List? thumbnail,
    List<Background> backgrounds = const [],
  }) async {
    final metadata = createMetadata(type: NoteFileType.template, name: name);
    final page = DocumentPage(
      backgrounds: backgrounds,
      areas: const [
        Area(
          name: '第 1 页',
          width: kMumuDefaultPageWidth,
          height: kMumuDefaultPageHeight,
          position: math.Point<double>(0.0, 0.0),
        ),
      ],
      extra: const {
        'mumu:mode': 'standard',
        'mumu:spec': 'A4',
        'mumu:scrollDirection': 'vertical',
        'mumu:pullToAddPage': true,
      },
    );
    var data = NoteData(Archive())
        .setMetadata(metadata)
        .setInfo(createInfo(backgrounds.firstOrNull?.defaultColor))
        .setPage(page, '第 1 页')
        .$1;
    if (thumbnail != null) data = data.setThumbnail(thumbnail);
    return data;
  }

  static FileMetadata createMetadata({
    NoteFileType type = .document,
    String name = '',
  }) => FileMetadata(
    name: name,
    createdAt: DateTime.now().toUtc(),
    type: type,
    fileVersion: kFileVersion,
    updatedAt: DateTime.now().toUtc(),
  );
}
