import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef PointerCancelCallback = void Function(int pointerId);

/// Mumu 风格 6 大防误触握笔姿势预设
enum PalmPosturePreset {
  rightHandStandard('右手标准握姿', 0, 'RIGHT_DIAGONAL'),
  rightHandHook('右手内勾握姿', 1, 'RIGHT_HORIZONTAL'),
  leftHandStandard('左手标准握姿', 2, 'LEFT_DIAGONAL'),
  leftHandHook('左手内勾握姿', 3, 'LEFT_DIAGONAL'),
  flatWriting('平放速记模式', 4, 'AREA_ONLY'),
  strictPenOnly('极严主动笔模式', 5, 'RIGHT_DIAGONAL');

  final String label;
  final int code;
  final String handednessMode;
  const PalmPosturePreset(this.label, this.code, this.handednessMode);

  static PalmPosturePreset fromCode(int code) {
    for (final preset in PalmPosturePreset.values) {
      if (preset.code == code) return preset;
    }
    return PalmPosturePreset.rightHandStandard;
  }
}

/// Mumu 极简防误触核心状态（无感运行，无需在画布裸露调试面板）
class PalmGuardState {
  final bool enabled;
  final bool penOnlyMode;
  final double sensitivity; // 0.1 ~ 1.0 (默认 0.65)
  final PalmPosturePreset posture;
  final int rejectedPalmCount;

  const PalmGuardState({
    this.enabled = true,
    this.penOnlyMode = true,
    this.sensitivity = 0.65,
    this.posture = PalmPosturePreset.rightHandStandard,
    this.rejectedPalmCount = 0,
  });

  PalmGuardState copyWith({
    bool? enabled,
    bool? penOnlyMode,
    double? sensitivity,
    PalmPosturePreset? posture,
    int? rejectedPalmCount,
  }) {
    return PalmGuardState(
      enabled: enabled ?? this.enabled,
      penOnlyMode: penOnlyMode ?? this.penOnlyMode,
      sensitivity: sensitivity ?? this.sensitivity,
      posture: posture ?? this.posture,
      rejectedPalmCount: rejectedPalmCount ?? this.rejectedPalmCount,
    );
  }
}

/// 实时 7 维触点特征与三阶防误触遥测快照（仅供校准实验室弹窗内部使用，不在主画布裸露）。
class PalmGuardTelemetry {
  final String state;
  final String stateLabel;
  final String lastDecision;
  final int activePenPointerId;
  final double candidateDiameterMm;
  final double penMaxThresholdMm;
  final double palmHardThresholdMm;
  final double eccentricity;
  final double maxEccentricity;
  final double areaExpansionRate;
  final double velocityDpPerSec;
  final double accelerationDpPerSec2;
  final double curvatureRad;
  final double postureScore;
  final double emaMeanMm;
  final int rejectedPalmCount;
  final int sensitivityLevel;
  final String handednessMode;
  final String fingerActionMode;
  final bool shieldEnabled;
  final double shieldHeightDp;
  final String shieldMode;
  final bool isCalibrated;
  final bool motionOnlyMode;
  final int rollbackWindowMs;
  final bool stylusLockEnabled;
  final bool showRejectRipple;
  final bool emaAdaptiveEnabled;
  final bool simulatedTaperEnabled;
  final bool oneEuroFilterEnabled;
  final double xdpi;
  final bool twoFingerTapUndoEnabled;
  final bool threeFingerTapRedoEnabled;
  final String undoGestureMode; // TWO_FINGER_TAP, THREE_FINGER_SWIPE_LEFT, OFF
  final bool zoomLocked;
  final bool zoomFollowStrokeWidth;
  final bool doubleTapFitWidthEnabled;
  final bool freePageMoveEnabled;
  final double dragResistance;
  final bool pressureEraserEnabled;
  final double pressureEraserThreshold;
  final bool holdToTempEraserEnabled;
  final int holdToTempEraserMs;
  final bool quickShapeHoldEnabled;
  final int quickShapeHoldMs;
  final bool stylusTextSelectionEnabled;
  final bool straightLineEditMode;
  final String pageAddMode; // PULL_UP, AUTO_BOTTOM_WRITE, MANUAL_ONLY
  final double pullUpProgress;
  final bool tempEraserActive;

  const PalmGuardTelemetry({
    this.state = 'IDLE',
    this.stateLabel = '四重防误触待机',
    this.lastDecision = '就绪',
    this.activePenPointerId = -1,
    this.candidateDiameterMm = 2.1,
    this.penMaxThresholdMm = 4.2,
    this.palmHardThresholdMm = 11.5,
    this.eccentricity = 1.05,
    this.maxEccentricity = 1.75,
    this.areaExpansionRate = 0.02,
    this.velocityDpPerSec = 0.0,
    this.accelerationDpPerSec2 = 0.0,
    this.curvatureRad = 0.0,
    this.postureScore = 0.0,
    this.emaMeanMm = 2.4,
    this.rejectedPalmCount = 0,
    this.sensitivityLevel = 3,
    this.handednessMode = 'RIGHT_DIAGONAL',
    this.fingerActionMode = 'PEN_ONLY_PAN',
    this.shieldEnabled = false,
    this.shieldHeightDp = 180.0,
    this.shieldMode = 'FULL_WIDTH',
    this.isCalibrated = false,
    this.motionOnlyMode = false,
    this.rollbackWindowMs = 160,
    this.stylusLockEnabled = true,
    this.showRejectRipple = false,
    this.emaAdaptiveEnabled = true,
    this.simulatedTaperEnabled = true,
    this.oneEuroFilterEnabled = true,
    this.xdpi = 309.0,
    this.twoFingerTapUndoEnabled = false,
    this.threeFingerTapRedoEnabled = false,
    this.undoGestureMode = 'TWO_FINGER_TAP',
    this.zoomLocked = false,
    this.zoomFollowStrokeWidth = true,
    this.doubleTapFitWidthEnabled = true,
    this.freePageMoveEnabled = true,
    this.dragResistance = 0.15,
    this.pressureEraserEnabled = false,
    this.pressureEraserThreshold = 0.85,
    this.holdToTempEraserEnabled = true,
    this.holdToTempEraserMs = 850,
    this.quickShapeHoldEnabled = true,
    this.quickShapeHoldMs = 600,
    this.stylusTextSelectionEnabled = false,
    this.straightLineEditMode = false,
    this.pageAddMode = 'PULL_UP',
    this.pullUpProgress = 0.0,
    this.tempEraserActive = false,
  });

  PalmGuardTelemetry copyWith({
    String? state,
    String? stateLabel,
    String? lastDecision,
    int? activePenPointerId,
    double? candidateDiameterMm,
    double? penMaxThresholdMm,
    double? palmHardThresholdMm,
    double? eccentricity,
    double? maxEccentricity,
    double? areaExpansionRate,
    double? velocityDpPerSec,
    double? accelerationDpPerSec2,
    double? curvatureRad,
    double? postureScore,
    double? emaMeanMm,
    int? rejectedPalmCount,
    int? sensitivityLevel,
    String? handednessMode,
    String? fingerActionMode,
    bool? shieldEnabled,
    double? shieldHeightDp,
    String? shieldMode,
    bool? isCalibrated,
    bool? motionOnlyMode,
    int? rollbackWindowMs,
    bool? stylusLockEnabled,
    bool? showRejectRipple,
    bool? emaAdaptiveEnabled,
    bool? simulatedTaperEnabled,
    bool? oneEuroFilterEnabled,
    double? xdpi,
    bool? twoFingerTapUndoEnabled,
    bool? threeFingerTapRedoEnabled,
    String? undoGestureMode,
    bool? zoomLocked,
    bool? zoomFollowStrokeWidth,
    bool? doubleTapFitWidthEnabled,
    bool? freePageMoveEnabled,
    double? dragResistance,
    bool? pressureEraserEnabled,
    double? pressureEraserThreshold,
    bool? holdToTempEraserEnabled,
    int? holdToTempEraserMs,
    bool? quickShapeHoldEnabled,
    int? quickShapeHoldMs,
    bool? stylusTextSelectionEnabled,
    bool? straightLineEditMode,
    String? pageAddMode,
    double? pullUpProgress,
    bool? tempEraserActive,
  }) {
    return PalmGuardTelemetry(
      state: state ?? this.state,
      stateLabel: stateLabel ?? this.stateLabel,
      lastDecision: lastDecision ?? this.lastDecision,
      activePenPointerId: activePenPointerId ?? this.activePenPointerId,
      candidateDiameterMm: candidateDiameterMm ?? this.candidateDiameterMm,
      penMaxThresholdMm: penMaxThresholdMm ?? this.penMaxThresholdMm,
      palmHardThresholdMm: palmHardThresholdMm ?? this.palmHardThresholdMm,
      eccentricity: eccentricity ?? this.eccentricity,
      maxEccentricity: maxEccentricity ?? this.maxEccentricity,
      areaExpansionRate: areaExpansionRate ?? this.areaExpansionRate,
      velocityDpPerSec: velocityDpPerSec ?? this.velocityDpPerSec,
      accelerationDpPerSec2:
          accelerationDpPerSec2 ?? this.accelerationDpPerSec2,
      curvatureRad: curvatureRad ?? this.curvatureRad,
      postureScore: postureScore ?? this.postureScore,
      emaMeanMm: emaMeanMm ?? this.emaMeanMm,
      rejectedPalmCount: rejectedPalmCount ?? this.rejectedPalmCount,
      sensitivityLevel: sensitivityLevel ?? this.sensitivityLevel,
      handednessMode: handednessMode ?? this.handednessMode,
      fingerActionMode: fingerActionMode ?? this.fingerActionMode,
      shieldEnabled: shieldEnabled ?? this.shieldEnabled,
      shieldHeightDp: shieldHeightDp ?? this.shieldHeightDp,
      shieldMode: shieldMode ?? this.shieldMode,
      isCalibrated: isCalibrated ?? this.isCalibrated,
      motionOnlyMode: motionOnlyMode ?? this.motionOnlyMode,
      rollbackWindowMs: rollbackWindowMs ?? this.rollbackWindowMs,
      stylusLockEnabled: stylusLockEnabled ?? this.stylusLockEnabled,
      showRejectRipple: showRejectRipple ?? this.showRejectRipple,
      emaAdaptiveEnabled: emaAdaptiveEnabled ?? this.emaAdaptiveEnabled,
      simulatedTaperEnabled:
          simulatedTaperEnabled ?? this.simulatedTaperEnabled,
      oneEuroFilterEnabled: oneEuroFilterEnabled ?? this.oneEuroFilterEnabled,
      xdpi: xdpi ?? this.xdpi,
      twoFingerTapUndoEnabled:
          twoFingerTapUndoEnabled ?? this.twoFingerTapUndoEnabled,
      threeFingerTapRedoEnabled:
          threeFingerTapRedoEnabled ?? this.threeFingerTapRedoEnabled,
      undoGestureMode: undoGestureMode ?? this.undoGestureMode,
      zoomLocked: zoomLocked ?? this.zoomLocked,
      zoomFollowStrokeWidth:
          zoomFollowStrokeWidth ?? this.zoomFollowStrokeWidth,
      doubleTapFitWidthEnabled:
          doubleTapFitWidthEnabled ?? this.doubleTapFitWidthEnabled,
      freePageMoveEnabled: freePageMoveEnabled ?? this.freePageMoveEnabled,
      dragResistance: dragResistance ?? this.dragResistance,
      pressureEraserEnabled:
          pressureEraserEnabled ?? this.pressureEraserEnabled,
      pressureEraserThreshold:
          pressureEraserThreshold ?? this.pressureEraserThreshold,
      holdToTempEraserEnabled:
          holdToTempEraserEnabled ?? this.holdToTempEraserEnabled,
      holdToTempEraserMs: holdToTempEraserMs ?? this.holdToTempEraserMs,
      quickShapeHoldEnabled:
          quickShapeHoldEnabled ?? this.quickShapeHoldEnabled,
      quickShapeHoldMs: quickShapeHoldMs ?? this.quickShapeHoldMs,
      stylusTextSelectionEnabled:
          stylusTextSelectionEnabled ?? this.stylusTextSelectionEnabled,
      straightLineEditMode: straightLineEditMode ?? this.straightLineEditMode,
      pageAddMode: pageAddMode ?? this.pageAddMode,
      pullUpProgress: pullUpProgress ?? this.pullUpProgress,
      tempEraserActive: tempEraserActive ?? this.tempEraserActive,
    );
  }

  factory PalmGuardTelemetry.fromMap(
    Map<dynamic, dynamic> map,
    PalmGuardTelemetry prev,
  ) {
    return prev.copyWith(
      state: (map['state'] as String?) ?? prev.state,
      stateLabel: (map['stateLabel'] as String?) ?? prev.stateLabel,
      lastDecision: (map['lastDecision'] as String?) ?? prev.lastDecision,
      activePenPointerId:
          (map['activePenPointerId'] as num?)?.toInt() ??
          prev.activePenPointerId,
      candidateDiameterMm:
          (map['candidateDiameterMm'] as num?)?.toDouble() ??
          prev.candidateDiameterMm,
      penMaxThresholdMm:
          (map['penMaxThresholdMm'] as num?)?.toDouble() ??
          prev.penMaxThresholdMm,
      palmHardThresholdMm:
          (map['palmHardThresholdMm'] as num?)?.toDouble() ??
          prev.palmHardThresholdMm,
      eccentricity:
          (map['eccentricity'] as num?)?.toDouble() ?? prev.eccentricity,
      maxEccentricity:
          (map['maxEccentricity'] as num?)?.toDouble() ?? prev.maxEccentricity,
      velocityDpPerSec:
          (map['velocityDpPerSec'] as num?)?.toDouble() ??
          prev.velocityDpPerSec,
      rejectedPalmCount:
          (map['rejectedPalmCount'] as num?)?.toInt() ?? prev.rejectedPalmCount,
      sensitivityLevel:
          (map['sensitivityLevel'] as num?)?.toInt() ?? prev.sensitivityLevel,
      handednessMode:
          (map['handednessMode'] as String?) ?? prev.handednessMode,
      fingerActionMode:
          (map['fingerActionMode'] as String?) ?? prev.fingerActionMode,
      shieldEnabled: (map['shieldEnabled'] as bool?) ?? prev.shieldEnabled,
      shieldHeightDp:
          (map['shieldHeightDp'] as num?)?.toDouble() ?? prev.shieldHeightDp,
      shieldMode: (map['shieldMode'] as String?) ?? prev.shieldMode,
      isCalibrated: (map['isCalibrated'] as bool?) ?? prev.isCalibrated,
      motionOnlyMode: (map['motionOnlyMode'] as bool?) ?? prev.motionOnlyMode,
      xdpi: (map['xdpi'] as num?)?.toDouble() ?? prev.xdpi,
    );
  }
}

/// 手掌误触红色波纹视觉反馈点
class PalmRejectRippleEvent {
  final int id;
  final Offset localPosition;
  final double diameterMm;
  final DateTime timestamp;

  PalmRejectRippleEvent({
    required this.id,
    required this.localPosition,
    required this.diameterMm,
    required this.timestamp,
  });
}

/// 自适应一欧元滤波器 (1€ Filter)：消除通用电容笔慢速画斜线时的电容网格阶梯状抖动，同时保持快写零延迟。
class OneEuroFilter1D {
  final double minCutoff;
  final double beta;
  final double dCutoff;

  double? _prevValue;
  double _prevDerivative = 0.0;
  int? _prevTimeMs;

  OneEuroFilter1D({
    this.minCutoff = 1.25,
    this.beta = 0.035,
    this.dCutoff = 1.0,
  });

  void reset() {
    _prevValue = null;
    _prevDerivative = 0.0;
    _prevTimeMs = null;
  }

  double _alpha(double cutoffHz, double dtSec) {
    final tau = 1.0 / (2.0 * math.pi * cutoffHz);
    return 1.0 / (1.0 + tau / math.max(dtSec, 0.0005));
  }

  double filter(double value, int timeMs) {
    if (_prevValue == null || _prevTimeMs == null) {
      _prevValue = value;
      _prevTimeMs = timeMs;
      return value;
    }
    final dtSec = math.max(1, timeMs - _prevTimeMs!) / 1000.0;
    _prevTimeMs = timeMs;

    final rawDerivative = (value - _prevValue!) / dtSec;
    final aDeriv = _alpha(dCutoff, dtSec);
    final estDerivative =
        _prevDerivative + aDeriv * (rawDerivative - _prevDerivative);
    _prevDerivative = estDerivative;

    final cutoff = minCutoff + beta * estDerivative.abs();
    final aVal = _alpha(cutoff, dtSec);
    final filtered = _prevValue! + aVal * (value - _prevValue!);
    _prevValue = filtered;
    return filtered;
  }
}

class OneEuroFilter2D {
  final OneEuroFilter1D _fx;
  final OneEuroFilter1D _fy;

  OneEuroFilter2D({
    double minCutoff = 1.25,
    double beta = 0.035,
    double dCutoff = 1.0,
  }) : _fx = OneEuroFilter1D(
         minCutoff: minCutoff,
         beta: beta,
         dCutoff: dCutoff,
       ),
       _fy = OneEuroFilter1D(
         minCutoff: minCutoff,
         beta: beta,
         dCutoff: dCutoff,
       );

  void reset() {
    _fx.reset();
    _fy.reset();
  }

  Offset filter(Offset pt, int timeMs) {
    return Offset(_fx.filter(pt.dx, timeMs), _fy.filter(pt.dy, timeMs));
  }
}

/// 单个活动触点轨迹跟踪
class _PointerTrackState {
  final int pointerId;
  final PointerDeviceKind kind;
  final int startTimeMs;
  final Offset startPos;
  final double initialDiameterMm;
  int lastTimeMs;
  Offset lastPos;
  Offset? prevPos;
  double lastDiameterMm;
  double maxDiameterMm;
  double totalDistanceDp = 0.0;
  double lastVelocityDpPerMs = 0.0;
  double lastSimulatedPressure = 0.45;
  int sampleCount = 0;
  final OneEuroFilter2D filter2d = OneEuroFilter2D();
  final List<({Offset pos, int timeMs, double diameterMm})> samples = [];

  _PointerTrackState({
    required this.pointerId,
    required this.kind,
    required this.startTimeMs,
    required this.startPos,
    required this.initialDiameterMm,
  }) : lastTimeMs = startTimeMs,
       lastPos = startPos,
       lastDiameterMm = initialDiameterMm,
       maxDiameterMm = initialDiameterMm {
    samples.add((
      pos: startPos,
      timeMs: startTimeMs,
      diameterMm: initialDiameterMm,
    ));
  }

  bool isPreemptable(int nowMs, int rollbackWindowMs) {
    return (nowMs - startTimeMs) <= rollbackWindowMs && totalDistanceDp < 28.0;
  }

  bool isWritingLocked(int nowMs, int rollbackWindowMs) {
    if (kind == PointerDeviceKind.stylus ||
        kind == PointerDeviceKind.invertedStylus) {
      return true;
    }
    return (nowMs - startTimeMs) > rollbackWindowMs || totalDistanceDp >= 24.0;
  }
}

/// 连接 Butterfly 画布与 Android 原生 `:palm-guard` 防误触引擎 + 无压感笔锋模拟器的全局服务。
class PalmGuardService extends ChangeNotifier {
  PalmGuardService._() {
    init();
  }

  static final PalmGuardService instance = PalmGuardService._();

  static const MethodChannel _channel = MethodChannel(
    'com.mumunotes.core.touch/palm_guard',
  );
  static const MethodChannel _legacyChannel = MethodChannel(
    'com.mumunotes/palm_guard',
  );

  PalmGuardState _state = const PalmGuardState();
  PalmGuardState get state => _state;

  final Set<PointerCancelCallback> _cancelListeners = {};
  DateTime _lastTelemetryUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _initialized = false;

  PalmGuardTelemetry _telemetry = const PalmGuardTelemetry();
  PalmGuardTelemetry get telemetry => _telemetry;

  final Set<int> _rejectedPointers = <int>{};
  final Map<int, _PointerTrackState> _tracks = <int, _PointerTrackState>{};
  int? _activeStylusPointerId;
  Offset? _palmAnchor;
  int _lastHardwareStylusMs = -999999;

  final List<PalmRejectRippleEvent> _ripples = <PalmRejectRippleEvent>[];
  List<PalmRejectRippleEvent> get ripples => List.unmodifiable(_ripples);
  int _rippleSeq = 0;

  /// 当 160ms 小指抢先落屏幽灵短笔迹或 80ms 手掌下压膨胀被检出时，立即回调 `PenHandler` 抹除指定 pointerId 的未提交笔画
  void Function(int cancelledPointerId)? onRollbackPointerStroke;

  /// 双指轻点撤销 / 三指轻点重做回调
  VoidCallback? onTwoFingerUndo;
  VoidCallback? onThreeFingerRedo;

  /// 单指双击适配页面宽度回调
  VoidCallback? onDoubleTapFitWidth;

  /// 按住约 1 秒临时切橡皮 / 压感橡皮进入与抬笔自动恢复原笔回调
  VoidCallback? onEnterTemporaryEraser;
  VoidCallback? onExitTemporaryEraser;

  /// 停笔按住 600ms 快速形状识别回调
  void Function(List<Offset> strokePoints)? onQuickShapeHoldRecognized;

  /// 页底上滑添加新页面 / 底部书写自动加页回调
  VoidCallback? onRequestAddPageFromBottom;


  /// 无压感电容笔的笔锋模拟强度 (0.4 ~ 1.6)，由笔刷设置面板的“笔锋强度”滑块调节
  double taperStrength = 1.0;
  void setTaperStrength(double value) {
    taperStrength = value.clamp(0.4, 1.6);
  }

  // 多指轻触撤销/重做与双指缩放仲裁跟踪
  final Map<int, ({Offset startPos, Offset lastPos, int downTimeMs})>
  _gestureTapPointers = {};
  int _peakMultiTouchCount = 0;
  int _multiTouchClusterStartMs = 0;
  double? _initialTwoFingerSpan;

  // 单指双击适配宽度跟踪
  int _lastSingleTapUpMs = 0;
  Offset _lastSingleTapPos = Offset.zero;

  Timer? _holdTempEraserTimer;
  Timer? _quickShapeHoldTimer;
  bool _tempEraserTriggeredThisStroke = false;
  bool _quickShapeTriggeredThisStroke = false;

  int? _pullUpPointerId;
  double _pullUpStartY = 0.0;

  bool _penBoxExpanded = true;
  bool get penBoxExpanded => _penBoxExpanded;
  void togglePenBoxExpanded() {
    _penBoxExpanded = !_penBoxExpanded;
    notifyListeners();
  }

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
    _legacyChannel.setMethodCallHandler(_handleNativeCall);
    await _loadQuickActionSettings();
    await _syncConfigToNative();
    unawaited(refreshTelemetry());
  }

  Future<void> _loadQuickActionSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _telemetry = _telemetry.copyWith(
        twoFingerTapUndoEnabled:
            prefs.getBool('mumu_quick_two_finger_undo') ??
            _telemetry.twoFingerTapUndoEnabled,
        threeFingerTapRedoEnabled:
            prefs.getBool('mumu_quick_three_finger_redo') ??
            _telemetry.threeFingerTapRedoEnabled,
        doubleTapFitWidthEnabled:
            prefs.getBool('mumu_quick_double_tap_fit') ??
            _telemetry.doubleTapFitWidthEnabled,
        holdToTempEraserEnabled:
            prefs.getBool('mumu_quick_hold_eraser') ??
            _telemetry.holdToTempEraserEnabled,
        quickShapeHoldEnabled:
            prefs.getBool('mumu_quick_shape_hold') ??
            _telemetry.quickShapeHoldEnabled,
        pressureEraserEnabled:
            prefs.getBool('mumu_quick_pressure_eraser') ??
            _telemetry.pressureEraserEnabled,
      );
      notifyListeners();
    } catch (_) {
      // Preferences are optional on desktop/web and in tests.
    }
  }

  Future<void> _saveQuickActionSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(
        'mumu_quick_two_finger_undo',
        _telemetry.twoFingerTapUndoEnabled,
      );
      await prefs.setBool(
        'mumu_quick_three_finger_redo',
        _telemetry.threeFingerTapRedoEnabled,
      );
      await prefs.setBool(
        'mumu_quick_double_tap_fit',
        _telemetry.doubleTapFitWidthEnabled,
      );
      await prefs.setBool(
        'mumu_quick_hold_eraser',
        _telemetry.holdToTempEraserEnabled,
      );
      await prefs.setBool(
        'mumu_quick_shape_hold',
        _telemetry.quickShapeHoldEnabled,
      );
      await prefs.setBool(
        'mumu_quick_pressure_eraser',
        _telemetry.pressureEraserEnabled,
      );
    } catch (_) {
      // Preferences are optional on desktop/web and in tests.
    }
  }

  void registerPointerCancelCallback(PointerCancelCallback callback) {
    _cancelListeners.add(callback);
  }

  void unregisterPointerCancelCallback(PointerCancelCallback callback) {
    _cancelListeners.remove(callback);
  }

  void addPointerCancelListener(PointerCancelCallback listener) {
    _cancelListeners.add(listener);
  }

  void removePointerCancelListener(PointerCancelCallback listener) {
    _cancelListeners.remove(listener);
  }

  Future<void> setEnabled(bool enabled) async {
    if (_state.enabled == enabled) return;
    _state = _state.copyWith(enabled: enabled);
    notifyListeners();
    await _syncConfigToNative();
  }

  Future<void> setPenOnlyMode(bool penOnly) async {
    final modeStr = penOnly ? 'PEN_ONLY_PAN' : 'ALLOW_FINGER_WRITE';
    _state = _state.copyWith(penOnlyMode: penOnly);
    _telemetry = _telemetry.copyWith(fingerActionMode: modeStr);
    notifyListeners();
    await _syncConfigToNative();
  }

  Future<void> setPosture(PalmPosturePreset posture) async {
    if (_state.posture == posture) return;
    _state = _state.copyWith(posture: posture);
    _telemetry = _telemetry.copyWith(handednessMode: posture.handednessMode);
    notifyListeners();
    await _syncConfigToNative();
  }

  Future<void> _syncConfigToNative() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod('updateConfig', {
        'enabled': _state.enabled,
        'penOnlyMode': _state.penOnlyMode,
        'sensitivity': _state.sensitivity,
        'postureCode': _state.posture.code,
        'handednessMode': _state.posture.handednessMode,
        // 在仅手写笔模式下，允许双指缩放平移，禁止大面积单指画线
        'fingerActionMode':
            _state.penOnlyMode ? 'PAN_AND_ZOOM_ONLY' : 'ALL_ALLOWED',
      });
    } catch (_) {
      // 忽略桌面端或未挂载原生插件时的异常
    }
  }

  void _notifyPointerCancelled(int pointerId) {
    onRollbackPointerStroke?.call(pointerId);
    for (final listener in List<PointerCancelCallback>.from(_cancelListeners)) {
      listener(pointerId);
    }
  }

  /// 节流保护：最高每 250ms 触发一次高频遥测 UI 刷新，彻底杜绝 240Hz 手写期间掉帧
  void _notifyTelemetryThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastTelemetryUpdate).inMilliseconds < 250) {
      return;
    }
    _lastTelemetryUpdate = now;
    notifyListeners();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'cancelPointer':
        final args = call.arguments;
        final int? pointerId = args is Map
            ? (args['pointerId'] as num?)?.toInt()
            : (args as num?)?.toInt();
        if (pointerId != null) {
          _rejectedPointers.add(pointerId);
          _tracks.remove(pointerId);
          if (_activeStylusPointerId == pointerId) {
            _activeStylusPointerId = null;
          }
          _notifyPointerCancelled(pointerId);
        }
        break;
      case 'onPalmRejected':
        final now = DateTime.now();
        if (now.difference(_lastTelemetryUpdate).inMilliseconds > 250) {
          _lastTelemetryUpdate = now;
          final nextCount = _state.rejectedPalmCount + 1;
          _state = _state.copyWith(rejectedPalmCount: nextCount);
          _telemetry = _telemetry.copyWith(rejectedPalmCount: nextCount);
          notifyListeners();
        }
        break;
      case 'onTelemetry':
        final now = DateTime.now();
        if (now.difference(_lastTelemetryUpdate).inMilliseconds < 250) {
          return;
        }
        _lastTelemetryUpdate = now;
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map != null) {
          _telemetry = PalmGuardTelemetry.fromMap(map, _telemetry);
          _state = _state.copyWith(
            rejectedPalmCount: _telemetry.rejectedPalmCount,
          );
          notifyListeners();
        }
        break;
      case 'onArbiterEvent':
        final map = call.arguments as Map<dynamic, dynamic>?;
        if (map == null) return;
        final eventType = map['eventType'] as String?;
        final payload =
            (map['payload'] as Map<dynamic, dynamic>?) ??
            const <dynamic, dynamic>{};

        switch (eventType) {
          case 'palm_rejected':
            final pid = (payload['pointerId'] as num?)?.toInt();
            if (pid != null) {
              _rejectedPointers.add(pid);
            }
            _telemetry = PalmGuardTelemetry.fromMap(payload, _telemetry);
            _state = _state.copyWith(
              rejectedPalmCount: _telemetry.rejectedPalmCount,
            );
            _notifyTelemetryThrottled();
          case 'palm_rollback':
            final cancelledPid = (payload['cancelledPointerId'] as num?)
                ?.toInt();
            if (cancelledPid != null) {
              _rejectedPointers.add(cancelledPid);
              _tracks.remove(cancelledPid);
              if (_activeStylusPointerId == cancelledPid) {
                _activeStylusPointerId = null;
              }
              _notifyPointerCancelled(cancelledPid);
            }
            _telemetry = PalmGuardTelemetry.fromMap(payload, _telemetry);
            _state = _state.copyWith(
              rejectedPalmCount: _telemetry.rejectedPalmCount,
            );
            notifyListeners();
          case 'two_finger_undo':
            onTwoFingerUndo?.call();
          case 'three_finger_redo':
            onThreeFingerRedo?.call();
        }
        break;
    }
  }

  // ====================================================================
  //  第一部分：7 维物理特征提取与五阶段防误触实时仲裁
  // ====================================================================

  /// 从 Flutter PointerEvent 提取等效物理毫米直径 D_mm 与接触椭圆长短轴偏心率 E_axis
  ({double diameterMm, double eccentricity}) extractContactGeometry(
    PointerEvent event,
  ) {
    final rMajor = event.radiusMajor > 0 ? event.radiusMajor : 0.0;
    final rMinor = event.radiusMinor > 0 ? event.radiusMinor : rMajor;
    if (rMajor <= 0.01) {
      if (event.kind == PointerDeviceKind.mouse ||
          event.kind == PointerDeviceKind.stylus ||
          event.kind == PointerDeviceKind.invertedStylus) {
        return (diameterMm: 2.0, eccentricity: 1.02);
      }
      final sz = event.size > 0 ? event.size : 0.08;
      final estMm = (sz * 28.0).clamp(1.6, 26.0);
      return (diameterMm: estMm, eccentricity: 1.05);
    }

    final majorLogicalPx = math.max(rMajor, rMinor) * 2.0;
    final minorLogicalPx = math.max(1.0, math.min(rMajor, rMinor) * 2.0);
    final eccentricity = (majorLogicalPx / minorLogicalPx).clamp(1.0, 5.0);

    final rawMm = (majorLogicalPx / 160.0) * 25.4 * 0.62;
    return (diameterMm: rawMm.clamp(0.8, 45.0), eccentricity: eccentricity);
  }

  /// 计算握笔姿态空间几何得分 S_pos(x, y)
  double computePostureScore(Offset pos) {
    switch (_telemetry.handednessMode) {
      case 'RIGHT_DIAGONAL':
        return pos.dy + 0.42 * pos.dx;
      case 'RIGHT_HORIZONTAL':
        return pos.dx + 0.15 * pos.dy;
      case 'LEFT_DIAGONAL':
        return pos.dy - 0.42 * pos.dx;
      case 'AREA_ONLY':
      default:
        return 0.0;
    }
  }

  bool _isHigherStylusPriority(Offset newPos, Offset oldPos) {
    if (_telemetry.handednessMode == 'AREA_ONLY') return false;
    final newScore = computePostureScore(newPos);
    final oldScore = computePostureScore(oldPos);
    return newScore < oldScore - 42.0;
  }

  /// 判断触点是否落在底部虚拟防误触手垫区域内
  bool isPointInsidePalmShield(Offset localPos, Size viewportSize) {
    if (!_telemetry.shieldEnabled || viewportSize.isEmpty) return false;
    final shieldTop = (viewportSize.height - _telemetry.shieldHeightDp).clamp(
      0.0,
      viewportSize.height,
    );
    if (localPos.dy < shieldTop) return false;
    if (_telemetry.shieldMode == 'CORNER_RIGHT') {
      return localPos.dx >= viewportSize.width * 0.45;
    }
    return true;
  }

  void _spawnRipple(Offset localPos, double diameterMm) {
    if (!_telemetry.showRejectRipple) return;
    final id = ++_rippleSeq;
    _ripples.add(
      PalmRejectRippleEvent(
        id: id,
        localPosition: localPos,
        diameterMm: diameterMm,
        timestamp: DateTime.now(),
      ),
    );
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 560), () {
      _ripples.removeWhere((e) => e.id == id);
      notifyListeners();
    });
  }

  void _recordRejectedPalm(
    int pointerId,
    Offset localPos,
    double diameterMm,
    double eccentricity,
    String reasonLabel,
  ) {
    _rejectedPointers.add(pointerId);
    _palmAnchor = localPos;
    final nextCount = _telemetry.rejectedPalmCount + 1;
    _state = _state.copyWith(rejectedPalmCount: nextCount);
    _telemetry = _telemetry.copyWith(
      rejectedPalmCount: nextCount,
      candidateDiameterMm: diameterMm,
      eccentricity: eccentricity,
      lastDecision: reasonLabel,
    );
    _spawnRipple(localPos, diameterMm);
    _notifyTelemetryThrottled();
  }

  /// 当前是否处于强书写锁定态（仅当真实主动笔落笔，或电容笔已连续书写超过回滚窗口 / 长度 >= 24dp 时返回 true，绝不在 0ms 锁死双指捏合缩放！）
  bool get isWritingLocked {
    if (!_state.enabled || !_telemetry.stylusLockEnabled) return false;
    final pid = _activeStylusPointerId;
    if (pid == null) return false;
    final trk = _tracks[pid];
    if (trk == null) return false;
    return trk.isWritingLocked(trk.lastTimeMs, _telemetry.rollbackWindowMs);
  }

  /// 当前活动笔尖 pointerId
  int? get activeStylusPointerId => _activeStylusPointerId;

  /// 检查某个 pointer 是否已被防误触模块拉黑
  bool isPointerRejected(int pointerId) =>
      _rejectedPointers.contains(pointerId);

  /// 当双指捏合缩放启动时，主动清理未进入强书写锁定的单指候选轨迹，确保双指缩放丝滑无阻且不留误触墨点
  void abortUnconfirmedTracksForMultiTouch() {
    if (isWritingLocked) return;
    final toCancel = _tracks.keys.toList();
    _tracks.clear();
    _activeStylusPointerId = null;
    _holdTempEraserTimer?.cancel();
    _quickShapeHoldTimer?.cancel();
    for (final pid in toCancel) {
      _notifyPointerCancelled(pid);
    }
  }

  void _pruneStaleTracks(int nowMs) {
    final staleIds = <int>[];
    _tracks.forEach((pid, trk) {
      if (nowMs > trk.lastTimeMs && (nowMs - trk.lastTimeMs) > 450) {
        staleIds.add(pid);
      }
    });
    for (final pid in staleIds) {
      _tracks.remove(pid);
      _gestureTapPointers.remove(pid);
      if (_activeStylusPointerId == pid) {
        _activeStylusPointerId = null;
      }
    }
  }

  /// 在 PointerDown 进入画布时执行五阶段防误触判定：返回 true 表示该触点为手掌/误触并予以拦截
  bool evaluatePointerDown(PointerDownEvent event, Size viewportSize) {
    final pid = event.pointer;
    final nowMs = event.timeStamp.inMilliseconds;
    final pos = event.localPosition;
    final isHardwareStylus =
        event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus;

    _pruneStaleTracks(nowMs);

    // 主动笔落笔：0 延迟直接放行，并激活 400ms 全屏手掌护盾
    if (isHardwareStylus) {
      _lastHardwareStylusMs = nowMs;
      abortUnconfirmedTracksForMultiTouch();
      _rejectedPointers.remove(pid);
      _activeStylusPointerId = pid;
      _tracks[pid] = _PointerTrackState(
        pointerId: pid,
        kind: event.kind,
        startTimeMs: nowMs,
        startPos: pos,
        initialDiameterMm: 1.8,
      );
      return false;
    }

    // 若主动笔在最近 400ms 内刚落笔或正在书写，任何手指/手掌触摸一律由 400ms 护盾拦截
    if ((nowMs - _lastHardwareStylusMs).abs() <= 400 ||
        (_activeStylusPointerId != null &&
            (_tracks[_activeStylusPointerId!]?.kind ==
                    PointerDeviceKind.stylus ||
                _tracks[_activeStylusPointerId!]?.kind ==
                    PointerDeviceKind.invertedStylus))) {
      _recordRejectedPalm(pid, pos, 14.0, 1.5, '主动笔400ms护盾');
      return true;
    }

    // 记录多指轻触与双指缩放平移候选 (B1 双指轻触撤销 / B2 三指轻触重做 / 双指捏合缩放)
    var isMultiTouchGestureCluster = false;
    if (_gestureTapPointers.isEmpty) {
      _multiTouchClusterStartMs = nowMs;
      _peakMultiTouchCount = 1;
      _initialTwoFingerSpan = null;
    } else if (!isWritingLocked) {
      isMultiTouchGestureCluster = true;
      _peakMultiTouchCount = math.max(
        _peakMultiTouchCount,
        _gestureTapPointers.length + 1,
      );
      // 冻结与回滚：当第 2/3 指落下且当前未处于强书写锁定时，立即回滚第 1 指可能产生的候选点，将控制权交给双指缩放/平移/轻点撤销！
      for (final existingPid in _gestureTapPointers.keys) {
        if (_tracks.containsKey(existingPid)) {
          _tracks.remove(existingPid);
          if (_activeStylusPointerId == existingPid) {
            _activeStylusPointerId = null;
          }
          _notifyPointerCancelled(existingPid);
        }
      }
      _holdTempEraserTimer?.cancel();
      _quickShapeHoldTimer?.cancel();
    }
    _gestureTapPointers[pid] = (
      startPos: pos,
      lastPos: pos,
      downTimeMs: nowMs,
    );
    if (_gestureTapPointers.length == 2) {
      final pts = _gestureTapPointers.values.toList();
      _initialTwoFingerSpan = (pts[0].startPos - pts[1].startPos).distance;
    }

    // 若当前属于双指/多指手势簇（如双指捏合缩放或双指拖动平移），不建立单笔书写轨迹，直接放行给 Flutter GestureDetector 处理缩放！
    if (isMultiTouchGestureCluster || _gestureTapPointers.length >= 2) {
      _rejectedPointers.remove(pid);
      return false;
    }

    if (!_state.enabled) {
      _rejectedPointers.remove(pid);
      _activeStylusPointerId ??= pid;
      _tracks[pid] = _PointerTrackState(
        pointerId: pid,
        kind: event.kind,
        startTimeMs: nowMs,
        startPos: pos,
        initialDiameterMm: 2.2,
      );
      return false;
    }

    final geom = extractContactGeometry(event);
    final dMm = geom.diameterMm;
    final ecc = geom.eccentricity;

    // B9 页底上滑添加页面检测：距底边 < 80dp 起手
    if (_telemetry.pageAddMode == 'PULL_UP' &&
        viewportSize.height > 160 &&
        pos.dy >= viewportSize.height - 80.0 &&
        _gestureTapPointers.length == 1) {
      _pullUpPointerId = pid;
      _pullUpStartY = pos.dy;
    }

    // 阶段 1：底部虚拟防误触手垫静默吸收
    if (isPointInsidePalmShield(pos, viewportSize)) {
      _recordRejectedPalm(pid, pos, dMm, ecc, '手垫吸收');
      return true;
    }

    // 阶段 2：0ms 物理面积硬上限与椭圆偏心率硬过滤
    if (dMm > _telemetry.palmHardThresholdMm ||
        ecc > _telemetry.maxEccentricity) {
      _recordRejectedPalm(pid, pos, dMm, ecc, '侧掌/掌根拦截');
      return true;
    }

    // 若已存在手掌基准锚点，且新触点位于手掌锚点的右下方余波扇区，直接拦截
    if (_palmAnchor != null &&
        _telemetry.handednessMode != 'AREA_ONLY' &&
        computePostureScore(pos) > computePostureScore(_palmAnchor!) - 20.0 &&
        dMm > _telemetry.penMaxThresholdMm * 0.92) {
      _recordRejectedPalm(pid, pos, dMm, ecc, '手掌余波拦截');
      return true;
    }

    // 阶段 4 & 5：若当前已有活动书写笔画
    if (_activeStylusPointerId != null && _activeStylusPointerId != pid) {
      final oldTrack = _tracks[_activeStylusPointerId!];
      if (oldTrack != null) {
        // 规则 C：160ms 小指侧边先落屏、真笔尖后落屏的空间几何抢占与自动回滚
        if (oldTrack.isPreemptable(nowMs, _telemetry.rollbackWindowMs) &&
            dMm <= _telemetry.penMaxThresholdMm &&
            _isHigherStylusPriority(pos, oldTrack.startPos)) {
          final oldPid = _activeStylusPointerId!;
          _recordRejectedPalm(
            oldPid,
            oldTrack.startPos,
            oldTrack.maxDiameterMm,
            ecc,
            '160ms小指回滚',
          );
          _tracks.remove(oldPid);
          _notifyPointerCancelled(oldPid);

          _activeStylusPointerId = pid;
          _tracks[pid] = _PointerTrackState(
            pointerId: pid,
            kind: event.kind,
            startTimeMs: nowMs,
            startPos: pos,
            initialDiameterMm: dMm,
          );
          _telemetry = _telemetry.copyWith(
            state: 'WRITING_LOCKED',
            stateLabel: '真笔尖抢占书写',
            activePenPointerId: pid,
            candidateDiameterMm: dMm,
            eccentricity: ecc,
            postureScore: computePostureScore(pos),
          );
          _notifyTelemetryThrottled();
          return false;
        }

        // 规则 B：强书写锁定态下并发多点绝对免疫
        if (oldTrack.isWritingLocked(nowMs, _telemetry.rollbackWindowMs) &&
            _telemetry.stylusLockEnabled) {
          _recordRejectedPalm(pid, pos, dMm, ecc, '书写锁免疫');
          return true;
        }
      }
    }

    // 极严主动笔模式下，普通触摸 (PointerDeviceKind.touch) 不产生画线，但保留在 GestureArena 以支持双指缩放！
    if (_state.posture == PalmPosturePreset.strictPenOnly &&
        event.kind == PointerDeviceKind.touch) {
      return false;
    }

    // 若触点直径超出笔尖最大阈值（介于笔尖与掌根之间的手指）：
    // 在“仅手写笔模式”下，不将其加入 _activeStylusPointerId（从而在 PenHandler 中不画线），但返回 false 让 Flutter GestureDetector 正常识别单指平移或双指缩放！
    if (dMm > _telemetry.penMaxThresholdMm) {
      if (_state.penOnlyMode || _telemetry.fingerActionMode == 'PEN_ONLY_PAN') {
        return false;
      }
    }

    // 合法笔尖候选建立
    _rejectedPointers.remove(pid);
    _activeStylusPointerId ??= pid;
    _tracks[pid] = _PointerTrackState(
      pointerId: pid,
      kind: event.kind,
      startTimeMs: nowMs,
      startPos: pos,
      initialDiameterMm: dMm,
    );

    _tempEraserTriggeredThisStroke = false;
    _quickShapeTriggeredThisStroke = false;
    if (_telemetry.pressureEraserEnabled &&
        event.pressure > _telemetry.pressureEraserThreshold &&
        event.pressure < 1.5) {
      _tempEraserTriggeredThisStroke = true;
      _telemetry = _telemetry.copyWith(
        tempEraserActive: true,
        lastDecision: '压感临时橡皮',
      );
      onEnterTemporaryEraser?.call();
    } else if (_telemetry.holdToTempEraserEnabled && isHardwareStylus) {
      _holdTempEraserTimer?.cancel();
      _holdTempEraserTimer = Timer(
        Duration(milliseconds: _telemetry.holdToTempEraserMs),
        () {
          final currentTrack = _tracks[pid];
          if (currentTrack != null &&
              currentTrack.totalDistanceDp < 6.0 &&
              _gestureTapPointers.length == 1 &&
              !_tempEraserTriggeredThisStroke) {
            _tempEraserTriggeredThisStroke = true;
            _notifyPointerCancelled(pid);
            _telemetry = _telemetry.copyWith(
              tempEraserActive: true,
              stateLabel: '临时橡皮模式',
              lastDecision: '按住1s临时橡皮',
            );
            notifyListeners();
            onEnterTemporaryEraser?.call();
          }
        },
      );
    }

    _telemetry = _telemetry.copyWith(
      state: 'WRITING_LOCKED',
      stateLabel: _tempEraserTriggeredThisStroke ? '临时橡皮模式' : '书写锁定中',
      lastDecision: _tempEraserTriggeredThisStroke ? '临时橡皮' : '笔尖书写',
      activePenPointerId: _activeStylusPointerId,
      candidateDiameterMm: dMm,
      eccentricity: ecc,
      postureScore: computePostureScore(pos),
    );
    _notifyTelemetryThrottled();
    return false;
  }

  /// 在 PointerMove 时执行 80ms 面积膨胀检测、1€ 滤波与无压感三元动态线宽计算
  ({bool rejected, Offset filteredLocalPos, double simulatedPressure})
  evaluatePointerMove(PointerMoveEvent event, Size viewportSize) {
    final pid = event.pointer;
    if (_rejectedPointers.contains(pid)) {
      return (
        rejected: true,
        filteredLocalPos: event.localPosition,
        simulatedPressure: 0.5,
      );
    }
    if (_activeStylusPointerId != null &&
        _activeStylusPointerId != pid &&
        isWritingLocked) {
      return (
        rejected: true,
        filteredLocalPos: event.localPosition,
        simulatedPressure: 0.5,
      );
    }

    final nowMs = event.timeStamp.inMilliseconds;
    final rawPos = event.localPosition;
    if (event.kind == PointerDeviceKind.stylus ||
        event.kind == PointerDeviceKind.invertedStylus) {
      _lastHardwareStylusMs = nowMs;
    }

    final prevTap = _gestureTapPointers[pid];
    if (prevTap != null) {
      _gestureTapPointers[pid] = (
        startPos: prevTap.startPos,
        lastPos: rawPos,
        downTimeMs: prevTap.downTimeMs,
      );
    }

    final geom = extractContactGeometry(event);
    final dMm = geom.diameterMm;
    final ecc = geom.eccentricity;

    if (_state.enabled && isPointInsidePalmShield(rawPos, viewportSize)) {
      _recordRejectedPalm(pid, rawPos, dMm, ecc, '进入手垫区');
      _tracks.remove(pid);
      if (_activeStylusPointerId == pid) _activeStylusPointerId = null;
      _notifyPointerCancelled(pid);
      return (
        rejected: true,
        filteredLocalPos: rawPos,
        simulatedPressure: 0.5,
      );
    }

    final track = _tracks[pid];
    if (track == null) {
      return (
        rejected: false,
        filteredLocalPos: rawPos,
        simulatedPressure: 0.5,
      );
    }

    final elapsedFromStart = math.max(1, nowMs - track.startTimeMs);
    final dt = math.max(1, nowMs - track.lastTimeMs);
    final expansionRate = (dMm - track.lastDiameterMm) / dt;
    if (dMm > track.maxDiameterMm) track.maxDiameterMm = dMm;

    // 阶段 3A：80ms 内手掌压实面积骤增拦截与自动回滚
    if (_state.enabled &&
        track.kind == PointerDeviceKind.touch &&
        elapsedFromStart <= 90 &&
        (dMm > _telemetry.penMaxThresholdMm * 1.18 ||
            ecc > _telemetry.maxEccentricity * 1.05 ||
            expansionRate > 0.45)) {
      _recordRejectedPalm(pid, rawPos, dMm, ecc, '80ms压实回滚');
      _tracks.remove(pid);
      if (_activeStylusPointerId == pid) _activeStylusPointerId = null;
      _notifyPointerCancelled(pid);
      return (
        rejected: true,
        filteredLocalPos: rawPos,
        simulatedPressure: 0.5,
      );
    }

    // 第一级平滑：自适应一欧元滤波器 (1€ Filter)
    final filteredPos = _telemetry.oneEuroFilterEnabled
        ? track.filter2d.filter(rawPos, nowMs)
        : rawPos;

    // B9 页底上滑添加新页进度更新（一旦确认为上拉加页手势，立即回滚候选墨迹避免画出竖线）
    if (_pullUpPointerId == pid && _telemetry.pageAddMode == 'PULL_UP') {
      final upwardDelta = _pullUpStartY - rawPos.dy;
      final horizDelta = (rawPos.dx - track.startPos.dx).abs();
      if (upwardDelta > 16.0 && upwardDelta > horizDelta * 1.3) {
        _notifyPointerCancelled(pid);
        final prog = (upwardDelta / 68.0).clamp(0.0, 1.0);
        if ((prog - _telemetry.pullUpProgress).abs() > 0.03) {
          _telemetry = _telemetry.copyWith(pullUpProgress: prog);
          notifyListeners();
        }
      }
    }

    final distDp = (filteredPos - track.lastPos).distance;
    track.totalDistanceDp += distDp;

    if (track.totalDistanceDp >= 6.0) {
      _holdTempEraserTimer?.cancel();
    }

    if (_telemetry.quickShapeHoldEnabled &&
        !_tempEraserTriggeredThisStroke &&
        !_quickShapeTriggeredThisStroke &&
        track.totalDistanceDp >= 28.0 &&
        distDp > 1.8) {
      _quickShapeHoldTimer?.cancel();
      _quickShapeHoldTimer = Timer(
        Duration(milliseconds: _telemetry.quickShapeHoldMs),
        () {
          final activeTrk = _tracks[pid];
          if (activeTrk != null &&
              !_tempEraserTriggeredThisStroke &&
              !_quickShapeTriggeredThisStroke &&
              activeTrk.samples.length >= 6) {
            _quickShapeTriggeredThisStroke = true;
            _telemetry = _telemetry.copyWith(
              lastDecision: '停笔快速形状识别',
            );
            notifyListeners();
            onQuickShapeHoldRecognized?.call(
              activeTrk.samples.map((s) => s.pos).toList(),
            );
          }
        },
      );
    }
    final velocityDpPerMs = distDp / dt;
    final accelDpPerMs2 = (velocityDpPerMs - track.lastVelocityDpPerMs) / dt;

    double curvatureRad = 0.0;
    if (track.prevPos != null && distDp > 0.4) {
      final u = track.lastPos - track.prevPos!;
      final v = filteredPos - track.lastPos;
      if (u.distance > 0.4 && v.distance > 0.4) {
        final a1 = math.atan2(u.dy, u.dx);
        final a2 = math.atan2(v.dy, v.dx);
        var diff = (a2 - a1).abs();
        if (diff > math.pi) diff = 2 * math.pi - diff;
        curvatureRad = diff;
      }
    }

    double simulatedPressure = 0.55;
    if (_telemetry.simulatedTaperEnabled) {
      track.sampleCount += 1;
      final tEntry = (track.sampleCount / 4.0).clamp(0.0, 1.0);
      final hermiteEntry = tEntry * tEntry * (3.0 - 2.0 * tEntry);

      final velTerm = 0.65 * math.exp(-0.42 * velocityDpPerMs);
      final curvTerm =
          0.25 * (math.exp(1.6 * curvatureRad) - 1.0) /
          (math.exp(1.6 * curvatureRad) + 1.0);
      final areaTerm =
          0.10 * (dMm / math.max(1.5, _telemetry.penMaxThresholdMm)).clamp(
            0.3,
            1.2,
          );
      final rawTargetP =
          ((velTerm + curvTerm + areaTerm) * (0.38 + 0.62 * hermiteEntry))
              .clamp(0.22, 0.96);
      // 用户可调的笔锋强度：以 0.55 为中性笔压放大/收敛顿挫幅度
      final targetP = (0.55 + (rawTargetP - 0.55) * taperStrength).clamp(
        0.12,
        0.98,
      );

      simulatedPressure = 0.72 * track.lastSimulatedPressure + 0.28 * targetP;
      track.lastSimulatedPressure = simulatedPressure;
    }

    track.prevPos = track.lastPos;
    track.lastPos = filteredPos;
    track.lastTimeMs = nowMs;
    track.lastDiameterMm = dMm;
    track.lastVelocityDpPerMs = velocityDpPerMs;
    track.samples.add((pos: filteredPos, timeMs: nowMs, diameterMm: dMm));

    _telemetry = _telemetry.copyWith(
      candidateDiameterMm: dMm,
      eccentricity: ecc,
      areaExpansionRate: expansionRate,
      velocityDpPerSec: velocityDpPerMs * 1000.0,
      accelerationDpPerSec2: accelDpPerMs2 * 1000.0,
      curvatureRad: curvatureRad,
      postureScore: computePostureScore(filteredPos),
    );
    _notifyTelemetryThrottled();

    return (
      rejected: false,
      filteredLocalPos: filteredPos,
      simulatedPressure: simulatedPressure,
    );
  }

  /// 在 PointerUp 抬笔时计算末速度切线外插收笔出锋点 (Exit Flick Taper) 并更新 L3 Winsorized EMA 基准
  List<({Offset localPos, double pressure})> evaluatePointerUp(
    PointerUpEvent event,
  ) {
    final pid = event.pointer;
    final nowMs = event.timeStamp.inMilliseconds;
    _holdTempEraserTimer?.cancel();
    _quickShapeHoldTimer?.cancel();

    if (_pullUpPointerId == pid) {
      _pullUpPointerId = null;
      final upwardDelta = _pullUpStartY - event.localPosition.dy;
      if (_telemetry.pageAddMode == 'PULL_UP' && upwardDelta >= 64.0) {
        _telemetry = _telemetry.copyWith(
          pullUpProgress: 0.0,
          lastDecision: '上滑新增页面',
        );
        _notifyPointerCancelled(pid);
        onRequestAddPageFromBottom?.call();
      } else if (_telemetry.pullUpProgress > 0.0) {
        _telemetry = _telemetry.copyWith(pullUpProgress: 0.0);
      }
    }

    final tapInfo = _gestureTapPointers.remove(pid);
    if (tapInfo != null && _gestureTapPointers.isEmpty) {
      final totalDurationMs = nowMs - _multiTouchClusterStartMs;
      final moveDist = (event.localPosition - tapInfo.startPos).distance;

      // 情况 1：双指轻点直接触发快捷撤销 (Mumu 经典手势)
      if (_peakMultiTouchCount == 2 &&
          _telemetry.twoFingerTapUndoEnabled &&
          _telemetry.undoGestureMode == 'TWO_FINGER_TAP' &&
          totalDurationMs <= 280 &&
          moveDist < 14.0) {
        _telemetry = _telemetry.copyWith(lastDecision: '双指轻触撤销');
        onTwoFingerUndo?.call();
      }
      // 情况 2：三指轻点重做
      else if (_peakMultiTouchCount == 3 &&
          _telemetry.threeFingerTapRedoEnabled &&
          totalDurationMs <= 280 &&
          moveDist < 16.0) {
        _telemetry = _telemetry.copyWith(lastDecision: '三指轻触重做');
        onThreeFingerRedo?.call();
      }
      // 情况 3：三指左滑撤销
      else if (_peakMultiTouchCount == 3 &&
          _telemetry.undoGestureMode == 'THREE_FINGER_SWIPE_LEFT' &&
          totalDurationMs <= 360 &&
          (event.localPosition.dx - tapInfo.startPos.dx) < -48.0) {
        _telemetry = _telemetry.copyWith(lastDecision: '三指左滑撤销');
        onTwoFingerUndo?.call();
      }
      // 情况 5：单指双击适配页面宽度
      else if (_peakMultiTouchCount == 1 &&
          _telemetry.doubleTapFitWidthEnabled &&
          !_telemetry.zoomLocked &&
          _state.penOnlyMode &&
          totalDurationMs <= 150 &&
          moveDist < 8.0) {
        if (nowMs - _lastSingleTapUpMs <= 300 &&
            (event.localPosition - _lastSingleTapPos).distance < 24.0) {
          _lastSingleTapUpMs = 0;
          _telemetry = _telemetry.copyWith(lastDecision: '单指双击适配宽度');
          onDoubleTapFitWidth?.call();
        } else {
          _lastSingleTapUpMs = nowMs;
          _lastSingleTapPos = event.localPosition;
        }
      }
      _peakMultiTouchCount = 0;
    }

    if (_tempEraserTriggeredThisStroke || _telemetry.tempEraserActive) {
      _tempEraserTriggeredThisStroke = false;
      _telemetry = _telemetry.copyWith(
        tempEraserActive: false,
        stateLabel: '四重防误触已开启',
        lastDecision: '抬笔恢复原笔',
      );
      onExitTemporaryEraser?.call();
    }

    _rejectedPointers.remove(pid);
    final track = _tracks.remove(pid);
    if (_activeStylusPointerId == pid) {
      _activeStylusPointerId = null;
    }

    final exitFlickPoints = <({Offset localPos, double pressure})>[];
    if (track != null) {
      if (_telemetry.simulatedTaperEnabled &&
          track.samples.length >= 3 &&
          track.lastVelocityDpPerMs > 0.22) {
        final last = track.samples.last;
        final prev = track.samples[track.samples.length - 2];
        final delta = last.pos - prev.pos;
        final len = delta.distance;
        if (len > 1.2) {
          final ux = delta.dx / len;
          final uy = delta.dy / len;
          final tailCount = math.min(
            5,
            math.max(2, (track.lastVelocityDpPerMs * 4.5).round()),
          );
          for (int m = 1; m <= tailCount; m++) {
            final ratio = 1.0 - m / (tailCount + 1.0);
            final decay = ratio * ratio;
            exitFlickPoints.add((
              localPos: Offset(
                last.pos.dx + ux * m * 2.2,
                last.pos.dy + uy * m * 2.2,
              ),
              pressure: (track.lastSimulatedPressure * decay).clamp(0.08, 0.85),
            ));
          }
        }
      }

      if (_telemetry.emaAdaptiveEnabled &&
          track.totalDistanceDp > 50.0 &&
          track.samples.isNotEmpty) {
        final avgMm =
            track.samples.fold<double>(0.0, (s, e) => s + e.diameterMm) /
            track.samples.length;
        if (avgMm >= 0.6 && avgMm <= _telemetry.penMaxThresholdMm * 1.2) {
          final clampedMm = avgMm.clamp(
            _telemetry.emaMeanMm * 0.65,
            _telemetry.emaMeanMm * 1.35,
          );
          final newEma = 0.95 * _telemetry.emaMeanMm + 0.05 * clampedMm;
          _telemetry = _telemetry.copyWith(emaMeanMm: newEma);
        }
      }
    }

    _telemetry = _telemetry.copyWith(
      state: _activeStylusPointerId == null ? 'IDLE' : 'WRITING_LOCKED',
      stateLabel: _activeStylusPointerId == null ? '四重防误触已开启' : '书写锁定中',
      activePenPointerId: _activeStylusPointerId ?? -1,
    );
    _notifyTelemetryThrottled();
    return exitFlickPoints;
  }

  /// 系统三指截屏 `ACTION_CANCEL` 保护
  ({bool shouldCommitProtected, int truncateTailMs}) evaluatePointerCancel(
    PointerCancelEvent event,
  ) {
    final pid = event.pointer;
    _rejectedPointers.remove(pid);
    _gestureTapPointers.remove(pid);
    final track = _tracks.remove(pid);
    if (_activeStylusPointerId == pid) {
      _activeStylusPointerId = null;
    }
    if (track == null) {
      return (shouldCommitProtected: false, truncateTailMs: 0);
    }
    final durationMs = track.lastTimeMs - track.startTimeMs;
    final shouldCommit = durationMs >= 180 && track.totalDistanceDp >= 35.0;
    _telemetry = _telemetry.copyWith(
      state: 'IDLE',
      stateLabel: '四重防误触已开启',
      lastDecision: shouldCommit ? '三指截屏保护保存' : '取消短误触',
      activePenPointerId: -1,
    );
    _notifyTelemetryThrottled();
    return (shouldCommitProtected: shouldCommit, truncateTailMs: 30);
  }

  // ====================================================================
  //  第二部分：与 Android 原生 `:palm-guard` 模块的双向配置同步
  // ====================================================================

  Future<void> refreshTelemetry() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getTelemetry',
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        _state = _state.copyWith(
          rejectedPalmCount: _telemetry.rejectedPalmCount,
        );
        notifyListeners();
      }
    } on MissingPluginException {
      // 非 Android 平台使用纯 Dart 引擎
    } catch (_) {}
  }

  Future<void> setCanvasInteractive(bool interactive) async {
    try {
      await _channel.invokeMethod('setCanvasInteractive', {
        'interactive': interactive,
      });
    } catch (_) {}
  }

  Future<void> setImmersiveSystemBars(bool immersive) async {
    try {
      await _channel.invokeMethod('setImmersiveSystemBars', {
        'immersive': immersive,
      });
    } catch (_) {}
  }

  /// 同时兼容 `0.1 ~ 1.0` 连续灵敏度滑块与 `1 ~ 5` 档位设置
  Future<void> setSensitivity(num value) async {
    int level;
    double normSensitivity;
    if (value <= 1.0) {
      normSensitivity = value.toDouble().clamp(0.1, 1.0);
      level = (normSensitivity * 5.0).round().clamp(1, 5);
    } else {
      level = value.round().clamp(1, 5);
      normSensitivity = (level / 5.0).clamp(0.2, 1.0);
    }
    const mapMaxMm = {1: 5.6, 2: 4.8, 3: 4.2, 4: 3.5, 5: 2.8};
    _state = _state.copyWith(sensitivity: normSensitivity);
    _telemetry = _telemetry.copyWith(
      sensitivityLevel: level,
      penMaxThresholdMm: mapMaxMm[level] ?? 4.2,
    );
    notifyListeners();
    await _syncConfigToNative();
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'setSensitivity',
        {'level': level},
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        notifyListeners();
      }
    } catch (_) {}
  }

  void setPenMaxThresholdMm(double mm) {
    _telemetry = _telemetry.copyWith(penMaxThresholdMm: mm.clamp(1.5, 9.5));
    notifyListeners();
  }

  void setRollbackWindowMs(int ms) {
    _telemetry = _telemetry.copyWith(rollbackWindowMs: ms.clamp(40, 350));
    notifyListeners();
  }

  void setStylusLockEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(stylusLockEnabled: enabled);
    notifyListeners();
  }

  void setShowRejectRipple(bool enabled) {
    _telemetry = _telemetry.copyWith(showRejectRipple: enabled);
    notifyListeners();
  }

  void setEmaAdaptiveEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(emaAdaptiveEnabled: enabled);
    notifyListeners();
  }

  void setSimulatedTaperEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(simulatedTaperEnabled: enabled);
    notifyListeners();
  }

  void setOneEuroFilterEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(oneEuroFilterEnabled: enabled);
    notifyListeners();
  }

  Future<void> setHandedness(String mode) async {
    final matchedPosture = switch (mode) {
      'RIGHT_DIAGONAL' => PalmPosturePreset.rightHandStandard,
      'RIGHT_HORIZONTAL' => PalmPosturePreset.rightHandHook,
      'LEFT_DIAGONAL' => PalmPosturePreset.leftHandStandard,
      'AREA_ONLY' => PalmPosturePreset.flatWriting,
      _ => _state.posture,
    };
    _state = _state.copyWith(posture: matchedPosture);
    _telemetry = _telemetry.copyWith(handednessMode: mode);
    notifyListeners();
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'setHandedness',
        {'mode': mode},
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setSingleFingerPanMode(bool panOnly) {
    _state = _state.copyWith(penOnlyMode: panOnly);
    return setFingerActionMode(
      panOnly ? 'PEN_ONLY_PAN' : 'ALLOW_FINGER_WRITE',
    );
  }

  Future<void> setFingerActionMode(String mode) async {
    final isPenOnly = mode == 'PEN_ONLY_PAN' || mode == 'PAN_AND_ZOOM_ONLY';
    _state = _state.copyWith(penOnlyMode: isPenOnly);
    _telemetry = _telemetry.copyWith(fingerActionMode: mode);
    notifyListeners();
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'setFingerActionMode',
        {'mode': mode},
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> setPalmShield({
    bool? enabled,
    double? heightDp,
    String? mode,
  }) async {
    final nextEnabled = enabled ?? _telemetry.shieldEnabled;
    final nextHeight = (heightDp ?? _telemetry.shieldHeightDp).clamp(
      90.0,
      420.0,
    );
    final nextMode = mode ?? _telemetry.shieldMode;
    _telemetry = _telemetry.copyWith(
      shieldEnabled: nextEnabled,
      shieldHeightDp: nextHeight,
      shieldMode: nextMode,
    );
    notifyListeners();
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'setPalmShield',
        {
          'enabled': nextEnabled,
          'heightDp': nextHeight,
          'mode': nextMode,
        },
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        notifyListeners();
      }
    } catch (_) {}
  }

  void applyHardwarePreset({
    required String tabletPreset,
    required String tipPreset,
  }) {
    final ppiMap = {
      'pad6pro': 309.0,
      'pad6spro': 294.0,
      'matepad': 280.0,
      'vivopad': 309.0,
      'legion': 343.0,
    };
    final tipMaxMmMap = {
      'pom_fine': 3.6,
      'disc_metal': 4.4,
      'fiber_soft': 5.2,
    };
    _telemetry = _telemetry.copyWith(
      xdpi: ppiMap[tabletPreset] ?? 309.0,
      penMaxThresholdMm: tipMaxMmMap[tipPreset] ?? 4.2,
    );
    notifyListeners();
  }

  Future<String> calibrateFromSamples({
    required List<double> penSamplesMm,
    required List<double> palmSamplesMm,
  }) async {
    if (penSamplesMm.isNotEmpty) {
      final meanPen =
          penSamplesMm.reduce((a, b) => a + b) / penSamplesMm.length;
      final variance =
          penSamplesMm
              .map((x) => (x - meanPen) * (x - meanPen))
              .reduce((a, b) => a + b) /
          penSamplesMm.length;
      final stdPen = math.sqrt(variance);
      final minPalm = palmSamplesMm.isNotEmpty
          ? palmSamplesMm.reduce(math.min)
          : 11.5;
      final optimalPenMax = math
          .min(meanPen + 3.2 * stdPen + 0.8, 0.62 * meanPen + 0.38 * minPalm)
          .clamp(2.2, 6.8);
      final optimalPalmHard = math.max(optimalPenMax + 3.5, minPalm * 0.85);
      _telemetry = _telemetry.copyWith(
        penMaxThresholdMm: optimalPenMax,
        palmHardThresholdMm: optimalPalmHard,
        emaMeanMm: meanPen,
        isCalibrated: true,
      );
      notifyListeners();
    }

    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'calibrateFromSamples',
        {'penSamplesMm': penSamplesMm, 'palmSamplesMm': palmSamplesMm},
      );
      if (res != null) {
        await refreshTelemetry();
        return (res['message'] as String?) ??
            'L2 双模态实测校准已生效：笔尖阈值 ≤ ${_telemetry.penMaxThresholdMm.toStringAsFixed(2)}mm';
      }
    } catch (_) {}
    return 'L2 双模态实测校准已生效：笔尖阈值 ≤ ${_telemetry.penMaxThresholdMm.toStringAsFixed(2)}mm';
  }

  void setTwoFingerTapUndoEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(twoFingerTapUndoEnabled: enabled);
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setThreeFingerTapRedoEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(threeFingerTapRedoEnabled: enabled);
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setUndoGestureMode(String mode) {
    _telemetry = _telemetry.copyWith(
      undoGestureMode: mode,
      twoFingerTapUndoEnabled: mode != 'OFF',
    );
    notifyListeners();
  }

  void setZoomLocked(bool locked) {
    _telemetry = _telemetry.copyWith(zoomLocked: locked);
    notifyListeners();
  }

  void setZoomFollowStrokeWidth(bool enabled) {
    _telemetry = _telemetry.copyWith(zoomFollowStrokeWidth: enabled);
    notifyListeners();
  }

  void setDoubleTapFitWidthEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(doubleTapFitWidthEnabled: enabled);
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setFreePageMove({bool? enabled, double? resistance}) {
    _telemetry = _telemetry.copyWith(
      freePageMoveEnabled: enabled ?? _telemetry.freePageMoveEnabled,
      dragResistance: (resistance ?? _telemetry.dragResistance).clamp(
        0.0,
        0.85,
      ),
    );
    notifyListeners();
  }

  void setPressureEraser({bool? enabled, double? threshold}) {
    _telemetry = _telemetry.copyWith(
      pressureEraserEnabled: enabled ?? _telemetry.pressureEraserEnabled,
      pressureEraserThreshold:
          (threshold ?? _telemetry.pressureEraserThreshold).clamp(0.55, 0.98),
    );
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setHoldToTempEraser({bool? enabled, int? holdMs}) {
    _telemetry = _telemetry.copyWith(
      holdToTempEraserEnabled: enabled ?? _telemetry.holdToTempEraserEnabled,
      holdToTempEraserMs: (holdMs ?? _telemetry.holdToTempEraserMs).clamp(
        400,
        1500,
      ),
    );
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setQuickShapeHold({bool? enabled, int? holdMs}) {
    _telemetry = _telemetry.copyWith(
      quickShapeHoldEnabled: enabled ?? _telemetry.quickShapeHoldEnabled,
      quickShapeHoldMs: (holdMs ?? _telemetry.quickShapeHoldMs).clamp(
        300,
        1200,
      ),
    );
    notifyListeners();
    unawaited(_saveQuickActionSettings());
  }

  void setStylusTextSelectionEnabled(bool enabled) {
    _telemetry = _telemetry.copyWith(stylusTextSelectionEnabled: enabled);
    notifyListeners();
  }

  void setStraightLineEditMode(bool enabled) {
    _telemetry = _telemetry.copyWith(straightLineEditMode: enabled);
    notifyListeners();
  }

  int _lastBottomPageAddMs = 0;

  void updatePullUpProgress(double progress) {
    final clamped = progress.clamp(0.0, 1.0);
    if ((clamped - _telemetry.pullUpProgress).abs() < 0.02 && clamped != 0.0) {
      return;
    }
    _telemetry = _telemetry.copyWith(pullUpProgress: clamped);
    notifyListeners();
  }

  bool canTriggerBottomPageAdd() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastBottomPageAddMs < 650) return false;
    _lastBottomPageAddMs = now;
    _telemetry = _telemetry.copyWith(
      pullUpProgress: 0.0,
      lastDecision: '下滑底部自动加页',
    );
    notifyListeners();
    return true;
  }

  void setPageAddMode(String mode) {
    _telemetry = _telemetry.copyWith(pageAddMode: mode, pullUpProgress: 0.0);
    notifyListeners();
  }

  Future<void> resetToPreset() async {
    _state = const PalmGuardState();
    _telemetry = const PalmGuardTelemetry();
    notifyListeners();
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'resetToPreset',
      );
      if (res != null) {
        _telemetry = PalmGuardTelemetry.fromMap(res, _telemetry);
        notifyListeners();
      }
    } catch (_) {}
  }
}
