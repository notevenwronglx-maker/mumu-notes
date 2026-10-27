package com.mumunotes.core.touch.model

/**
 * 一次手掌/手指触点的拒绝记录，供「手掌误触热力诊断图层」与诊断回放消费。
 */
data class PalmContactRecord(
    val x: Float,
    val y: Float,
    val timeMs: Long,
    val diameterMm: Float,
    val eccentricity: Float,
    val reason: PalmRejectReason,
    val source: PalmAnchorSource
)

/**
 * 顶部浮动栏「通用电容笔防误触遥测胶囊」的数据源快照。
 *
 * 实时展示当前触点的物理直径与阈值、当前状态机状态、已拦截侧掌次数，
 * 以及完整的 7 维特征向量，便于用户与开发者直接观察算法判定依据。
 */
data class TouchTelemetry(
    val state: EngineState,
    val lastDecision: String,

    // ---- 维度 1：直径 / 面积 ----
    val candidateDiameterMm: Float,
    val penMaxThresholdMm: Float,
    val palmHardThresholdMm: Float,
    val equivalentAreaMm2: Float,

    /**
     * 当前焦点触点的内容坐标。
     * App 层据此动态移动系统边缘手势豁免窗（跟随笔尖 Y 轴），
     * 也可用于诊断回放时高亮当前触点。
     */
    val touchX: Float,
    val touchY: Float,

    // ---- 维度 2：偏心 ----
    val eccentricity: Float,
    val maxEccentricity: Float,

    // ---- 维度 3：面积膨胀 ----
    val areaExpansionDpPerMs: Float,

    // ---- 维度 4：速度 / 加速度 ----
    val velocityDpPerSec: Float,
    val accelerationDpPerSec2: Float,

    // ---- 维度 5：曲率 / 折返角 ----
    val turnAngleDeg: Float,
    val curvaturePerMm: Float,

    // ---- 维度 6：握笔空间几何 ----
    val spatialScore: Float,
    /** 相对手掌锚点的空间几何余量（dp），正值表示位于真笔尖应有方位 */
    val spatialHeadroomDp: Float,

    // ---- 引擎上下文 ----
    val handednessMode: HandednessMode,
    val sensitivityLevel: Int,
    val activePenPointerId: Int,
    val pointerCount: Int,
    val rejectedPalmCount: Int,
    val rejectedPointerCount: Int,
    val palmAnchorX: Float?,
    val palmAnchorY: Float?,
    val isWritingLocked: Boolean,
    val strokeAliveMs: Long,
    val strokePathDp: Float,

    // ---- 无压感笔锋模拟反馈 ----
    val simulatedPressure: Float,
    val simulatedWidthPx: Float,

    // ---- 驱动能力诊断 ----
    val diameterReportAvailable: Boolean,
    /** 驱动未上报面积时，算法降级为纯运动学模式，UI 应给出提示 */
    val motionOnlyMode: Boolean
) {
    val diameterHeadroomMm: Float get() = penMaxThresholdMm - candidateDiameterMm

    val isDiameterWithinPenThreshold: Boolean get() = candidateDiameterMm <= penMaxThresholdMm

    companion object {
        val EMPTY = TouchTelemetry(
            state = EngineState.IDLE,
            lastDecision = "待机",
            candidateDiameterMm = 0f,
            penMaxThresholdMm = 4.2f,
            palmHardThresholdMm = 11.5f,
            equivalentAreaMm2 = 0f,
            touchX = 0f,
            touchY = 0f,
            eccentricity = 1f,
            maxEccentricity = 1.75f,
            areaExpansionDpPerMs = 0f,
            velocityDpPerSec = 0f,
            accelerationDpPerSec2 = 0f,
            turnAngleDeg = 0f,
            curvaturePerMm = 0f,
            spatialScore = 0f,
            spatialHeadroomDp = 0f,
            handednessMode = HandednessMode.DEFAULT,
            sensitivityLevel = 3,
            activePenPointerId = TouchPacket.INVALID,
            pointerCount = 0,
            rejectedPalmCount = 0,
            rejectedPointerCount = 0,
            palmAnchorX = null,
            palmAnchorY = null,
            isWritingLocked = false,
            strokeAliveMs = 0L,
            strokePathDp = 0f,
            simulatedPressure = 0f,
            simulatedWidthPx = 0f,
            diameterReportAvailable = true,
            motionOnlyMode = false
        )
    }
}
