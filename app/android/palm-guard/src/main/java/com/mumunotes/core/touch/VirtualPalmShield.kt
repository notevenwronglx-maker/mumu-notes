package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.PalmRect
import kotlin.math.hypot

/** 虚拟防误触手垫的三种贴屏形态（文档 5.1 节第 11 项） */
enum class ShieldMode(val label: String) {
    /** 全宽横条：横屏整篇书写时最常用 */
    FULL_WIDTH("全宽手垫"),

    /** 右下角块状：右手竖屏手写 */
    CORNER_RIGHT("右下手垫"),

    /** 左下角块状：左手竖屏手写 */
    CORNER_LEFT("左下手垫")
}

/**
 * 虚拟防误触手垫与动态手掌包络护盾（VirtualPalmShield）。
 *
 * 兼具两项核心能力：
 * 1. **底部/角落可调虚拟防误触手垫**：通过 [resolve] 解析当前视图宽高下的静态保护矩形，并支持在横竖屏/分屏切换时
 *    通过 [updateViewportBounds] 实时重算边界与钳制拖拽偏移；
 * 2. **主动笔锚点与动态手掌包络足迹（Dynamic Palm Footprint）**：通过 [AnchorStylus]、[registerPalmFootprint]
 *    与 [isInsidePalmZone] 维护最近手掌压屏包络圆，拦截同一手掌区域内的后续边缘误触。
 */
class VirtualPalmShield(
    var enabled: Boolean = false,
    var mode: ShieldMode = ShieldMode.CORNER_RIGHT,
    /** 角块模式下占据的画布宽度比例 */
    widthRatio: Float = 0.42f,
    /** 手垫高度（dp），可手动调节 */
    heightDp: Float = 96f,
    /** 距离屏幕底部的内缩（dp） */
    var bottomInsetDp: Float = 0f
) {

    private data class PalmFootprint(
        val x: Float,
        val y: Float,
        val radiusPx: Float,
        val timestampMs: Long
    )

    /** 角块模式下占据的画布宽度比例（自动夹持到 [MIN_WIDTH_RATIO, MAX_WIDTH_RATIO]） */
    var widthRatio: Float = widthRatio.coerceIn(MIN_WIDTH_RATIO, MAX_WIDTH_RATIO)
        set(value) {
            field = value.coerceIn(MIN_WIDTH_RATIO, MAX_WIDTH_RATIO)
        }

    /** 手垫高度（dp，自动夹持到 [MIN_HEIGHT_DP, MAX_HEIGHT_DP]） */
    var heightDp: Float = heightDp.coerceIn(MIN_HEIGHT_DP, MAX_HEIGHT_DP)
        set(value) {
            field = value.coerceIn(MIN_HEIGHT_DP, MAX_HEIGHT_DP)
        }

    /** 用户拖拽产生的额外偏移（px） */
    var dragOffsetX: Float = 0f

    var dragOffsetY: Float = 0f

    /** 最近一次更新的视口宽高（px）与逻辑密度 */
    var viewportWidthPx: Float = 0f
        private set
    var viewportHeightPx: Float = 0f
        private set
    var viewportDensity: Float = 2.75f
        private set

    /** 主动笔最新锚点坐标与时间戳 */
    var stylusAnchorX: Float = 0f
        private set
    var stylusAnchorY: Float = 0f
        private set
    var stylusAnchorTimeMs: Long = -1L
        private set

    private val footprints = ArrayDeque<PalmFootprint>(16)

    /** 当前是否为有效（启用且高度足够）手垫 */
    val isActive: Boolean get() = enabled && heightDp >= MIN_HEIGHT_DP

    /**
     * 当横竖屏切换、分屏或折叠屏展开导致窗口尺寸变化时，实时更新护盾视口边界并钳制偏移量。
     */
    fun updateViewportBounds(widthPx: Int, heightPx: Int, density: Float) {
        if (widthPx <= 0 || heightPx <= 0) return
        viewportWidthPx = widthPx.toFloat()
        viewportHeightPx = heightPx.toFloat()
        if (density > 0f) viewportDensity = density
        dragOffsetX = dragOffsetX.coerceIn(-viewportWidthPx * 0.5f, viewportWidthPx * 0.5f)
        dragOffsetY = dragOffsetY.coerceIn(-viewportHeightPx * 0.5f, viewportHeightPx * 0.5f)
    }

    /**
     * 登记主动笔（Stylus / Eraser）的最新悬停或落笔锚点。
     */
    @Suppress("FunctionName")
    fun AnchorStylus(x: Float, y: Float, timestampMs: Long) {
        stylusAnchorX = x
        stylusAnchorY = y
        stylusAnchorTimeMs = timestampMs
    }

    fun anchorStylus(x: Float, y: Float, timestampMs: Long) = AnchorStylus(x, y, timestampMs)

    /**
     * 记录一次被识别的手掌压屏包络足迹（Footprint），在短时间内阻断该半径区域内的后续余波触点。
     */
    fun registerPalmFootprint(x: Float, y: Float, radiusPx: Float, timestampMs: Long) {
        pruneExpiredFootprints(timestampMs)
        footprints.addLast(
            PalmFootprint(
                x = x,
                y = y,
                radiusPx = radiusPx.coerceAtLeast(16f),
                timestampMs = timestampMs
            )
        )
        while (footprints.size > MAX_FOOTPRINTS) {
            footprints.removeFirst()
        }
    }

    /**
     * 判断当前触点 `(x, y)` 是否落在虚拟手垫矩形内或未过期的手掌压屏包络足迹内。
     */
    fun isInsidePalmZone(x: Float, y: Float, currentTimeMs: Long): Boolean {
        if (isActive && viewportWidthPx > 0f && viewportHeightPx > 0f) {
            val rect = resolve(viewportWidthPx, viewportHeightPx, viewportDensity)
            if (rect.contains(x, y)) return true
        }
        pruneExpiredFootprints(currentTimeMs)
        for (fp in footprints) {
            if (hypot(x - fp.x, y - fp.y) <= fp.radiusPx) {
                return true
            }
        }
        return false
    }

    private fun pruneExpiredFootprints(currentTimeMs: Long) {
        while (footprints.isNotEmpty()) {
            val oldest = footprints.first()
            if (currentTimeMs > oldest.timestampMs && (currentTimeMs - oldest.timestampMs) > FOOTPRINT_TTL_MS) {
                footprints.removeFirst()
            } else {
                break
            }
        }
    }

    /**
     * 解析手垫当前占据的屏幕区域。
     *
     * 约束：手垫高度恒不超过画布高度的一半，防止用户把手垫拉到覆盖整个书写区而完全无法写字。
     */
    fun resolve(viewWidthPx: Float, viewHeightPx: Float, density: Float): PalmRect {
        if (!enabled || viewWidthPx <= 0f || viewHeightPx <= 0f) return PalmRect.EMPTY

        viewportWidthPx = viewWidthPx
        viewportHeightPx = viewHeightPx
        if (density > 0f) viewportDensity = density

        val maxHeightPx = viewHeightPx * MAX_CANVAS_HEIGHT_RATIO
        val heightPx = (heightDp * density).coerceIn(MIN_HEIGHT_DP * density, maxHeightPx)

        val baseBottom = viewHeightPx - bottomInsetDp * density + dragOffsetY
        val bottom = baseBottom.coerceIn(heightPx, viewHeightPx)
        val top = (bottom - heightPx).coerceAtLeast(0f)

        return when (mode) {
            ShieldMode.FULL_WIDTH -> PalmRect(0f, top, viewWidthPx, bottom)

            ShieldMode.CORNER_RIGHT -> {
                val widthPx = (viewWidthPx * widthRatio.coerceIn(MIN_WIDTH_RATIO, MAX_WIDTH_RATIO))
                val left = (viewWidthPx - widthPx + dragOffsetX).coerceIn(0f, viewWidthPx - widthPx * 0.4f)
                PalmRect(left, top, (left + widthPx).coerceAtMost(viewWidthPx), bottom)
            }

            ShieldMode.CORNER_LEFT -> {
                val widthPx = (viewWidthPx * widthRatio.coerceIn(MIN_WIDTH_RATIO, MAX_WIDTH_RATIO))
                val right = (widthPx + dragOffsetX).coerceIn(widthPx * 0.4f, viewWidthPx)
                PalmRect((right - widthPx).coerceAtLeast(0f), top, right, bottom)
            }
        }
    }

    /** 拖拽：把位移叠加到偏移量上（限制在 ±画布高度区间内，避免无限漂移） */
    fun dragBy(dx: Float, dy: Float) {
        dragOffsetX += dx
        dragOffsetY += dy
    }

    /** 复位到默认位置并清空临时手掌足迹 */
    fun resetPosition() {
        dragOffsetX = 0f
        dragOffsetY = 0f
        footprints.clear()
    }

    /** 切换形态（全宽 / 右下 / 左下），切换时清除拖拽偏移以获得确定的默认落点 */
    fun switchMode(next: ShieldMode) {
        if (mode == next) return
        mode = next
        resetPosition()
    }

    companion object {
        const val MIN_HEIGHT_DP = 48f
        const val MAX_HEIGHT_DP = 240f
        const val MIN_WIDTH_RATIO = 0.2f
        const val MAX_WIDTH_RATIO = 0.8f
        const val MAX_CANVAS_HEIGHT_RATIO = 0.5f
        const val FOOTPRINT_TTL_MS = 650L
        const val MAX_FOOTPRINTS = 12
    }
}
