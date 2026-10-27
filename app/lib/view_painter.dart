import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/helpers/page.dart';
import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly/models/viewport.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly/views/navigator/constants.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:material_leap/material_leap.dart';

import 'cubits/transform.dart';
import 'selections/selection.dart';

void _paintRenderer(
  Canvas canvas,
  Size size,
  NoteData document,
  DocumentPage page,
  DocumentInfo info,
  CameraTransform transform,
  ColorScheme? colorScheme,
  Renderer renderer, {
  bool foreground = false,
  bool combined = false,
}) {
  final transformed = renderer.transformCanvas(canvas);
  if (combined && renderer is PenRenderer) {
    renderer.buildCombined(canvas);
  } else {
    renderer.build(
      canvas,
      size,
      document,
      page,
      info,
      transform,
      colorScheme,
      foreground,
    );
  }
  if (transformed) canvas.restore();
}

Rect? _rendererBounds(Renderer renderer) => renderer.expandedRect;

Rect? _groupBounds(Iterable<Renderer> renderers) {
  Rect? bounds;
  for (final renderer in renderers) {
    final rect = _rendererBounds(renderer);
    if (rect == null) return null;
    bounds = bounds?.expandToInclude(rect) ?? rect;
  }
  return bounds;
}

/// 视口空间剔除（Viewport Frustum Culling）：屏幕外的元素直接跳过 Canvas 绘制指令
bool _isVisibleInViewport(Rect? elementBounds, Rect visibleViewportRect) {
  if (elementBounds == null || visibleViewportRect.isEmpty) return true;
  return elementBounds.overlaps(visibleViewportRect);
}

void _paintRenderers(
  Canvas canvas,
  Size size,
  NoteData document,
  DocumentPage page,
  DocumentInfo info,
  CameraTransform transform,
  ColorScheme? colorScheme,
  Iterable<Renderer> renderers, {
  bool foreground = false,
}) {
  final rendererList = renderers is List<Renderer>
      ? renderers
      : renderers.toList();
  if (rendererList.isEmpty) return;

  final visibleViewportRect = size.isEmpty
      ? Rect.zero
      : transform.localToGlobalRect(Offset.zero & size);

  Map<String, List<PenRenderer>>? groups;
  for (final renderer in rendererList.whereType<PenRenderer>()) {
    final combineId = renderer.element.combineId;
    if (combineId != null) {
      (groups ??= {}).putIfAbsent(combineId, () => []).add(renderer);
    }
  }
  if (groups == null) {
    for (final renderer in rendererList) {
      if (!_isVisibleInViewport(
        _rendererBounds(renderer),
        visibleViewportRect,
      )) {
        continue;
      }
      _paintRenderer(
        canvas,
        size,
        document,
        page,
        info,
        transform,
        colorScheme,
        renderer,
        foreground: foreground,
      );
    }
    return;
  }
  final paintedGroups = <String>{};
  for (final renderer in rendererList) {
    final combineId = renderer is PenRenderer
        ? renderer.element.combineId
        : null;
    if (combineId == null) {
      if (!_isVisibleInViewport(
        _rendererBounds(renderer),
        visibleViewportRect,
      )) {
        continue;
      }
      _paintRenderer(
        canvas,
        size,
        document,
        page,
        info,
        transform,
        colorScheme,
        renderer,
        foreground: foreground,
      );
      continue;
    }
    if (!paintedGroups.add(combineId)) continue;
    final group = groups[combineId]!;
    final groupBounds = _groupBounds(group);
    if (!_isVisibleInViewport(groupBounds, visibleViewportRect)) {
      continue;
    }
    if (group.length == 1) {
      _paintRenderer(
        canvas,
        size,
        document,
        page,
        info,
        transform,
        colorScheme,
        group.first,
        foreground: foreground,
        combined: true,
      );
      continue;
    }
    canvas.saveLayer(groupBounds, Paint());
    for (final groupedRenderer in group) {
      _paintRenderer(
        canvas,
        size,
        document,
        page,
        info,
        transform,
        colorScheme,
        groupedRenderer,
        foreground: foreground,
        combined: true,
      );
    }
    canvas.restore();
  }
}

class ForegroundPainter extends CustomPainter {
  final ColorScheme colorScheme;
  final NoteData document;
  final DocumentPage page;
  final DocumentInfo info;
  final List<Renderer> renderers;
  final CameraTransform transform;
  final Selection? selection;
  final NavigatorPosition navigatorPosition;

  ForegroundPainter(
    this.renderers,
    this.document,
    this.page,
    this.info,
    this.colorScheme, [
    this.transform = const CameraTransform(),
    this.selection,
    this.navigatorPosition = .left,
  ]);

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    if (renderers.isEmpty && sel == null) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    transform.applyToCanvas(canvas);
    _paintRenderers(
      canvas,
      size,
      document,
      page,
      info,
      transform,
      colorScheme,
      renderers,
      foreground: true,
    );
    if (sel is ElementSelection) {
      _drawSelection(canvas, size, sel);
    }
    canvas.restore();
  }

  void _drawSelection(Canvas canvas, Size size, ElementSelection selection) {
    final rect = selection.expandedRect;
    if (rect == null) return;
    var viewport =
        Offset.zero & Size(size.width - kNavigationRailWidth, size.height);
    if (navigatorPosition == .left) {
      viewport = viewport.translate(kNavigationRailWidth, 0);
    }
    final bounds = transform.localToGlobalRect(viewport);
    final intersection = rect.intersect(bounds);
    if (intersection.isEmpty) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(intersection, const Radius.circular(2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..color = colorScheme.primary
        ..strokeWidth = 5 / transform.size,
    );
  }

  @override
  bool shouldRepaint(ForegroundPainter oldDelegate) =>
      oldDelegate.renderers != renderers ||
      oldDelegate.transform != transform ||
      oldDelegate.selection != selection ||
      oldDelegate.colorScheme != colorScheme;
}

class ViewPainter extends CustomPainter {
  final NoteData document;
  final DocumentPage page;
  final DocumentInfo info;
  final Area? currentArea;
  final bool renderBackground, renderBaked, renderBakedLayers;
  final CameraViewport cameraViewport;
  final CameraTransform transform;
  final ColorScheme? colorScheme;
  final Set<String>? invisibleLayers;

  const ViewPainter(
    this.document,
    this.page,
    this.info, {
    super.repaint,
    this.currentArea,
    this.invisibleLayers,
    this.renderBackground = true,
    this.renderBaked = true,
    this.renderBakedLayers = true,
    required this.cameraViewport,
    this.colorScheme,
    this.transform = const CameraTransform(),
  });

  void _paintStandardPageFrames(Canvas canvas, Size size) {
    final isDark = colorScheme?.brightness == Brightness.dark;
    final visibleRect = transform.localToGlobalRect(
      (Offset.zero & size).inflate(80),
    );
    final sheets = page.resolvedPageSheets;
    final basePaperColor =
        page.backgrounds.firstOrNull?.defaultColor.toColor() ??
        const Color(0xFFFEF9EF);
    final invScale = (1.0 / (transform.size <= 0 ? 1.0 : transform.size)).clamp(
      0.35,
      3.5,
    );
    final templateId = page.extra['mumu:template']?.toString() ?? 'ruled';

    for (var i = 0; i < sheets.length; i++) {
      final rect = sheets[i].rect;
      if (!rect.overlaps(visibleRect)) continue;

      // 1. 纸张柔和悬浮投影 (Mumu A4 实体纸张阴影)
      final shadowRRect = RRect.fromRectAndRadius(
        rect.shift(Offset(0, 4.0 * invScale)),
        Radius.circular(3.0 * invScale),
      );
      canvas.drawRRect(
        shadowRRect,
        Paint()
          ..color = Colors.black.withValues(alpha: isDark ? 0.45 : 0.11)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8.0 * invScale),
      );

      // 2. 纸张底色填充
      canvas.drawRect(
        rect,
        Paint()
          ..color = basePaperColor
          ..style = PaintingStyle.fill,
      );
    }

    // 3. 绘制页面纹理背景（已在 TextureBackgroundRenderer 中按每页裁剪）
    for (final e in cameraViewport.backgrounds) {
      e.build(canvas, size, document, page, info, transform, colorScheme);
    }

    // 4. 绘制每页的天头装饰线、康奈尔总结线、纸张外边框与右下角页码水印
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1 * invScale
      ..color = isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1);

    final headerLinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 * invScale
      ..color = const Color(0x55EF4444);

    for (var i = 0; i < sheets.length; i++) {
      final rect = sheets[i].rect;
      if (!rect.overlaps(visibleRect)) continue;

      if (templateId == 'ruled' ||
          templateId == 'cornell' ||
          templateId == 'legal') {
        final headerY = rect.top + 68.0;
        if (headerY < rect.bottom - 40) {
          canvas.drawLine(
            Offset(rect.left + 28, headerY),
            Offset(rect.right - 28, headerY),
            headerLinePaint,
          );
        }
      }
      if (templateId == 'cornell') {
        final summaryY = rect.bottom - 180.0;
        if (summaryY > rect.top + 120) {
          canvas.drawLine(
            Offset(rect.left, summaryY),
            Offset(rect.right, summaryY),
            headerLinePaint,
          );
        }
      }

      canvas.drawRect(rect, borderPaint);

      // 右下角 Mumu 页码标识 ("1 / N")
      final pageBadgeTp = TextPainter(
        text: TextSpan(
          text: '${i + 1} / ${sheets.length}',
          style: TextStyle(
            fontSize: 12.0 * invScale,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF64748B).withValues(alpha: 0.72),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      pageBadgeTp.paint(
        canvas,
        Offset(
          rect.right - pageBadgeTp.width - 18.0 * invScale,
          rect.bottom - pageBadgeTp.height - 12.0 * invScale,
        ),
      );
    }

    // 5. 在最后一页底部桌面区绘制 Mumu「下滑到底部自动加页」引导标签
    if (sheets.isNotEmpty && page.isMumuPullToAddPageEnabled) {
      final lastRect = sheets.last.rect;
      final hintCenter = page.isMumuHorizontalScroll
          ? Offset(lastRect.right + 90.0, lastRect.center.dy)
          : Offset(lastRect.center.dx, lastRect.bottom + 36.0 * invScale);
      if (visibleRect.inflate(160).contains(hintCenter)) {
        final hintText = page.isMumuHorizontalScroll
            ? '→ 继续左滑自动新增第 ${sheets.length + 1} 页'
            : '↓ 下滑至页面底部 · 继续上拉自动新增第 ${sheets.length + 1} 页';
        final tp = TextPainter(
          text: TextSpan(
            text: hintText,
            style: TextStyle(
              fontSize: 12.5 * invScale,
              fontWeight: FontWeight.w600,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pillRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: hintCenter,
            width: tp.width + 28.0 * invScale,
            height: tp.height + 12.0 * invScale,
          ),
          Radius.circular(999 * invScale),
        );
        canvas.drawRRect(
          pillRect,
          Paint()
            ..color = isDark
                ? const Color(0xFF1E293B).withValues(alpha: 0.85)
                : Colors.white.withValues(alpha: 0.88),
        );
        canvas.drawRRect(
          pillRect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0 * invScale
            ..color = isDark
                ? const Color(0xFF334155)
                : const Color(0xFFCBD5E1),
        );
        tp.paint(
          canvas,
          Offset(hintCenter.dx - tp.width / 2, hintCenter.dy - tp.height / 2),
        );
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final isInfinite = page.isMumuInfiniteCanvas(info);
    final isDark = colorScheme?.brightness == Brightness.dark;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (renderBackground) {
      if (isInfinite) {
        final bg =
            page.backgrounds.firstOrNull?.defaultColor.toColor() ??
            Colors.white;
        canvas.drawColor(bg, BlendMode.src);
      } else {
        // Mumu 标准分页桌面底色（浅色模式为柔和灰蓝桌面 #E4E7EE，深色模式为深邃蓝黑 #0B1120）
        canvas.drawColor(
          isDark ? const Color(0xFF0B1120) : const Color(0xFFE4E7EE),
          BlendMode.src,
        );
      }
    }
    transform.applyToCanvas(canvas);
    if (renderBackground) {
      if (isInfinite) {
        for (final e in cameraViewport.backgrounds) {
          e.build(canvas, size, document, page, info, transform, colorScheme);
        }
      } else {
        _paintStandardPageFrames(canvas, size);
      }
    }
    final belowLayerImage = cameraViewport.belowLayerImage;
    final bakedRect = cameraViewport.toRect();
    final imagePaint = Paint()..filterQuality = FilterQuality.medium;
    if (renderBakedLayers && belowLayerImage != null) {
      canvas.drawImageRect(
        belowLayerImage,
        cameraViewport.toImageSourceRect(
          Size(
            belowLayerImage.width.toDouble(),
            belowLayerImage.height.toDouble(),
          ),
        ),
        bakedRect,
        imagePaint,
      );
    }
    final areaRect = currentArea?.rect;
    final areaSelectionWidth = 5 / transform.size;
    if (areaRect != null) {
      final visibleRect = transform.localToGlobalRect(Offset.zero & size);
      final currentAreaColor = currentArea?.color?.toColor();
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..color = currentAreaColor ?? colorScheme?.primary ?? Colors.green
        ..strokeWidth = areaSelectionWidth;
      canvas.drawRect(areaRect.inflate(areaSelectionWidth / 2), paint);
      for (final area in page.areas) {
        if (area == currentArea || !area.rect.overlaps(visibleRect)) continue;
        if (areaRect.overlaps(area.rect)) continue;
        final areaPaint = Paint()
          ..style = PaintingStyle.stroke
          ..color =
              area.color?.toColor() ?? colorScheme?.secondary ?? Colors.grey
          ..strokeWidth = areaSelectionWidth;
        canvas.drawRect(area.rect.inflate(areaSelectionWidth / 2), areaPaint);
      }
      canvas.clipRect(areaRect);
    }
    final image = cameraViewport.image;
    if (image != null &&
        renderBaked &&
        (cameraViewport.bakedElements.isNotEmpty ||
            cameraViewport.visibleUnbakedElements.isNotEmpty)) {
      try {
        canvas.drawImageRect(
          image,
          cameraViewport.toImageSourceRect(
            Size(image.width.toDouble(), image.height.toDouble()),
          ),
          bakedRect,
          imagePaint,
        );
      } catch (_) {}
    }
    final renderers = cameraViewport.visibleUnbakedElements.where((renderer) {
      final state = cameraViewport.rendererStates[renderer.id];
      return !(invisibleLayers?.contains(renderer.layer) ?? false) &&
          state != .hidden;
    });
    _paintRenderers(
      canvas,
      size,
      document,
      page,
      info,
      transform,
      colorScheme,
      renderers,
    );
    final aboveLayerImage = cameraViewport.aboveLayerImage;
    if (renderBakedLayers && aboveLayerImage != null) {
      canvas.drawImageRect(
        aboveLayerImage,
        cameraViewport.toImageSourceRect(
          Size(
            aboveLayerImage.width.toDouble(),
            aboveLayerImage.height.toDouble(),
          ),
        ),
        bakedRect,
        imagePaint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ViewPainter oldDelegate) {
    final shouldRepaint =
        !identical(document, oldDelegate.document) ||
        !identical(page, oldDelegate.page) ||
        !identical(info, oldDelegate.info) ||
        renderBackground != oldDelegate.renderBackground ||
        renderBaked != oldDelegate.renderBaked ||
        renderBakedLayers != oldDelegate.renderBakedLayers ||
        transform != oldDelegate.transform ||
        !identical(cameraViewport, oldDelegate.cameraViewport) ||
        (!identical(invisibleLayers, oldDelegate.invisibleLayers) &&
            !setEquals(invisibleLayers, oldDelegate.invisibleLayers)) ||
        !identical(currentArea, oldDelegate.currentArea) ||
        colorScheme != oldDelegate.colorScheme;
    return shouldRepaint;
  }
}
