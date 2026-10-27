package com.mumunotes.core.touch

import android.content.Context
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import com.mumunotes.core.touch.model.CalibrationSnapshot
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.HandednessMode

/**
 * 零外部依赖的校准参数持久化工具（基于原生 [SharedPreferences] + 内存脏标记与防抖异步 `apply()`）。
 *
 * 优化修复：
 * - 引入内存脏标记（[isDirty]）与防抖异步落盘（[saveDebounced]），避免在高频书写 L3 EMA 更新或滑块连续拖动时
 *   同步触发磁盘 I/O 阻塞 UI 主线程导致掉帧。
 */
object CalibrationPreferences {

    private const val PREFS_NAME = "palm_guard_calibration_prefs"
    private const val DEFAULT_DEBOUNCE_MS = 600L

    private const val KEY_HAS_SNAPSHOT = "has_snapshot"
    private const val KEY_PEN_MAX_MM = "pen_max_mm"
    private const val KEY_PALM_HARD_MIN_MM = "palm_hard_min_mm"
    private const val KEY_PALM_HARD_DP = "palm_hard_dp"
    private const val KEY_MAX_ECCENTRICITY = "max_eccentricity"
    private const val KEY_EMA_PEN_DIAMETER_MM = "ema_pen_diameter_mm"
    private const val KEY_SENSITIVITY_LEVEL = "sensitivity_level"
    private const val KEY_HANDEDNESS_MODE = "handedness_mode"
    private const val KEY_FINGER_ACTION_MODE = "finger_action_mode"
    private const val KEY_DEVICE_PRESET_ID = "device_preset_id"
    private const val KEY_PEN_SAMPLE_COUNT = "pen_sample_count"
    private const val KEY_PALM_SAMPLE_COUNT = "palm_sample_count"
    private const val KEY_LAST_CALIBRATED_MS = "last_calibrated_ms"
    private const val KEY_IS_CALIBRATED = "is_calibrated"
    private const val KEY_PEN_MAX_CALIBRATED_MM = "pen_max_calibrated_mm"
    private const val KEY_PALM_HARD_CALIBRATED_MM = "palm_hard_calibrated_mm"
    private const val KEY_ECCENTRICITY_BASE = "eccentricity_base"
    private const val KEY_CALIBRATED_PEN_MEAN_MM = "calibrated_pen_mean_mm"

    private const val KEY_SHIELD_ENABLED = "shield_enabled"
    private const val KEY_SHIELD_MODE = "shield_mode"
    private const val KEY_SHIELD_WIDTH_RATIO = "shield_width_ratio"
    private const val KEY_SHIELD_HEIGHT_DP = "shield_height_dp"

    @Volatile
    var isDirty: Boolean = false
        private set

    private val mainHandler: Handler? by lazy {
        runCatching { Handler(Looper.getMainLooper()) }.getOrNull()
    }
    private var pendingFlushRunnable: Runnable? = null

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * 标记内存状态已变更并防抖异步写入 SharedPreferences（默认 600ms 合并一次 apply()，零主线程阻塞）。
     */
    fun saveDebounced(
        context: Context,
        profile: AdaptiveThresholdProfile,
        shield: VirtualPalmShield? = null,
        debounceMs: Long = DEFAULT_DEBOUNCE_MS
    ) {
        isDirty = true
        profile.isDirty = true
        val appContext = context.applicationContext
        val handler = mainHandler
        if (handler == null) {
            flushNow(appContext, profile, shield)
            return
        }
        pendingFlushRunnable?.let { handler.removeCallbacks(it) }
        val task = Runnable {
            if (isDirty || profile.isDirty) {
                flushNow(appContext, profile, shield)
            }
        }
        pendingFlushRunnable = task
        handler.postDelayed(task, debounceMs.coerceAtLeast(50L))
    }

    /** 保存当前阈值配置与虚拟手垫状态（默认走防抖异步 apply，需要立即落盘时可传 immediate = true） */
    fun save(
        context: Context,
        profile: AdaptiveThresholdProfile,
        shield: VirtualPalmShield? = null,
        immediate: Boolean = false
    ) {
        if (immediate) {
            flushNow(context, profile, shield)
        } else {
            saveDebounced(context, profile, shield)
        }
    }

    /** 立即执行异步 apply() 落盘并清除脏标记 */
    fun flushNow(
        context: Context,
        profile: AdaptiveThresholdProfile,
        shield: VirtualPalmShield? = null
    ) {
        pendingFlushRunnable?.let { mainHandler?.removeCallbacks(it) }
        pendingFlushRunnable = null
        isDirty = false
        profile.isDirty = false

        val snap = profile.snapshot()
        prefs(context).edit().apply {
            putBoolean(KEY_HAS_SNAPSHOT, true)
            putFloat(KEY_PEN_MAX_MM, snap.penMaxMm)
            putFloat(KEY_PALM_HARD_MIN_MM, snap.palmHardMinMm)
            putFloat(KEY_PALM_HARD_DP, snap.palmHardDp)
            putFloat(KEY_MAX_ECCENTRICITY, snap.maxEccentricity)
            putFloat(KEY_EMA_PEN_DIAMETER_MM, snap.emaPenDiameterMm)
            putInt(KEY_SENSITIVITY_LEVEL, snap.sensitivityLevel)
            putString(KEY_HANDEDNESS_MODE, snap.handednessMode.name)
            putString(KEY_FINGER_ACTION_MODE, profile.fingerActionMode.name)
            putString(KEY_DEVICE_PRESET_ID, snap.devicePresetId)
            putInt(KEY_PEN_SAMPLE_COUNT, snap.penSampleCount)
            putInt(KEY_PALM_SAMPLE_COUNT, snap.palmSampleCount)
            putLong(KEY_LAST_CALIBRATED_MS, snap.lastCalibratedAtMs)
            putBoolean(KEY_IS_CALIBRATED, snap.isCalibrated)
            putFloat(KEY_PEN_MAX_CALIBRATED_MM, snap.penMaxCalibratedMm)
            putFloat(KEY_PALM_HARD_CALIBRATED_MM, snap.palmHardCalibratedMm)
            putFloat(KEY_ECCENTRICITY_BASE, snap.eccentricityBase)
            putFloat(KEY_CALIBRATED_PEN_MEAN_MM, snap.calibratedPenMeanMm)

            if (shield != null) {
                putBoolean(KEY_SHIELD_ENABLED, shield.enabled)
                putString(KEY_SHIELD_MODE, shield.mode.name)
                putFloat(KEY_SHIELD_WIDTH_RATIO, shield.widthRatio)
                putFloat(KEY_SHIELD_HEIGHT_DP, shield.heightDp)
            }
        }.apply()
    }

    /** 从 SharedPreferences 恢复校准状态与虚拟手垫配置；若尚未保存过则返回 false */
    fun loadInto(
        context: Context,
        profile: AdaptiveThresholdProfile,
        shield: VirtualPalmShield? = null
    ): Boolean {
        val sp = prefs(context)
        if (!sp.getBoolean(KEY_HAS_SNAPSHOT, false)) return false

        val preset = profile.devicePreset
        val emaMean = sp.getFloat(KEY_EMA_PEN_DIAMETER_MM, AdaptiveThresholdProfile.DEFAULT_EMA_PEN_DIAMETER_MM)
        val snapshot = CalibrationSnapshot(
            penMaxMm = sp.getFloat(KEY_PEN_MAX_MM, preset.penMaxMm),
            palmHardMinMm = sp.getFloat(KEY_PALM_HARD_MIN_MM, preset.palmHardMinMm),
            palmHardDp = sp.getFloat(KEY_PALM_HARD_DP, profile.palmHardDp),
            maxEccentricity = sp.getFloat(KEY_MAX_ECCENTRICITY, preset.maxEccentricity),
            emaPenDiameterMm = emaMean,
            sensitivityLevel = sp.getInt(KEY_SENSITIVITY_LEVEL, AdaptiveThresholdProfile.DEFAULT_SENSITIVITY),
            handednessMode = HandednessMode.fromNameOrDefault(sp.getString(KEY_HANDEDNESS_MODE, null)),
            devicePresetId = sp.getString(KEY_DEVICE_PRESET_ID, preset.id) ?: preset.id,
            penSampleCount = sp.getInt(KEY_PEN_SAMPLE_COUNT, 0),
            palmSampleCount = sp.getInt(KEY_PALM_SAMPLE_COUNT, 0),
            lastCalibratedAtMs = sp.getLong(KEY_LAST_CALIBRATED_MS, 0L),
            isCalibrated = sp.getBoolean(KEY_IS_CALIBRATED, false),
            penMaxCalibratedMm = sp.getFloat(KEY_PEN_MAX_CALIBRATED_MM, preset.penMaxMm),
            palmHardCalibratedMm = sp.getFloat(KEY_PALM_HARD_CALIBRATED_MM, preset.palmHardMinMm),
            eccentricityBase = sp.getFloat(KEY_ECCENTRICITY_BASE, preset.maxEccentricity),
            calibratedPenMeanMm = sp.getFloat(KEY_CALIBRATED_PEN_MEAN_MM, emaMean)
        )
        profile.restore(snapshot)

        val fingerModeName = sp.getString(KEY_FINGER_ACTION_MODE, null)
        if (fingerModeName != null) {
            FingerActionMode.entries.firstOrNull { it.name == fingerModeName }?.let {
                profile.fingerActionMode = it
            }
        }

        if (shield != null) {
            shield.enabled = sp.getBoolean(KEY_SHIELD_ENABLED, shield.enabled)
            val modeName = sp.getString(KEY_SHIELD_MODE, null)
            if (modeName != null) {
                ShieldMode.entries.firstOrNull { it.name == modeName }?.let {
                    shield.mode = it
                }
            }
            shield.widthRatio = sp.getFloat(KEY_SHIELD_WIDTH_RATIO, shield.widthRatio)
            shield.heightDp = sp.getFloat(KEY_SHIELD_HEIGHT_DP, shield.heightDp)
        }
        isDirty = false
        profile.isDirty = false
        return true
    }

    /** 清除已保存的校准记录并恢复出厂预设 */
    fun clear(context: Context, profile: AdaptiveThresholdProfile, shield: VirtualPalmShield? = null) {
        pendingFlushRunnable?.let { mainHandler?.removeCallbacks(it) }
        pendingFlushRunnable = null
        isDirty = false
        profile.isDirty = false
        prefs(context).edit().clear().apply()
        profile.resetToDevicePreset()
        shield?.resetPosition()
    }
}
