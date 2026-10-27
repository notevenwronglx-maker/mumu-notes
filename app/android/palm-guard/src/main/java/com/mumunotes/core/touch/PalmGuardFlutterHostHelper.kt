package com.mumunotes.core.touch

import android.app.Activity
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.mumunotes.core.touch.model.CommitReason
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.HandednessMode
import com.mumunotes.core.touch.model.PalmRect
import com.mumunotes.core.touch.model.PalmRejectReason
import com.mumunotes.core.touch.model.RollbackDescriptor
import com.mumunotes.core.touch.model.StrokeCancelReason

/**
 * 专为 Flutter 版开源软件 **Linwood Butterfly** 设计的 Android 原生层触摸防误触与校准桥接器。
 *
 * 新增优化：
 * 1. **动态布局监听（OnLayoutChangeListener）**：当平板发生横竖屏旋转、进入分屏或折叠屏展开时，
 *    自动重建 [DisplayProfile] 并同步更新 [VirtualPalmShield] 物理边界与毫米换算比例；
 * 2. **幽灵笔画定向取消（cancelPointer）**：当某个已被放行的 `pointerId` 中途被判定为手掌时，
 *    立即向 Flutter 侧 `PalmGuardService` 发送 `cancelPointer` 与 `palm_rollback` 信号，
 *    确保 `PenHandler` 即时擦除残缺幽灵笔画且不误杀正在书写的电容笔或另一侧手势；
 * 3. **主动笔悬停预热（dispatchGenericMotionEvent）**：捕获 `TOOL_TYPE_STYLUS` 悬停事件，
 *    提前激活 400ms 主动笔时间护盾（Stylus Temporal Shield）；
 * 4. **`updateConfig` 全量同步通道**：支持接收木木笔记 6 种握姿预设、灵敏度与手写笔/手指模式配置。
 */
class PalmGuardFlutterHostHelper(
    private val activity: Activity
) {
    fun interface SuperTouchDispatcher {
        fun superDispatch(event: MotionEvent): Boolean
    }

    fun interface ArbiterEventCallback {
        fun onEvent(eventType: String, payload: Map<String, Any?>)
    }

    fun interface PointerCancelDispatcher {
        fun onCancelPointer(pointerId: Int)
    }

    val bridge: PalmGuardTouchBridge = PalmGuardTouchBridge.create(
        context = activity,
        autoLoadPreferences = true
    )

    /** 当前是否处于画布编辑页面（由 Flutter 通知，避免在首页文件列表拦截大面积手指滑动） */
    var canvasInteractive: Boolean = true

    /** 全局防误触开关（由 updateConfig 控制） */
    var palmGuardEnabled: Boolean = true

    /** 是否启用原生层单指针重构直通模式 */
    var filterMotionEventsBeforeFlutter: Boolean = false

    /** 实时事件回调（转发至 Flutter MethodChannel） */
    var arbiterEventCallback: ArbiterEventCallback? = null

    /** 定向取消单个 pointerId 的回调（直接调用 Flutter 侧 cancelPointer） */
    var pointerCancelDispatcher: PointerCancelDispatcher? = null

    private var layoutListenerAttached: Boolean = false

    private val decorLayoutChangeListener =
        View.OnLayoutChangeListener { view, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom ->
            val newW = right - left
            val newH = bottom - top
            val oldW = oldRight - oldLeft
            val oldH = oldBottom - oldTop
            if (newW > 0 && newH > 0 && (newW != oldW || newH != oldH)) {
                bridge.onViewportLayoutChanged(view.context ?: activity, newW, newH)
            }
        }

    init {
        bridge.onCancelPointerInFlutter = { cancelledPointerId ->
            pointerCancelDispatcher?.onCancelPointer(cancelledPointerId)
        }
        ensureLayoutChangeListenerAttached()
    }

    fun ensureLayoutChangeListenerAttached() {
        if (layoutListenerAttached) return
        val decorView = activity.window?.decorView ?: return
        decorView.addOnLayoutChangeListener(decorLayoutChangeListener)
        layoutListenerAttached = true
        if (decorView.width > 0 && decorView.height > 0) {
            bridge.onViewportLayoutChanged(activity, decorView.width, decorView.height)
        }
    }

    private val internalListener = object : PalmGuardListener {
        override fun onPalmRejected(
            pointerId: Int,
            x: Float,
            y: Float,
            diameterMm: Float,
            reason: PalmRejectReason
        ) {
            arbiterEventCallback?.onEvent(
                "palm_rejected",
                mapOf(
                    "pointerId" to pointerId,
                    "x" to x,
                    "y" to y,
                    "diameterMm" to diameterMm,
                    "reason" to reason.name,
                    "rejectedPalmCount" to bridge.telemetry.rejectedPalmCount,
                    "candidateDiameterMm" to bridge.telemetry.candidateDiameterMm,
                    "eccentricity" to bridge.telemetry.eccentricity,
                    "velocityDpPerSec" to bridge.telemetry.velocityDpPerSec,
                    "state" to bridge.telemetry.state.name,
                    "stateLabel" to bridge.telemetry.state.label
                )
            )
        }

        override fun onStylusStrokeCancel(
            pointerId: Int,
            reason: StrokeCancelReason,
            descriptor: RollbackDescriptor
        ) {
            val nowMs = SystemClock.uptimeMillis()
            val startTimeMs = (nowMs - descriptor.cancelledAliveMs).coerceAtLeast(0L)
            pointerCancelDispatcher?.onCancelPointer(pointerId)
            arbiterEventCallback?.onEvent(
                "palm_rollback",
                mapOf(
                    "cancelledPointerId" to pointerId,
                    "reason" to reason.name,
                    "startTimeMs" to startTimeMs,
                    "endTimeMs" to nowMs,
                    "cancelledPathDp" to descriptor.cancelledPathDp,
                    "cancelledAliveMs" to descriptor.cancelledAliveMs,
                    "tailTruncateMs" to descriptor.tailTruncateMs,
                    "rejectedPalmCount" to bridge.telemetry.rejectedPalmCount,
                    "state" to bridge.telemetry.state.name,
                    "stateLabel" to bridge.telemetry.state.label
                )
            )
        }

        override fun onStylusStrokeCommit(
            pointerId: Int,
            reason: CommitReason,
            totalPathDp: Float,
            tailTruncateMs: Long
        ) {
            if (bridge.profile.isDirty) {
                bridge.savePreferences(activity, immediate = false)
            }
            if (reason == CommitReason.SYSTEM_CANCEL_PARTIAL) {
                arbiterEventCallback?.onEvent(
                    "stroke_cancel_protected",
                    mapOf(
                        "pointerId" to pointerId,
                        "tailTruncateMs" to tailTruncateMs,
                        "totalPathDp" to totalPathDp
                    )
                )
            }
        }

        override fun onTwoFingerTapUndo() {
            arbiterEventCallback?.onEvent(
                "two_finger_undo",
                mapOf("type" to "two_finger_undo")
            )
        }

        override fun onThreeFingerTapRedo() {
            arbiterEventCallback?.onEvent(
                "three_finger_redo",
                mapOf("type" to "three_finger_redo")
            )
        }
    }

    fun configureTransientSystemBars(enableImmersive: Boolean) {
        val window = activity.window ?: return
        val decorView = window.decorView
        val controller = WindowCompat.getInsetsController(window, decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (enableImmersive) {
            controller.hide(WindowInsetsCompat.Type.systemBars())
        } else {
            controller.show(WindowInsetsCompat.Type.systemBars())
        }
    }

    fun dispatchGenericMotionEvent(
        rawEvent: MotionEvent,
        superDispatcher: SuperTouchDispatcher
    ): Boolean {
        ensureLayoutChangeListenerAttached()
        return bridge.onInterceptHoverEvent(rawEvent) { ev ->
            superDispatcher.superDispatch(ev)
        }
    }

    fun dispatchTouchEvent(
        rawEvent: MotionEvent,
        superDispatcher: SuperTouchDispatcher
    ): Boolean {
        ensureLayoutChangeListenerAttached()
        val rootView: View? = activity.window?.decorView
        if (!canvasInteractive || !palmGuardEnabled) {
            return superDispatcher.superDispatch(rawEvent)
        }

        if (!filterMotionEventsBeforeFlutter) {
            val outcome = bridge.processTouchEvent(
                hostView = rootView,
                rawEvent = rawEvent,
                pointMapper = null,
                listener = internalListener
            )
            // 当单指触控中途被识别为手掌取消时，向宿主下发合成 ACTION_CANCEL 释放 Flutter GestureArena
            if (outcome.hasStrokeInvalidation && rawEvent.pointerCount == 1) {
                val cancelEvent = MotionEvent.obtain(
                    rawEvent.downTime,
                    SystemClock.uptimeMillis(),
                    MotionEvent.ACTION_CANCEL,
                    rawEvent.x,
                    rawEvent.y,
                    rawEvent.metaState
                )
                try {
                    superDispatcher.superDispatch(cancelEvent)
                } finally {
                    cancelEvent.recycle()
                }
                return true
            }
            return superDispatcher.superDispatch(rawEvent)
        }

        return bridge.dispatchFilteredMotionEvents(
            hostView = rootView,
            rawEvent = rawEvent,
            canvasTouchConsumer = { cleanSinglePointerEvent ->
                superDispatcher.superDispatch(cleanSinglePointerEvent)
            },
            onRollbackGhostStroke = { desc ->
                internalListener.onStylusStrokeCancel(
                    bridge.arbiter.activePenId,
                    StrokeCancelReason.GHOST_PREEMPTED,
                    desc
                )
            },
            onUndo = {
                internalListener.onTwoFingerTapUndo()
            },
            onRedo = {
                internalListener.onThreeFingerTapRedo()
            }
        )
    }

    @Suppress("UNCHECKED_CAST")
    fun handleMethodCall(method: String, arguments: Any?): Any? {
        val args = arguments as? Map<String, Any?> ?: emptyMap()
        return when (method) {
            "getTelemetry" -> telemetryToMap()

            "updateConfig" -> {
                palmGuardEnabled = args["enabled"] as? Boolean ?: true
                val penOnly = args["penOnlyMode"] as? Boolean ?: true
                val rawSens = (args["sensitivity"] as? Number)?.toFloat() ?: 0.65f
                val level = if (rawSens <= 1.0f) {
                    (rawSens * 5f).toInt().coerceIn(1, 5)
                } else {
                    rawSens.toInt().coerceIn(1, 5)
                }
                bridge.profile.sensitivityLevel = level
                val postureCode = (args["postureCode"] as? Number)?.toInt() ?: 0
                val handedness = when (postureCode) {
                    0 -> HandednessMode.RIGHT_DIAGONAL
                    1 -> HandednessMode.RIGHT_HORIZONTAL
                    2, 3 -> HandednessMode.LEFT_DIAGONAL
                    4 -> HandednessMode.AREA_ONLY
                    5 -> HandednessMode.RIGHT_DIAGONAL
                    else -> HandednessMode.fromNameOrDefault(args["handednessMode"] as? String)
                }
                bridge.profile.handednessMode = handedness
                bridge.profile.fingerActionMode = if (penOnly) {
                    FingerActionMode.PAN_CANVAS
                } else {
                    FingerActionMode.WRITE_WITH_FINGER
                }
                bridge.savePreferences(activity)
                telemetryToMap()
            }

            "setCanvasInteractive" -> {
                canvasInteractive = args["interactive"] as? Boolean ?: true
                if (!canvasInteractive) {
                    bridge.reset()
                }
                telemetryToMap()
            }

            "setFilterBeforeFlutter" -> {
                filterMotionEventsBeforeFlutter = args["enabled"] as? Boolean ?: false
                telemetryToMap()
            }

            "setImmersiveSystemBars" -> {
                val immersive = args["immersive"] as? Boolean ?: false
                configureTransientSystemBars(immersive)
                telemetryToMap()
            }

            "setUiRegions" -> {
                val rawList = args["regions"] as? List<*> ?: emptyList<Any>()
                val density = bridge.displayProfile.density
                val regions = rawList.mapNotNull { item ->
                    val m = item as? Map<*, *> ?: return@mapNotNull null
                    val left = ((m["left"] as? Number)?.toFloat() ?: return@mapNotNull null) * density
                    val top = ((m["top"] as? Number)?.toFloat() ?: return@mapNotNull null) * density
                    val right = ((m["right"] as? Number)?.toFloat() ?: return@mapNotNull null) * density
                    val bottom = ((m["bottom"] as? Number)?.toFloat() ?: return@mapNotNull null) * density
                    PalmRect(left, top, right, bottom)
                }
                bridge.setUiRegions(regions)
                telemetryToMap()
            }

            "setSensitivity" -> {
                val level = (args["level"] as? Number)?.toInt() ?: 3
                bridge.profile.sensitivityLevel = level
                bridge.savePreferences(activity)
                telemetryToMap()
            }

            "setHandedness" -> {
                val modeName = args["mode"] as? String
                bridge.profile.handednessMode = HandednessMode.fromNameOrDefault(modeName)
                bridge.savePreferences(activity)
                telemetryToMap()
            }

            "setFingerActionMode" -> {
                val modeName = args["mode"] as? String
                when (modeName) {
                    "PAN_AND_ZOOM_ONLY", "PEN_ONLY_PAN" ->
                        bridge.profile.fingerActionMode = FingerActionMode.PAN_CANVAS
                    "ALL_ALLOWED", "ALLOW_FINGER_WRITE" ->
                        bridge.profile.fingerActionMode = FingerActionMode.WRITE_WITH_FINGER
                    else -> {
                        FingerActionMode.entries.firstOrNull { it.name == modeName }?.let {
                            bridge.profile.fingerActionMode = it
                        }
                    }
                }
                bridge.savePreferences(activity)
                telemetryToMap()
            }

            "setPalmShield" -> {
                val enabled = args["enabled"] as? Boolean ?: bridge.palmShield.enabled
                val heightDp = (args["heightDp"] as? Number)?.toFloat() ?: bridge.palmShield.heightDp
                val modeName = args["mode"] as? String
                bridge.palmShield.enabled = enabled
                bridge.palmShield.heightDp = heightDp
                if (modeName != null) {
                    ShieldMode.entries.firstOrNull { it.name == modeName }?.let {
                        bridge.palmShield.switchMode(it)
                    }
                }
                bridge.savePreferences(activity)
                telemetryToMap()
            }

            "calibrateFromSamples" -> {
                val penList = (args["penSamplesMm"] as? List<*>)
                    ?.mapNotNull { (it as? Number)?.toFloat() }
                    ?: emptyList()
                val palmList = (args["palmSamplesMm"] as? List<*>)
                    ?.mapNotNull { (it as? Number)?.toFloat() }
                    ?: emptyList()
                val result = bridge.profile.calibrateFromSamples(penList, palmList)
                if (result.success) {
                    bridge.savePreferences(activity, immediate = true)
                }
                mapOf(
                    "success" to result.success,
                    "penMaxMm" to result.penMaxMm,
                    "palmHardMinMm" to result.palmHardMinMm,
                    "penMeanMm" to result.penMeanMm,
                    "palmMinMm" to result.palmMinMm,
                    "message" to result.message
                )
            }

            "resetToPreset" -> {
                CalibrationPreferences.clear(activity, bridge.profile, bridge.palmShield)
                telemetryToMap()
            }

            else -> null
        }
    }

    fun telemetryToMap(): Map<String, Any?> {
        val t = bridge.telemetry
        return mapOf(
            "state" to t.state.name,
            "stateLabel" to t.state.label,
            "lastDecision" to t.lastDecision,
            "activePenPointerId" to bridge.arbiter.activePenId,
            "candidateDiameterMm" to t.candidateDiameterMm,
            "penMaxThresholdMm" to t.penMaxThresholdMm,
            "palmHardThresholdMm" to t.palmHardThresholdMm,
            "eccentricity" to t.eccentricity,
            "maxEccentricity" to t.maxEccentricity,
            "velocityDpPerSec" to t.velocityDpPerSec,
            "rejectedPalmCount" to t.rejectedPalmCount,
            "sensitivityLevel" to bridge.profile.sensitivityLevel,
            "handednessMode" to bridge.profile.handednessMode.name,
            "fingerActionMode" to bridge.profile.fingerActionMode.name,
            "shieldEnabled" to bridge.palmShield.enabled,
            "shieldHeightDp" to bridge.palmShield.heightDp,
            "shieldMode" to bridge.palmShield.mode.name,
            "isCalibrated" to bridge.profile.isCalibrated,
            "motionOnlyMode" to t.motionOnlyMode,
            "xdpi" to bridge.displayProfile.xdpi,
            "density" to bridge.displayProfile.density
        )
    }
}
