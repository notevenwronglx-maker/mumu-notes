package com.mumunotes.core.touch.model

import android.view.MotionEvent

/**
 * 单次触点采样点（已从 [android.view.MotionEvent] 解包）。
 *
 * ### 零分配环形缓冲支持（240Hz~360Hz 高刷屏无 GC 抖动）
 * - 支持在 [com.mumunotes.core.touch.SampleRingBuffer] 预分配槽位中通过 [update] 原地覆写属性，
 *   避免高频触控下每秒创建数百个临时对象。
 * - 同时保留双坐标系设计：[x]、[y] 为物理视图坐标（View px），[contentX]、[contentY] 为画布内容坐标。
 */
data class TouchSample(
    var pointerId: Int = -1,
    /** 视图坐标系 X（px，物理屏幕维度） */
    var x: Float = 0f,
    /** 视图坐标系 Y（px，物理屏幕维度） */
    var y: Float = 0f,
    /** 原始接触长轴直径（px），0 表示驱动未上报 */
    var touchMajorPx: Float = 0f,
    /** 原始接触短轴直径（px），0 表示驱动未上报 */
    var touchMinorPx: Float = 0f,
    /** 事件时间戳（ms，取自 eventTime / historicalEventTime，保证与系统同源） */
    var timeMs: Long = 0L,
    /** 是否来自 historySize 历史批处理（用于还原 240Hz~360Hz 原始触控流） */
    var isHistorical: Boolean = false,
    /** 官方归一化面积比（0~1），touchMajor 缺失时的回退来源 */
    var normalizedSize: Float = 0f,
    /** 画布内容坐标系 X（已叠加缩放/平移逆变换，默认等于 [x]） */
    var contentX: Float = x,
    /** 画布内容坐标系 Y（已叠加缩放/平移逆变换，默认等于 [y]） */
    var contentY: Float = y,
    /** 压力值（仅作诊断记录，不作为通用电容笔压感依据） */
    var pressure: Float = 0f,
    /** 触点方向角（弧度） */
    var orientation: Float = 0f,
    /** 工具类型（如 MotionEvent.TOOL_TYPE_FINGER / TOOL_TYPE_STYLUS） */
    var toolType: Int = MotionEvent.TOOL_TYPE_FINGER
) {
    /** 兼容命名属性：与 SampleRingBuffer 预分配构造参数对齐 */
    var timestampMillis: Long
        get() = timeMs
        set(value) {
            timeMs = value
        }

    var touchMajor: Float
        get() = touchMajorPx
        set(value) {
            touchMajorPx = value
        }

    var touchMinor: Float
        get() = touchMinorPx
        set(value) {
            touchMinorPx = value
        }

    var size: Float
        get() = normalizedSize
        set(value) {
            normalizedSize = value
        }

    constructor(
        pointerId: Int,
        timestampMillis: Long,
        x: Float,
        y: Float,
        pressure: Float,
        touchMajor: Float,
        touchMinor: Float,
        size: Float,
        orientation: Float,
        toolType: Int
    ) : this(
        pointerId = pointerId,
        x = x,
        y = y,
        touchMajorPx = touchMajor,
        touchMinorPx = touchMinor,
        timeMs = timestampMillis,
        isHistorical = false,
        normalizedSize = size,
        contentX = x,
        contentY = y,
        pressure = pressure,
        orientation = orientation,
        toolType = toolType
    )

    /**
     * 原地覆写当前槽位数据（In-place Mutation），供 [com.mumunotes.core.touch.SampleRingBuffer] 零分配复用。
     */
    fun update(
        pointerId: Int,
        timestampMillis: Long,
        x: Float,
        y: Float,
        pressure: Float = 0f,
        touchMajor: Float,
        touchMinor: Float,
        size: Float,
        orientation: Float = 0f,
        toolType: Int = MotionEvent.TOOL_TYPE_FINGER,
        isHistorical: Boolean = false,
        contentX: Float = x,
        contentY: Float = y
    ) {
        this.pointerId = pointerId
        this.timeMs = timestampMillis
        this.x = x
        this.y = y
        this.pressure = pressure
        this.touchMajorPx = touchMajor
        this.touchMinorPx = touchMinor
        this.normalizedSize = size
        this.orientation = orientation
        this.toolType = toolType
        this.isHistorical = isHistorical
        this.contentX = contentX
        this.contentY = contentY
    }

    /** 生成不可变快照副本（当需要脱离环形缓冲区长期持有时调用） */
    fun copySnapshot(): TouchSample = copy()
}

/**
 * 一帧 [android.view.MotionEvent] 解包后的完整触控包。
 *
 * [points] 中每个 pointerId 对应一个**有序**采样列表（历史点在前、当前点在最后），
 * 这样上层就能以「原始触控流」而非「每帧一个点」的粒度做运动学建模。
 */
data class TouchPacket(
    /** MotionEvent.actionMasked */
    val action: Int,
    /** MotionEvent.actionIndex */
    val actionIndex: Int,
    /** 事件时间戳（ms） */
    val eventTimeMs: Long,
    /** 本帧全部 active 的 pointerId，顺序与 MotionEvent 指针索引一致 */
    val pointerIds: List<Int>,
    /** pointerId → 有序采样列表（历史 + 当前） */
    val points: Map<Int, List<TouchSample>>,
    /** 设备上报的接触面积数据是否可信（若驱动恒为 0 则退化为纯运动学判定） */
    val diameterReportAvailable: Boolean
) {
    val pointerCount: Int get() = pointerIds.size

    /** 触发本帧 action 的 pointerId（ACTION_MOVE 时为第一个指针） */
    val actionPointerId: Int
        get() = pointerIds.getOrNull(actionIndex) ?: pointerIds.firstOrNull() ?: INVALID

    fun pointsOf(pointerId: Int): List<TouchSample> = points[pointerId].orEmpty()

    /** 本帧首个采样点（任意指针），用于区域预检 */
    val firstSample: TouchSample?
        get() = actionPointerId.let { points[it]?.lastOrNull() } ?: points.values.firstOrNull()?.lastOrNull()

    companion object {
        const val INVALID = -1
    }
}
