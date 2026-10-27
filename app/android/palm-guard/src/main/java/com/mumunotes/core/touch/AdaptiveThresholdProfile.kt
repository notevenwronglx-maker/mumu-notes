package com.mumunotes.core.touch

import android.os.Build
import com.mumunotes.core.touch.model.CalibrationResult
import com.mumunotes.core.touch.model.CalibrationSnapshot
import com.mumunotes.core.touch.model.DevicePreset
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.HandednessMode
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * 三阶自适应动态阈值引擎（文档 1.4 节）。
 *
 * - **L1 设备 DPI 物理归一化层**：全部绝对尺寸判定换算到物理毫米，消除 PPI 差异；并按机型套用预设参数库。
 * - **L2 双模态交互校准向导**：笔尖连点 5 次 + 手掌贴屏 3 次，计算最优分割阈值。
 * - **L3 Winsorized EMA（截尾指数移动平均）在线漂移自适应补偿**：对已确认长度 > 50dp 的合法笔迹统计直径，
 *   先通过上下界离群值夹持（Outlier Clamping）防止整只手掌拍击/擦拭屏幕导致的“自适应阈值中毒（Threshold Poisoning）”，
 *   再以 0.95 : 0.05 指数滑动平均微调 T_pen_max，浮动范围 ±15%。
 */
class AdaptiveThresholdProfile(
    var displayProfile: DisplayProfile,
    deviceModel: String = Build.MODEL.orEmpty(),
    initialSensitivity: Int = DEFAULT_SENSITIVITY,
    handednessMode: HandednessMode = HandednessMode.DEFAULT,
    fingerActionMode: FingerActionMode = FingerActionMode.PAN_CANVAS
) {

    // ============================ L1：设备归一化与机型预设 ============================

    val devicePreset: DevicePreset = lookupPreset(deviceModel)

    /** 机型的原始标识，用于遥测与预设回溯 */
    val deviceModel: String = deviceModel

    /** 笔尖等效直径上限基准（mm），权威阈值之一 */
    private var penMaxBaseMm: Float = devicePreset.penMaxMm

    /** 掌根硬拒绝下限基准（mm），权威阈值之一 */
    private var palmHardBaseMm: Float = devicePreset.palmHardMinMm

    /** 椭圆偏心率上限 */
    private var eccentricityLimit: Float = devicePreset.maxEccentricity

    /**
     * L2 校准得到的笔尖上限，作为 L3 漂移补偿的锚点；
     * 未校准时等于 L1 预设值。
     */
    private var penMaxCalibratedMm: Float = devicePreset.penMaxMm

    private var palmHardCalibratedMm: Float = devicePreset.palmHardMinMm

    /** L2 校准时的笔尖均值锚点（mm），用于无跳变计算 L3 相对漂移比 */
    private var calibratedPenMeanMm: Float = DEFAULT_EMA_PEN_DIAMETER_MM

    /** 在线 EMA 观察到的笔尖平均直径基准（mm） */
    var emaPenDiameterMm: Float = DEFAULT_EMA_PEN_DIAMETER_MM
        private set

    /** 内存脏标记：当在线 EMA 或配置发生变更但尚未落盘时置为 true */
    @Volatile
    var isDirty: Boolean = false
        internal set

    /** 用户校准档位 1~5，数值越大防误触越强 */
    var sensitivityLevel: Int = initialSensitivity.coerceIn(MIN_SENSITIVITY, MAX_SENSITIVITY)
        set(value) {
            field = value.coerceIn(MIN_SENSITIVITY, MAX_SENSITIVITY)
            isDirty = true
        }

    /** 握笔姿态空间几何模式 */
    var handednessMode: HandednessMode = handednessMode
        set(value) {
            field = value
            isDirty = true
        }

    /** 手指尺寸触点处置策略 */
    var fingerActionMode: FingerActionMode = fingerActionMode
        set(value) {
            field = value
            isDirty = true
        }

    var penSampleCount: Int = 0
        private set
    var palmSampleCount: Int = 0
        private set
    var penSigmaMm: Float = 0f
        private set
    var palmMinMm: Float = 0f
        private set
    var lastCalibratedAtMs: Long = 0L
        private set
    var isCalibrated: Boolean = false
        private set

    // ============================ 生效阈值 ============================

    /**
     * 生效的笔尖等效直径上限（mm）。
     */
    val penMaxMm: Float
        get() {
            val scale = PenSensitivityScale[sensitivityLevel]
            val driftAdjusted = penMaxFromOnlineMean()
            val lo = penMaxCalibratedMm * (1f - ONLINE_DRIFT_BAND)
            val hi = penMaxCalibratedMm * (1f + ONLINE_DRIFT_BAND)
            return (driftAdjusted.coerceIn(lo, hi) * scale).coerceIn(MIN_PEN_MAX_MM, MAX_PEN_MAX_MM)
        }

    /** 生效的掌根硬拒绝下限（mm），恒大于笔尖上限并保留安全间隔 */
    val palmHardMinMm: Float
        get() {
            val scale = PalmSensitivityScale[sensitivityLevel]
            val scaled = (palmHardCalibratedMm * scale).coerceIn(MIN_PALM_HARD_MM, MAX_PALM_HARD_MM)
            return max(scaled, penMaxMm + MIN_PEN_PALM_GAP_MM)
        }

    /** 兼容属性：多模态仲裁器使用的动态手掌长轴毫米阈值 */
    val palmTouchMajorThresholdMm: Float
        get() = palmHardMinMm

    /** 兼容属性：归一化面积阈值（MotionEvent.getSize() 上限） */
    val palmSizeThreshold: Float = DEFAULT_PALM_SIZE_THRESHOLD

    /** 由毫米阈值推导的 dp 阈值 */
    val palmHardDp: Float
        get() = displayProfile.pxToDp(displayProfile.mmToPx(palmHardMinMm))

    /** 生效的笔尖上限 dp */
    val penMaxDp: Float
        get() = displayProfile.pxToDp(displayProfile.mmToPx(penMaxMm))

    /** 生效的椭圆偏心率上限；灵敏度越高越严格 */
    val maxEccentricity: Float
        get() = (eccentricityLimit * EccentricitySensitivityScale[sensitivityLevel])
            .coerceIn(MIN_ECCENTRICITY, MAX_ECCENTRICITY)

    // ============================ 阶段 2：0ms 瞬时形态硬阈值 ============================

    val sidePalmEccentricity: Float get() = SIDE_PALM_ECCENTRICITY * EccentricitySensitivityScale[sensitivityLevel]
    val penEccentricityMax: Float get() = PEN_ECCENTRICITY_MAX
    val trailingEdgeMarginDp: Float = TRAILING_EDGE_MARGIN_DP
    val trailingEdgeProximityDp: Float = TRAILING_EDGE_PROXIMITY_DP

    // ============================ 阶段 3：35ms 候选观察窗 ============================

    val observeWindowMs: Long = OBSERVE_WINDOW_MS
    val candidateStablePromoteMs: Long = OBSERVE_WINDOW_MS
    val candidatePromotePathDp: Float = CANDIDATE_PROMOTE_PATH_DP
    val observeWindowExpansionDpPerMs: Float = OBSERVE_EXPANSION_DP_PER_MS
    val penExpansionMaxDpPerMs: Float = PEN_EXPANSION_MAX_DP_PER_MS

    // ============================ 阶段 4：160ms 空间几何抢占 ============================

    val preemptWindowMs: Long = PREEMPT_WINDOW_MS
    val preemptMaxPathDp: Float = PREEMPT_MAX_PATH_DP
    val geometricPreemptMarginDp: Float = GEOMETRIC_PREEMPT_MARGIN_DP

    // ============================ 阶段 5：强书写锁定与并发免疫 ============================

    val writingLockMs: Long = WRITING_LOCK_MS
    val writingLockPathDp: Float = WRITING_LOCK_PATH_DP
    val expansionCancelWindowMs: Long = EXPANSION_CANCEL_WINDOW_MS
    val expansionCancelDpPerMs: Float = EXPANSION_CANCEL_DP_PER_MS
    val penMaxGrowthFactor: Float = PEN_MAX_GROWTH_FACTOR

    // ============================ 多指手势仲裁 ============================

    val gestureDownWindowMs: Long = GESTURE_DOWN_WINDOW_MS
    val gestureMinSpanDp: Float = GESTURE_MIN_SPAN_DP
    val threeFingerTapMaxDurationMs: Long = THREE_FINGER_TAP_MAX_MS
    val threeFingerTapMaxPathDp: Float = THREE_FINGER_TAP_MAX_PATH_DP
    val gestureTapMaxDurationMs: Long get() = threeFingerTapMaxDurationMs
    val gestureTapMaxPathDp: Float get() = threeFingerTapMaxPathDp

    // ============================ 系统手势 ACTION_CANCEL 防护 ============================

    val cancelProtectMinAliveMs: Long = CANCEL_PROTECT_MIN_ALIVE_MS
    val cancelProtectMinPathDp: Float = CANCEL_PROTECT_MIN_PATH_DP
    val cancelTailTruncateMs: Long = CANCEL_TAIL_TRUNCATE_MS
    val systemGestureMinPointers: Int = SYSTEM_GESTURE_MIN_POINTERS
    val systemGestureMaxAliveMs: Long = SYSTEM_GESTURE_MAX_ALIVE_MS

    // ============================ L3 在线校准 ============================

    val onlineCalibrationMinPathDp: Float = ONLINE_CALIBRATION_MIN_PATH_DP
    val onlineEmaAlpha: Float = ONLINE_EMA_ALPHA

    // ============================ L2：双模态实测校准 ============================

    fun calibrateFromSamples(
        penSamplesMm: List<Float>,
        palmSamplesMm: List<Float>,
        nowMs: Long = System.currentTimeMillis()
    ): CalibrationResult {
        val pens = penSamplesMm.filter { it.isFinite() && it > 0f }
        val palms = palmSamplesMm.filter { it.isFinite() && it > 0f }

        if (pens.size < MIN_CALIBRATION_PEN_SAMPLES) {
            return CalibrationResult.rejected("笔尖样本不足：至少需要 $MIN_CALIBRATION_PEN_SAMPLES 次有效点画，当前 ${pens.size} 次")
        }
        if (palms.size < MIN_CALIBRATION_PALM_SAMPLES) {
            return CalibrationResult.rejected("手掌样本不足：至少需要 $MIN_CALIBRATION_PALM_SAMPLES 次有效贴屏，当前 ${palms.size} 次")
        }

        val penMean = pens.average().toFloat()
        val penSigma = standardDeviation(pens, penMean)
        val palmMin = palms.min()

        val upperBound = penMean + PEN_SIGMA_FACTOR * penSigma + PEN_SIGMA_HEADROOM_MM
        val splitBound = PEN_MEAN_WEIGHT * penMean + PALM_MIN_WEIGHT * palmMin
        var penMax = min(upperBound, splitBound).coerceIn(MIN_PEN_MAX_MM, MAX_PEN_MAX_MM)

        // 物理一致性：笔尖上限必须显著低于实测手掌最小值
        val consistencyCeiling = palmMin * PEN_TO_PALM_SAFE_RATIO
        val consistencyNote = if (penMax > consistencyCeiling) {
            penMax = consistencyCeiling
            "（样本重叠较大，已按实测手掌下限收敛）"
        } else {
            ""
        }

        val palmHard = max(palmMin * PALM_MIN_SAFETY_RATIO, penMax + MIN_PEN_PALM_GAP_MM)
            .coerceIn(MIN_PALM_HARD_MM, MAX_PALM_HARD_MM)

        penMaxCalibratedMm = penMax
        palmHardCalibratedMm = palmHard
        calibratedPenMeanMm = penMean.coerceAtLeast(0.1f)
        emaPenDiameterMm = penMean
        penSampleCount = pens.size
        palmSampleCount = palms.size
        penSigmaMm = penSigma
        palmMinMm = palmMin
        lastCalibratedAtMs = nowMs
        isCalibrated = true
        isDirty = true

        val overlap = penMean + PEN_SIGMA_FACTOR * penSigma > palmMin
        return CalibrationResult(
            success = true,
            penMaxMm = penMax,
            palmHardMinMm = palmHard,
            penMeanMm = penMean,
            penSigmaMm = penSigma,
            palmMinMm = palmMin,
            penSampleCount = pens.size,
            palmSampleCount = palms.size,
            message = buildString {
                append("校准完成：笔尖均值 %.2fmm，标准差 %.2fmm，手掌下限 %.2fmm。".format(penMean, penSigma, palmMin))
                append(consistencyNote)
                if (overlap) append("提示：笔尖样本与手掌样本存在重叠，建议更换笔头或降低握笔倾角后重测。")
            }
        )
    }

    /** 恢复出厂预设（清空 L2/L3 结果） */
    fun resetToDevicePreset() {
        penMaxBaseMm = devicePreset.penMaxMm
        palmHardBaseMm = devicePreset.palmHardMinMm
        eccentricityLimit = devicePreset.maxEccentricity
        penMaxCalibratedMm = devicePreset.penMaxMm
        palmHardCalibratedMm = devicePreset.palmHardMinMm
        calibratedPenMeanMm = DEFAULT_EMA_PEN_DIAMETER_MM
        emaPenDiameterMm = DEFAULT_EMA_PEN_DIAMETER_MM
        penSampleCount = 0
        palmSampleCount = 0
        penSigmaMm = 0f
        palmMinMm = 0f
        lastCalibratedAtMs = 0L
        isCalibrated = false
        isDirty = true
    }

    // ============================ L3：Winsorized EMA（截尾指数移动平均）防中毒更新 ============================

    /**
     * 采用 Winsorized EMA（截尾指数移动平均）更新在线笔尖直径均值。
     *
     * 修复阈值中毒（Threshold Poisoning）：
     * 1. 若单次样本偏离物理笔尖合理区间 `[MIN_WINSORIZED_PEN_MM, penMaxCalibratedMm * 1.25f]`，直接拒绝混入；
     * 2. 将有效样本截尾夹持在当前 `emaPenDiameterMm` 的 `[0.65x, 1.35x]` 区间内，
     *    确保即使偶发大面积边缘擦拭混入，单次更新也绝不会把阈值拉偏。
     */
    fun updateOnlinePenStats(observedMeanDiameterMm: Float) {
        if (!observedMeanDiameterMm.isFinite() || observedMeanDiameterMm <= 0f) return
        val hardCeiling = min(MAX_PEN_MAX_MM, penMaxCalibratedMm * WINSORIZE_CALIBRATED_CEILING_FACTOR)
        if (observedMeanDiameterMm < MIN_WINSORIZED_PEN_MM || observedMeanDiameterMm > hardCeiling) {
            return
        }
        val lo = max(MIN_WINSORIZED_PEN_MM, emaPenDiameterMm * WINSORIZE_STEP_MIN_RATIO)
        val hi = min(hardCeiling, emaPenDiameterMm * WINSORIZE_STEP_MAX_RATIO)
        val clampedSample = observedMeanDiameterMm.coerceIn(lo, hi)

        val anchorFloor = calibratedPenMeanMm * (1f - ONLINE_DRIFT_BAND)
        val anchorCeiling = calibratedPenMeanMm * (1f + ONLINE_DRIFT_BAND)
        emaPenDiameterMm = (onlineEmaAlpha * emaPenDiameterMm + (1f - onlineEmaAlpha) * clampedSample)
            .coerceIn(anchorFloor.coerceAtLeast(MIN_WINSORIZED_PEN_MM), anchorCeiling.coerceAtMost(MAX_PEN_MAX_MM))
        isDirty = true
    }

    private fun penMaxFromOnlineMean(): Float {
        val anchorMean = calibratedPenMeanMm.coerceAtLeast(0.1f)
        if (abs(emaPenDiameterMm - anchorMean) < 1e-4f) {
            return penMaxCalibratedMm
        }
        val ratio = emaPenDiameterMm / anchorMean
        return penMaxCalibratedMm * ratio
    }

    // ============================ 快照 ============================

    fun snapshot(nowMs: Long = System.currentTimeMillis()): CalibrationSnapshot = CalibrationSnapshot(
        penMaxMm = penMaxMm,
        palmHardMinMm = palmHardMinMm,
        palmHardDp = palmHardDp,
        maxEccentricity = maxEccentricity,
        emaPenDiameterMm = emaPenDiameterMm,
        sensitivityLevel = sensitivityLevel,
        handednessMode = handednessMode,
        devicePresetId = devicePreset.id,
        penSampleCount = penSampleCount,
        palmSampleCount = palmSampleCount,
        lastCalibratedAtMs = if (lastCalibratedAtMs == 0L) nowMs else lastCalibratedAtMs,
        isCalibrated = isCalibrated,
        penMaxCalibratedMm = penMaxCalibratedMm,
        palmHardCalibratedMm = palmHardCalibratedMm,
        eccentricityBase = eccentricityLimit,
        calibratedPenMeanMm = calibratedPenMeanMm
    )

    fun restore(snapshot: CalibrationSnapshot) {
        penMaxCalibratedMm = snapshot.penMaxCalibratedMm.coerceIn(MIN_PEN_MAX_MM, MAX_PEN_MAX_MM)
        palmHardCalibratedMm = snapshot.palmHardCalibratedMm.coerceIn(MIN_PALM_HARD_MM, MAX_PALM_HARD_MM)
        eccentricityLimit = snapshot.eccentricityBase.coerceIn(MIN_ECCENTRICITY, MAX_ECCENTRICITY)
        emaPenDiameterMm = snapshot.emaPenDiameterMm.coerceAtLeast(0.1f)
        calibratedPenMeanMm = snapshot.calibratedPenMeanMm.coerceAtLeast(0.1f)
        sensitivityLevel = snapshot.sensitivityLevel
        handednessMode = snapshot.handednessMode
        penSampleCount = snapshot.penSampleCount
        palmSampleCount = snapshot.palmSampleCount
        lastCalibratedAtMs = snapshot.lastCalibratedAtMs
        isCalibrated = snapshot.isCalibrated
        isDirty = false
    }

    fun describe(): String = buildString {
        append("笔尖≤%.2fmm / 掌根>%.2fmm (%.1fdp) / 偏心率≤%.2f / 灵敏度 L%d / %s".format(
            penMaxMm, palmHardMinMm, palmHardDp, maxEccentricity, sensitivityLevel, handednessMode.label
        ))
        if (!isCalibrated) append(" · 出厂预设（建议实测校准）")
    }

    companion object {
        const val MIN_SENSITIVITY = 1
        const val MAX_SENSITIVITY = 5
        const val DEFAULT_SENSITIVITY = 3

        const val LEGACY_PALM_HARD_DP = 14.5f

        const val MIN_PEN_MAX_MM = 1.0f
        const val MAX_PEN_MAX_MM = 8.0f
        const val MIN_PALM_HARD_MM = 5.0f
        const val MAX_PALM_HARD_MM = 45.0f
        const val MIN_PEN_PALM_GAP_MM = 1.2f
        const val MIN_ECCENTRICITY = 1.25f
        const val MAX_ECCENTRICITY = 2.4f
        const val DEFAULT_PALM_SIZE_THRESHOLD = 0.28f

        const val PEN_ECCENTRICITY_MAX = 1.35f
        const val SIDE_PALM_ECCENTRICITY = 1.65f

        const val TRAILING_EDGE_MARGIN_DP = 25f
        const val TRAILING_EDGE_PROXIMITY_DP = 260f

        const val OBSERVE_WINDOW_MS = 35L
        const val CANDIDATE_PROMOTE_PATH_DP = 3f
        const val OBSERVE_EXPANSION_DP_PER_MS = 0.8f
        const val PEN_EXPANSION_MAX_DP_PER_MS = 0.15f

        const val PREEMPT_WINDOW_MS = 160L
        const val PREEMPT_MAX_PATH_DP = 24f
        const val GEOMETRIC_PREEMPT_MARGIN_DP = 45f

        const val WRITING_LOCK_MS = 160L
        const val WRITING_LOCK_PATH_DP = 24f
        const val EXPANSION_CANCEL_WINDOW_MS = 80L
        const val EXPANSION_CANCEL_DP_PER_MS = 0.85f
        const val PEN_MAX_GROWTH_FACTOR = 1.18f

        const val GESTURE_DOWN_WINDOW_MS = 35L
        const val GESTURE_MIN_SPAN_DP = 55f
        const val THREE_FINGER_TAP_MAX_MS = 320L
        const val THREE_FINGER_TAP_MAX_PATH_DP = 12f

        const val CANCEL_PROTECT_MIN_ALIVE_MS = 180L
        const val CANCEL_PROTECT_MIN_PATH_DP = 35f
        const val CANCEL_TAIL_TRUNCATE_MS = 30L
        const val SYSTEM_GESTURE_MIN_POINTERS = 3
        const val SYSTEM_GESTURE_MAX_ALIVE_MS = 150L

        const val ONLINE_CALIBRATION_MIN_PATH_DP = 50f
        const val ONLINE_EMA_ALPHA = 0.95f
        const val ONLINE_DRIFT_BAND = 0.15f
        const val ONLINE_MEAN_TO_PEN_MAX_SLOPE = 1.35f
        const val ONLINE_MEAN_TO_PEN_MAX_OFFSET = 0.6f
        const val DEFAULT_EMA_PEN_DIAMETER_MM = 2.4f

        /** Winsorized EMA 离群值截尾参数 */
        const val MIN_WINSORIZED_PEN_MM = 0.6f
        const val WINSORIZE_CALIBRATED_CEILING_FACTOR = 1.25f
        const val WINSORIZE_STEP_MIN_RATIO = 0.65f
        const val WINSORIZE_STEP_MAX_RATIO = 1.35f

        const val PEN_SIGMA_FACTOR = 3.2f
        const val PEN_SIGMA_HEADROOM_MM = 0.8f
        const val PEN_MEAN_WEIGHT = 0.62f
        const val PALM_MIN_WEIGHT = 0.38f
        const val PEN_TO_PALM_SAFE_RATIO = 0.72f
        const val PALM_MIN_SAFETY_RATIO = 0.9f

        const val MIN_CALIBRATION_PEN_SAMPLES = 3
        const val MIN_CALIBRATION_PALM_SAMPLES = 2

        private val PenSensitivityScale = floatArrayOf(
            0f,
            1.15f,
            1.07f,
            1.00f,
            0.94f,
            0.88f
        )

        private val PalmSensitivityScale = floatArrayOf(
            0f,
            1.25f,
            1.10f,
            1.00f,
            0.90f,
            0.82f
        )

        private val EccentricitySensitivityScale = floatArrayOf(
            1f,
            1.10f,
            1.04f,
            1.00f,
            0.95f,
            0.90f
        )

        private val DEVICE_PRESETS = listOf(
            DevicePreset(
                id = "xiaomi_pad_6_pro",
                label = "小米平板 6 Pro",
                modelPatterns = listOf("23043rp34c", "pad 6 pro", "24018rpacc"),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.5f,
                maxEccentricity = 1.75f,
                note = "309 PPI 11 英寸 LCD；文档基准机型，触控上报面积较完整，适合开启空间几何抢占"
            ),
            DevicePreset(
                id = "xiaomi_pad_6",
                label = "小米平板 6 / 6S Pro",
                modelPatterns = listOf("23043rp34g", "24018rpacg", "pad 6", "pad 6s pro"),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.5f,
                maxEccentricity = 1.75f,
                note = "与 6 Pro 同族触控 IC，参数沿用文档基准"
            ),
            DevicePreset(
                id = "xiaomi_pad_5",
                label = "小米平板 5 系列",
                modelPatterns = listOf("21051182c", "pad 5", "22081283c"),
                penMaxMm = 4.0f,
                palmHardMinMm = 11.0f,
                maxEccentricity = 1.78f,
                note = "120Hz LCD，触控采样较密，膨胀率阈值可略放宽"
            ),
            DevicePreset(
                id = "huawei_matepad_11",
                label = "华为 MatePad 11 / 11.5",
                modelPatterns = listOf("dbr-w09", "dby-w09", "matepad 11", "matepad 11.5"),
                penMaxMm = 4.4f,
                palmHardMinMm = 12.0f,
                maxEccentricity = 1.72f,
                note = "触控上报偏保守，面积整体略小，笔尖上限适度放宽"
            ),
            DevicePreset(
                id = "honor_pad",
                label = "荣耀平板 V8 / GT 系列",
                modelPatterns = listOf("brt-w09", "gdi-w09", "honor pad"),
                penMaxMm = 4.3f,
                palmHardMinMm = 11.8f,
                maxEccentricity = 1.74f,
                note = "与华为系触控方案接近"
            ),
            DevicePreset(
                id = "vivo_pad",
                label = "vivo Pad 2 / 3 / Pad Air",
                modelPatterns = listOf("pa2373", "pa2170", "vivo pad", "pad air"),
                penMaxMm = 4.1f,
                palmHardMinMm = 11.2f,
                maxEccentricity = 1.76f,
                note = "144Hz 高刷，速度快、采样密"
            ),
            DevicePreset(
                id = "lenovo_legion_y700",
                label = "联想拯救者 Y700 / 小新 Pad",
                modelPatterns = listOf("tb320fc", "tb321fu", "legion y700", "lenovo tab"),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.6f,
                maxEccentricity = 1.75f,
                note = "8.8 英寸高 PPI，px 与 mm 比例差异较大，务必依赖 mm 归一化"
            ),
            DevicePreset(
                id = "samsung_galaxy_tab",
                label = "三星 Galaxy Tab S / A 系列",
                modelPatterns = listOf("sm-x710", "sm-x910", "sm-p610", "galaxy tab"),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.5f,
                maxEccentricity = 1.75f,
                note = "若机身附带 S Pen，请勿使用；本预设针对普通通用电容笔"
            ),
            DevicePreset(
                id = "oppo_oneplus_pad",
                label = "OPPO Pad / 一加平板",
                modelPatterns = listOf("oppo pad", "opd2101", "opd2202", "oneplus pad"),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.5f,
                maxEccentricity = 1.75f,
                note = "通用起步参数"
            ),
            DevicePreset(
                id = "generic",
                label = "通用 Android 平板",
                modelPatterns = emptyList(),
                penMaxMm = 4.2f,
                palmHardMinMm = 11.5f,
                maxEccentricity = 1.75f,
                note = "保守起步参数；触控 IC 差异极大，强烈建议先做一次双框实测校准"
            )
        )

        fun lookupPreset(deviceModel: String): DevicePreset {
            val normalized = deviceModel.lowercase().trim()
            if (normalized.isEmpty()) return DEVICE_PRESETS.last()
            for (preset in DEVICE_PRESETS) {
                for (pattern in preset.modelPatterns) {
                    if (normalized.contains(pattern)) return preset
                }
            }
            return DEVICE_PRESETS.last()
        }

        fun allPresets(): List<DevicePreset> = DEVICE_PRESETS

        private fun standardDeviation(values: List<Float>, mean: Float): Float {
            if (values.size < 2) return 0f
            var acc = 0f
            for (v in values) {
                val d = v - mean
                acc += d * d
            }
            return sqrt(acc / values.size)
        }
    }
}
