package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.HandednessMode
import com.mumunotes.core.touch.model.TouchFeatures
import com.mumunotes.core.touch.model.TouchSample
import com.mumunotes.core.touch.model.TouchTrack
import kotlin.math.acos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * 四级流水线 **Stage 2 — 特征提取层 (TouchFeatureExtractor)**。
 *
 * 为每个采样点实时计算 7 维特征向量 `F_i = ⟨D_eq, E_axis, Ȧ, v, a, κ, S_pos⟩`。
 * 所有几何与运动学物理量均基于物理屏幕坐标 `(sample.x, sample.y)` 计算，
 * 同时将映射后的画布内容坐标 `(sample.contentX, sample.contentY)` 无损透传至 [TouchFeatures]。
 */
class TouchFeatureExtractor(var displayProfile: DisplayProfile) {

    /** 直接从聚合轨迹提取最新特征快照 */
    fun extract(track: TouchTrack): TouchFeatures = track.lastFeatures

    fun extract(
        sample: TouchSample,
        trail: List<TouchFeatures>,
        handednessMode: HandednessMode
    ): TouchFeatures {
        val density = displayProfile.density
        val majorPx = sample.touchMajorPx.coerceAtLeast(0f)
        val minorPxRaw = if (sample.touchMinorPx > 0f) sample.touchMinorPx else majorPx
        val usedFallback = sample.touchMajorPx <= 0f

        // ---- 维度 1：物理直径与等效椭圆面积 ----
        val majorMm = displayProfile.pxToMm(majorPx)
        val minorMm = displayProfile.pxToMm(minorPxRaw)
        val areaMm2 = (PI_QUARTER * majorMm * minorMm).coerceAtLeast(0f)
        val diameterDp = if (density > 0f) majorPx / density else majorPx

        // ---- 维度 2：椭圆长短轴偏心率 ----
        val longAxis = max(majorPx, minorPxRaw)
        val shortAxis = max(min(majorPx, minorPxRaw), MIN_AXIS_PX)
        val eccentricity = if (majorPx <= 0f) 1f else (longAxis / shortAxis).coerceAtLeast(1f)

        val previous = trail.lastOrNull()
        val previousPrevious = if (trail.size >= 2) trail[trail.size - 2] else null

        // ---- 维度 3：面积膨胀速率 ----
        val dtMs = if (previous != null) max(1L, sample.timeMs - previous.timeMs) else 0L
        val areaExpansionDpPerMs =
            if (previous != null && dtMs > 0L) (diameterDp - previous.diameterDp) / dtMs else 0f

        // ---- 维度 4：瞬时速度与加速度 ----
        val refX = previous?.x ?: sample.x
        val refY = previous?.y ?: sample.y
        val refTimeMs = previous?.timeMs ?: sample.timeMs
        val stepPx = hypot(sample.x - refX, sample.y - refY)
        val stepDp = if (density > 0f) stepPx / density else stepPx
        val dtSec = if (previous != null) max(1L, sample.timeMs - refTimeMs) / 1000f else 0f
        val velocityDpPerSec = if (dtSec > 0f) stepDp / dtSec else 0f
        val accelerationDpPerSec2 =
            if (previous != null && dtSec > 0f) (velocityDpPerSec - previous.velocityDpPerSec) / dtSec else 0f

        // ---- 维度 5：三点离散轨迹折返角与曲率 ----
        var turnAngleDeg = 0f
        var curvaturePerMm = 0f
        if (previousPrevious != null && previous != null) {
            val ux = previous.x - previousPrevious.x
            val uy = previous.y - previousPrevious.y
            val vx = sample.x - previous.x
            val vy = sample.y - previous.y
            val uLen = hypot(ux, uy)
            val vLen = hypot(vx, vy)
            if (uLen > MIN_SEGMENT_PX && vLen > MIN_SEGMENT_PX) {
                val cosine = ((ux * vx + uy * vy) / (uLen * vLen)).coerceIn(-1f, 1f)
                turnAngleDeg = Math.toDegrees(acos(cosine).toDouble()).toFloat()
                val arcLenMm = displayProfile.pxToMm((uLen + vLen) * 0.5f)
                curvaturePerMm = if (arcLenMm > MIN_ARC_MM) {
                    Math.toRadians(turnAngleDeg.toDouble()).toFloat() / arcLenMm
                } else {
                    0f
                }
            }
        }

        // ---- 维度 6：握笔姿态空间几何得分 ----
        val spatialScore = handednessMode.spatialScore(sample.x, sample.y)

        return TouchFeatures(
            pointerId = sample.pointerId,
            x = sample.x,
            y = sample.y,
            timeMs = sample.timeMs,
            isHistorical = sample.isHistorical,
            diameterMm = majorMm,
            minorDiameterMm = minorMm,
            areaMm2 = areaMm2,
            diameterDp = diameterDp,
            eccentricity = eccentricity,
            areaExpansionDpPerMs = areaExpansionDpPerMs,
            velocityDpPerSec = velocityDpPerSec,
            accelerationDpPerSec2 = accelerationDpPerSec2,
            turnAngleDeg = turnAngleDeg,
            curvaturePerMm = curvaturePerMm,
            spatialScore = spatialScore,
            rawTouchMajorPx = majorPx,
            rawTouchMinorPx = minorPxRaw,
            diameterFromFallback = usedFallback,
            contentX = sample.contentX,
            contentY = sample.contentY,
            normalizedSize = sample.normalizedSize,
            toolType = sample.toolType
        )
    }

    fun extractSequence(
        samples: List<TouchSample>,
        startingTrail: List<TouchFeatures>,
        handednessMode: HandednessMode
    ): List<TouchFeatures> {
        if (samples.isEmpty()) return emptyList()
        val out = ArrayList<TouchFeatures>(samples.size)
        val window = ArrayList<TouchFeatures>(4)
        window.addAll(startingTrail.takeLast(TRAIL_LENGTH))
        for (sample in samples) {
            val features = extract(sample, window, handednessMode)
            out.add(features)
            window.add(features)
            if (window.size > TRAIL_LENGTH) window.removeAt(0)
        }
        return out
    }

    fun trailingEdgeOverrunDp(
        features: TouchFeatures,
        anchorSpatialScore: Float,
        anchorX: Float,
        anchorY: Float,
        marginDp: Float,
        proximityDp: Float
    ): Float? {
        val proximityPx = displayProfile.dpToPx(proximityDp)
        val distance = hypot(features.x - anchorX, features.y - anchorY)
        if (distance > proximityPx) return null
        val marginPx = displayProfile.dpToPx(marginDp)
        val overrunPx = features.spatialScore - (anchorSpatialScore - marginPx)
        if (overrunPx <= 0f) return null
        return displayProfile.pxToDp(overrunPx)
    }

    fun geometricPriorityAdvantageDp(
        newSpatialScore: Float,
        oldSpatialScore: Float,
        requiredMarginDp: Float
    ): Float? {
        val requiredPx = displayProfile.dpToPx(requiredMarginDp)
        val advantagePx = oldSpatialScore - newSpatialScore
        if (advantagePx <= requiredPx) return null
        return displayProfile.pxToDp(advantagePx)
    }

    fun spatialHeadroomDp(candidateScore: Float, anchorScore: Float): Float =
        displayProfile.pxToDp(anchorScore - candidateScore)

    companion object {
        private const val PI_QUARTER = 0.7853982f // π / 4
        private const val MIN_AXIS_PX = 1.0f
        private const val MIN_SEGMENT_PX = 0.8f
        private const val MIN_ARC_MM = 0.05f

        const val TRAIL_LENGTH = 2
    }
}
