package com.mumunotes.core.touch.model

import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max

/**
 * 单个 pointerId 的书写轨迹聚合器。
 *
 * 新增特性：
 * - [lastTimestampMillis]：每次追加采样时更新时间戳，支持超时清理异常残留的陈旧轨迹（Stale Track > 450~500ms）
 * - [wasDispatched]：记录该轨迹是否已向 Flutter 引擎放行派发，若中途识别为手掌则下发定向回滚与合成取消
 * - [toolType]：记录触控工具类型（主动笔 / 橡皮 / 普通电容笔与手指）
 */
class TouchTrack(
    val pointerId: Int,
    val startFeatures: TouchFeatures,
    val startTimeMs: Long,
    private val density: Float
) {
    val startX: Float = startFeatures.x
    val startY: Float = startFeatures.y
    val startSpatialScore: Float = startFeatures.spatialScore

    /** 触控工具类型（如 TOOL_TYPE_STYLUS / TOOL_TYPE_FINGER） */
    var toolType: Int = startFeatures.toolType

    /** 该触控轨迹是否已经放行派发给下游 Flutter 引擎 */
    var wasDispatched: Boolean = false

    /** 最近一次收到采样更新的时间戳（ms），用于 450ms~500ms 陈旧轨迹自动清理 */
    var lastTimestampMillis: Long = startTimeMs
        private set

    var lastFeatures: TouchFeatures = startFeatures
        private set

    var previousFeatures: TouchFeatures? = null
        private set

    /** 累计路径长度（px） */
    var totalPathPx: Float = 0f
        private set

    /** 累计路径长度（dp） */
    val totalPathDp: Float get() = if (density > 0f) totalPathPx / density else totalPathPx

    /** 距离起笔点的当前直线净位移（dp） */
    val netDisplacementDp: Float
        get() {
            val distPx = hypot(lastFeatures.x - startX, lastFeatures.y - startY)
            return if (density > 0f) distPx / density else distPx
        }

    /** 轨迹过程中偏离起笔点的最大净位移半径（px） */
    var maxDisplacementPx: Float = 0f
        private set

    /** 轨迹过程中偏离起笔点的最大净位移半径（dp）——防止原地高频抖动累加假路径晋升 */
    val maxDisplacementDp: Float
        get() = if (density > 0f) maxDisplacementPx / density else maxDisplacementPx

    var sampleCount: Int = 1
        private set

    var maxDiameterMm: Float = startFeatures.diameterMm
        private set

    var maxTouchMajorPx: Float = startFeatures.rawTouchMajorPx
        private set

    var minTouchMinorPx: Float = startFeatures.rawTouchMinorPx
        private set

    var expansionPeakDpPerMs: Float = 0f
        private set

    var maxTurnAngleDeg: Float = 0f
        private set

    /** 微小步长（< 4.0dp）下发生锐角折返（turnAngleDeg > 135°）的累计次数 */
    var sharpReversalCount: Int = 0
        private set

    /** 是否已从 CANDIDATE_BUFFER 晋升为 WRITING_LOCKED */
    var promotedToWritingLocked: Boolean = false

    /** 最后一帧的瞬时速度（dp/s），抬笔时用于出锋判定 */
    var lastVelocityDpPerSec: Float = startFeatures.velocityDpPerSec
        private set

    /** 直径的指数滑动平均，用于 L3 在线漂移补偿采样 */
    var emaDiameterMm: Float = startFeatures.diameterMm
        private set

    /** 累计直径均值（仅统计合法采样），用于笔迹结束时的 L3 更新 */
    private var diameterSumMm: Float = startFeatures.diameterMm
    private var diameterWeight: Int = 1

    /** 最近一次采样半径（px），供脏矩形计算 */
    var lastRadiusPx: Float = 0f
        private set

    fun append(features: TouchFeatures) {
        previousFeatures = lastFeatures
        val stepPx = hypot(features.x - lastFeatures.x, features.y - lastFeatures.y)
        val stepDp = if (density > 0f) stepPx / density else stepPx
        totalPathPx += stepPx

        val dispFromStartPx = hypot(features.x - startX, features.y - startY)
        maxDisplacementPx = max(maxDisplacementPx, dispFromStartPx)

        if (features.turnAngleDeg >= JITTER_REVERSAL_MIN_ANGLE_DEG && stepDp <= JITTER_STEP_MAX_DP) {
            sharpReversalCount++
        }

        lastFeatures = features
        lastTimestampMillis = max(lastTimestampMillis, features.timeMs)
        toolType = features.toolType
        sampleCount++
        maxDiameterMm = max(maxDiameterMm, features.diameterMm)
        maxTouchMajorPx = max(maxTouchMajorPx, features.rawTouchMajorPx)
        if (features.rawTouchMinorPx > 0f) {
            minTouchMinorPx = if (minTouchMinorPx <= 0f) {
                features.rawTouchMinorPx
            } else {
                kotlin.math.min(minTouchMinorPx, features.rawTouchMinorPx)
            }
        }
        expansionPeakDpPerMs = max(expansionPeakDpPerMs, features.areaExpansionDpPerMs)
        maxTurnAngleDeg = max(maxTurnAngleDeg, features.turnAngleDeg)
        lastVelocityDpPerSec = features.velocityDpPerSec
        emaDiameterMm = EMA_ALPHA * emaDiameterMm + (1f - EMA_ALPHA) * features.diameterMm
        diameterSumMm += features.diameterMm
        diameterWeight++
        lastRadiusPx = features.diameterDp * 0.5f * density
    }

    fun aliveMs(nowMs: Long): Long = max(0L, nowMs - startTimeMs)

    /** 判断该轨迹是否已超过 [timeoutMs]（默认 450ms~500ms）未收到更新，属于陈旧残留轨迹 */
    fun isStale(nowMs: Long, timeoutMs: Long = DEFAULT_STALE_TIMEOUT_MS): Boolean =
        nowMs > lastTimestampMillis && (nowMs - lastTimestampMillis) > timeoutMs

    /** 首次事件时间与最后一次采样时间之间的实际采样跨度 */
    fun sampleSpanMs(): Long = max(0L, lastFeatures.timeMs - startTimeMs)

    /**
     * 是否表现为手掌电容网格质心原地高频跳变（文档 1.1 节第 5 维特征）。
     * 条件：微步长下连续多次 >135° 锐角折返，且最大净移出半径极小。
     */
    fun isHighFrequencyCentroidJitter(maxNetRadiusDp: Float = JITTER_MAX_RADIUS_DP): Boolean =
        sharpReversalCount >= JITTER_MIN_REVERSAL_COUNT && maxDisplacementDp <= maxNetRadiusDp

    /**
     * 是否仍处于可被真笔尖抢占的窗口内（文档 1.3 规则 C）。
     * 条件：存活时长 ≤ preemptWindowMs 且最大有效偏离位移 < maxPathDp。
     */
    fun isPreemptable(nowMs: Long, preemptWindowMs: Long, maxPathDp: Float): Boolean =
        aliveMs(nowMs) <= preemptWindowMs && maxDisplacementDp < maxPathDp

    /**
     * 是否已进入强书写锁定（文档 1.3 规则 B / 阶段 5）。
     * 条件：存活时长 ≥ lockMs **或** 最大有效偏离位移 ≥ lockPathDp。
     */
    fun hasExceededLockThreshold(
        nowMs: Long,
        lockMs: Long,
        lockPathDp: Float
    ): Boolean = aliveMs(nowMs) >= lockMs || maxDisplacementDp >= lockPathDp

    /** 笔迹平均直径（mm），用于 L3 在线 EMA 基准更新 */
    fun averageDiameterMm(): Float =
        if (diameterWeight <= 0) startFeatures.diameterMm else diameterSumMm / diameterWeight

    /** 笔迹是否达到 L3 校准所需的最小长度（文档 1.4 节：已确认长度 > 50dp 且非原地抖动） */
    fun qualifiesForOnlineCalibration(minPathDp: Float): Boolean =
        totalPathDp > minPathDp && maxDisplacementDp >= minPathDp * 0.35f

    /** 笔迹是否达到取消保护所需的最小规模（存活 > 180ms 且累计长度 > 35dp） */
    fun qualifiesForCancelProtection(minAliveMs: Long, minPathDp: Float): Boolean =
        aliveMs(lastFeatures.timeMs) > minAliveMs && totalPathDp > minPathDp

    /** 轨迹是否近乎静止（支撑手掌的典型特征：低频蠕动） */
    fun isNearlyStatic(staticVelocityDpPerSec: Float): Boolean =
        abs(lastVelocityDpPerSec) < staticVelocityDpPerSec

    internal companion object {
        const val EMA_ALPHA = 0.95f
        const val JITTER_REVERSAL_MIN_ANGLE_DEG = 135f
        const val JITTER_STEP_MAX_DP = 4.0f
        const val JITTER_MAX_RADIUS_DP = 4.5f
        const val JITTER_MIN_REVERSAL_COUNT = 3
        const val DEFAULT_STALE_TIMEOUT_MS = 450L
    }
}
