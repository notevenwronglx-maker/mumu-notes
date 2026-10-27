import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/editor_runtime.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/helpers/page.dart';
import 'package:butterfly/helpers/point.dart';
import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly/services/palm_guard_service.dart';
import 'package:butterfly/views/navigator/constants.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_leap/material_leap.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'transform.freezed.dart';

const kMinZoom = 0.1;
const kMaxZoom = 10.0;
const kRoundPrecision = 3;
const kDrag = 0.001;
const kBoundsSnapBackDuration = 0.18;

@freezed
class const FrictionState(
  final Offset beginOffset,
  final double beginSize,
  final DateTime lastUpdate,
  final double duration,
) with _$FrictionState {}

@freezed
class const CameraTransform([
  final double pixelRatio = 1,
  final Offset position = .zero,
  final double size = 1,
  final double rotation = 0,
  final FrictionState? friction,
]) with _$CameraTransform {
  CameraTransform withPosition(Offset position) =>
      CameraTransform(pixelRatio, position, size, rotation);

  CameraTransform withPointPosition(Point<double> position) =>
      CameraTransform(pixelRatio, position.toOffset(), size, rotation);

  CameraTransform withSize(double size, [Offset cursor = .zero]) {
    final double newSize = size.clamp(kMinZoom, kMaxZoom);
    return CameraTransform(
      pixelRatio,
      localToGlobal(cursor) - cursor.rotate(Offset.zero, -rotation) / newSize,
      newSize,
      rotation,
    );
  }

  CameraTransform withRotation(double rotation, [Offset cursor = .zero]) {
    final normalized = (rotation + pi) % (2 * pi) - pi;
    return CameraTransform(
      pixelRatio,
      localToGlobal(cursor) - cursor.rotate(Offset.zero, -normalized) / size,
      size,
      normalized,
    );
  }

  Offset localToGlobal(Offset local) =>
      local.rotate(Offset.zero, -rotation) / size + position;

  Offset globalToLocal(Offset global) =>
      ((global - position) * size).rotate(Offset.zero, rotation);

  Offset localToGlobalDelta(Offset delta) =>
      delta.rotate(Offset.zero, -rotation) / size;

  Rect localToGlobalRect(Rect rect) => _transformRect(rect, localToGlobal);

  Rect globalToLocalRect(Rect rect) => _transformRect(rect, globalToLocal);

  Rect _transformRect(Rect rect, Offset Function(Offset) transform) {
    final topLeft = transform(rect.topLeft);
    final topRight = transform(rect.topRight);
    final bottomLeft = transform(rect.bottomLeft);
    final bottomRight = transform(rect.bottomRight);
    return Rect.fromLTRB(
      min(min(topLeft.dx, topRight.dx), min(bottomLeft.dx, bottomRight.dx)),
      min(min(topLeft.dy, topRight.dy), min(bottomLeft.dy, bottomRight.dy)),
      max(max(topLeft.dx, topRight.dx), max(bottomLeft.dx, bottomRight.dx)),
      max(max(topLeft.dy, topRight.dy), max(bottomLeft.dy, bottomRight.dy)),
    );
  }

  void applyToCanvas(Canvas canvas) {
    canvas.rotate(rotation);
    canvas.scale(size);
    canvas.translate(-position.dx, -position.dy);
  }

  double _getFinalTime(
    double velocity,
    double drag, {
    double effectivelyMotionless = 10,
  }) {
    final speed = velocity.abs();
    if (speed <= effectivelyMotionless) {
      return 0;
    }
    return log(effectivelyMotionless / speed) / log(drag);
  }

  FrictionSimulation _getSimulation(double velocity) =>
      FrictionSimulation(kDrag, 0, velocity);

  Offset _clampPosition(Offset position, Rect bounds) => Offset(
    position.dx.clamp(bounds.left, bounds.right),
    position.dy.clamp(bounds.top, bounds.bottom),
  );

  CameraTransform withFriction(
    Offset velocityPosition,
    double velocitySize, {
    Rect? positionBounds,
  }) {
    final simX = _getSimulation(velocityPosition.dx);
    final finalX = simX.finalX;
    final simY = _getSimulation(velocityPosition.dy);
    final finalY = simY.finalX;
    final durationPosition = _getFinalTime(velocityPosition.distance, kDrag);
    final finalPos = Offset(finalX, finalY);
    final simScale = _getSimulation(velocitySize);
    final finalSize = simScale.finalX;
    final durationSize = _getFinalTime(velocitySize, kDrag);
    final finalPosition = positionBounds == null
        ? position - finalPos
        : _clampPosition(position - finalPos, positionBounds);
    final finalScale = (size + finalSize).clamp(kMinZoom, kMaxZoom);
    var duration = max(durationPosition, durationSize);
    if (!duration.isFinite) {
      duration = 0;
    }
    if (duration <= 0) {
      if (finalPosition == position && finalScale == size) {
        return this;
      }
      duration = kBoundsSnapBackDuration;
    }
    final frictionState = FrictionState(
      finalPosition - position,
      finalScale - size,
      DateTime.now(),
      duration,
    );

    return CameraTransform(
      pixelRatio,
      finalPosition,
      finalScale,
      rotation,
      frictionState,
    );
  }

  CameraTransform withFrictionless(Offset position, double size) {
    return CameraTransform(
      pixelRatio,
      this.position - position,
      this.size - size,
      rotation,
      null,
    );
  }

  CameraTransform improve(RenderResolution resolution, Rect rect) {
    return CameraTransform(pixelRatio, rect.topLeft, size, 0, friction);
  }
}

class TransformCubit(double pixelRatio, [Offset? position])
    extends Cubit<CameraTransform> {
  this : super(CameraTransform(pixelRatio, position ?? .zero));

  void move(Offset delta) => emit(state.withPosition(state.position + delta));

  void teleport(Offset position, [double? scale, double? rotation]) => emit(
    state
        .withPosition(position)
        .withSize(scale ?? state.size)
        .withRotation(rotation ?? state.rotation),
  );

  void zoom(double delta, [Offset cursor = .zero]) =>
      emit(state.withSize(state.size * delta, cursor));

  void focus(Offset cursor) => emit(state.withSize(state.size, cursor));

  void rotate(double delta, [Offset cursor = .zero]) =>
      emit(state.withRotation(state.rotation + delta, cursor));

  void reset() => emit(CameraTransform(state.pixelRatio));

  void size(double size, [Offset cursor = .zero]) =>
      emit(state.withSize(size, cursor));

  void teleportToWaypoint(Waypoint waypoint) =>
      teleport(waypoint.position.toOffset(), waypoint.scale ?? state.size);

  /// 将 Mumu 标准分页纸张按当前视口尺寸自动居中适配，彻底告别“新建笔记像无限画布”的错觉。
  void fitMumuStandardPage({
    required DocumentPage page,
    required DocumentInfo info,
    required Size viewportSize,
    int sheetIndex = 0,
  }) {
    if (viewportSize.isEmpty) return;
    if (page.isMumuInfiniteCanvas(info)) {
      teleport(Offset.zero, 1.0, 0.0);
      return;
    }
    final sheets = page.resolvedPageSheets;
    final idx = sheetIndex.clamp(0, sheets.length - 1);
    final sheet = sheets[idx];
    final pageW = sheet.width > 80 ? sheet.width : kMumuDefaultPageWidth;
    final vw = viewportSize.width;
    final vh = viewportSize.height;
    final horizPad = (vw * 0.045).clamp(14.0, 44.0);
    final targetScreenW = min(vw - horizPad * 2, max(300.0, vh * 1.06));
    final fitScale = (targetScreenW / pageW).clamp(0.26, 1.35);
    final centeredX =
        sheet.rect.left - ((vw - pageW * fitScale) / 2.0) / fitScale;
    final topY = sheet.rect.top - (18.0 / fitScale);
    teleport(Offset(centeredX, topY), fitScale, 0.0);
  }

  void teleportToArea(
    Area area, [
    Size? screen,
    RenderResolution resolution = .performance,
  ]) {
    if (screen == null || area.width <= 0 || area.height <= 0) {
      teleport(area.position.toOffset(), state.size);
      return;
    }

    final effectiveScreen = screen / resolution.multiplier;
    final width = effectiveScreen.width / area.width;
    final height = effectiveScreen.height / area.height;
    final size = min(width, height).clamp(kMinZoom, kMaxZoom);
    final position =
        area.rect.center - effectiveScreen.center(Offset.zero) / size;
    teleport(position, size);
  }

  void slide(
    Offset velocityPosition,
    double velocitySize, {
    Rect? positionBounds,
  }) => emit(
    state.withFriction(
      velocityPosition,
      velocitySize,
      positionBounds: positionBounds,
    ),
  );

  Rect getContentRect(RendererCubit rendererCubit, [Area? currentArea]) {
    if (currentArea != null) {
      return currentArea.rect;
    }
    final renderers = rendererCubit.renderers;
    if (renderers.isEmpty) {
      return Rect.zero;
    }

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    for (final renderer in renderers) {
      final rect = renderer.expandedRect;
      if (rect != null) {
        minX = min(minX, rect.left);
        minY = min(minY, rect.top);
        maxX = max(maxX, rect.right);
        maxY = max(maxY, rect.bottom);
      }
    }

    if (minX == double.infinity) {
      return Rect.zero;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  bool _isNavigationRailVisible(EditorRuntimeContext runtime) {
    final settings = runtime.settingsCubit.state;
    final viewport = runtime.rendererCubit.state.cameraViewport;
    return settings.navigationRail &&
        settings.navigatorPosition == .left &&
        runtime.inputCubit.state.hideUi == .visible &&
        (viewport.width ?? 0) >= LeapBreakpoints.expanded &&
        (viewport.height ?? 0) >= 400;
  }

  Rect? calculateViewportBounds({
    required EditorRuntimeContext runtime,
    Area? currentArea,
    CameraTransform? customTransform,
    DocumentPage? page,
    DocumentInfo? info,
  }) {
    final transform = customTransform ?? state;
    final scale = transform.size <= 0 ? 1.0 : transform.size;
    final viewport = runtime.rendererCubit.state.cameraViewport;
    final rawVw = (viewport.width ?? 0).toDouble();
    final rawVh = (viewport.height ?? 0).toDouble();

    // Mumu 标准分页模式：将水平与垂直相机边界严格约束在纸张页面栈范围内，支持纵向连续滚动
    if (page != null &&
        !page.isMumuInfiniteCanvas(info) &&
        rawVw > 20 &&
        rawVh > 20) {
      final totalRect = page.totalSheetsBounds;
      final viewWGlobal = rawVw / scale;
      final viewHGlobal = rawVh / scale;

      if (page.isMumuHorizontalScroll) {
        final idealY = totalRect.top - (viewHGlobal - totalRect.height) / 2.0;
        final double minY = totalRect.height * scale <= rawVh * 1.04
            ? idealY - 24.0 / scale
            : totalRect.top - 48.0 / scale;
        final double maxY = totalRect.height * scale <= rawVh * 1.04
            ? idealY + 24.0 / scale
            : totalRect.bottom - viewHGlobal + 48.0 / scale;
        final double minX = totalRect.left - 36.0 / scale;
        final double maxX = max(
          minX,
          totalRect.right - viewWGlobal + 240.0 / scale,
        );
        return Rect.fromLTRB(minX, minY, maxX, maxY);
      } else {
        final idealX = totalRect.left - (viewWGlobal - totalRect.width) / 2.0;
        // 页面允许左右自由平移：横向留出至少一屏的活动空间（Mumu 可把纸面拖到任意位置）
        final horizontalSlack = max(viewWGlobal, totalRect.width * 0.35);
        final double minX = idealX - horizontalSlack;
        final double maxX = idealX + horizontalSlack;
        final double minY = totalRect.top - 36.0 / scale;
        final double maxY = max(
          minY,
          totalRect.bottom - viewHGlobal + 240.0 / scale,
        );
        return Rect.fromLTRB(minX, minY, maxX, maxY);
      }
    }

    final settings = runtime.settingsCubit.state;
    var multiplier = settings.limitViewportMultiplier;
    final positive = settings.limitViewportPositive;

    if (multiplier == null && !positive && currentArea == null) return null;

    final navigationRailOffset = _isNavigationRailVisible(runtime)
        ? kNavigationRailWidth / transform.size
        : 0.0;
    final size =
        Size(
          ((viewport.width ?? 0) / transform.size) - navigationRailOffset,
          (viewport.height ?? 0) / transform.size,
        ) /
        settings.renderResolution.multiplier;

    final contentRect = getContentRect(runtime.rendererCubit, currentArea);

    double minX = double.negativeInfinity;
    double minY = double.negativeInfinity;
    double maxX = double.infinity;
    double maxY = double.infinity;

    if (multiplier != null || currentArea != null) {
      multiplier ??= 1;
      final padX = size.width * multiplier;
      final padY = size.height * multiplier;

      minX = contentRect.left - padX;
      minY = contentRect.top - padY;
      maxX = contentRect.right - size.width + padX;
      maxY = contentRect.bottom - size.height + padY;

      if (minX > maxX) {
        final mid = (minX + maxX) / 2;
        minX = mid;
        maxX = mid;
      }
      if (minY > maxY) {
        final mid = (minY + maxY) / 2;
        minY = mid;
        maxY = mid;
      }
    }

    if (positive && currentArea == null) {
      minX = max(-navigationRailOffset, minX);
      minY = max(0.0, minY);
      maxX = max(-navigationRailOffset, maxX);
      maxY = max(0.0, maxY);
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  CameraTransform _clampTransform({
    required CameraTransform transform,
    required EditorRuntimeContext runtime,
  }) {
    final bounds = calculateViewportBounds(
      runtime: runtime,
      customTransform: transform,
    );
    if (bounds == null) return transform;
    return transform.withPosition(
      Offset(
        transform.position.dx.clamp(bounds.left, bounds.right),
        transform.position.dy.clamp(bounds.top, bounds.bottom),
      ),
    );
  }

  Area? getRelativeArea({
    required DocumentLoadSuccess docState,
    required EditorViewCubit viewCubit,
    required Area currentArea,
    required int dx,
    required int dy,
    bool? exact,
  }) {
    if (dx == 0 && dy == 0) return null;

    final rect = currentArea.rect.translate(
      dx.toDouble() * currentArea.rect.width,
      dy.toDouble() * currentArea.rect.height,
    );

    return docState.page.areas.firstWhereOrNull((area) {
      final currentAreaRect = area.rect;
      if (exact ?? viewCubit.state.areaNavigatorExact) {
        return (currentAreaRect.top - rect.top).abs() <
                precisionErrorTolerance &&
            (currentAreaRect.left - rect.left).abs() <
                precisionErrorTolerance &&
            (currentAreaRect.width - rect.width).abs() <
                precisionErrorTolerance &&
            (currentAreaRect.height - rect.height).abs() <
                precisionErrorTolerance;
      }
      return currentAreaRect.overlaps(rect.deflate(precisionErrorTolerance));
    });
  }

  void teleportToAreaEdge({
    required Area area,
    required int dx,
    required int dy,
    required EditorRuntimeContext runtime,
  }) {
    final newBounds = calculateViewportBounds(
      runtime: runtime,
      currentArea: area,
    );
    if (newBounds == null) return;

    final pos = state.position;
    double newX = pos.dx;
    double newY = pos.dy;
    if (dx > 0) {
      newX = newBounds.left;
    } else if (dx < 0) {
      newX = newBounds.right;
    } else {
      newX = newX.clamp(newBounds.left, newBounds.right);
    }
    if (dy > 0) {
      newY = newBounds.top;
    } else if (dy < 0) {
      newY = newBounds.bottom;
    } else {
      newY = newY.clamp(newBounds.top, newBounds.bottom);
    }
    teleport(Offset(newX, newY));
  }

  Future<void> navigateToRelativeArea({
    required DocumentBloc bloc,
    required EditorRuntimeContext runtime,
    required int dx,
    required int dy,
    Future<String?> Function()? createAreaName,
  }) async {
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;

    final current = docState.currentArea;
    if (current == null) return;

    var area = getRelativeArea(
      docState: docState,
      viewCubit: runtime.viewCubit,
      currentArea: current,
      dx: dx,
      dy: dy,
    );
    if (area != null) {
      bloc.add(CurrentAreaChanged(area.name));
      teleportToAreaEdge(area: area, dx: dx, dy: dy, runtime: runtime);
      return;
    }

    if (!runtime.viewCubit.state.areaNavigatorCreate ||
        createAreaName == null) {
      return;
    }
    final name = await createAreaName();
    if (name == null) return;

    final rect = current.rect.translate(
      dx.toDouble() * current.rect.width,
      dy.toDouble() * current.rect.height,
    );

    final newArea = Area(
      position: rect.topLeft.toPoint(),
      height: rect.height,
      width: rect.width,
      name: name,
    );
    bloc.add(AreasCreated([AreaPreset(area: newArea)]));
    bloc.add(CurrentAreaChanged(name));
    teleportToAreaEdge(area: newArea, dx: dx, dy: dy, runtime: runtime);
  }

  void moveConstrained(
    Offset delta, {
    required EditorRuntimeContext runtime,
    DocumentBloc? bloc,
    bool force = false,
    Area? currentArea,
  }) {
    final locks = runtime.viewCubit.state.locks;
    final docState = bloc?.state;
    final loadedState = docState is DocumentLoadSuccess ? docState : null;
    if (!force) {
      if (locks.lockHorizontal) delta = Offset(0, delta.dy);
      if (locks.lockVertical) delta = Offset(delta.dx, 0);

      final bounds = calculateViewportBounds(
        runtime: runtime,
        currentArea: currentArea,
        page: loadedState?.page,
        info: loadedState?.info,
      );
      if (bounds != null) {
        final pos = state.position;
        var newPos = pos + delta;
        final clampedPos = Offset(
          newPos.dx.clamp(bounds.left, bounds.right),
          newPos.dy.clamp(bounds.top, bounds.bottom),
        );

        // Mumu 标准分页模式：下滑到底部越界时实时更新上拉加页进度，并在达到阈值时自动追加新页面
        if (loadedState != null &&
            bloc != null &&
            !loadedState.page.isMumuInfiniteCanvas(loadedState.info) &&
            loadedState.page.isMumuPullToAddPageEnabled) {
          final viewport = runtime.rendererCubit.state.cameraViewport;
          final scale = state.size <= 0 ? 1.0 : state.size;
          final rawVh = (viewport.height ?? 0).toDouble();
          final rawVw = (viewport.width ?? 0).toDouble();
          final totalRect = loadedState.page.totalSheetsBounds;
          final isHoriz = loadedState.page.isMumuHorizontalScroll;
          final forwardScrolling = isHoriz ? delta.dx > 0.2 : delta.dy > 0.2;

          if (rawVh > 20 && rawVw > 20) {
            final visibleEdgeGlobal = isHoriz
                ? (clampedPos.dx + rawVw / scale)
                : (clampedPos.dy + rawVh / scale);
            final sheetEndGlobal = isHoriz ? totalRect.right : totalRect.bottom;
            final overscrollPx = (visibleEdgeGlobal - sheetEndGlobal) * scale;

            if (overscrollPx > 24.0 && forwardScrolling) {
              final prog = ((overscrollPx - 24.0) / 84.0).clamp(0.0, 1.0);
              PalmGuardService.instance.updatePullUpProgress(prog);
              if (overscrollPx >= 108.0 &&
                  PalmGuardService.instance.canTriggerBottomPageAdd()) {
                final nextSheet = loadedState.page.buildNextPageSheet();
                final presets = <AreaPreset>[
                  if (loadedState.page.areas.isEmpty)
                    AreaPreset(area: loadedState.page.resolvedPageSheets.first),
                  AreaPreset(area: nextSheet),
                ];
                bloc.add(AreasCreated(presets));
              }
            } else if (overscrollPx <= 12.0 &&
                PalmGuardService.instance.telemetry.pullUpProgress > 0.0) {
              PalmGuardService.instance.updatePullUpProgress(0.0);
            }
          }
        }

        if (currentArea != null &&
            loadedState != null &&
            (clampedPos.dx != newPos.dx || clampedPos.dy != newPos.dy)) {
          int dx = 0;
          int dy = 0;
          if (newPos.dx < bounds.left) {
            dx = -1;
          } else if (newPos.dx > bounds.right) {
            dx = 1;
          }

          if (newPos.dy < bounds.top) {
            dy = -1;
          } else if (newPos.dy > bounds.bottom) {
            dy = 1;
          }

          if ((dx != 0 || dy != 0) &&
              runtime.settingsCubit.state.hasFlag('edgePanAreaSwitching')) {
            final area = getRelativeArea(
              docState: loadedState,
              viewCubit: runtime.viewCubit,
              currentArea: currentArea,
              dx: dx,
              dy: dy,
            );
            if (area != null) {
              bloc?.add(CurrentAreaChanged(area.name));
              teleportToAreaEdge(area: area, dx: dx, dy: dy, runtime: runtime);
              return;
            }
          }
        }

        delta = clampedPos - pos;
      }
    }

    if (delta.dx == 0 && delta.dy == 0) {
      return;
    }
    move(delta);
  }

  void zoomConstrained(
    double delta, {
    required EditorRuntimeContext runtime,
    Offset cursor = .zero,
    bool force = false,
  }) {
    final locks = runtime.viewCubit.state.locks;
    if (locks.lockZoom && !force) {
      delta = 1;
    }
    if (delta == 1) {
      return;
    }
    if (force) {
      zoom(delta, cursor);
      return;
    }
    final transform = state.withSize(state.size * delta, cursor);
    final clamped = _clampTransform(transform: transform, runtime: runtime);
    teleport(clamped.position, clamped.size);
  }

  void rotateConstrained(
    double delta, {
    required EditorRuntimeContext runtime,
    Offset cursor = .zero,
    bool force = false,
  }) {
    if (delta == 0 || (runtime.viewCubit.state.locks.lockRotation && !force)) {
      return;
    }
    rotate(delta, cursor);
  }

  void sizeConstrained(
    double size, {
    required EditorRuntimeContext runtime,
    Offset cursor = .zero,
    bool force = false,
  }) {
    final locks = runtime.viewCubit.state.locks;
    if (locks.lockZoom && !force) return;
    if (force) {
      this.size(size, cursor);
      return;
    }
    final transform = _clampTransform(
      transform: state.withSize(size, cursor),
      runtime: runtime,
    );
    teleport(transform.position, transform.size);
  }

  void slideConstrained(
    Offset positionVelocity,
    double sizeVelocity, {
    required EditorRuntimeContext runtime,
    bool force = false,
    Area? currentArea,
  }) {
    final settings = runtime.settingsCubit.state;
    if (!settings.hasFlag('smoothNavigation')) return;
    final locks = runtime.viewCubit.state.locks;
    Rect? bounds;
    var outOfBounds = false;
    if (!force) {
      if (locks.lockHorizontal) {
        positionVelocity = Offset(0, positionVelocity.dy);
      }
      if (locks.lockVertical) {
        positionVelocity = Offset(positionVelocity.dx, 0);
      }
      if (locks.lockZoom) sizeVelocity = 0;

      bounds = calculateViewportBounds(
        runtime: runtime,
        currentArea: currentArea,
      );
      if (bounds != null) {
        final pos = state.position;
        final clampedPos = Offset(
          pos.dx.clamp(bounds.left, bounds.right),
          pos.dy.clamp(bounds.top, bounds.bottom),
        );
        outOfBounds = clampedPos != pos;
        var vX = positionVelocity.dx;
        var vY = positionVelocity.dy;

        if (pos.dx >= bounds.right && vX > 0) {
          vX = 0;
        }
        if (pos.dx <= bounds.left && vX < 0) {
          vX = 0;
        }
        if (pos.dy >= bounds.bottom && vY > 0) {
          vY = 0;
        }
        if (pos.dy <= bounds.top && vY < 0) {
          vY = 0;
        }

        positionVelocity = Offset(vX, vY);
      }
    }

    if (positionVelocity.dx == 0 &&
        positionVelocity.dy == 0 &&
        sizeVelocity == 0 &&
        !outOfBounds) {
      return;
    }
    slide(positionVelocity, sizeVelocity, positionBounds: bounds);
  }
}
