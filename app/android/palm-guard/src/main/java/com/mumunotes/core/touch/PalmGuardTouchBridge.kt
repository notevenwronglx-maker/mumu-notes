package com.mumunotes.core.touch

import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.core.view.ViewCompat
import com.mumunotes.core.touch.model.ArbiterOutcome
import com.mumunotes.core.touch.model.CommitReason
import com.mumunotes.core.touch.model.DispatchDecision
import com.mumunotes.core.touch.model.GestureDescriptor
import com.mumunotes.core.touch.model.PalmRect
import com.mumunotes.core.touch.model.PalmRejectReason
import com.mumunotes.core.touch.model.RollbackDescriptor
import com.mumunotes.core.touch.model.StrokeCancelReason
import com.mumunotes.core.touch.model.TouchFeatures
import com.mumunotes.core.touch.model.TouchTelemetry

/**
 * 面向开源笔记应用的结构化回调接口（可选接入方式 B）。
 */
interface PalmGuardListener {
    /** 笔尖候选建立（可开始绘制实时预览笔迹） */
    fun onStylusStrokeStart(pointerId: Int, startFeature: TouchFeatures) {}

    /** 追加高频采样点批次（包含从 historySize 还原出的 240Hz~360Hz 采样） */
    fun onStylusStrokeBatch(pointerId: Int, batch: List<TouchFeatures>) {}

    /** 笔迹正常提交或因系统三指截屏触发保护性保存 */
    fun onStylusStrokeCommit(pointerId: Int, reason: CommitReason, totalPathDp: Float, tailTruncateMs: Long) {}

    /** 取消并抹除当前未提交的短笔迹 */
    fun onStylusStrokeCancel(pointerId: Int, reason: StrokeCancelReason, descriptor: RollbackDescriptor) {}

    /** 多指缩放/平移/旋转手势启动 */
    fun onMultiFingerGestureStart(pointerIds: List<Int>, gesture: GestureDescriptor) {}

    /** 多指缩放/平移/旋转手势逐帧更新 */
    fun onMultiFingerGestureUpdate(gesture: GestureDescriptor) {}

    /** 双指轻点快捷手势：撤销一步 */
    fun onTwoFingerTapUndo() {}

    /** 三指轻点快捷手势：重做一步 */
    fun onThreeFingerTapRedo() {}

    /** 单指漫游平移启动 */
    fun onFingerPanStart(pointerId: Int, startFeature: TouchFeatures) {}

    /** 单指漫游平移增量 */
    fun onFingerPanUpdate(pointerId: Int, dx: Float, dy: Float) {}

    /** 触点落在 UI 热区内，交还给工具栏或按钮处理 */
    fun onFingerUiTap(pointerId: Int, x: Float, y: Float) {}

    /** 手掌或侧掌触点被成功拦截 */
    fun onPalmRejected(pointerId: Int, x: Float, y: Float, diameterMm: Float, reason: PalmRejectReason) {}
}

/**
 * **开源软件即插即用防误触桥接器 (`PalmGuardTouchBridge`)**。
 *
 * 核心升级：
 * 1. [onInterceptHoverEvent]：处理主动笔悬停事件，在笔尖触屏前预先建立 400ms 主动笔防误触护盾（Stylus Temporal Shield）；
 * 2. [onInterceptTouchEvent]：在 `ACTION_DOWN` 时调用 `collector.pruneStaleTracks(eventTime, 450L)` 清理陈旧轨迹，
 *    当已被放行的 `pointerId` 中途被识别为手掌时，立即调用 [onCancelPointerInFlutter] 定向回滚幽灵笔画，
 *    并在单指场景下通过 `try-finally { cancelEvent.recycle() }` 安全派发合成的 `ACTION_CANCEL`；
 * 3. [onViewportLayoutChanged]：响应屏幕旋转、分屏或折叠屏切换，实时重建 [DisplayProfile] 并更新 [VirtualPalmShield] 边界。
 */
class PalmGuardTouchBridge(
    var displayProfile: DisplayProfile,
    val profile: AdaptiveThresholdProfile,
    val collector: RawTouchCollector = RawTouchCollector(displayProfile),
    val arbiter: PalmAndGestureArbiter = PalmAndGestureArbiter(profile, displayProfile),
    val palmShield: VirtualPalmShield = arbiter.palmShield,
    val extractor: TouchFeatureExtractor = TouchFeatureExtractor(displayProfile),
    var onCancelPointerInFlutter: ((pointerId: Int) -> Unit)? = null,
    var dispatchToSuper: ((MotionEvent) -> Boolean)? = null
) {
    constructor(
        collector: RawTouchCollector,
        extractor: TouchFeatureExtractor,
        arbiter: PalmAndGestureArbiter,
        onCancelPointerInFlutter: (pointerId: Int) -> Unit,
        dispatchToSuper: (MotionEvent) -> Boolean
    ) : this(
        displayProfile = arbiter.displayProfile,
        profile = arbiter.profile,
        collector = collector,
        arbiter = arbiter,
        palmShield = arbiter.palmShield,
        extractor = extractor,
        onCancelPointerInFlutter = onCancelPointerInFlutter,
        dispatchToSuper = dispatchToSuper
    )

    private var uiRegions: List<PalmRect> = emptyList()
    private var lastExclusionCenterY: Int = Int.MIN_VALUE
    private var downstreamPenActive: Boolean = false
    private var downstreamPenDownTimeMs: Long = 0L

    val telemetry: TouchTelemetry get() = arbiter.telemetry

    /** 设置顶部工具栏、浮动笔盒等 UI 热区（View 像素坐标） */
    fun setUiRegions(regions: List<PalmRect>) {
        uiRegions = regions
    }

    /**
     * 当平板发生横竖屏旋转、进入分屏或折叠屏展开导致视图宽高变化时，实时重建 [DisplayProfile] 并同步给所有子组件。
     */
    fun onViewportLayoutChanged(context: Context?, newWidthPx: Int, newHeightPx: Int) {
        if (newWidthPx <= 0 || newHeightPx <= 0) return
        if (newWidthPx == displayProfile.widthPx && newHeightPx == displayProfile.heightPx) return
        val updated = displayProfile.withUpdatedBounds(newWidthPx, newHeightPx, context)
        displayProfile = updated
        collector.displayProfile = updated
        extractor.displayProfile = updated
        arbiter.updateDisplayProfile(updated)
        palmShield.updateViewportBounds(newWidthPx, newHeightPx, updated.density)
        lastExclusionCenterY = Int.MIN_VALUE
    }

    /** 保存当前 L2/L3 校准参数与手垫配置到 SharedPreferences（防抖异步 apply） */
    fun savePreferences(context: Context, immediate: Boolean = false) {
        CalibrationPreferences.save(context, profile, palmShield, immediate = immediate)
    }

    /** 从 SharedPreferences 加载已保存的校准参数与手垫配置 */
    fun loadPreferences(context: Context): Boolean =
        CalibrationPreferences.loadInto(context, profile, palmShield)

    /** 复位瞬时状态（页面切换 / 视图销毁时调用） */
    fun reset() {
        collector.reset()
        arbiter.reset()
        downstreamPenActive = false
        lastExclusionCenterY = Int.MIN_VALUE
    }

    // ==================================================================
    //  原生拦截器接口：悬停护盾预热 + 触控拦截与安全取消
    // ==================================================================

    /**
     * 处理悬停事件（提前建立主动笔防误触护盾）。
     */
    fun onInterceptHoverEvent(
        event: MotionEvent,
        fallbackSuper: ((MotionEvent) -> Boolean)? = dispatchToSuper
    ): Boolean {
        if (event.pointerCount > 0) {
            val toolType = event.getToolType(0)
            if (toolType == MotionEvent.TOOL_TYPE_STYLUS ||
                toolType == MotionEvent.TOOL_TYPE_ERASER
            ) {
                arbiter.onStylusActivity(event.eventTime, event.x, event.y)
            }
        }
        return fallbackSuper?.invoke(event) ?: false
    }

    /**
     * 拦截并评估多指触控流：当已被放行的 `pointerId` 中途被判定为手掌时，
     * 立即通知 Flutter 定向回滚幽灵笔画，并在单指场景下安全派发 `ACTION_CANCEL`。
     */
    fun onInterceptTouchEvent(
        event: MotionEvent,
        fallbackSuper: ((MotionEvent) -> Boolean)? = dispatchToSuper
    ): Boolean {
        val actionMasked = event.actionMasked
        if (actionMasked == MotionEvent.ACTION_DOWN) {
            // 新手势序列开始，清理任何异常残留的陈旧轨迹
            collector.pruneStaleTracks(event.eventTime, timeoutMs = 450L)
            arbiter.pruneStaleTracks(event.eventTime, timeoutMs = 450L)
        }

        collector.currentFingerMode = profile.fingerActionMode
        collector.currentHandednessMode = profile.handednessMode
        val updatedTracks = collector.collectTracks(event)
        var shouldBlockCurrentEvent = false
        var needSynthesizeCancel = false

        for (track in updatedTracks) {
            val features = extractor.extract(track)
            val decision = arbiter.evaluateTrack(
                track = track,
                features = features,
                fingerMode = collector.currentFingerMode,
                currentTimeMs = event.eventTime
            )

            when (decision) {
                is DispatchDecision.RejectPalm -> {
                    shouldBlockCurrentEvent = true
                    if (decision.shouldCancelExisting) {
                        track.wasDispatched = false
                        // 通知 Flutter 立即回滚该 pointerId 已经落下的幽灵笔迹点
                        onCancelPointerInFlutter?.invoke(track.pointerId)
                        needSynthesizeCancel = true
                    }
                }
                is DispatchDecision.HoldPending -> {
                    // 临界点暂缓派发，等待下一帧 MOVE 确认面积变化
                    shouldBlockCurrentEvent = true
                }
                is DispatchDecision.AllowStylus,
                is DispatchDecision.AllowFingerDraw,
                is DispatchDecision.AllowGestureOnly -> {
                    track.wasDispatched = true
                }
                else -> Unit
            }
        }

        if (needSynthesizeCancel && event.pointerCount == 1) {
            dispatchSyntheticCancel(event, fallbackSuper)
            return true
        }

        if (shouldBlockCurrentEvent && event.pointerCount == 1) {
            return true
        }

        return fallbackSuper?.invoke(event) ?: false
    }

    private fun dispatchSyntheticCancel(
        source: MotionEvent,
        fallbackSuper: ((MotionEvent) -> Boolean)? = dispatchToSuper
    ) {
        val cancelEvent = MotionEvent.obtain(
            source.downTime,
            SystemClock.uptimeMillis(),
            MotionEvent.ACTION_CANCEL,
            source.x,
            source.y,
            source.metaState
        )
        try {
            fallbackSuper?.invoke(cancelEvent)
        } finally {
            cancelEvent.recycle()
        }
    }

    // ==================================================================
    //  模式 B：结构化特征流与回调入口
    // ==================================================================

    fun processTouchEvent(
        hostView: View?,
        rawEvent: MotionEvent,
        pointMapper: TouchPointMapper? = null,
        listener: PalmGuardListener? = null
    ): ArbiterOutcome {
        if (hostView != null) {
            if (hostView.width > 0 && hostView.height > 0 &&
                (hostView.width != displayProfile.widthPx || hostView.height != displayProfile.heightPx)
            ) {
                onViewportLayoutChanged(hostView.context, hostView.width, hostView.height)
            }
            if (rawEvent.actionMasked == MotionEvent.ACTION_DOWN) {
                hostView.parent?.requestDisallowInterceptTouchEvent(true)
                collector.pruneStaleTracks(rawEvent.eventTime, timeoutMs = 450L)
                arbiter.pruneStaleTracks(rawEvent.eventTime, timeoutMs = 450L)
            }
            val shieldRect = if (palmShield.isActive) {
                palmShield.resolve(
                    viewWidthPx = hostView.width.toFloat(),
                    viewHeightPx = hostView.height.toFloat(),
                    density = displayProfile.density
                )
            } else {
                null
            }
            arbiter.configureRegions(uiRegions, shieldRect)
        }

        collector.currentFingerMode = profile.fingerActionMode
        collector.currentHandednessMode = profile.handednessMode
        val packet = collector.collect(rawEvent, pointMapper)
        val outcome = arbiter.process(packet)

        // 若有活动笔尖，实时移动左右两侧 200dp 系统返回手势豁免窗跟随笔尖 Y 轴
        if (hostView != null && arbiter.activePenId != -1) {
            updateSystemGestureExclusionForPen(hostView, arbiter.telemetry.touchY)
        }

        // 若发生笔迹取消或幽灵回滚，同步触发 onCancelPointerInFlutter 定向回滚回调
        for (decision in outcome.decisions) {
            when (decision) {
                is DispatchDecision.CancelStroke ->
                    onCancelPointerInFlutter?.invoke(decision.pointerId)
                is DispatchDecision.RollbackAndSwitchStylus ->
                    onCancelPointerInFlutter?.invoke(decision.cancelledPointerId)
                is DispatchDecision.RejectPalm ->
                    if (decision.shouldCancelExisting) {
                        onCancelPointerInFlutter?.invoke(decision.pointerId)
                    }
                else -> Unit
            }
        }

        if (listener != null) {
            dispatchToListener(outcome, listener)
        }

        return outcome
    }

    private fun dispatchToListener(outcome: ArbiterOutcome, listener: PalmGuardListener) {
        for (decision in outcome.decisions) {
            when (decision) {
                is DispatchDecision.StartStylusStroke ->
                    listener.onStylusStrokeStart(decision.pointerId, decision.features)
                is DispatchDecision.AppendStylusBatch ->
                    listener.onStylusStrokeBatch(decision.pointerId, decision.batch)
                is DispatchDecision.CommitStylusStroke ->
                    listener.onStylusStrokeCommit(
                        decision.pointerId,
                        decision.reason,
                        decision.totalPathDp,
                        decision.tailTruncateMs
                    )
                is DispatchDecision.CancelStroke ->
                    listener.onStylusStrokeCancel(decision.pointerId, decision.reason, decision.descriptor)
                is DispatchDecision.RollbackAndSwitchStylus -> {
                    listener.onStylusStrokeCancel(
                        decision.cancelledPointerId,
                        StrokeCancelReason.GHOST_PREEMPTED,
                        decision.rollback
                    )
                    listener.onStylusStrokeStart(decision.newStylusPointerId, decision.startPoint)
                }
                is DispatchDecision.SwitchToMultiFingerGesture ->
                    listener.onMultiFingerGestureStart(decision.pointerIds, decision.gesture)
                is DispatchDecision.UpdateMultiFingerGesture ->
                    listener.onMultiFingerGestureUpdate(decision.gesture)
                DispatchDecision.TwoFingerTapUndo ->
                    listener.onTwoFingerTapUndo()
                DispatchDecision.ThreeFingerTapRedo ->
                    listener.onThreeFingerTapRedo()
                is DispatchDecision.StartFingerPan ->
                    listener.onFingerPanStart(decision.pointerId, decision.features)
                is DispatchDecision.UpdateFingerPan ->
                    listener.onFingerPanUpdate(decision.pointerId, decision.dx, decision.dy)
                is DispatchDecision.FingerUiTap ->
                    listener.onFingerUiTap(decision.pointerId, decision.x, decision.y)
                is DispatchDecision.RejectPalm ->
                    listener.onPalmRejected(
                        decision.pointerId,
                        decision.x,
                        decision.y,
                        decision.diameterMm,
                        decision.reason
                    )
                else -> Unit
            }
        }
    }

    // ==================================================================
    //  模式 A：开源画布单指针净化 MotionEvent 直通适配器
    // ==================================================================

    fun dispatchFilteredMotionEvents(
        hostView: View?,
        rawEvent: MotionEvent,
        canvasTouchConsumer: (MotionEvent) -> Unit,
        onRollbackGhostStroke: ((RollbackDescriptor) -> Unit)? = null,
        onMultiFingerGesture: ((GestureDescriptor) -> Unit)? = null,
        onFingerPan: ((dx: Float, dy: Float) -> Unit)? = null,
        onUndo: (() -> Unit)? = null,
        onRedo: (() -> Unit)? = null
    ): Boolean {
        val outcome = processTouchEvent(hostView, rawEvent, pointMapper = null, listener = null)

        for (decision in outcome.decisions) {
            when (decision) {
                is DispatchDecision.StartStylusStroke -> {
                    downstreamPenActive = true
                    downstreamPenDownTimeMs = decision.features.timeMs
                    emitSinglePointerEvent(
                        action = MotionEvent.ACTION_DOWN,
                        downTimeMs = downstreamPenDownTimeMs,
                        eventTimeMs = decision.features.timeMs,
                        x = decision.features.x,
                        y = decision.features.y,
                        consumer = canvasTouchConsumer
                    )
                }

                is DispatchDecision.AppendStylusBatch -> {
                    if (!downstreamPenActive) {
                        val first = decision.batch.firstOrNull() ?: continue
                        downstreamPenActive = true
                        downstreamPenDownTimeMs = first.timeMs
                        emitSinglePointerEvent(
                            action = MotionEvent.ACTION_DOWN,
                            downTimeMs = downstreamPenDownTimeMs,
                            eventTimeMs = first.timeMs,
                            x = first.x,
                            y = first.y,
                            consumer = canvasTouchConsumer
                        )
                    }
                    emitSinglePointerBatchMove(
                        downTimeMs = downstreamPenDownTimeMs,
                        batch = decision.batch,
                        consumer = canvasTouchConsumer
                    )
                }

                is DispatchDecision.CommitStylusStroke -> {
                    if (downstreamPenActive) {
                        val focus = arbiter.telemetry
                        emitSinglePointerEvent(
                            action = MotionEvent.ACTION_UP,
                            downTimeMs = downstreamPenDownTimeMs,
                            eventTimeMs = rawEvent.eventTime,
                            x = focus.touchX,
                            y = focus.touchY,
                            consumer = canvasTouchConsumer
                        )
                        downstreamPenActive = false
                    }
                }

                is DispatchDecision.CancelStroke -> {
                    if (downstreamPenActive) {
                        val focus = arbiter.telemetry
                        emitSinglePointerEvent(
                            action = MotionEvent.ACTION_CANCEL,
                            downTimeMs = downstreamPenDownTimeMs,
                            eventTimeMs = rawEvent.eventTime,
                            x = focus.touchX,
                            y = focus.touchY,
                            consumer = canvasTouchConsumer
                        )
                        downstreamPenActive = false
                    }
                    onCancelPointerInFlutter?.invoke(decision.pointerId)
                    onRollbackGhostStroke?.invoke(decision.descriptor)
                }

                is DispatchDecision.RollbackAndSwitchStylus -> {
                    if (downstreamPenActive) {
                        emitSinglePointerEvent(
                            action = MotionEvent.ACTION_CANCEL,
                            downTimeMs = downstreamPenDownTimeMs,
                            eventTimeMs = decision.startPoint.timeMs,
                            x = decision.startPoint.x,
                            y = decision.startPoint.y,
                            consumer = canvasTouchConsumer
                        )
                    }
                    onCancelPointerInFlutter?.invoke(decision.cancelledPointerId)
                    onRollbackGhostStroke?.invoke(decision.rollback)

                    downstreamPenActive = true
                    downstreamPenDownTimeMs = decision.startPoint.timeMs
                    emitSinglePointerEvent(
                        action = MotionEvent.ACTION_DOWN,
                        downTimeMs = downstreamPenDownTimeMs,
                        eventTimeMs = decision.startPoint.timeMs,
                        x = decision.startPoint.x,
                        y = decision.startPoint.y,
                        consumer = canvasTouchConsumer
                    )
                }

                is DispatchDecision.SwitchToMultiFingerGesture -> {
                    onMultiFingerGesture?.invoke(decision.gesture)
                }

                is DispatchDecision.UpdateMultiFingerGesture -> {
                    onMultiFingerGesture?.invoke(decision.gesture)
                }

                is DispatchDecision.UpdateFingerPan -> {
                    onFingerPan?.invoke(decision.dx, decision.dy)
                }

                DispatchDecision.TwoFingerTapUndo -> {
                    onUndo?.invoke()
                }

                DispatchDecision.ThreeFingerTapRedo -> {
                    onRedo?.invoke()
                }

                else -> Unit
            }
        }
        return true
    }

    private fun emitSinglePointerEvent(
        action: Int,
        downTimeMs: Long,
        eventTimeMs: Long,
        x: Float,
        y: Float,
        consumer: (MotionEvent) -> Unit
    ) {
        val ev = MotionEvent.obtain(downTimeMs, eventTimeMs, action, x, y, 0)
        try {
            consumer(ev)
        } finally {
            ev.recycle()
        }
    }

    private fun emitSinglePointerBatchMove(
        downTimeMs: Long,
        batch: List<TouchFeatures>,
        consumer: (MotionEvent) -> Unit
    ) {
        if (batch.isEmpty()) return
        val first = batch.first()
        val ev = MotionEvent.obtain(downTimeMs, first.timeMs, MotionEvent.ACTION_MOVE, first.x, first.y, 0)
        try {
            for (i in 1 until batch.size) {
                val pt = batch[i]
                ev.addBatch(pt.timeMs, pt.x, pt.y, 1.0f, 1.0f, 0)
            }
            consumer(ev)
        } finally {
            ev.recycle()
        }
    }

    // ==================================================================
    //  Android 10+ 笔尖跟随式系统边缘返回手势豁免窗（200dp 上限）
    // ==================================================================

    fun updateSystemGestureExclusionForPen(view: View, currentPenViewY: Float) {
        if (view.width <= 0 || view.height <= 0) return
        val centerY = currentPenViewY.toInt()
        if (kotlin.math.abs(centerY - lastExclusionCenterY) < EXCLUSION_UPDATE_SLOP_PX) return
        lastExclusionCenterY = centerY

        val density = displayProfile.density
        val halfWindowPx = (HALF_EXCLUSION_WINDOW_DP * density).toInt()
        val edgeWidthPx = (EDGE_EXCLUSION_WIDTH_DP * density).toInt()

        val top = (centerY - halfWindowPx).coerceAtLeast(0)
        val bottom = (centerY + halfWindowPx).coerceAtMost(view.height)
        if (bottom <= top) return

        val leftRect = Rect(0, top, edgeWidthPx.coerceAtMost(view.width), bottom)
        val rightRect = Rect((view.width - edgeWidthPx).coerceAtLeast(0), top, view.width, bottom)
        ViewCompat.setSystemGestureExclusionRects(view, listOf(leftRect, rightRect))
    }

    companion object {
        private const val HALF_EXCLUSION_WINDOW_DP = 100f
        private const val EDGE_EXCLUSION_WIDTH_DP = 36f
        private const val EXCLUSION_UPDATE_SLOP_PX = 8

        fun create(
            context: Context,
            autoLoadPreferences: Boolean = true,
            deviceModel: String = Build.MODEL.orEmpty()
        ): PalmGuardTouchBridge {
            val display = DisplayProfile.fromContext(context)
            val profile = AdaptiveThresholdProfile(displayProfile = display, deviceModel = deviceModel)
            val shield = VirtualPalmShield()
            val collector = RawTouchCollector(display)
            val extractor = TouchFeatureExtractor(display)
            val arbiter = PalmAndGestureArbiter(profile, display, shield)
            val bridge = PalmGuardTouchBridge(
                displayProfile = display,
                profile = profile,
                collector = collector,
                arbiter = arbiter,
                palmShield = shield,
                extractor = extractor
            )
            if (autoLoadPreferences) {
                bridge.loadPreferences(context)
            }
            return bridge
        }
    }
}
