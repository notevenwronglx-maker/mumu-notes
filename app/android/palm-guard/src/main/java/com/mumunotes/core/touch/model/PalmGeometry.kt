package com.mumunotes.core.touch.model

import kotlin.math.max
import kotlin.math.min

/**
 * 与 Android 框架解耦的矩形，便于算法层在 JVM 单元测试中直接构造并复用。
 *
 * 用于两类区域预检：
 * 1. UI 工具栏 / 底部笔盒等控件热区 → 归类 `FINGER_UI_TAP`；
 * 2. 用户开启的「虚拟防误触手垫」区域 → 归类 `PALM_SHIELD_ABSORBED`。
 */
data class PalmRect(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top
    val area: Float get() = width * height

    fun contains(x: Float, y: Float): Boolean =
        x >= left && x <= right && y >= top && y <= bottom

    /** 两矩形是否相交（用于手垫与 UI 区域互斥判断） */
    fun intersects(other: PalmRect): Boolean =
        left < other.right && other.left < right && top < other.bottom && other.top < bottom

    companion object {
        val EMPTY = PalmRect(0f, 0f, 0f, 0f)

        fun of(x0: Float, y0: Float, x1: Float, y1: Float): PalmRect =
            PalmRect(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))

        /** 以中心点与半径构造（用于触点包络盒） */
        fun around(cx: Float, cy: Float, radius: Float): PalmRect =
            PalmRect(cx - radius, cy - radius, cx + radius, cy + radius)

        /** 由点集构造最小外接矩形 */
        fun enclosing(xs: FloatArray, ys: FloatArray): PalmRect {
            if (xs.isEmpty()) return EMPTY
            var l = xs[0]; var t = ys[0]; var r = xs[0]; var b = ys[0]
            for (i in 1 until xs.size) {
                l = min(l, xs[i]); t = min(t, ys[i])
                r = max(r, xs[i]); b = max(b, ys[i])
            }
            return PalmRect(l, t, r, b)
        }
    }
}

/** 手掌锚点的来源，用于遥测诊断与热力图着色 */
enum class PalmAnchorSource(val label: String) {
    HARD_THRESHOLD("面积/偏心硬阈值"),
    ECCENTRICITY("狭长侧掌偏心率"),
    TRAILING_EDGE("手掌锚点右下余波"),
    VIRTUAL_SHIELD("虚拟防误触手垫"),
    GHOST_ROLLBACK("幽灵笔迹回滚"),
    EXPANSION_CANCEL("面积膨胀压实"),
    MID_STROKE("书写中并发触点")
}

/**
 * 手掌基准锚点。
 *
 * 一旦某个触点被判定为掌根 / 侧掌 / 手垫吸收，就把它的位置登记为锚点，
 * 后续新落下的触点可据此做「右下方余波」空间几何判定（文档 1.2 节阶段 2）。
 *
 * 关键行为（文档 2.1 场景 4）：手掌全程紧贴屏幕不抬起时，锚点在整个手掌按住期间持续有效，
 * 即使笔尖反复抬起又落下（连续写多个字）也不会失效。
 */
data class PalmAnchor(
    val pointerId: Int,
    val x: Float,
    val y: Float,
    val diameterMm: Float,
    val spatialScore: Float,
    val timeMs: Long,
    val source: PalmAnchorSource
) {
    val isFromRealPointer: Boolean get() = pointerId >= 0
}
