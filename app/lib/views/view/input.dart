part of '../view.dart';

class _ViewportInputCoordinator {
  _ViewportInputCoordinator(this._settleSlide, this._context) {
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  final void Function(TransformCubit transformCubit) _settleSlide;
  final BuildContext _context;
  final Map<int, PointerDeviceKind> _pointerKinds = {};
  final PointerShortcutManager _shortcutManager = .new();
  int? _heldShortcutKeyId;

  double _gestureScale = 1;
  double _gestureRotation = 0;
  int _gesturePointerCount = 0;
  bool? _handlerHandlesScaleGesture;
  int? _singleFingerPanPointer;
  RulerHandler? _ruler;
  int? _rulerPointer;
  ({int pointer, Offset center, Offset previous})? _rotationDrag;
  bool _cameraRotationGesture = false;

  bool get isCameraRotationGesture => _cameraRotationGesture;

  bool _rotationShortcutPressed(HardwareKeyboard keyboard) {
    final activator = keybinder.getActivator(rotateDragShortcut.id);
    if (activator is! SingleActivator) return false;
    return keyboard.logicalKeysPressed.contains(activator.trigger) &&
        keyboard.isShiftPressed == activator.shift &&
        keyboard.isControlPressed == activator.control &&
        keyboard.isAltPressed == activator.alt &&
        keyboard.isMetaPressed == activator.meta;
  }

  bool get _isHandlerGesture => _handlerHandlesScaleGesture ?? true;

  void reset() {
    _shortcutManager.reset();
    _pointerKinds.clear();
    _rotationDrag = null;
    _cameraRotationGesture = false;
    _resetRulerInteraction();
    _handlerHandlesScaleGesture = null;
    _heldShortcutKeyId = null;
  }

  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _shortcutManager.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyUpEvent || event.logicalKey.keyId != _heldShortcutKeyId) {
      return false;
    }
    _releaseHoldShortcut();
    return false;
  }

  void _releaseHoldShortcut() {
    _heldShortcutKeyId = null;
    final cubit = _context.read<EditorController>();
    if (cubit.inputCubit.state.pointers.isNotEmpty) {
      cubit.toolCubit.setTemporaryState(TemporaryState.removeAfterRelease);
    } else {
      cubit.toolCubit.resetTemporaryHandler(
        _context.read<DocumentBloc>(),
        true,
        cubit.rendererCubit,
      );
    }
  }

  void beginTrackpadGesture() => _handlerHandlesScaleGesture = false;

  EventContext createEventContext(BuildContext context, Size viewportSize) {
    final keyboard = HardwareKeyboard.instance;
    return EventContext(
      context,
      viewportSize,
      keyboard.isShiftPressed,
      keyboard.isAltPressed,
      keyboard.isControlPressed,
    );
  }

  bool _isTouchMoveGesture(EditorController controller) {
    if (!controller.settingsCubit.state.moveOnGesture) return false;
    final pointers = controller.inputCubit.state.pointers;
    if (pointers.isEmpty) return false;
    final allTouch = pointers.every((p) => _pointerKinds[p] == .touch);
    if (!allTouch) return false;
    if (pointers.length >= 2) return true;
    final pid = pointers.first;
    final pg = PalmGuardService.instance;
    if (pg.telemetry.fingerActionMode == 'SINGLE_FINGER_PAN') return true;
    if (pg.state.penOnlyMode && pg.activeStylusPointerId != pid) return true;
    return false;
  }

  Future<void> handlePointerDown(
    PointerDownEvent event,
    _PointerInputContext input, {
    bool skipShortcuts = false,
  }) async {
    final cubit = input.cubit;
    final getHandler = input.getHandler;
    final getEventContext = input.getEventContext;
    final eventContext = getEventContext();

    if (PalmGuardService.instance.evaluatePointerDown(
      event,
      eventContext.viewportSize,
    )) {
      return;
    }

    // 页间空白处禁止落笔/落图/落文本（仅手写笔模式下，触摸仍用于拖动纸面）
    final previewHandler = input.getHandler();
    final createsElement = previewHandler is PenHandler ||
        previewHandler is ShapeHandler ||
        previewHandler is LabelHandler ||
        previewHandler is StampHandler ||
        previewHandler is LaserHandler;
    final docState = input.state;
    if (createsElement &&
        docState is DocumentLoadSuccess &&
        !(cubit.inputCubit.effectivePenOnlyInput &&
            event.kind == PointerDeviceKind.touch)) {
      final globalDown = eventContext.getCameraTransform().localToGlobal(
        event.localPosition,
      );
      if (!docState.page.containsGlobalPoint(globalDown, docState.info)) {
        return;
      }
    }

    if (!skipShortcuts && cubit.inputCubit.state.pointers.isEmpty) {
      _cameraRotationGesture = false;
      final keyboard = HardwareKeyboard.instance;
      if (event.kind != PointerDeviceKind.touch &&
          event.kind != PointerDeviceKind.trackpad &&
          _rotationShortcutPressed(keyboard) &&
          !cubit.isEditingText) {
        _settleSlide(cubit.transformCubit);
        _cameraRotationGesture = true;
        _handlerHandlesScaleGesture = false;
        _rotationDrag = (
          pointer: event.pointer,
          center: eventContext.viewportSize.center(Offset.zero),
          previous: event.localPosition,
        );
        _pointerKinds[event.pointer] = event.kind;
        cubit.inputCubit.addPointer(event.pointer);
        cubit.inputCubit.setButtons(event.buttons);
        return;
      }
    }
    if (_cameraRotationGesture) return;
    if (!skipShortcuts && cubit.inputCubit.state.pointers.isEmpty) {
      _settleSlide(cubit.transformCubit);
      _handlerHandlesScaleGesture = event.kind == .trackpad ? false : null;
    }
    if (!skipShortcuts) {
      if (event.kind == .stylus || event.kind == .invertedStylus) {
        cubit.inputCubit.detectPen(true);
      }
      final result = _shortcutManager.pointerDown(
        event,
        input.context.read<SettingsCubit>().state.inputConfiguration,
      );
      await _replayPointerEvents(result.releasedEvents, input);
      if (result.consumed) return;
    }

    _pointerKinds[event.pointer] = event.kind;
    cubit.inputCubit.addPointer(event.pointer);
    cubit.inputCubit.setButtons(event.buttons);

    if (cubit.inputCubit.state.pointers.length >= 2 &&
        !PalmGuardService.instance.isWritingLocked) {
      PalmGuardService.instance.abortUnconfirmedTracksForMultiTouch();
      _handlerHandlesScaleGesture = false;
      return;
    }

    final handler = getHandler();
    final ruler = RulerHandler.getInteractiveRuler(
      cubit.toolCubit.state,
      handler,
      event.localPosition,
      eventContext.viewportSize,
    );
    if (event.kind != .touch && ruler != null) {
      _ruler = ruler;
      _rulerPointer = event.pointer;
      ruler.beginTransform(event.localPosition);
      return;
    }
    if (handler.canChange(event, eventContext)) {
      await _changeTemporaryTool(event.kind, event.buttons, input);
    }
    if (_isHandlerGesture) {
      await getHandler().onPointerDown(event, eventContext);
    }
  }

  bool _trySingleFingerPagePan(
    PointerMoveEvent event,
    _PointerInputContext input,
  ) {
    if (event.kind != PointerDeviceKind.touch) return false;
    final cubit = input.cubit;
    final settings = input.context.read<SettingsCubit>().state;
    if (!settings.moveOnGesture) return false;
    if (!cubit.inputCubit.effectivePenOnlyInput) return false;
    if (cubit.inputCubit.state.pointers.length != 1) return false;
    final activeStylus = PalmGuardService.instance.activeStylusPointerId;
    if (activeStylus != null && activeStylus != event.pointer) return false;
    final handler = input.getHandler();
    if (handler is PenHandler && handler.elements.containsKey(event.pointer)) {
      return false;
    }
    final existing = _singleFingerPanPointer;
    if (existing != null && existing != event.pointer) return false;
    _singleFingerPanPointer = event.pointer;
    final tele = PalmGuardService.instance.telemetry;
    final resistance = tele.freePageMoveEnabled
        ? (1.0 - tele.dragResistance * 0.65).clamp(0.25, 1.0)
        : 1.0;
    final delta =
        cubit.transformCubit.state.localToGlobalDelta(-event.delta) *
        (settings.panGestureSensitivity * resistance);
    cubit.transformCubit.moveConstrained(
      delta,
      runtime: cubit,
      bloc: input.bloc,
      currentArea: input.state.currentArea,
    );
    input.delayBake();
    return true;
  }

  Future<void> handlePointerMove(
    PointerMoveEvent event,
    _PointerInputContext input, {
    bool skipShortcuts = false,
  }) async {
    if (PalmGuardService.instance.isPointerRejected(event.pointer)) {
      return;
    }
    // 仅手写笔模式：单指触摸直接拖动纸面（上下/左右均可），不依赖缩放手势识别器
    if (_trySingleFingerPagePan(event, input)) return;
    final cubit = input.cubit;
    if (_cameraRotationGesture) {
      final drag = _rotationDrag;
      if (drag == null || drag.pointer != event.pointer) return;
      final previous = drag.previous - drag.center;
      final current = event.localPosition - drag.center;
      if (previous.distance > 4 && current.distance > 4) {
        final delta = atan2(
          previous.dx * current.dy - previous.dy * current.dx,
          previous.dx * current.dx + previous.dy * current.dy,
        );
        cubit.transformCubit.rotateConstrained(
          delta,
          cursor: drag.center,
          runtime: cubit,
        );
        _delayBakeUnlessSmooth(cubit.settingsCubit.state, input.delayBake);
      }
      _rotationDrag = (
        pointer: drag.pointer,
        center: drag.center,
        previous: event.localPosition,
      );
      cubit.inputCubit.updateLastPosition(event.localPosition);
      return;
    }
    if (!skipShortcuts) {
      final result = _shortcutManager.pointerMove(event);
      await _replayPointerEvents(result.releasedEvents, input);
      if (result.consumed) return;
    }

    final renderObject = input.context.findRenderObject();
    if (kIsWeb &&
        (renderObject is! RenderBox ||
            !renderObject.paintBounds.contains(event.localPosition))) {
      return;
    }
    cubit.inputCubit.updateLastPosition(event.localPosition);
    final ruler = _ruler;
    if (ruler != null && event.kind != .touch) {
      ruler.transformWithPointerMove(input.getEventContext(), event);
      return;
    }
    if (_isTouchMoveGesture(cubit)) {
      return;
    }
    if (_isHandlerGesture) {
      await input.getHandler().onPointerMove(event, input.getEventContext());
    }
  }

  Future<void> handlePointerUp(
    PointerUpEvent event,
    _PointerInputContext input, {
    bool skipShortcuts = false,
  }) async {
    if (PalmGuardService.instance.isPointerRejected(event.pointer)) {
      PalmGuardService.instance.evaluatePointerUp(event);
      input.cubit.inputCubit.removePointer(event.pointer);
      _pointerKinds.remove(event.pointer);
      return;
    }
    if (!skipShortcuts) {
      PalmGuardService.instance.evaluatePointerUp(event);
    }
    if (_singleFingerPanPointer == event.pointer) {
      _singleFingerPanPointer = null;
      input.cubit.inputCubit.removePointer(event.pointer);
      _pointerKinds.remove(event.pointer);
      input.cubit.inputCubit.removeButtons();
      input.delayBake();
      return;
    }
    final cubit = input.cubit;
    if (_cameraRotationGesture) {
      if (_rotationDrag?.pointer != event.pointer) return;
      _rotationDrag = null;
      cubit.inputCubit.removePointer(event.pointer);
      _pointerKinds.remove(event.pointer);
      cubit.inputCubit.removeButtons();
      input.delayBake();
      return;
    }
    if (!skipShortcuts) {
      if (_ruler != null) {
        _shortcutManager.pointerCancel(event);
      } else {
        final result = _shortcutManager.pointerUp(
          event,
          getConfiguration: () =>
              input.context.read<SettingsCubit>().state.inputConfiguration,
          onTriggered: (shortcutId, pointerEvent) => invokePointerShortcut(
            input.context,
            shortcutId,
            pointerEvent,
            cubit,
            input.getHandler,
            input.getEventContext,
          ),
          onFallback: (events) =>
              unawaited(_replayPointerEvents(events, input)),
        );
        await _replayPointerEvents(result.releasedEvents, input);
        if (result.consumed) return;
      }
    }

    cubit.inputCubit.updateLastPosition(event.localPosition);
    final wasRulerInteraction = _ruler != null;
    _resetRulerInteraction();
    if (!wasRulerInteraction && _isHandlerGesture) {
      await input.getHandler().onPointerUp(event, input.getEventContext());
    }
    cubit.inputCubit.removePointer(event.pointer);
    _pointerKinds.remove(event.pointer);
    if (wasRulerInteraction) cubit.inputCubit.removeButtons();
    if (cubit.inputCubit.state.pointers.isEmpty) {
      _handlerHandlesScaleGesture = null;
      cubit.toolCubit.resetReleaseHandler(input.bloc, cubit.rendererCubit);
    }
  }

  Future<void> _replayPointerEvents(
    List<PointerEvent> events,
    _PointerInputContext input,
  ) async {
    for (final event in events) {
      switch (event) {
        case PointerDownEvent():
          await handlePointerDown(event, input, skipShortcuts: true);
        case PointerMoveEvent():
          await handlePointerMove(event, input, skipShortcuts: true);
        case PointerUpEvent():
          await handlePointerUp(event, input, skipShortcuts: true);
        default:
          break;
      }
    }
  }

  void handlePointerCancel(PointerCancelEvent event, EditorController cubit) {
    if (_singleFingerPanPointer == event.pointer) {
      _singleFingerPanPointer = null;
    }
    final cancelOutcome = PalmGuardService.instance.evaluatePointerCancel(
      event,
    );
    final bloc = _context.read<DocumentBloc>();
    final handler = cubit.toolCubit.state.handler;
    if (handler is PenHandler) {
      if (cancelOutcome.shouldCommitProtected) {
        handler.commitProtectedOnCancel(bloc, event.pointer);
      } else {
        handler.rollbackPointerStroke(bloc, event.pointer);
      }
    } else if (handler is EraserHandler) {
      handler.resetInput(bloc);
    }
    if (_cameraRotationGesture) {
      if (_rotationDrag?.pointer == event.pointer) _rotationDrag = null;
      cubit.inputCubit.removePointer(event.pointer);
      _pointerKinds.remove(event.pointer);
      cubit.inputCubit.removeButtons();
      return;
    }
    if (_shortcutManager.pointerCancel(event)) return;
    _resetRulerInteraction();
    cubit.inputCubit.removePointer(event.pointer);
    _pointerKinds.remove(event.pointer);
    cubit.inputCubit.removeButtons();
    if (cubit.inputCubit.state.pointers.isEmpty) {
      _handlerHandlesScaleGesture = null;
      cubit.toolCubit.resetReleaseHandler(bloc, cubit.rendererCubit);
    }
  }

  void _resetRulerInteraction() {
    _ruler?.endTransform();
    _ruler = null;
    _rulerPointer = null;
  }

  void _rebaseScaleGesture(ScaleUpdateDetails details) {
    _gesturePointerCount = details.pointerCount;
    _gestureScale = details.scale;
    _gestureRotation = details.rotation;
  }

  void _delayBakeUnlessSmooth(
    ButterflySettings settings,
    VoidCallback delayBake,
  ) {
    if (!settings.hasFlag('smoothNavigation')) delayBake();
  }

  void handleScaleStart(ScaleStartDetails details, _PointerInputContext input) {
    if (_cameraRotationGesture) return;
    if (PalmGuardService.instance.isWritingLocked &&
        input.getHandler() is PenHandler) {
      _handlerHandlesScaleGesture = true;
      return;
    }
    final cubit = input.cubit;
    final handler = input.getHandler();
    final eventContext = input.getEventContext();

    if (details.pointerCount >= 2 || _isTouchMoveGesture(cubit)) {
      PalmGuardService.instance.abortUnconfirmedTracksForMultiTouch();
      _handlerHandlesScaleGesture = false;
      handler.onScaleStartAbort(details, eventContext);
      _gestureScale = 1;
      _gestureRotation = 0;
      _gesturePointerCount = details.pointerCount;
      return;
    }

    _handlerHandlesScaleGesture ??= !_isTouchMoveGesture(cubit);

    if (_rulerPointer == null) {
      _ruler = RulerHandler.getInteractiveRuler(
        cubit.toolCubit.state,
        handler,
        details.localFocalPoint,
        eventContext.viewportSize,
      );
      _ruler?.beginTransform(details.localFocalPoint);
    }

    if (_ruler != null) {
      _handlerHandlesScaleGesture = false;
    } else if (_handlerHandlesScaleGesture != false) {
      _handlerHandlesScaleGesture = handler.onScaleStart(details, eventContext);
    } else {
      handler.onScaleStartAbort(details, eventContext);
    }

    _gestureScale = 1;
    _gestureRotation = 0;
    _gesturePointerCount = details.pointerCount;
  }

  void handleScaleUpdate(
    ScaleUpdateDetails details,
    _PointerInputContext input,
  ) {
    if (_cameraRotationGesture) return;
    if (PalmGuardService.instance.isWritingLocked &&
        input.getHandler() is PenHandler) {
      return;
    }
    final cubit = input.cubit;
    final handler = input.getHandler();

    if (details.pointerCount >= 2 && _handlerHandlesScaleGesture == true) {
      PalmGuardService.instance.abortUnconfirmedTracksForMultiTouch();
      _handlerHandlesScaleGesture = false;
      _rebaseScaleGesture(details);
    }

    final ruler = _ruler;
    if (ruler != null) {
      if (_rulerPointer == null) {
        ruler.transformWithScaleUpdate(input.getEventContext(), details);
      }
      return;
    }
    if (_isHandlerGesture && details.pointerCount < 2) {
      handler.onScaleUpdate(details, input.getEventContext());
      return;
    }

    final settings = input.context.read<SettingsCubit>().state;
    final hasSelectHandler =
        cubit.toolCubit.fetchHandler<SelectHandler>(
          editable: cubit.saveCubit.state.embedding?.editable != false,
        ) !=
        null;
    if (!hasSelectHandler &&
        !settings.inputGestures &&
        details.pointerCount < 2 &&
        !_isTouchMoveGesture(cubit)) {
      return;
    }

    if (details.pointerCount != _gesturePointerCount) {
      _rebaseScaleGesture(details);
      return;
    }

    final tele = PalmGuardService.instance.telemetry;
    final resistanceFactor = tele.freePageMoveEnabled
        ? (1.0 - tele.dragResistance * 0.65).clamp(0.25, 1.0)
        : 1.0;
    final panSensitivity = settings.panGestureSensitivity * resistanceFactor;
    _gestureRotation = details.rotation;

    cubit.transformCubit.moveConstrained(
      cubit.transformCubit.state.localToGlobalDelta(-details.focalPointDelta) *
          panSensitivity,
      runtime: cubit,
      bloc: input.bloc,
      currentArea: input.state.currentArea,
    );

    if (!tele.zoomLocked && details.pointerCount >= 2) {
      final scaleDelta = details.scale / _gestureScale;
      final currentZoom = cubit.transformCubit.state.size;
      final proposedFactor =
          (scaleDelta - 1) * settings.zoomGestureSensitivity + 1;
      final nextZoom = (currentZoom * proposedFactor).clamp(0.26, 16.0);
      final clampedFactor = currentZoom > 0 ? (nextZoom / currentZoom) : 1.0;
      cubit.transformCubit.zoomConstrained(
        clampedFactor,
        cursor: details.localFocalPoint,
        runtime: cubit,
      );
    }
    _gestureScale = details.scale;
    _delayBakeUnlessSmooth(settings, input.delayBake);
  }

  void handleScaleEnd(ScaleEndDetails details, _PointerInputContext input) {
    if (_cameraRotationGesture) return;
    final cubit = input.cubit;
    if (_ruler != null) {
      _resetRulerInteraction();
      _handlerHandlesScaleGesture = null;
      cubit.inputCubit.removeButtons();
      return;
    }

    // 若用户在页面底部下滑/上拉使加页进度超过 65% 后松手，立即自动新增下一页
    final pullProg = PalmGuardService.instance.telemetry.pullUpProgress;
    if (pullProg >= 0.65 && input.state is DocumentLoadSuccess) {
      final docState = input.state as DocumentLoadSuccess;
      if (!docState.page.isMumuInfiniteCanvas(docState.info) &&
          docState.page.isMumuPullToAddPageEnabled &&
          PalmGuardService.instance.canTriggerBottomPageAdd()) {
        final nextSheet = docState.page.buildNextPageSheet();
        final presets = <AreaPreset>[
          if (docState.page.areas.isEmpty)
            AreaPreset(area: docState.page.resolvedPageSheets.first),
          AreaPreset(area: nextSheet),
        ];
        input.bloc.add(AreasCreated(presets));
      }
    } else if (pullProg > 0.0) {
      PalmGuardService.instance.updatePullUpProgress(0.0);
    }

    final isNavigation = !_isHandlerGesture;
    if (isNavigation && details.pointerCount > 0) return;

    input.getHandler().onScaleEnd(details, input.getEventContext());
    if (isNavigation) {
      final settings = input.context.read<SettingsCubit>().state;
      final sensitivity = settings.panGestureSensitivity;
      cubit.rendererCubit.cancelDelayedBake();
      cubit.transformCubit.slideConstrained(
        cubit.transformCubit.state.localToGlobalDelta(
              details.velocity.pixelsPerSecond,
            ) *
            sensitivity,
        details.scaleVelocity * settings.zoomGestureSensitivity,
        runtime: cubit,
        currentArea: input.state.currentArea,
      );
      _delayBakeUnlessSmooth(settings, input.delayBake);
    }
    _resetRulerInteraction();
    cubit.inputCubit.removeButtons();
  }

  void handlePointerSignal(
    PointerSignalEvent event,
    _PointerInputContext input,
  ) {
    if (input.state is! DocumentLoadSuccess || event is! PointerScrollEvent) {
      return;
    }

    final settings = input.context.read<SettingsCubit>().state;
    final sensitivity = settings.scrollPanSensitivity;
    final cubit = input.cubit;
    final scrollDelta = event.scrollDelta * sensitivity;
    final keyboard = HardwareKeyboard.instance;

    if (!keyboard.isShiftPressed && keyboard.isControlPressed) {
      cubit.transformCubit.zoomConstrained(
        -(event.scrollDelta.dx + event.scrollDelta.dy / 2) *
                settings.zoomGestureSensitivity /
                100 +
            1,
        cursor: event.localPosition,
        runtime: cubit,
      );
    } else {
      final panDelta = keyboard.isShiftPressed
          ? Offset(scrollDelta.dy, scrollDelta.dx)
          : scrollDelta;
      cubit.transformCubit.moveConstrained(
        cubit.transformCubit.state.localToGlobalDelta(panDelta),
        runtime: cubit,
        bloc: input.bloc,
        currentArea: input.state.currentArea,
      );
      cubit.transformCubit.zoomConstrained(
        event.size * settings.zoomGestureSensitivity / -100 + 1,
        cursor: event.localPosition,
        runtime: cubit,
      );
    }
    _delayBakeUnlessSmooth(settings, input.delayBake);
  }

  Future<void> _changeTemporaryTool(
    PointerDeviceKind kind,
    int buttons,
    _PointerInputContext input,
  ) async {
    final context = input.context;
    final cubit = input.cubit;
    final config = context.read<SettingsCubit>().state.inputConfiguration;
    cubit.toolCubit.resetDownHandler(input.bloc, cubit.rendererCubit);
    var mapping = config.getPointerMapping(kind, buttons);

    final pressedKeys = HardwareKeyboard.instance.logicalKeysPressed;
    int? holdShortcutKeyId;
    for (final shortcut in config.holdShortcuts) {
      if (pressedKeys.contains(LogicalKeyboardKey(shortcut.keyId))) {
        mapping = shortcut.mapping;
        holdShortcutKeyId = shortcut.keyId;
        break;
      }
    }
    _heldShortcutKeyId = holdShortcutKeyId;

    switch (mapping?.getCategory()) {
      case null:
      case .activeTool:
        return;
      case .handTool:
        cubit.toolCubit.changeTemporaryHandlerMove(cubit.rendererCubit);
        return;
      default:
        final index = mapping?.getToolPositionIndex();
        if (index != null) {
          await cubit.toolCubit.changeTemporaryHandlerIndex(
            context,
            cubit,
            index,
            temporaryState: TemporaryState.removeAfterClick,
          );
          if (holdShortcutKeyId != null &&
              !HardwareKeyboard.instance.logicalKeysPressed.contains(
                LogicalKeyboardKey(holdShortcutKeyId),
              ) &&
              (_heldShortcutKeyId == null ||
                  _heldShortcutKeyId == holdShortcutKeyId)) {
            _releaseHoldShortcut();
          }
        }
    }
  }
}
