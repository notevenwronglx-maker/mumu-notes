import 'dart:math' as math;

import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:material_ui/material_ui.dart';
import 'package:butterfly/src/generated/i18n/app_localizations.dart';

const double kMumuDefaultPageWidth = 840.0;
const double kMumuDefaultPageHeight = 1188.0;
const double kMumuPageGap = 12.0;

extension DocumentPageHelper on DocumentPage {
  String? createAreaName(BuildContext context, [bool askForName = false]) {
    var count = areas.length + 1;
    var name = '';
    while (name.isEmpty || getAreaByName(name) != null) {
      name = AppLocalizations.of(context).areaIndex(count);
      count++;
    }
    return name;
  }

  /// 判断当前页面是否为无边界无限画布模式。
  /// 默认所有新建笔记均为 Mumu 标准分页模式 (standard)，仅当显式标记为 'infinite' 时才启用无限画布。
  bool isMumuInfiniteCanvas([DocumentInfo? info]) {
    final pageMode = extra['mumu:mode']?.toString().toLowerCase();
    final infoMode = info?.extra['mumu:mode']?.toString().toLowerCase();
    final pageSpec = extra['mumu:spec']?.toString().toLowerCase();
    final infoSpec = info?.extra['mumu:spec']?.toString().toLowerCase();
    return pageMode == 'infinite' ||
        infoMode == 'infinite' ||
        pageSpec == 'infinite' ||
        infoSpec == 'infinite';
  }

  /// 是否为横向翻页/滚动（默认为 false，即 Mumu 标志性的纵向连续滚动下滑加页）。
  bool get isMumuHorizontalScroll =>
      extra['mumu:scrollDirection']?.toString().toLowerCase() == 'horizontal';

  /// 是否允许下滑/上拉到底部自动加页（默认开启）。
  bool get isMumuPullToAddPageEnabled =>
      extra['mumu:pullToAddPage'] != false;

  /// 判断一个全局画布坐标是否落在任意一张纸页内（用于禁止页间空白处书写）。
  bool containsGlobalPoint(Offset point, [DocumentInfo? info]) {
    if (isMumuInfiniteCanvas(info)) return true;
    final sheets = resolvedPageSheets;
    if (sheets.isEmpty) return true;
    for (final area in sheets) {
      if (point.dx >= area.position.x &&
          point.dx <= area.position.x + area.width &&
          point.dy >= area.position.y &&
          point.dy <= area.position.y + area.height) {
        return true;
      }
    }
    return false;
  }

  /// 解析当前标准笔记的所有纵向/横向排列页面纸张区域 (Area)。
  /// 若旧笔记或默认空白笔记未包含 Area，自动回退为第 1 页标准 A4 (840×1188) 纸张。
  List<Area> get resolvedPageSheets {
    final valid = areas
        .where((a) => a.width > 80 && a.height > 80)
        .toList(growable: false);
    if (valid.isEmpty) {
      final (double w, double h) = _resolveDefaultSpecSize();
      return [
        Area(
          name: '第 1 页',
          width: w,
          height: h,
          position: const math.Point<double>(0.0, 0.0),
        ),
      ];
    }
    final sorted = List<Area>.from(valid);
    if (isMumuHorizontalScroll) {
      sorted.sort((a, b) {
        final cmpX = a.position.x.compareTo(b.position.x);
        return cmpX != 0 ? cmpX : a.position.y.compareTo(b.position.y);
      });
    } else {
      sorted.sort((a, b) {
        final cmpY = a.position.y.compareTo(b.position.y);
        return cmpY != 0 ? cmpY : a.position.x.compareTo(b.position.x);
      });
    }
    return sorted;
  }

  (double, double) _resolveDefaultSpecSize() {
    final spec = extra['mumu:spec']?.toString() ?? 'A4';
    final isLandscape = extra['mumu:landscape'] == true;
    final (double rawW, double rawH) = switch (spec) {
      'A3' => (1188.0, 1680.0),
      'A4' => (840.0, 1188.0),
      'A5' => (595.0, 840.0),
      'Letter' => (816.0, 1056.0),
      'B5' => (708.0, 1000.0),
      'Phone' => (480.0, 960.0),
      'Tablet' => (960.0, 1360.0),
      _ => (kMumuDefaultPageWidth, kMumuDefaultPageHeight),
    };
    final w = isLandscape ? math.max(rawW, rawH) : math.min(rawW, rawH);
    final h = isLandscape ? math.min(rawW, rawH) : math.max(rawW, rawH);
    return (w, h);
  }

  /// 所有标准纸张页面合集的总外接矩形。
  Rect get totalSheetsBounds {
    final sheets = resolvedPageSheets;
    var bounds = sheets.first.rect;
    for (var i = 1; i < sheets.length; i++) {
      bounds = bounds.expandToInclude(sheets[i].rect);
    }
    return bounds;
  }

  /// 根据当前视口中心的全局画布坐标，计算当前正在阅读/书写的页码索引 (0-based)。
  int activeSheetIndexForGlobalPoint(Offset globalCenter) {
    final sheets = resolvedPageSheets;
    if (sheets.length <= 1) return 0;
    var bestIdx = 0;
    var bestDist = double.infinity;
    final horizontal = isMumuHorizontalScroll;
    for (var i = 0; i < sheets.length; i++) {
      final r = sheets[i].rect;
      if (r.contains(globalCenter)) return i;
      final dist = horizontal
          ? (globalCenter.dx < r.left
                ? r.left - globalCenter.dx
                : (globalCenter.dx > r.right ? globalCenter.dx - r.right : 0.0))
          : (globalCenter.dy < r.top
                ? r.top - globalCenter.dy
                : (globalCenter.dy > r.bottom
                      ? globalCenter.dy - r.bottom
                      : 0.0));
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// 在最后一页下方（纵向模式）或右方（横向模式）自动生成下一页纸张 Area。
  Area buildNextPageSheet() {
    final sheets = resolvedPageSheets;
    final last = sheets.last;
    final existingNames = areas.map((a) => a.name).toSet();
    var nextNum = sheets.length + 1;
    var name = '第 $nextNum 页';
    while (existingNames.contains(name)) {
      nextNum++;
      name = '第 $nextNum 页';
    }
    final nextPos = isMumuHorizontalScroll
        ? math.Point<double>(
            last.position.x + last.width + kMumuPageGap,
            last.position.y,
          )
        : math.Point<double>(
            last.position.x,
            last.position.y + last.height + kMumuPageGap,
          );
    return Area(
      name: name,
      width: last.width > 80 ? last.width : kMumuDefaultPageWidth,
      height: last.height > 80 ? last.height : kMumuDefaultPageHeight,
      position: nextPos,
    );
  }
}
