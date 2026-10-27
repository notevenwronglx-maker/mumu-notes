package dev.linwood.butterfly;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.media.MediaPlayer;
import android.media.MediaRecorder;
import android.media.PlaybackParams;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.io.File;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Real audio recording / playback bridge for the "音文手写同步" toolbar.
 *
 * <p>Recording uses {@link MediaRecorder} (AAC in MPEG_4 container) and playback uses
 * {@link MediaPlayer} with adjustable playback speed. Recordings are written to the app
 * scoped external files directory so no storage permission is required.</p>
 */
public class AudioSyncChannel implements MethodChannel.MethodCallHandler {

    private static final int RECORD_AUDIO_REQUEST_CODE = 4781;

    private final Activity activity;

    private MediaRecorder recorder;
    private MediaPlayer player;
    private File currentRecording;
    private long recordingStartedAtMs = 0L;
    private long lastDurationMs = 0L;
    private double playbackSpeed = 1.0;

    private MethodChannel.Result pendingPermissionResult;

    public AudioSyncChannel(Activity activity) {
        this.activity = activity;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "hasPermission":
                result.success(hasRecordPermission());
                return;
            case "requestPermission":
                requestRecordPermission(result);
                return;
            case "startRecording":
                startRecording(result);
                return;
            case "stopRecording":
                stopRecording(result);
                return;
            case "play":
                play(call, result);
                return;
            case "pause":
                pause(result);
                return;
            case "resume":
                resume(result);
                return;
            case "stopPlayback":
                stopPlayback(result);
                return;
            case "setSpeed":
                setSpeed(call, result);
                return;
            case "getStatus":
                result.success(buildStatus());
                return;
            case "deleteRecording":
                deleteRecording(call, result);
                return;
            default:
                result.notImplemented();
        }
    }

    // ------------------------------------------------------------------
    // Permission
    // ------------------------------------------------------------------

    private boolean hasRecordPermission() {
        return ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO)
                == PackageManager.PERMISSION_GRANTED;
    }

    private void requestRecordPermission(MethodChannel.Result result) {
        if (hasRecordPermission()) {
            result.success(true);
            return;
        }
        if (pendingPermissionResult != null) {
            pendingPermissionResult.success(false);
        }
        pendingPermissionResult = result;
        ActivityCompat.requestPermissions(
                activity,
                new String[]{Manifest.permission.RECORD_AUDIO},
                RECORD_AUDIO_REQUEST_CODE
        );
    }

    public void onRequestPermissionsResult(int requestCode, @NonNull int[] grantResults) {
        if (requestCode != RECORD_AUDIO_REQUEST_CODE || pendingPermissionResult == null) {
            return;
        }
        boolean granted = grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED;
        pendingPermissionResult.success(granted);
        pendingPermissionResult = null;
    }

    // ------------------------------------------------------------------
    // Recording
    // ------------------------------------------------------------------

    private void startRecording(MethodChannel.Result result) {
        if (!hasRecordPermission()) {
            result.error("permission_denied", "RECORD_AUDIO permission is not granted", null);
            return;
        }
        if (recorder != null) {
            result.success(buildStatus());
            return;
        }
        try {
            File dir = activity.getExternalFilesDir("recordings");
            if (dir == null) {
                dir = new File(activity.getFilesDir(), "recordings");
            }
            if (!dir.exists() && !dir.mkdirs()) {
                result.error("io_error", "Could not create recordings directory", null);
                return;
            }
            File target = new File(dir, "mumu_rec_" + System.currentTimeMillis() + ".m4a");

            MediaRecorder newRecorder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
                    ? new MediaRecorder(activity)
                    : new MediaRecorder();
            newRecorder.setAudioSource(MediaRecorder.AudioSource.MIC);
            newRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
            newRecorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC);
            newRecorder.setAudioSamplingRate(44100);
            newRecorder.setAudioEncodingBitRate(96000);
            newRecorder.setOutputFile(target.getAbsolutePath());
            newRecorder.prepare();
            newRecorder.start();

            recorder = newRecorder;
            currentRecording = target;
            recordingStartedAtMs = System.currentTimeMillis();
            lastDurationMs = 0L;
            result.success(buildStatus());
        } catch (IOException | RuntimeException e) {
            recorder = null;
            result.error("record_error", e.getMessage(), null);
        }
    }

    private void stopRecording(MethodChannel.Result result) {
        if (recorder == null) {
            result.success(buildStatus());
            return;
        }
        try {
            recorder.stop();
        } catch (RuntimeException e) {
            // stop() throws when the recording was too short to contain any frame.
            lastDurationMs = 0L;
        } finally {
            recorder.release();
            recorder = null;
        }
        if (recordingStartedAtMs > 0) {
            long elapsed = System.currentTimeMillis() - recordingStartedAtMs;
            if (lastDurationMs <= 0L) {
                lastDurationMs = elapsed;
            }
        }
        result.success(buildStatus());
    }

    // ------------------------------------------------------------------
    // Playback
    // ------------------------------------------------------------------

    private void play(MethodCall call, MethodChannel.Result result) {
        String path = call.argument("path");
        if (path == null || path.isEmpty()) {
            path = currentRecording != null ? currentRecording.getAbsolutePath() : null;
        }
        if (path == null) {
            result.error("no_recording", "There is no recording to play", null);
            return;
        }
        try {
            stopPlayerInternal();
            MediaPlayer newPlayer = new MediaPlayer();
            newPlayer.setDataSource(path);
            newPlayer.prepare();
            applySpeed(newPlayer, playbackSpeed);
            newPlayer.setOnCompletionListener(mp -> stopPlayerInternal());
            newPlayer.start();
            player = newPlayer;
            result.success(buildStatus());
        } catch (IOException | RuntimeException e) {
            stopPlayerInternal();
            result.error("play_error", e.getMessage(), null);
        }
    }

    private void pause(MethodChannel.Result result) {
        if (player != null && player.isPlaying()) {
            player.pause();
        }
        result.success(buildStatus());
    }

    private void resume(MethodChannel.Result result) {
        if (player != null && !player.isPlaying()) {
            applySpeed(player, playbackSpeed);
            player.start();
        }
        result.success(buildStatus());
    }

    private void stopPlayback(MethodChannel.Result result) {
        stopPlayerInternal();
        result.success(buildStatus());
    }

    private void setSpeed(MethodCall call, MethodChannel.Result result) {
        Double speed = call.argument("speed");
        playbackSpeed = speed == null ? 1.0 : speed;
        if (player != null) {
            try {
                applySpeed(player, playbackSpeed);
            } catch (RuntimeException ignored) {
                // Some devices reject speed changes while paused; the value is applied on resume.
            }
        }
        result.success(buildStatus());
    }

    private void applySpeed(MediaPlayer target, double speed) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PlaybackParams params = target.getPlaybackParams();
            params.setSpeed((float) speed);
            target.setPlaybackParams(params);
        }
    }

    private void stopPlayerInternal() {
        if (player == null) {
            return;
        }
        try {
            player.stop();
        } catch (IllegalStateException ignored) {
            // Already stopped.
        }
        player.release();
        player = null;
    }

    private void deleteRecording(MethodCall call, MethodChannel.Result result) {
        String path = call.argument("path");
        if (path != null && path.equals(currentRecording != null ? currentRecording.getAbsolutePath() : null)) {
            currentRecording = null;
            lastDurationMs = 0L;
        }
        if (path != null) {
            File file = new File(path);
            if (file.exists()) {
                //noinspection ResultOfMethodCallIgnored
                file.delete();
            }
        }
        result.success(buildStatus());
    }

    // ------------------------------------------------------------------
    // Status
    // ------------------------------------------------------------------

    private Map<String, Object> buildStatus() {
        Map<String, Object> status = new HashMap<>();
        status.put("isRecording", recorder != null);
        status.put("isPlaying", player != null && player.isPlaying());
        status.put("hasPlayer", player != null);
        status.put("speed", playbackSpeed);
        status.put("path", currentRecording != null ? currentRecording.getAbsolutePath() : null);

        long positionMs = 0L;
        long durationMs = recorder != null
                ? Math.max(0L, System.currentTimeMillis() - recordingStartedAtMs)
                : lastDurationMs;
        if (player != null) {
            try {
                positionMs = player.getCurrentPosition();
                durationMs = player.getDuration();
            } catch (IllegalStateException ignored) {
                // Keep the previous values.
            }
        } else if (recorder == null) {
            positionMs = 0L;
        }
        status.put("positionMs", positionMs);
        status.put("durationMs", durationMs);
        return status;
    }

    public void dispose() {
        stopPlayerInternal();
        if (recorder != null) {
            try {
                recorder.stop();
            } catch (RuntimeException ignored) {
                // Recording was too short.
            }
            recorder.release();
            recorder = null;
        }
    }
}
