import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Immutable snapshot of the native audio recorder / player state.
@immutable
class AudioSyncSnapshot {
  final bool isRecording;
  final bool isPlaying;
  final bool hasPlayer;
  final double speed;
  final String? path;
  final int positionMs;
  final int durationMs;
  final bool supported;
  final String? error;

  const AudioSyncSnapshot({
    this.isRecording = false,
    this.isPlaying = false,
    this.hasPlayer = false,
    this.speed = 1.0,
    this.path,
    this.positionMs = 0,
    this.durationMs = 0,
    this.supported = true,
    this.error,
  });

  AudioSyncSnapshot copyWith({
    bool? isRecording,
    bool? isPlaying,
    bool? hasPlayer,
    double? speed,
    String? path,
    bool clearPath = false,
    int? positionMs,
    int? durationMs,
    bool? supported,
    String? error,
    bool clearError = false,
  }) => AudioSyncSnapshot(
    isRecording: isRecording ?? this.isRecording,
    isPlaying: isPlaying ?? this.isPlaying,
    hasPlayer: hasPlayer ?? this.hasPlayer,
    speed: speed ?? this.speed,
    path: clearPath ? null : (path ?? this.path),
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs ?? this.durationMs,
    supported: supported ?? this.supported,
    error: clearError ? null : (error ?? this.error),
  );

  String get positionLabel => _format(positionMs);

  String get durationLabel => _format(durationMs);

  static String _format(int ms) {
    final total = (ms / 1000).floor().clamp(0, 359999);
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// 音文同步：真实的原生录音 / 回放通道（Android 端 MediaRecorder + MediaPlayer）。
///
/// 其他平台没有注册该 channel 时会自动降级为“当前平台不支持”，
/// 界面据此显示禁用态而不是伪造一个假状态。
class AudioSyncService extends ChangeNotifier {
  AudioSyncService._();

  static final AudioSyncService instance = AudioSyncService._();

  static const MethodChannel _channel = MethodChannel(
    'com.mumunotes/audio_sync',
  );

  AudioSyncSnapshot _snapshot = const AudioSyncSnapshot();
  AudioSyncSnapshot get snapshot => _snapshot;

  Timer? _pollTimer;
  bool _channelMissing = false;

  bool get isAvailable => !_channelMissing;

  Future<bool> ensurePermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>('hasPermission');
      if (granted == true) return true;
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result == true;
    } on MissingPluginException {
      _markUnsupported();
      return false;
    } catch (e) {
      _snapshot = _snapshot.copyWith(error: '$e');
      notifyListeners();
      return false;
    }
  }

  Future<void> startRecording() async {
    if (_channelMissing) return;
    if (!await ensurePermission()) {
      _snapshot = _snapshot.copyWith(error: '未获得麦克风权限，无法录音');
      notifyListeners();
      return;
    }
    await _invoke('startRecording');
    _startPolling();
  }

  Future<void> stopRecording() async {
    if (_channelMissing) return;
    await _invoke('stopRecording');
    await refresh();
    _stopPollingIfIdle();
  }

  /// 播放 / 暂停一键切换：没有活跃播放器时从文件播放，否则暂停或继续。
  Future<void> togglePlay({String? path}) async {
    if (_snapshot.isPlaying) {
      await pause();
    } else if (_snapshot.hasPlayer) {
      await resume();
    } else {
      await play(path: path);
    }
  }

  Future<void> play({String? path}) async {
    if (_channelMissing) return;
    await _invoke('play', {'path': path ?? _snapshot.path});
    _startPolling();
  }

  Future<void> pause() async {
    if (_channelMissing) return;
    await _invoke('pause');
    await refresh();
  }

  Future<void> resume() async {
    if (_channelMissing) return;
    await _invoke('resume');
    _startPolling();
  }

  Future<void> stopPlayback() async {
    if (_channelMissing) return;
    await _invoke('stopPlayback');
    await refresh();
    _stopPollingIfIdle();
  }

  Future<void> setSpeed(double speed) async {
    _snapshot = _snapshot.copyWith(speed: speed);
    notifyListeners();
    if (_channelMissing) return;
    await _invoke('setSpeed', {'speed': speed});
  }

  bool get hasRecording => (_snapshot.path ?? '').isNotEmpty;

  Future<void> refresh() async {
    if (_channelMissing) return;
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getStatus',
      );
      if (res != null) {
        _snapshot = _fromMap(res);
        notifyListeners();
      }
    } on MissingPluginException {
      _markUnsupported();
    } catch (_) {
      // Keep the previous snapshot on transient platform errors.
    }
  }

  Future<void> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        method,
        args,
      );
      if (res != null) {
        _snapshot = _fromMap(res);
        notifyListeners();
      }
    } on MissingPluginException {
      _markUnsupported();
    } on PlatformException catch (e) {
      _snapshot = _snapshot.copyWith(error: e.message ?? e.code);
      notifyListeners();
    } catch (e) {
      _snapshot = _snapshot.copyWith(error: '$e');
      notifyListeners();
    }
  }

  AudioSyncSnapshot _fromMap(Map<dynamic, dynamic> map) {
    return _snapshot.copyWith(
      isRecording: map['isRecording'] as bool? ?? false,
      isPlaying: map['isPlaying'] as bool? ?? false,
      hasPlayer: map['hasPlayer'] as bool? ?? false,
      speed: (map['speed'] as num?)?.toDouble() ?? _snapshot.speed,
      path: map['path'] as String?,
      clearPath: map['path'] == null,
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      supported: true,
      clearError: true,
    );
  }

  void _markUnsupported() {
    _channelMissing = true;
    _snapshot = _snapshot.copyWith(
      supported: false,
      isRecording: false,
      isPlaying: false,
      error: '当前平台未内置录音模块',
    );
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => refresh(),
    );
  }

  void _stopPollingIfIdle() {
    if (!_snapshot.isPlaying && !_snapshot.isRecording) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
