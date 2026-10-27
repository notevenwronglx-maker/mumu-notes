package com.mumunotes.core.touch.model

import android.view.MotionEvent

/**
 * 握笔姿态空间几何模式（文档 1.1 节第 6 维特征 S_pos）。
 *
 * 空间得分 [spatialScore] 的语义统一为：**分值越小，越靠近真笔尖应有的方位**。
 * 因此抢占判定恒为 `score(新触点) < score(旧触点) - 45dp`。
 */
enum class HandednessMode(val label: String, val hint: String) {
    /** 右手斜握：笔尖恒位于手掌支撑区左上方 → S = y + 0.42x */
    RIGHT_DIAGONAL("右手斜握", "笔尖位于掌根左上方"),

    /** 右手横握（横屏正握）：S = x + 0.15y */
    RIGHT_HORIZONTAL("右手横握", "笔尖位于掌根正左侧"),

    /** 左手斜握：笔尖恒位于手掌支撑区右上方 → S = y - 0.42x */
    LEFT_DIAGONAL("左手斜握", "笔尖位于掌根右上方"),

    /** 纯面积判定：完全关闭空间几何优先级（仅依赖面积/运动学） */
    AREA_ONLY("纯面积判定", "关闭空间几何，仅用面积与运动学");

    /** 是否启用空间几何优先级（AREA_ONLY 下所有抢占与余波判定必须短路，否则会拒绝一切触点） */
    val spatialEnabled: Boolean get() = this != AREA_ONLY

    fun spatialScore(x: Float, y: Float): Float = when (this) {
        RIGHT_DIAGONAL -> y + RIGHT_DIAGONAL_SLOPE * x
        RIGHT_HORIZONTAL -> x + RIGHT_HORIZONTAL_SLOPE * y
        LEFT_DIAGONAL -> y - LEFT_DIAGONAL_SLOPE * x
        AREA_ONLY -> 0f
    }

    companion object {
        const val RIGHT_DIAGONAL_SLOPE = 0.42f
        const val RIGHT_HORIZONTAL_SLOPE = 0.15f
        const val LEFT_DIAGONAL_SLOPE = 0.42f

        val DEFAULT = RIGHT_DIAGONAL

        fun fromNameOrDefault(name: String?): HandednessMode =
            entries.firstOrNull { it.name == name } ?: DEFAULT
    }
}

/**
 * 防误触引擎状态机的 5 个稳定状态（文档 1.2 节阶段 1~5）。
 */
enum class EngineState(val label: String) {
    /** 空闲：屏幕无任何有效触点 */
    IDLE("空闲"),

    /** 候选观察窗：触点形态像笔尖，但尚未通过 35ms 观察窗确认（前端可绘制虚影） */
    CANDIDATE_BUFFER("候选观察中"),

    /** 笔尖独占书写态：已确认书写，进入强锁定，绝不因并发触点中断 */
    WRITING_LOCKED("书写锁定中"),

    /** 多指手势锁：双指缩放 / 平移 / 三指轻点撤销 */
    GESTURE_LOCKED("多指手势中"),

    /** 单指漫游：手指（非笔尖尺寸）用于平移画布 */
    FINGER_PANNING("单指漫游中")
}

/**
 * 7 维触点特征向量 F_i = ⟨D_eq, E_axis, Ȧ, v, a, κ, S_pos⟩（文档 1.1 节）。
 */
data class TouchFeatures(
    val pointerId: Int,
    /** 视图坐标 X（px，物理屏幕坐标系） */
    val x: Float,
    /** 视图坐标 Y（px，物理屏幕坐标系） */
    val y: Float,
    val timeMs: Long,
    val isHistorical: Boolean,

    // ---- 维度 1：等效接触直径与面积（物理毫米归一化） ----
    val diameterMm: Float,
    val minorDiameterMm: Float,
    val areaMm2: Float,
    /** 便于与文档中以 dp 表述的动力学阈值直接比较 */
    val diameterDp: Float,

    // ---- 维度 2：接触椭圆长短轴偏心率 ----
    val eccentricity: Float,

    // ---- 维度 3：面积膨胀速率（dp/ms） ----
    val areaExpansionDpPerMs: Float,

    // ---- 维度 4：瞬时速度与加速度 ----
    val velocityDpPerSec: Float,
    val accelerationDpPerSec2: Float,

    // ---- 维度 5：三点离散轨迹曲率与折返角 ----
    /** 折返角：0° = 沿原方向直行，180° = 原地锐角折返（手掌电容质心跳变的典型特征） */
    val turnAngleDeg: Float,
    /** 曲率（rad/mm），用于无压感笔锋线宽映射 */
    val curvaturePerMm: Float,

    // ---- 维度 6：握笔姿态空间几何得分 ----
    val spatialScore: Float,

    // ---- 原始量（供遥测与回退分析） ----
    val rawTouchMajorPx: Float,
    val rawTouchMinorPx: Float,
    val diameterFromFallback: Boolean = false,

    // ---- 画布内容坐标（供宿主画布在缩放/平移状态下直接落墨） ----
    val contentX: Float = x,
    val contentY: Float = y,

    // ---- 扩展形态学与工具类型属性 ----
    val normalizedSize: Float = 0f,
    val toolType: Int = MotionEvent.TOOL_TYPE_FINGER
) {
    /** 兼容多模态仲裁器字段命名 */
    val latestX: Float get() = x
    val latestY: Float get() = y
    val maxTouchMajorPx: Float get() = rawTouchMajorPx
    val minTouchMinorPx: Float get() = rawTouchMinorPx

    /** 长轴直径膨胀速率（mm/s） */
    val majorGrowthRateMmPerSec: Float
        get() = areaExpansionDpPerMs * 158.75f

    /** 质心移动速度（mm/s） */
    val velocityMmPerSec: Float
        get() = velocityDpPerSec * 0.15875f

    /** 是否处于「疑似笔尖」的物理尺寸区间 */
    fun withinPenDiameter(penMaxMm: Float): Boolean = diameterMm <= penMaxMm

    /** 是否处于「人类手指」的物理尺寸区间 */
    fun withinFingerDiameter(penMaxMm: Float, palmHardMm: Float): Boolean =
        diameterMm > penMaxMm && diameterMm < palmHardMm

    /** 是否超过硬手掌下限 */
    fun exceedsPalmDiameter(palmHardMm: Float): Boolean = diameterMm > palmHardMm

    val isValid: Boolean get() = timeMs > 0L

    companion object {
        /** 无有效触点时的占位特征（遥测在空闲态展示 0 值而非残留数据） */
        val EMPTY = TouchFeatures(
            pointerId = TouchPacket.INVALID,
            x = 0f,
            y = 0f,
            timeMs = 0L,
            isHistorical = false,
            diameterMm = 0f,
            minorDiameterMm = 0f,
            areaMm2 = 0f,
            diameterDp = 0f,
            eccentricity = 1f,
            areaExpansionDpPerMs = 0f,
            velocityDpPerSec = 0f,
            accelerationDpPerSec2 = 0f,
            turnAngleDeg = 0f,
            curvaturePerMm = 0f,
            spatialScore = 0f,
            rawTouchMajorPx = 0f,
            rawTouchMinorPx = 0f,
            diameterFromFallback = false,
            contentX = 0f,
            contentY = 0f,
            normalizedSize = 0f,
            toolType = MotionEvent.TOOL_TYPE_FINGER
        )
    }
}
