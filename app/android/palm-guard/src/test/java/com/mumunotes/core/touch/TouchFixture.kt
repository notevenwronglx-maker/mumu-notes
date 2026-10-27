package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.TouchAction
import com.mumunotes.core.touch.model.TouchPacket
import com.mumunotes.core.touch.model.TouchSample

/**
 * 测试夹具：以合成 [TouchPacket] 驱动防误触状态机。
 */
object TouchFixture {

    val displayProfile = DisplayProfile.manual(
        xdpi = 309f,
        density = 2.75f,
        widthPx = 2880,
        heightPx = 1800,
        refreshRateHz = 120f
    )

    fun mm(value: Float): Float = displayProfile.mmToPx(value)

    fun dp(value: Float): Float = displayProfile.dpToPx(value)

    data class Pointer(
        val id: Int,
        val x: Float,
        val y: Float,
        val diameterMm: Float,
        val timeMs: Long,
        val minorRatio: Float = 1f,
        val contentX: Float = x,
        val contentY: Float = y
    )

    fun pointer(
        id: Int,
        x: Float,
        y: Float,
        diameterMm: Float,
        timeMs: Long,
        minorRatio: Float = 1f,
        contentX: Float = x,
        contentY: Float = y
    ) = Pointer(id, x, y, diameterMm, timeMs, minorRatio, contentX, contentY)

    fun packet(
        action: Int,
        pointers: List<Pointer>,
        actionPointerId: Int = pointers.last().id,
        diameterReportAvailable: Boolean = true
    ): TouchPacket {
        val ids = pointers.map { it.id }
        val actionIndex = ids.indexOf(actionPointerId).coerceAtLeast(0)
        val eventTime = pointers.maxOf { it.timeMs }
        val points = pointers.associate { p ->
            p.id to listOf(
                TouchSample(
                    pointerId = p.id,
                    x = p.x,
                    y = p.y,
                    touchMajorPx = mm(p.diameterMm),
                    touchMinorPx = mm(p.diameterMm * p.minorRatio),
                    timeMs = p.timeMs,
                    isHistorical = false,
                    normalizedSize = 0f,
                    contentX = p.contentX,
                    contentY = p.contentY
                )
            )
        }
        return TouchPacket(
            action = action,
            actionIndex = actionIndex,
            eventTimeMs = eventTime,
            pointerIds = ids,
            points = points,
            diameterReportAvailable = diameterReportAvailable
        )
    }

    fun single(action: Int, p: Pointer): TouchPacket = packet(action, listOf(p))

    fun arbiter(
        sensitivity: Int = AdaptiveThresholdProfile.DEFAULT_SENSITIVITY,
        fingerMode: com.mumunotes.core.touch.model.FingerActionMode =
            com.mumunotes.core.touch.model.FingerActionMode.PAN_CANVAS
    ): PalmAndGestureArbiter {
        val profile = AdaptiveThresholdProfile(
            displayProfile = displayProfile,
            deviceModel = "23043RP34C",
            initialSensitivity = sensitivity,
            fingerActionMode = fingerMode
        )
        return PalmAndGestureArbiter(profile, displayProfile)
    }

    const val PEN_MM = 2.0f
    const val THICK_PEN_MM = 3.6f
    const val FINGER_MM = 7.0f
    const val PALM_MM = 30.0f

    const val DOWN = TouchAction.DOWN
    const val MOVE = TouchAction.MOVE
    const val UP = TouchAction.UP
    const val CANCEL = TouchAction.CANCEL
    const val POINTER_DOWN = TouchAction.POINTER_DOWN
    const val POINTER_UP = TouchAction.POINTER_UP
}
