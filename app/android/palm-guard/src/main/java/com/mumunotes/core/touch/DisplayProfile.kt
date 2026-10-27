package com.mumunotes.core.touch

import android.content.Context
import android.util.DisplayMetrics
import kotlin.math.sqrt

/**
 * 设备物理度量归一化档位（L1 层）。
 *
 * 新增特性：
 * - [isNearScreenEdge]：屏幕边缘防误触带（Edge Guard，默认 8.5mm）判定
 * - [withUpdatedBounds]：横竖屏切换、分屏模式或折叠屏展开时动态更新窗口宽高与对角线像素尺寸
 */
data class DisplayProfile(
    /** 物理横向每英寸像素数，用于 px ↔ mm 换算 */
    val xdpi: Float,
    /** 逻辑密度（1dp = density px），用于 px ↔ dp 换算 */
    val density: Float,
    /** 屏幕对角线像素长度，用于触控驱动未上报 touchMajor 时的面积回退估算 */
    val screenDiagonalPx: Float,
    /** 屏幕宽度像素 */
    val widthPx: Int,
    /** 屏幕高度像素 */
    val heightPx: Int,
    /** 屏幕刷新率（Hz），用于评估采样上限与预测窗口 */
    val refreshRateHz: Float
) {

    /** px → 物理毫米 */
    fun pxToMm(px: Float): Float = px / xdpi * MM_PER_INCH

    /** 物理毫米 → px */
    fun mmToPx(mm: Float): Float = mm / MM_PER_INCH * xdpi

    /** px → dp */
    fun pxToDp(px: Float): Float = px / density

    /** dp → px */
    fun dpToPx(dp: Float): Float = dp * density

    /**
     * 判断坐标是否处于屏幕四周边缘防误触拒识带（Edge Guard）内。
     */
    fun isNearScreenEdge(xPx: Float, yPx: Float, marginMm: Float = DEFAULT_EDGE_GUARD_MM): Boolean {
        if (widthPx <= 0 || heightPx <= 0 || marginMm <= 0f) return false
        val marginPx = mmToPx(marginMm)
        return xPx <= marginPx ||
            xPx >= (widthPx - marginPx) ||
            yPx <= marginPx ||
            yPx >= (heightPx - marginPx)
    }

    /**
     * 当视图发生横竖屏旋转、分屏或折叠屏尺寸切换时，使用最新窗口像素宽高与 Context 度量重建 [DisplayProfile]。
     */
    fun withUpdatedBounds(newWidthPx: Int, newHeightPx: Int, context: Context? = null): DisplayProfile {
        val w = if (newWidthPx > 0) newWidthPx else widthPx
        val h = if (newHeightPx > 0) newHeightPx else heightPx
        val metrics = context?.resources?.displayMetrics
        val newDensity = metrics?.density?.takeIf { it > 0f } ?: density
        val rawXdpi = metrics?.xdpi?.takeIf { it > 0f } ?: xdpi
        val newXdpi = rawXdpi.coerceIn(MIN_PLAUSIBLE_XDPI, MAX_PLAUSIBLE_XDPI)
        val diag = sqrt((w.toDouble() * w.toDouble() + h.toDouble() * h.toDouble())).toFloat()
        return copy(
            xdpi = newXdpi,
            density = newDensity,
            screenDiagonalPx = diag,
            widthPx = w,
            heightPx = h
        )
    }

    /**
     * 触控驱动未上报 touchMajor 时的等效直径回退。
     */
    fun fallbackDiameterPx(normalizedSize: Float): Float {
        if (normalizedSize <= 0f) return 0f
        val raw = normalizedSize.coerceIn(0f, 1f) * screenDiagonalPx
        return raw.coerceIn(0f, mmToPx(MAX_FALLBACK_DIAMETER_MM))
    }

    companion object {
        const val MM_PER_INCH = 25.4f
        const val DEFAULT_EDGE_GUARD_MM = 8.5f

        /** 回退直径的物理上限（mm）：超过这个尺寸的"触点"物理上不可能存在 */
        const val MAX_FALLBACK_DIAMETER_MM = 20f

        /** 逻辑密度兜底：部分模拟器/定制 ROM 会返回 0 或荒谬值 */
        private const val MIN_PLAUSIBLE_XDPI = 96f
        private const val MAX_PLAUSIBLE_XDPI = 1200f

        fun fromContext(context: Context, overrideWidthPx: Int = 0, overrideHeightPx: Int = 0): DisplayProfile {
            val metrics: DisplayMetrics = context.resources.displayMetrics
            val density = if (metrics.density > 0f) metrics.density else 1f
            val rawXdpi = if (metrics.xdpi > 0f) metrics.xdpi else density * 160f
            val xdpi = rawXdpi.coerceIn(MIN_PLAUSIBLE_XDPI, MAX_PLAUSIBLE_XDPI)
            val widthPx = when {
                overrideWidthPx > 0 -> overrideWidthPx
                metrics.widthPixels > 0 -> metrics.widthPixels
                else -> 1600
            }
            val heightPx = when {
                overrideHeightPx > 0 -> overrideHeightPx
                metrics.heightPixels > 0 -> metrics.heightPixels
                else -> 2560
            }
            val diagonal = sqrt(
                (widthPx.toDouble() * widthPx.toDouble() + heightPx.toDouble() * heightPx.toDouble())
            ).toFloat()
            val refresh = context.display?.refreshRate
                ?.takeIf { it in 1f..480f }
                ?: 60f
            return DisplayProfile(
                xdpi = xdpi,
                density = density,
                screenDiagonalPx = diagonal,
                widthPx = widthPx,
                heightPx = heightPx,
                refreshRateHz = refresh
            )
        }

        fun manual(
            xdpi: Float = 309f,
            density: Float = 2.75f,
            widthPx: Int = 2880,
            heightPx: Int = 1800,
            refreshRateHz: Float = 120f
        ): DisplayProfile {
            val diagonal = sqrt(
                (widthPx.toDouble() * widthPx.toDouble() + heightPx.toDouble() * heightPx.toDouble())
            ).toFloat()
            return DisplayProfile(
                xdpi = xdpi.coerceIn(MIN_PLAUSIBLE_XDPI, MAX_PLAUSIBLE_XDPI),
                density = density,
                screenDiagonalPx = diagonal,
                widthPx = widthPx,
                heightPx = heightPx,
                refreshRateHz = refreshRateHz
            )
        }
    }
}
