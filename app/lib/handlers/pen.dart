part of 'handler.dart';

class PenHandler extends Handler<PenTool> with ColoredHandler {
  bool _hideCursorWhileDrawing = false;
  final Map<int, PenElement> elements = {};
  final Map<int, List<PathPoint>> _elementPoints = {};
  final List<PenElement> _submittedElements = [];
  final Map<int, Offset> lastPosition = {};
  final Map<int, OneEuroFilter2D> _pointerOneEuroFilters = {};
  final points = <Offset>[];
  bool isDrawing = false;
  Timer? _positionCheckTimer;
  Offset? lastPosit;
  Offset? localPos;
  late final PointerCancelCallback _cancelPointerListener;

  PenHandler(super.data) {
    PalmGuardService.instance.init();
    _cancelPointerListener = (cancelledPid) {
      final bloc = _bloc;
      if (bloc != null && !bloc.isClosed) {
        rollbackPointerStroke(bloc, cancelledPid);
      } else {
        elements.remove(cancelledPid);
        _elementPoints.remove(cancelledPid);
        lastPosition.remove(cancelledPid);
        _pointerOneEuroFilters.remove(cancelledPid);
      }
    };
    PalmGuardService.instance.registerPointerCancelCallback(
      _cancelPointerListener,
    );
    PalmGuardService.instance.onRollbackPointerStroke = _cancelPointerListener;
  }

  /// 160ms 小指抢先落屏幽灵短笔迹、80ms 手掌压实膨胀、双指缩放启动或原生 cancelPointer 触发时，立即抹除指定 pointer 的候选笔迹
  void rollbackPointerStroke(DocumentBloc bloc, int cancelledPointerId) {
    elements.remove(cancelledPointerId);
    _elementPoints.remove(cancelledPointerId);
    lastPosition.remove(cancelledPointerId);
    _pointerOneEuroFilters.remove(cancelledPointerId);
    if (elements.isEmpty) {
      isDrawing = false;
      _positionCheckTimer?.cancel();
      _positionCheckTimer = null;
      points.clear();
    }
    unawaited(bloc.delayedRefreshForegrounds());
  }

  /// 系统三指截屏触发 ACTION_CANCEL 时的防丢字保护：截去末尾少量抖动点并正常提交已写好的长笔画
  void commitProtectedOnCancel(DocumentBloc bloc, int pointerId) {
    final pts = _elementPoints[pointerId];
    if (pts != null && pts.length > 4) {
      final cutCount = min(2, pts.length ~/ 5);
      final trimmed = pts.sublist(0, pts.length - cutCount);
      _elementPoints[pointerId] = trimmed;
      final el = elements[pointerId];
      if (el != null) {
        elements[pointerId] = el.copyWith(points: trimmed);
      }
    }
    submitElements(bloc, [pointerId]);
  }

  @override
  List<Renderer> createForegrounds(
    EditorController editorController,
    NoteData document,
    DocumentPage page,
    DocumentInfo info, [
    Area? currentArea,
  ]) => [...elements.values, ..._submittedElements]
      .map(
        (e) => e.points.length > 1
            ? PenRenderer(e.copyWith(id: createUniqueId()))
            : null,
      )
      .whereType<Renderer>()
      .toList();

  @override
  void resetInput(DocumentBloc bloc) {
    submitElements(bloc, elements.keys.toList());
    _positionCheckTimer?.cancel();
    _positionCheckTimer = null;
    elements.clear();
    _elementPoints.clear();
    lastPosition.clear();
    _pointerOneEuroFilters.clear();
    points.clear();
    lastPosit = null;
  }

  @override
  void onPointerUp(PointerUpEvent event, EventContext context) {
    if (PalmGuardService.instance.isPointerRejected(event.pointer)) {
      _pointerOneEuroFilters.remove(event.pointer);
      return;
    }
    isDrawing = false;
    _positionCheckTimer?.cancel();
    _positionCheckTimer = null;

    final docBloc = context.getDocumentBloc();
    _bloc = docBloc;

    final exitFlickPoints = PalmGuardService.instance.evaluatePointerUp(event);
    if (event.kind == PointerDeviceKind.touch && exitFlickPoints.isNotEmpty) {
      for (final flick in exitFlickPoints) {
        addPoint(
          context.buildContext,
          event.pointer,
          flick.localPos,
          context.viewportSize,
          flick.pressure,
          event.kind,
          refresh: false,
          alreadyFiltered: true,
        );
      }
    } else {
      addPoint(
        context.buildContext,
        event.pointer,
        event.localPosition,
        context.viewportSize,
        getPressureOfEvent(event),
        event.kind,
        refresh: false,
      );
    }

    lastPosition.remove(event.pointer);
    _pointerOneEuroFilters.remove(event.pointer);
    submitElements(docBloc, [event.pointer]);
    points.clear();
    lastPosit = null;
  }

  DocumentBloc? _bloc;

  Future<void> submitElements(DocumentBloc bloc, List<int> indexes) async {
    _bloc = bloc;
    final elements = indexes
        .map((e) {
          final element = this.elements.remove(e);
          final points = _elementPoints.remove(e);
          _pointerOneEuroFilters.remove(e);
          if (element == null) return null;
          return points == null
              ? element
              : element.copyWith(points: List<PathPoint>.of(points));
        })
        .nonNulls
        .toList();
    if (elements.isEmpty) return;
    _submittedElements.addAll(elements);
    lastPosition.removeWhere((key, value) => indexes.contains(key));
    bloc.add(ElementsCreated(elements));
    bloc.refresh(allowBake: false);
  }

  @override
  bool onRenderersCreated(DocumentPage page, List<Renderer> renderers) {
    if (_submittedElements.isEmpty) return false;
    final createdIds = renderers
        .map((renderer) => renderer.element)
        .whereType<PenElement>()
        .map((element) => element.id)
        .nonNulls
        .toSet();
    if (createdIds.isEmpty) return false;
    final previousLength = _submittedElements.length;
    _submittedElements.removeWhere((e) => createdIds.contains(e.id));
    final changed = previousLength != _submittedElements.length;
    if (changed && _submittedElements.isEmpty && elements.isEmpty) {
      unawaited(_bloc?.delayedBake());
    }
    return changed;
  }

  @override
  Future<void> onViewportUpdated(
    CameraViewport currentViewport,
    CameraViewport newViewport,
  ) async {
    if (_submittedElements.isEmpty) return;
    final submittedIds = _submittedElements.map((e) => e.id).nonNulls.toSet();
    final viewportIds = [
      ...newViewport.bakedElements,
      ...newViewport.unbakedElements,
    ].map((renderer) => renderer.element.id).nonNulls.toSet();
    if (submittedIds.intersection(viewportIds).isNotEmpty) return;
    _submittedElements.clear();
    await _bloc?.refresh(allowBake: false);
    if (elements.isEmpty) {
      await _bloc?.delayedBake();
    }
  }

  bool _isWritablePoint(DocumentLoadSuccess state, Offset global) {
    final page = state.page;
    if (page.isMumuInfiniteCanvas(state.info)) return true;
    final sheets = page.resolvedPageSheets;
    if (sheets.isEmpty) return true;
    for (final area in sheets) {
      if (global.dx >= area.position.x &&
          global.dx <= area.position.x + area.width &&
          global.dy >= area.position.y &&
          global.dy <= area.position.y + area.height) {
        return true;
      }
    }
    return false;
  }

  void addPoint(
    BuildContext context,
    int pointer,
    Offset localPos,
    Size viewportSize,
    double pressure,
    PointerDeviceKind kind, {
    bool refresh = true,
    bool shouldCreate = false,
    bool alreadyFiltered = false,
  }) {
    final bloc = context.read<DocumentBloc>();
    _bloc = bloc;
    final editorController = context.read<EditorController>();
    final transform = context.read<TransformCubit>().state;

    // 一欧元自适应平滑滤波（1€ Filter）：对低速移动采用较低截止频率消除抖动锯齿，对高速书写动态提升截止频率消除跟手延迟
    if (!alreadyFiltered &&
        PalmGuardService.instance.telemetry.oneEuroFilterEnabled) {
      final filter = _pointerOneEuroFilters.putIfAbsent(
        pointer,
        () => OneEuroFilter2D(minCutoff: 1.25, beta: 0.035, dCutoff: 1.0),
      );
      localPos = filter.filter(
        localPos,
        DateTime.now().millisecondsSinceEpoch,
      );
    }

    localPos = PointerManipulationHandler.calculatePointerPosition(
      editorController.toolCubit.state,
      localPos,
      viewportSize,
      transform,
    );
    final globalPos = transform.localToGlobal(localPos);
    if (!bloc.isInBounds(globalPos)) return;
    final state = bloc.state as DocumentLoadSuccess;
    // 只允许在纸张页面内书写：页面之外的空白画布区域不接受笔迹
    if (!_isWritablePoint(state, globalPos)) {
      return;
    }
    final settings = context.read<SettingsCubit>().state;
    final penOnlyInput =
        PalmGuardService.instance.state.penOnlyMode ||
        editorController.inputCubit.effectivePenOnlyInput;
    if (lastPosition[pointer] == localPos) return;
    lastPosition[pointer] = localPos;
    final isVerifiedCapacitiveStylus =
        PalmGuardService.instance.activeStylusPointerId == pointer &&
        !PalmGuardService.instance.isPointerRejected(pointer);
    if (penOnlyInput &&
        !isVerifiedCapacitiveStylus &&
        (kind != .stylus && kind != .invertedStylus)) {
      return;
    }
    if (settings.ignorePressure == .always) {
      pressure = 1;
    }
    double zoom = data.zoomDependent ? transform.size : 1;
    final createNew = !elements.containsKey(pointer);
    if (createNew && !shouldCreate) return;
    final element = elements[pointer];
    final point = PathPoint.fromPoint(globalPos.toPoint(), pressure);
    if (element != null) {
      final points = _elementPoints[pointer] ?? element.points.toList();
      points.add(point);
      if (points.length == 2 && settings.ignorePressure == .first) {
        points[0] = points[0].copyWith(pressure: pressure);
      }
      _elementPoints[pointer] = points;
      elements[pointer] = element.copyWith(points: points);
    } else {
      final points = [point];
      _elementPoints[pointer] = points;
      elements[pointer] = PenElement(
        id: createUniqueId(),
        zoom: transform.size,
        combineId: data.combinePaths ? data.id : null,
        collection: state.currentCollection,
        property: data.property.copyWith(
          strokeWidth: data.property.strokeWidth / zoom,
        ),
        points: points,
      );
    }
    if (refresh) unawaited(bloc.delayedRefreshForegrounds());
  }

  @override
  void onPointerDown(PointerDownEvent event, EventContext context) {
    if (PalmGuardService.instance.isPointerRejected(event.pointer)) {
      return;
    }
    final initialState = context.getState();
    if (initialState != null) {
      final globalDown =
          context.getCameraTransform().localToGlobal(event.localPosition);
      if (!_isWritablePoint(initialState, globalDown)) return;
    }
    final cubit = context.getEditorController();
    _bloc = context.getDocumentBloc();
    cubit.rendererCubit.cancelDelayedBake();
    isDrawing = true;
    changeStartedDrawing(context);
    _hideCursorWhileDrawing = context.getSettings().hideCursorWhileDrawing;
    if (cubit.inputCubit.moveEnabled && event.kind != .stylus) {
      elements.clear();
      context.refreshForegrounds();
      return;
    }
    elements.remove(event.pointer);
    _elementPoints.remove(event.pointer);
    _pointerOneEuroFilters.remove(event.pointer);
    final initialPressure = event.kind == PointerDeviceKind.touch
        ? (PalmGuardService.instance.telemetry.simulatedTaperEnabled
              ? 0.35
              : 0.55)
        : getPressureOfEvent(event);
    addPoint(
      context.buildContext,
      event.pointer,
      event.localPosition,
      context.viewportSize,
      initialPressure,
      event.kind,
      shouldCreate: true,
    );
  }

  @override
  void onPointerMove(PointerMoveEvent event, EventContext context) {
    if (!isDrawing) return;
    if (PalmGuardService.instance.isPointerRejected(event.pointer)) {
      return;
    }
    final moveEval = PalmGuardService.instance.evaluatePointerMove(
      event,
      context.viewportSize,
    );
    if (moveEval.rejected) {
      return;
    }

    final effectivePos = event.kind == PointerDeviceKind.touch
        ? moveEval.filteredLocalPos
        : event.localPosition;
    final effectivePressure = event.kind == PointerDeviceKind.touch
        ? moveEval.simulatedPressure
        : getPressureOfEvent(event);

    if (lastPosit == effectivePos) return;
    lastPosit = effectivePos;
    _positionCheckTimer?.cancel();
    _positionCheckTimer = Timer(
      Duration(milliseconds: (data.shapeDetectionTime * 1000).round()),
      () {
        _tickShapeDetection(event.pointer, context, effectivePos);
      },
    );
    addPoint(
      context.buildContext,
      event.pointer,
      effectivePos,
      context.viewportSize,
      effectivePressure,
      event.kind,
      alreadyFiltered: event.kind == PointerDeviceKind.touch,
    );
    points.add(effectivePos);
  }

  void showMessage(EventContext context, String recognizedShape) {
    ScaffoldMessenger.of(context.buildContext).showSnackBar(
      SnackBar(
        width: MediaQuery.sizeOf(context.buildContext).width * 0.1,
        behavior: SnackBarBehavior.floating,
        content: Text(textAlign: .center, recognizedShape),
        duration: const Duration(milliseconds: 300),
      ),
    );
  }

  void _tickShapeDetection(
    int pointer,
    EventContext context,
    Offset localPosition,
  ) {
    if (!data.shapeDetectionEnabled) return;
    final element = elements[pointer];
    if (element == null || points.length > 600 || points.isEmpty) {
      return;
    }

    final transform = context.getCameraTransform();
    final creationTransform = CameraTransform(
      transform.pixelRatio,
      transform.position.rotate(Offset.zero, transform.rotation),
      transform.size,
    );
    final recognized = recognizeUnistroke(points);
    final state = context.getState();
    final currentCollection = state!.currentCollection;

    if (recognized == null) {
      return;
    }
    PadElement? shapeElement;
    switch (recognized.name) {
      case .line:
        double startX = points.first.dx;
        double startY = points.first.dy;
        double endX = points.last.dx;
        double endY = points.last.dy;

        Point<double> firstPosition = Point(startX, startY);
        Point<double> secondPosition = Point(endX, endY);

        Offset firstPositionInView = creationTransform.localToGlobal(
          firstPosition.toOffset(),
        );
        Offset secondPositionInView = creationTransform.localToGlobal(
          secondPosition.toOffset(),
        );

        shapeElement = PadElement.shape(
          id: createUniqueId(),
          firstPosition: firstPositionInView.toPoint(),
          secondPosition: secondPositionInView.toPoint(),
          property: ShapeProperty(
            shape: const LineShape(),
            paint: data.property.paint,
            strokeWidth: data.property.strokeWidth,
          ),
          collection: currentCollection,
        );

        showMessage(context, AppLocalizations.of(context.buildContext).line);
      case .circle:
        double centerX =
            points.map((p) => p.dx).reduce((a, b) => a + b) / points.length;
        double centerY =
            points.map((p) => p.dy).reduce((a, b) => a + b) / points.length;
        Offset center = .new(centerX, centerY);

        double radius =
            points.map((p) => (p - center).distance).reduce((a, b) => a + b) /
            points.length;

        Point<double> firstPosition = Point<double>(
          center.dx - radius,
          center.dy - radius,
        );
        Point<double> secondPosition = Point<double>(
          center.dx + radius,
          center.dy + radius,
        );

        Offset firstPositionInView = creationTransform.localToGlobal(
          firstPosition.toOffset(),
        );
        Offset secondPositionInView = creationTransform.localToGlobal(
          secondPosition.toOffset(),
        );

        shapeElement = PadElement.shape(
          id: createUniqueId(),
          firstPosition: firstPositionInView.toPoint(),
          secondPosition: secondPositionInView.toPoint(),
          property: ShapeProperty(
            shape: const CircleShape(),
            paint: data.property.paint,
            strokeWidth: data.property.strokeWidth,
          ),
          collection: currentCollection,
        );

        showMessage(context, AppLocalizations.of(context.buildContext).circle);
      case .rectangle:
        double minX = points.map((p) => p.dx).reduce(min);
        double maxX = points.map((p) => p.dx).reduce(max);
        double minY = points.map((p) => p.dy).reduce(min);
        double maxY = points.map((p) => p.dy).reduce(max);

        Point<double> firstPosition = Point(minX, minY);
        Point<double> secondPosition = Point(maxX, maxY);

        Offset firstPositionInView = creationTransform.localToGlobal(
          firstPosition.toOffset(),
        );
        Offset secondPositionInView = creationTransform.localToGlobal(
          secondPosition.toOffset(),
        );

        shapeElement = PadElement.shape(
          id: createUniqueId(),
          firstPosition: firstPositionInView.toPoint(),
          secondPosition: secondPositionInView.toPoint(),
          property: ShapeProperty(
            shape: const RectangleShape(),
            paint: data.property.paint,
            strokeWidth: data.property.strokeWidth,
          ),
          collection: currentCollection,
        );
      case .triangle:
        double minX = points.map((p) => p.dx).reduce(min);
        double maxX = points.map((p) => p.dx).reduce(max);
        double minY = points.map((p) => p.dy).reduce(min);
        double maxY = points.map((p) => p.dy).reduce(max);

        Point<double> firstPosition = Point(minX, minY);
        Point<double> secondPosition = Point(maxX, maxY);

        Offset firstPositionInView = creationTransform.localToGlobal(
          firstPosition.toOffset(),
        );
        Offset secondPositionInView = creationTransform.localToGlobal(
          secondPosition.toOffset(),
        );

        shapeElement = PadElement.shape(
          id: createUniqueId(),
          firstPosition: firstPositionInView.toPoint(),
          secondPosition: secondPositionInView.toPoint(),
          property: ShapeProperty(
            shape: const TriangleShape(),
            paint: data.property.paint,
            strokeWidth: data.property.strokeWidth,
          ),
          collection: currentCollection,
        );
      default:
    }
    if (shapeElement != null) {
      context.getDocumentBloc().add(
        ElementsCreated([
          orientCreatedElement(shapeElement, transform.rotation),
        ]),
      );

      elements.clear();
      context.refresh();
    }
    points.clear();
  }

  @override
  void onScaleStartAbort(ScaleStartDetails details, EventContext context) {
    if (PalmGuardService.instance.isWritingLocked) {
      return;
    }
    _positionCheckTimer?.cancel();
    _positionCheckTimer = null;
    elements.clear();
    _elementPoints.clear();
    lastPosition.clear();
    _pointerOneEuroFilters.clear();
    points.clear();
    lastPosit = null;
    context.refresh();
  }

  @override
  void dispose(DocumentBloc bloc) {
    PalmGuardService.instance.unregisterPointerCancelCallback(
      _cancelPointerListener,
    );
    _positionCheckTimer?.cancel();
    _positionCheckTimer = null;
    elements.clear();
    _elementPoints.clear();
    _submittedElements.clear();
    lastPosition.clear();
    _pointerOneEuroFilters.clear();
    points.clear();
    isDrawing = false;
    lastPosit = null;
    _bloc = null;
  }

  @override
  SRGBColor getColor() => data.property.paint.previewColor;

  @override
  PenTool setColor(SRGBColor color) => data.copyWith(
    property: data.property.copyWith(
      paint: ElementPaint.solid(
        color: color.withValues(a: getColor().a),
        blur: data.property.paint.blur,
      ),
    ),
  );

  @override
  double getStrokeWidth() => data.property.strokeWidth;

  @override
  PenTool setStrokeWidth(double width) =>
      data.copyWith(property: data.property.copyWith(strokeWidth: width));

  @override
  MouseCursor get cursor => (_hideCursorWhileDrawing && elements.isNotEmpty)
      ? SystemMouseCursors.none
      : SystemMouseCursors.precise;

  @override
  Map<String, RendererState> get rendererStates => Map.fromEntries(
    _submittedElements.map((e) => MapEntry(e.id!, RendererState.hidden)),
  );
}
