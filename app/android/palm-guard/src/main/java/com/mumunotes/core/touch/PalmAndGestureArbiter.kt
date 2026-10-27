package com.mumunotes.core.touch

import android.view.MotionEvent
import com.mumunotes.core.touch.model.ArbiterOutcome
import com.mumunotes.core.touch.model.CommitReason
import com.mumunotes.core.touch.model.DispatchDecision
import com.mumunotes.core.touch.model.EngineState
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.GestureDescriptor
import com.mumunotes.core.touch.model.HandednessMode
import com.mumunotes.core.touch.model.PalmAnchor
import com.mumunotes.core.touch.model.PalmAnchorSource
import com.mumunotes.core.touch.model.PalmContactRecord
import com.mumunotes.core.touch.model.PalmRect
import com.mumunotes.core.touch.model.PalmRejectReason
import com.mumunotes.core.touch.model.RollbackDescriptor
import com.mumunotes.core.touch.model.StrokeCancelReason
import com.mumunotes.core.touch.model.TouchAction
import com.mumunotes.core.touch.model.TouchFeatures
import com.mumunotes.core.touch.model.TouchPacket
import com.mumunotes.core.touch.model.TouchTelemetry
import com.mumunotes.core.touch.model.TouchTrack
import kotlin.math.hypot
import kotlin.math.max

/**
 * 四级流水线 **Stage 3 — 多模态分类决策与多指冲突仲裁器 (PalmAndGestureArbiter)**。
 *
 * 核心增强与多模态防误触特性：
 * 1. **主动笔悬停/落笔全屏护盾冷却期（Stylus Temporal Shield）**：当检测到硬件 `TOOL_TYPE_STYLUS` / `TOOL_TYPE_ERASER`
 *    悬停或落笔时，激活默认 `400ms` 的冷却窗口（[stylusCooldownWindowMs]），在此窗口内严格拦截一切单指/手掌误触。
 * 2. **手掌几何形态学判定（Morphology Blob & Edge Guard）**：结合接触长短轴偏心率、面积快速膨胀率（`majorGrowthRateMmPerSec > 18.0mm/s`
 *    且低速 `velocityMmPerSec < 25.0mm/s` 的鱼际压屏过程）以及屏幕四周 `8.5mm` 边缘防误触带（[edgeGuardWidthMm]），
 *    精准剥离手掌倚靠并登记动态包络足迹（[VirtualPalmShield.registerPalmFootprint]）。
 * 3. **8~12ms 微延迟判定窗口（Hold Buffer）**：在初始前 2 个采样点（`< 12ms`）若接触面积处于临界区（`>= 0.78 * limit`），
 *    返回 [DispatchDecision.HoldPending] 暂缓派发，等待下一帧确认面积变化。
 * 4. **通用电容笔 7 维特征与 160ms 空间几何抢占回滚**：完整支持普通非协议电容笔（`TOOL_TYPE_FINGER`）的四阶段仲裁、
 *    双指撤销/三指重做手势隔离与系统三指截屏 `ACTION_CANCEL` 防丢字保护。
 */
class PalmAndGestureArbiter(
    var profile: AdaptiveThresholdProfile,
    var displayProfile: DisplayProfile = profile.displayProfile,
    val palmShield: VirtualPalmShield = VirtualPalmShield()
) {
    constructor(
        displayProfile: DisplayProfile,
        thresholdProfile: AdaptiveThresholdProfile,
        palmShield: VirtualPalmShield
    ) : this(
        profile = thresholdProfile,
        displayProfile = displayProfile,
        palmShield = palmShield
    )

    private val thresholdProfile: AdaptiveThresholdProfile
        get() = profile

    private val extractor = TouchFeatureExtractor(displayProfile)
    private val density: Float get() = displayProfile.density

    // ---------------- 主动笔冷却护盾与边缘防误触带 ----------------
    /** 主动笔最后一次活动时间戳（含 HOVER 与 TOUCH） */
    var lastStylusActiveTimeMs: Long = -1L
        private set

    /** 主动笔提笔后的防误触冷却窗口（默认 400ms 内拒绝一切单指误触） */
    var stylusCooldownWindowMs: Long = 400L

    /** 边缘拒识带宽度（毫米） */
    var edgeGuardWidthMm: Float = 8.5f

    // ---------------- 触点分类状态 ----------------
    private val rejectedPointers = LinkedHashSet<Int>()
    private val tracks = HashMap<Int, TouchTrack>()
    private val downTimes = HashMap<Int, Long>()
    private val lastFeatures = HashMap<Int, TouchFeatures>()

    private var activePenPointerId: Int = TouchPacket.INVALID
    private var palmAnchor: PalmAnchor? = null
    private var engineState: EngineState = EngineState.IDLE
    private var rejectedPalmCount: Int = 0
    private var lastDecisionLabel: String = "待机"
    private val rejectionRecords = ArrayDeque<PalmContactRecord>()

    // ---------------- 区域配置 ----------------
    private var uiRegions: List<PalmRect> = emptyList()
    private var palmShieldRegion: PalmRect? = null

    // ---------------- 多指手势 ----------------
    private var gesturePointerIds = LinkedHashSet<Int>()
    private var gestureStartTimeMs = 0L
    private var gestureMaxPathDp = 0f
    private var gestureEntryPointerCount = 0
    private var lastGestureAngleDeg = 0f
    private var hasLastGestureAngle = false
    private var lastGesture: GestureDescriptor = GestureDescriptor.NONE

    // ---------------- 单指漫游 ----------------
    private var fingerPanPointerId: Int = TouchPacket.INVALID
    private var fingerPanLastX = 0f
    private var fingerPanLastY = 0f

    private var currentTelemetry: TouchTelemetry = TouchTelemetry.EMPTY

    /** 累计处理的 MotionEvent 帧数 */
    var packetCount: Long = 0L
        private set

    /** 累计解包采样点数 */
    var sampleCount: Long = 0L
        private set

    // ==================================================================
    //  对外只读状态
    // ==================================================================

    val telemetry: TouchTelemetry get() = currentTelemetry
    val state: EngineState get() = engineState
    val activePenId: Int get() = activePenPointerId
    val anchor: PalmAnchor? get() = palmAnchor
    val rejectedPointerCount: Int get() = rejectedPointers.size

    /** 当前是否某 pointerId 已被标记为拒绝触点 */
    fun isPointerRejected(pointerId: Int): Boolean = pointerId in rejectedPointers

    /** 手掌误触记录快照（供热力诊断图层渲染） */
    val rejectionSnapshot: List<PalmContactRecord> get() = rejectionRecords.toList()

    val isWritingLocked: Boolean
        get() = engineState == EngineState.CANDIDATE_BUFFER || engineState == EngineState.WRITING_LOCKED

    fun currentTrack(pointerId: Int): TouchTrack? = tracks[pointerId]

    // ==================================================================
    //  多模态单轨迹直接评估接口（供 PalmGuardTouchBridge 拦截器直接调用）
    // ==================================================================

    fun onStylusActivity(timestampMs: Long, x: Float, y: Float) {
        lastStylusActiveTimeMs = timestampMs
        palmShield.AnchorStylus(x, y, timestampMs)
    }

    fun evaluateTrack(
        track: TouchTrack,
        features: TouchFeatures,
        fingerMode: FingerActionMode,
        currentTimeMs: Long
    ): DispatchDecision {
        // 1. 主动笔（Stylus / Eraser）无条件立即放行，并更新护盾锚点
        if (track.toolType == MotionEvent.TOOL_TYPE_STYLUS ||
            track.toolType == MotionEvent.TOOL_TYPE_ERASER
        ) {
            onStylusActivity(currentTimeMs, features.latestX, features.latestY)
            return DispatchDecision.AllowStylus(track.pointerId)
        }

        // 2. 若当前处于主动笔书写期或提笔冷却期内，严格拦截所有非笔触控
        val isStylusRecentlyActive = lastStylusActiveTimeMs > 0 &&
            (currentTimeMs - lastStylusActiveTimeMs) <= stylusCooldownWindowMs
        if (isStylusRecentlyActive || palmShield.isInsidePalmZone(features.latestX, features.latestY, currentTimeMs)) {
            return DispatchDecision.RejectPalm(
                pointerId = track.pointerId,
                reason = "StylusActiveOrPalmShieldZone",
                shouldCancelExisting = track.wasDispatched
            )
        }

        // 3. 物理尺寸与形态学特征判定：大接触轴、高面积膨胀率、低速大斑块
        val majorMm = displayProfile.pxToMm(features.maxTouchMajorPx)
        val minorMm = displayProfile.pxToMm(max(features.minTouchMinorPx, 1f))
        val aspectRatio = majorMm / minorMm.coerceAtLeast(0.5f)

        val dynamicMajorLimitMm = thresholdProfile.palmTouchMajorThresholdMm
        val isLargeContact = majorMm >= dynamicMajorLimitMm ||
            features.normalizedSize >= thresholdProfile.palmSizeThreshold

        // 面积快速膨胀但质心几乎不移动 = 典型手掌鱼际压屏过程
        val isExpandingStationaryBlob = features.majorGrowthRateMmPerSec > 18.0f &&
            features.velocityMmPerSec < 25.0f

        // 屏幕边缘手掌倚靠判定
        val isInEdgeZone = displayProfile.isNearScreenEdge(
            xPx = features.latestX,
            yPx = features.latestY,
            marginMm = edgeGuardWidthMm
        ) && features.velocityMmPerSec < 40.0f

        if (isLargeContact || isExpandingStationaryBlob || (isInEdgeZone && majorMm > dynamicMajorLimitMm * 0.72f)) {
            palmShield.registerPalmFootprint(
                x = features.latestX,
                y = features.latestY,
                radiusPx = max(features.maxTouchMajorPx * 1.35f, displayProfile.mmToPx(22f)),
                timestampMs = currentTimeMs
            )
            return DispatchDecision.RejectPalm(
                pointerId = track.pointerId,
                reason = "MorphologyPalm(major=${"%.1f".format(majorMm)}mm, ratio=${"%.1f".format(aspectRatio)})",
                shouldCancelExisting = track.wasDispatched
            )
        }

        // 4. 在初始前 2 个采样点（且持续时间 < 12ms）若特征处于临界区，进入 Hold 等待更多样本
        if (track.sampleCount < 3 &&
            (currentTimeMs - track.startTimeMs) < 12L &&
            majorMm >= dynamicMajorLimitMm * 0.78f
        ) {
            return DispatchDecision.HoldPending(track.pointerId)
        }

        // 5. 若是通用电容笔尖尺寸（majorMm <= penMaxMm），始终放行书写
        if (majorMm <= thresholdProfile.penMaxMm) {
            return DispatchDecision.AllowFingerDraw(track.pointerId)
        }

        // 6. 根据用户手指模式（禁用手指写字 / 仅平移缩放 / 允许手指绘画）返回决策
        return when (fingerMode) {
            FingerActionMode.REJECT_FINGERS -> DispatchDecision.RejectPalm(
                pointerId = track.pointerId,
                reason = "FingerDisabledInPenOnlyMode",
                shouldCancelExisting = track.wasDispatched
            )
            FingerActionMode.PAN_CANVAS -> DispatchDecision.AllowGestureOnly(track.pointerId)
            FingerActionMode.WRITE_WITH_FINGER -> DispatchDecision.AllowFingerDraw(track.pointerId)
        }
    }

    // ==================================================================
    //  配置与尺寸动态同步
    // ==================================================================

    fun updateDisplayProfile(newDisplayProfile: DisplayProfile) {
        displayProfile = newDisplayProfile
        profile.displayProfile = newDisplayProfile
        extractor.displayProfile = newDisplayProfile
        palmShield.updateViewportBounds(
            widthPx = newDisplayProfile.widthPx,
            heightPx = newDisplayProfile.heightPx,
            density = newDisplayProfile.density
        )
    }

    fun configureRegions(uiRegions: List<PalmRect>, palmShield: PalmRect?) {
        this.uiRegions = uiRegions
        this.palmShieldRegion = palmShield
    }

    fun setHandednessMode(mode: HandednessMode) {
        profile.handednessMode = mode
    }

    /** 清空全部瞬时状态（画布尺寸变化 / 页面切换 / 引擎复位） */
    fun reset() {
        rejectedPointers.clear()
        tracks.clear()
        downTimes.clear()
        lastFeatures.clear()
        activePenPointerId = TouchPacket.INVALID
        palmAnchor = null
        engineState = EngineState.IDLE
        lastDecisionLabel = "待机"
        gesturePointerIds.clear()
        gestureStartTimeMs = 0L
        gestureMaxPathDp = 0f
        gestureEntryPointerCount = 0
        hasLastGestureAngle = false
        lastGesture = GestureDescriptor.NONE
        fingerPanPointerId = TouchPacket.INVALID
        currentTelemetry = TouchTelemetry.EMPTY
    }

    /** 清空误触统计与热力图记录 */
    fun clearRejectionHistory() {
        rejectionRecords.clear()
        rejectedPalmCount = 0
    }

    /** 清理超过 [timeoutMs]（默认 450ms）未更新的残留轨迹 */
    fun pruneStaleTracks(currentTimeMs: Long, timeoutMs: Long = 450L) {
        val staleIds = tracks.values
            .filter { it.isStale(currentTimeMs, timeoutMs) }
            .map { it.pointerId }
        for (pid in staleIds) {
            tracks.remove(pid)
            downTimes.remove(pid)
            lastFeatures.remove(pid)
            gesturePointerIds.remove(pid)
            if (activePenPointerId == pid) {
                clearActivePen()
            }
            if (fingerPanPointerId == pid) {
                fingerPanPointerId = TouchPacket.INVALID
            }
        }
    }

    // ==================================================================
    //  主入口
    // ==================================================================

    fun process(packet: TouchPacket): ArbiterOutcome {
        packetCount++
        sampleCount += packet.points.values.sumOf { it.size }

        if (packet.action == TouchAction.DOWN) {
            pruneStaleTracks(packet.eventTimeMs, timeoutMs = 450L)
        }

        val decisions = ArrayList<DispatchDecision>(4)
        when {
            TouchAction.isDown(packet.action) -> handlePointerDown(packet, decisions)
            packet.action == TouchAction.MOVE -> handleMove(packet, decisions)
            TouchAction.isUp(packet.action) -> handlePointerUp(packet, decisions)
            packet.action == TouchAction.CANCEL -> handleCancel(packet, decisions)
            else -> Unit
        }

        updateTelemetry(packet)

        val primary = decisions.firstOrNull() ?: DispatchDecision.NoOp
        return ArbiterOutcome(primary = primary, decisions = decisions)
    }

    // ==================================================================
    //  阶段 1~5：ACTION_DOWN / ACTION_POINTER_DOWN
    // ==================================================================

    private fun handlePointerDown(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val pid = packet.actionPointerId
        if (pid == TouchPacket.INVALID) return
        val samples = packet.pointsOf(pid)
        if (samples.isEmpty()) return

        // 清理该 pointerId 可能残留的历史状态（防范 Android 复用 pointerId）
        rejectedPointers.remove(pid)
        tracks.remove(pid)
        downTimes.remove(pid)

        val featuresList = extractor.extractSequence(samples, emptyList(), profile.handednessMode)
        val feat = featuresList.last()
        lastFeatures[pid] = feat

        // 若是硬件主动笔（Stylus / Eraser），立即更新时间护盾锚点并放行
        if (feat.toolType == MotionEvent.TOOL_TYPE_STYLUS ||
            feat.toolType == MotionEvent.TOOL_TYPE_ERASER
        ) {
            onStylusActivity(packet.eventTimeMs, feat.x, feat.y)
        } else if (lastStylusActiveTimeMs > 0 &&
            (packet.eventTimeMs - lastStylusActiveTimeMs) <= stylusCooldownWindowMs
        ) {
            markRejected(pid)
            recordRejection(feat, PalmRejectReason.STYLUS_ACTIVE_SHIELD, PalmAnchorSource.MID_STROKE)
            out += rejectDecision(pid, feat, PalmRejectReason.STYLUS_ACTIVE_SHIELD)
            label("主动笔冷却护盾拦截")
            return
        }

        val areaDimensionUsable = packet.diameterReportAvailable

        // ---- 阶段 1：区域预检（强书写锁定态下让位于阶段 5 的并发免疫） ----
        if (engineState != EngineState.WRITING_LOCKED) {
            if (uiRegions.any { it.contains(feat.x, feat.y) }) {
                markRejected(pid)
                out += DispatchDecision.FingerUiTap(pid, feat.x, feat.y)
                label("UI 热区点击")
                return
            }
            val shield = palmShieldRegion
            if ((shield != null && shield.contains(feat.x, feat.y)) ||
                palmShield.isInsidePalmZone(feat.x, feat.y, packet.eventTimeMs)
            ) {
                markRejected(pid)
                registerAnchor(pid, feat, PalmAnchorSource.VIRTUAL_SHIELD)
                recordRejection(feat, PalmRejectReason.VIRTUAL_SHIELD, PalmAnchorSource.VIRTUAL_SHIELD)
                out += DispatchDecision.PalmShieldAbsorbed(pid, feat.x, feat.y)
                label("虚拟手垫吸收")
                return
            }
        }

        // ---- 阶段 2：0ms 瞬时形态硬阈值初筛（必须在多指手势判断之前执行，防止大掌根混入手势！） ----
        if (areaDimensionUsable) {
            if (feat.diameterMm > profile.palmHardMinMm) {
                markRejected(pid)
                registerAnchor(pid, feat, PalmAnchorSource.HARD_THRESHOLD)
                palmShield.registerPalmFootprint(
                    x = feat.x,
                    y = feat.y,
                    radiusPx = max(feat.rawTouchMajorPx * 1.35f, displayProfile.mmToPx(22f)),
                    timestampMs = packet.eventTimeMs
                )
                recordRejection(feat, PalmRejectReason.DIAMETER_HARD, PalmAnchorSource.HARD_THRESHOLD)
                out += rejectDecision(pid, feat, PalmRejectReason.DIAMETER_HARD)
                label("掌根面积硬拦截")
                return
            }
            if (feat.eccentricity > profile.maxEccentricity) {
                markRejected(pid)
                registerAnchor(pid, feat, PalmAnchorSource.ECCENTRICITY)
                palmShield.registerPalmFootprint(
                    x = feat.x,
                    y = feat.y,
                    radiusPx = max(feat.rawTouchMajorPx * 1.35f, displayProfile.mmToPx(22f)),
                    timestampMs = packet.eventTimeMs
                )
                recordRejection(feat, PalmRejectReason.ECCENTRICITY, PalmAnchorSource.ECCENTRICITY)
                out += rejectDecision(pid, feat, PalmRejectReason.ECCENTRICITY)
                label("狭长侧掌偏心率拦截")
                return
            }
            // 屏幕边缘手掌倚靠判定（Edge Guard）
            val isInEdgeZone = displayProfile.isNearScreenEdge(
                xPx = feat.x,
                yPx = feat.y,
                marginMm = edgeGuardWidthMm
            ) && feat.velocityMmPerSec < 40.0f && feat.diameterMm > profile.palmHardMinMm * 0.72f
            if (isInEdgeZone) {
                markRejected(pid)
                registerAnchor(pid, feat, PalmAnchorSource.HARD_THRESHOLD)
                palmShield.registerPalmFootprint(
                    x = feat.x,
                    y = feat.y,
                    radiusPx = max(feat.rawTouchMajorPx * 1.35f, displayProfile.mmToPx(22f)),
                    timestampMs = packet.eventTimeMs
                )
                recordRejection(feat, PalmRejectReason.SCREEN_EDGE_GUARD, PalmAnchorSource.HARD_THRESHOLD)
                out += rejectDecision(pid, feat, PalmRejectReason.SCREEN_EDGE_GUARD)
                label("屏幕边缘防误触带拦截")
                return
            }
        }
        if (engineState != EngineState.WRITING_LOCKED) {
            val overrun = trailingEdgeOverrun(feat, pid)
            if (overrun != null) {
                markRejected(pid)
                recordRejection(feat, PalmRejectReason.TRAILING_EDGE, PalmAnchorSource.TRAILING_EDGE)
                out += rejectDecision(pid, feat, PalmRejectReason.TRAILING_EDGE)
                label("掌根右下余波拦截")
                return
            }
        }

        // ---- 多指手势进行中：仅允许非掌根的合法新触点加入手势集合 ----
        if (engineState == EngineState.GESTURE_LOCKED) {
            downTimes[pid] = samples.first().timeMs
            tracks[pid] = TouchTrack(pointerId = pid, startFeatures = feat, startTimeMs = feat.timeMs, density = density)
            gesturePointerIds.add(pid)
            gestureEntryPointerCount = max(gestureEntryPointerCount, gesturePointerIds.size)
            val gesture = computeGestureDescriptor(packet)
            lastGesture = gesture
            out += DispatchDecision.UpdateMultiFingerGesture(gesture)
            label("手势追加触点")
            return
        }

        // ---- 阶段 5 前置：强书写锁定态并发多点绝对免疫 ----
        val penTrack = activeTrack()
        if (engineState == EngineState.WRITING_LOCKED && penTrack != null &&
            !penTrack.isPreemptable(packet.eventTimeMs, profile.preemptWindowMs, profile.preemptMaxPathDp)
        ) {
            markRejected(pid)
            recordRejection(feat, PalmRejectReason.MID_STROKE_IMMUNITY, PalmAnchorSource.MID_STROKE)
            out += rejectDecision(pid, feat, PalmRejectReason.MID_STROKE_IMMUNITY)
            label("书写中并发免疫")
            return
        }

        // ---- 阶段 4：160ms 空间几何抢占与幽灵笔迹回滚 ----
        if (penTrack != null && penTrack.pointerId != pid &&
            penTrack.isPreemptable(packet.eventTimeMs, profile.preemptWindowMs, profile.preemptMaxPathDp) &&
            (feat.diameterMm <= profile.penMaxMm || !packet.diameterReportAvailable) &&
            profile.handednessMode.spatialEnabled
        ) {
            val advantageDp = extractor.geometricPriorityAdvantageDp(
                newSpatialScore = feat.spatialScore,
                oldSpatialScore = penTrack.startSpatialScore,
                requiredMarginDp = profile.geometricPreemptMarginDp
            )
            if (advantageDp != null) {
                downTimes[pid] = samples.first().timeMs
                performGhostRollback(packet, penTrack, pid, feat, advantageDp, out)
                return
            }
        }

        // ---- 只有通过了阶段 1/2/4/5 的非掌根触点，才正式记入 downTimes 与 tracks ----
        downTimes[pid] = samples.first().timeMs
        val newTrack = TouchTrack(pointerId = pid, startFeatures = feat, startTimeMs = feat.timeMs, density = density)
        tracks[pid] = newTrack

        // ---- 阶段 3：35ms 同步观察窗 —— 多指手势仲裁 ----
        if (shouldEnterMultiFingerGesture(packet)) {
            enterMultiFingerGesture(packet, out)
            return
        }

        // ---- 规则 E：笔尖尺寸触点 → 进入候选观察窗（CANDIDATE_BUFFER） ----
        val penSized = if (areaDimensionUsable) {
            feat.diameterMm <= profile.penMaxMm
        } else {
            activePenPointerId == TouchPacket.INVALID
        }
        val fingerSized = areaDimensionUsable &&
            feat.withinFingerDiameter(profile.penMaxMm, profile.palmHardMinMm)
        val fingerStrokeAllowed = profile.fingerActionMode.allowsFingerStroke && fingerSized

        if (penSized || fingerStrokeAllowed) {
            if (activePenPointerId == TouchPacket.INVALID) {
                activePenPointerId = pid
                newTrack.wasDispatched = true
                engineState = EngineState.CANDIDATE_BUFFER
                out += DispatchDecision.StartStylusStroke(pid, feat)
                label(if (penSized) "笔尖候选建立" else "手指书写候选建立")
                return
            }
            // 已有一支活动笔尖且未能赢得几何抢占 → 第 2 个笔尖尺寸触点判为掌侧边缘
            markRejected(pid)
            recordRejection(feat, PalmRejectReason.MID_STROKE_IMMUNITY, PalmAnchorSource.MID_STROKE)
            out += rejectDecision(pid, feat, PalmRejectReason.MID_STROKE_IMMUNITY)
            label("并发笔尖尺寸触点被吞没")
            return
        }

        // ---- 规则 E 分支：手指尺寸触点 → 单指漫游或按误触拒绝 ----
        val canPan = activePenPointerId == TouchPacket.INVALID &&
            profile.fingerActionMode.allowsFingerPan
        if (canPan) {
            fingerPanPointerId = pid
            fingerPanLastX = feat.x
            fingerPanLastY = feat.y
            newTrack.wasDispatched = true
            engineState = EngineState.FINGER_PANNING
            out += DispatchDecision.StartFingerPan(pid, feat)
            label("单指漫游启动")
            return
        }

        markRejected(pid)
        recordRejection(feat, PalmRejectReason.FINGER_RANGE_NO_PAN, PalmAnchorSource.MID_STROKE)
        out += rejectDecision(pid, feat, PalmRejectReason.FINGER_RANGE_NO_PAN)
        label("手指尺寸误触拒绝")
    }

    private fun markRejected(pid: Int) {
        rejectedPointers.add(pid)
        tracks.remove(pid)
        downTimes.remove(pid)
    }

    private fun performGhostRollback(
        packet: TouchPacket,
        ghostTrack: TouchTrack,
        newPointerId: Int,
        newFeatures: TouchFeatures,
        advantageDp: Float,
        out: MutableList<DispatchDecision>
    ) {
        val ghostPointerId = ghostTrack.pointerId
        val ghostPathDp = ghostTrack.totalPathDp
        val ghostAliveMs = ghostTrack.aliveMs(packet.eventTimeMs)

        markRejected(ghostPointerId)
        registerAnchor(ghostPointerId, ghostTrack.startFeatures, PalmAnchorSource.GHOST_ROLLBACK)
        recordRejection(
            ghostTrack.startFeatures,
            PalmRejectReason.GHOST_ROLLBACK,
            PalmAnchorSource.GHOST_ROLLBACK
        )

        out += DispatchDecision.CancelStroke(
            pointerId = ghostPointerId,
            reason = StrokeCancelReason.GHOST_PREEMPTED,
            descriptor = RollbackDescriptor(
                cancelledPathDp = ghostPathDp,
                cancelledAliveMs = ghostAliveMs,
                tailTruncateMs = 0L
            )
        )

        activePenPointerId = newPointerId
        tracks[newPointerId] = TouchTrack(
            pointerId = newPointerId,
            startFeatures = newFeatures,
            startTimeMs = newFeatures.timeMs,
            density = density
        ).also {
            it.promotedToWritingLocked = true
            it.wasDispatched = true
        }
        engineState = EngineState.WRITING_LOCKED

        out += DispatchDecision.RollbackAndSwitchStylus(
            cancelledPointerId = ghostPointerId,
            newStylusPointerId = newPointerId,
            startPoint = newFeatures,
            rollback = RollbackDescriptor(
                cancelledPathDp = ghostPathDp,
                cancelledAliveMs = ghostAliveMs,
                tailTruncateMs = 0L
            )
        )
        label("几何抢占 %.0fdp：真笔尖接管".format(advantageDp))
    }

    // ==================================================================
    //  ACTION_MOVE
    // ==================================================================

    private fun handleMove(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        when (engineState) {
            EngineState.GESTURE_LOCKED -> {
                refreshLastFeatures(packet)
                updateGesture(packet, out)
                return
            }

            EngineState.FINGER_PANNING -> {
                updateFingerPan(packet, out)
                return
            }

            else -> Unit
        }

        val pid = activePenPointerId
        if (pid == TouchPacket.INVALID) {
            refreshLastFeatures(packet)
            label("无活动笔迹")
            return
        }

        val samples = packet.pointsOf(pid)
        val track = tracks[pid]
        if (samples.isEmpty() || track == null) {
            if (track == null) clearActivePen()
            return
        }

        val featuresList = extractor.extractSequence(samples, trailOf(pid), profile.handednessMode)

        // ---- 动态面积膨胀拦截：前 80ms 内接触直径骤增，说明是手掌由虚到实的压实过程 ----
        val growthThresholdDp = profile.penMaxDp * profile.penMaxGrowthFactor
        val expansionCheckEnabled = packet.diameterReportAvailable
        for (feat in featuresList) {
            if (!expansionCheckEnabled) break
            val withinWindow = track.aliveMs(feat.timeMs) <= profile.expansionCancelWindowMs
            if (!withinWindow) break
            val growthExceeded = feat.diameterDp > growthThresholdDp
            val expansionExceeded = feat.areaExpansionDpPerMs > profile.expansionCancelDpPerMs
            val isStationaryBlob = feat.majorGrowthRateMmPerSec > 18.0f &&
                feat.velocityMmPerSec < 25.0f &&
                feat.diameterMm > profile.penMaxMm
            if (growthExceeded || expansionExceeded || isStationaryBlob) {
                val cancelledPid = pid
                val pathDp = track.totalPathDp
                val aliveMs = track.aliveMs(feat.timeMs)
                track.wasDispatched = false
                markRejected(cancelledPid)
                lastFeatures[cancelledPid] = feat
                registerAnchor(cancelledPid, feat, PalmAnchorSource.EXPANSION_CANCEL)
                palmShield.registerPalmFootprint(
                    x = feat.x,
                    y = feat.y,
                    radiusPx = max(feat.rawTouchMajorPx * 1.35f, displayProfile.mmToPx(22f)),
                    timestampMs = feat.timeMs
                )
                recordRejection(feat, PalmRejectReason.EXPANSION_GROWTH, PalmAnchorSource.EXPANSION_CANCEL)
                clearActivePen()
                out += DispatchDecision.CancelStroke(
                    pointerId = cancelledPid,
                    reason = StrokeCancelReason.EXPANSION_PALM,
                    descriptor = RollbackDescriptor(pathDp, aliveMs, 0L)
                )
                label("手掌压实膨胀拦截")
                return
            }
        }

        // ---- 追加原始高频采样并检测电容网格质心原地抖动 ----
        for (feat in featuresList) track.append(feat)
        lastFeatures[pid] = featuresList.last()

        if (!track.promotedToWritingLocked &&
            track.aliveMs(packet.eventTimeMs) <= profile.expansionCancelWindowMs &&
            track.isHighFrequencyCentroidJitter()
        ) {
            val cancelledPid = pid
            val pathDp = track.totalPathDp
            val aliveMs = track.aliveMs(packet.eventTimeMs)
            val lastFeat = track.lastFeatures
            track.wasDispatched = false
            markRejected(cancelledPid)
            registerAnchor(cancelledPid, lastFeat, PalmAnchorSource.EXPANSION_CANCEL)
            recordRejection(lastFeat, PalmRejectReason.CENTROID_JITTER, PalmAnchorSource.EXPANSION_CANCEL)
            clearActivePen()
            out += DispatchDecision.CancelStroke(
                pointerId = cancelledPid,
                reason = StrokeCancelReason.CENTROID_JITTER_PALM,
                descriptor = RollbackDescriptor(pathDp, aliveMs, 0L)
            )
            label("电容质心高频抖动拦截")
            return
        }

        // ---- 阶段 3 情况 C：候选晋升为强书写锁定（要求实际最大净偏离位移达标或稳定持续） ----
        if (!track.promotedToWritingLocked &&
            (track.aliveMs(packet.eventTimeMs) >= profile.candidateStablePromoteMs ||
                track.maxDisplacementDp >= profile.candidatePromotePathDp)
        ) {
            track.promotedToWritingLocked = true
            engineState = EngineState.WRITING_LOCKED
        }

        track.wasDispatched = true
        out += DispatchDecision.AppendStylusBatch(pid, featuresList)
        label("笔迹追加 %d 点".format(featuresList.size))
    }

    private fun updateFingerPan(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val pid = fingerPanPointerId
        if (pid == TouchPacket.INVALID) {
            engineState = EngineState.IDLE
            return
        }
        val samples = packet.pointsOf(pid)
        if (samples.isEmpty()) return
        val featuresList = extractor.extractSequence(samples, trailOf(pid), profile.handednessMode)
        val last = featuresList.last()

        val dx = last.x - fingerPanLastX
        val dy = last.y - fingerPanLastY
        fingerPanLastX = last.x
        fingerPanLastY = last.y
        lastFeatures[pid] = last
        tracks[pid]?.let { t -> featuresList.forEach { t.append(it) } }

        out += DispatchDecision.UpdateFingerPan(pid, dx, dy)
        label("单指漫游")
    }

    // ==================================================================
    //  ACTION_UP / ACTION_POINTER_UP
    // ==================================================================

    private fun handlePointerUp(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val pid = packet.actionPointerId

        if (pid == activePenPointerId) {
            val track = tracks[pid]
            val pathDp = track?.totalPathDp ?: 0f

            // ---- L3 Winsorized EMA 漂移补偿：仅对合法且足够长的笔迹学习 ----
            if (track != null &&
                packet.diameterReportAvailable &&
                track.qualifiesForOnlineCalibration(profile.onlineCalibrationMinPathDp) &&
                track.maxDiameterMm <= profile.penMaxMm
            ) {
                profile.updateOnlinePenStats(track.averageDiameterMm())
            }

            out += DispatchDecision.CommitStylusStroke(
                pointerId = pid,
                reason = CommitReason.POINTER_UP,
                totalPathDp = pathDp,
                tailTruncateMs = 0L
            )
            tracks.remove(pid)
            clearActivePen()
            label("笔迹提交")
        } else {
            tracks.remove(pid)
        }

        rejectedPointers.remove(pid)
        downTimes.remove(pid)
        lastFeatures.remove(pid)

        // 手掌锚点仅在其自身 pointerId 抬起时释放
        if (palmAnchor?.pointerId == pid) palmAnchor = null

        if (fingerPanPointerId == pid) {
            fingerPanPointerId = TouchPacket.INVALID
            if (engineState == EngineState.FINGER_PANNING) engineState = EngineState.IDLE
        }

        if (engineState == EngineState.GESTURE_LOCKED) {
            gesturePointerIds.remove(pid)
            val activeGestureRemaining = packet.pointerIds.count { id ->
                id != pid && id in gesturePointerIds && id !in rejectedPointers
            }
            if (gesturePointerIds.isEmpty() || activeGestureRemaining <= 0) {
                finishGesture(packet, out)
            }
        }
    }

    private fun finishGesture(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val durationMs = packet.eventTimeMs - gestureStartTimeMs
        val isQuickTap = durationMs <= profile.gestureTapMaxDurationMs &&
            gestureMaxPathDp <= profile.gestureTapMaxPathDp

        when {
            isQuickTap && gestureEntryPointerCount >= profile.systemGestureMinPointers -> {
                out += DispatchDecision.ThreeFingerTapRedo
                label("三指轻点重做")
            }

            isQuickTap && gestureEntryPointerCount == TWO_FINGER_TAP_POINTERS -> {
                out += DispatchDecision.TwoFingerTapUndo
                label("双指轻点撤销")
            }

            else -> label("手势结束")
        }

        gesturePointerIds.clear()
        gestureEntryPointerCount = 0
        gestureStartTimeMs = 0L
        gestureMaxPathDp = 0f
        hasLastGestureAngle = false
        lastGesture = GestureDescriptor.NONE
        engineState = EngineState.IDLE
    }

    // ==================================================================
    //  ACTION_CANCEL —— 系统三指手势防丢字保护
    // ==================================================================

    private fun handleCancel(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val pid = activePenPointerId
        if (pid != TouchPacket.INVALID) {
            val track = tracks[pid]
            val pathDp = track?.totalPathDp ?: 0f
            val aliveMs = track?.aliveMs(packet.eventTimeMs) ?: 0L

            if (track != null && track.qualifiesForCancelProtection(
                    profile.cancelProtectMinAliveMs,
                    profile.cancelProtectMinPathDp
                )
            ) {
                out += DispatchDecision.CommitStylusStroke(
                    pointerId = pid,
                    reason = CommitReason.SYSTEM_CANCEL_PARTIAL,
                    totalPathDp = pathDp,
                    tailTruncateMs = profile.cancelTailTruncateMs
                )
                label("系统手势打断：已保护性保存")
            } else {
                val pureSystemGesture = isPureSystemGesture(packet)
                out += DispatchDecision.CancelStroke(
                    pointerId = pid,
                    reason = StrokeCancelReason.SYSTEM_CANCEL_DISCARDED,
                    descriptor = RollbackDescriptor(pathDp, aliveMs, profile.cancelTailTruncateMs)
                )
                label(if (pureSystemGesture) "纯系统三指手势：清空笔迹" else "系统取消：丢弃短笔迹")
            }
        } else {
            label("系统取消")
        }

        val keepRejections = rejectionRecords.toList()
        val keepPalmCount = rejectedPalmCount
        reset()
        rejectionRecords.clear()
        rejectionRecords.addAll(keepRejections.takeLast(MAX_REJECTION_RECORDS))
        rejectedPalmCount = keepPalmCount
    }

    private fun isPureSystemGesture(packet: TouchPacket): Boolean {
        val nonRejectedIds = packet.pointerIds.filter { it !in rejectedPointers }
        if (nonRejectedIds.size < profile.systemGestureMinPointers) return false
        val aliveTimes = nonRejectedIds.map { pid ->
            val down = downTimes[pid] ?: return false
            packet.eventTimeMs - down
        }
        if (aliveTimes.any { it > profile.systemGestureMaxAliveMs }) return false

        val directions = nonRejectedIds.mapNotNull { pid -> directionOf(pid) }
        if (directions.size < 2) return true
        for (i in directions.indices) {
            for (j in i + 1 until directions.size) {
                val a = directions[i]
                val b = directions[j]
                val norm = (hypot(a[0], a[1]) * hypot(b[0], b[1]))
                if (norm <= 0f) continue
                val cosine = (a[0] * b[0] + a[1] * b[1]) / norm
                if (cosine < SAME_DIRECTION_MIN_COSINE) return false
            }
        }
        return true
    }

    private fun directionOf(pointerId: Int): FloatArray? {
        val track = tracks[pointerId] ?: return null
        val dx = track.lastFeatures.x - track.startX
        val dy = track.lastFeatures.y - track.startY
        if (hypot(dx, dy) < MIN_DIRECTION_LENGTH_PX) return null
        return floatArrayOf(dx, dy)
    }

    // ==================================================================
    //  多指手势（严格排除已拒绝的手掌触点）
    // ==================================================================

    private fun shouldEnterMultiFingerGesture(packet: TouchPacket): Boolean {
        val validPointerIds = packet.pointerIds.filter { it !in rejectedPointers }
        if (validPointerIds.size < 2) return false

        val penTrack = activeTrack()
        if (penTrack != null && penTrack.hasExceededLockThreshold(
                packet.eventTimeMs, profile.writingLockMs, profile.writingLockPathDp
            )
        ) {
            return false
        }

        val synchronized = synchronizedPointerIds(packet.eventTimeMs, validPointerIds)
        if (synchronized.size < 2) return false

        val spanDp = displayProfile.pxToDp(maxPairwiseSpanPx(synchronized))
        val allInFingerRange = synchronized.all { pid ->
            val f = lastFeatures[pid] ?: return@all false
            f.withinFingerDiameter(profile.penMaxMm, profile.palmHardMinMm)
        }
        val spanQualified = spanDp >= profile.gestureMinSpanDp
        val tripleOrMore = synchronized.size >= 3

        return allInFingerRange || spanQualified || tripleOrMore
    }

    private fun enterMultiFingerGesture(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        val candidatePid = activePenPointerId
        if (candidatePid != TouchPacket.INVALID) {
            val old = tracks[candidatePid]
            if (old != null) {
                old.wasDispatched = false
                out += DispatchDecision.CancelStroke(
                    pointerId = candidatePid,
                    reason = StrokeCancelReason.GESTURE_TAKEOVER,
                    descriptor = RollbackDescriptor(old.totalPathDp, old.aliveMs(packet.eventTimeMs), 0L)
                )
            }
            tracks.remove(candidatePid)
            clearActivePen()
        }

        val validPointerIds = packet.pointerIds.filter { it !in rejectedPointers }
        gesturePointerIds.clear()
        gesturePointerIds.addAll(synchronizedPointerIds(packet.eventTimeMs, validPointerIds))
        gestureEntryPointerCount = gesturePointerIds.size
        gestureStartTimeMs = packet.eventTimeMs
        gestureMaxPathDp = 0f
        hasLastGestureAngle = false

        engineState = EngineState.GESTURE_LOCKED
        val gesture = computeGestureDescriptor(packet)
        lastGesture = gesture
        out += DispatchDecision.SwitchToMultiFingerGesture(gesturePointerIds.toList(), gesture)
        label("多指手势接管")
    }

    private fun updateGesture(packet: TouchPacket, out: MutableList<DispatchDecision>) {
        for (pid in gesturePointerIds) {
            if (pid in rejectedPointers) continue
            val track = tracks[pid]
            val current = lastFeatures[pid]
            if (track != null && current != null) {
                val travelDp = displayProfile.pxToDp(
                    hypot(current.x - track.startX, current.y - track.startY)
                )
                gestureMaxPathDp = max(gestureMaxPathDp, travelDp)
            }
        }
        val gesture = computeGestureDescriptor(packet)
        lastGesture = gesture
        out += DispatchDecision.UpdateMultiFingerGesture(gesture)
        label("多指手势更新")
    }

    private fun computeGestureDescriptor(packet: TouchPacket): GestureDescriptor {
        val ids = packet.pointerIds.filter { it in gesturePointerIds && it !in rejectedPointers && lastFeatures[it] != null }
        if (ids.size < 2) return GestureDescriptor.NONE

        var sumX = 0f
        var sumY = 0f
        for (pid in ids) {
            val f = lastFeatures.getValue(pid)
            sumX += f.x
            sumY += f.y
        }
        val centroidX = sumX / ids.size
        val centroidY = sumY / ids.size

        var spanPx = 0f
        var farthestA = lastFeatures.getValue(ids[0])
        var farthestB = farthestA
        for (i in ids.indices) {
            for (j in i + 1 until ids.size) {
                val a = lastFeatures.getValue(ids[i])
                val b = lastFeatures.getValue(ids[j])
                val d = hypot(a.x - b.x, a.y - b.y)
                if (d > spanPx) {
                    spanPx = d
                    farthestA = a
                    farthestB = b
                }
            }
        }

        val angleDeg = Math.toDegrees(
            kotlin.math.atan2(
                (farthestB.y - farthestA.y).toDouble(),
                (farthestB.x - farthestA.x).toDouble()
            )
        ).toFloat()
        val rotationDelta = if (hasLastGestureAngle) normalizeAngleDeg(angleDeg - lastGestureAngleDeg) else 0f
        lastGestureAngleDeg = angleDeg
        hasLastGestureAngle = true

        return GestureDescriptor(
            pointerCount = ids.size,
            centroidX = centroidX,
            centroidY = centroidY,
            spanPx = spanPx,
            rotationDeltaDeg = rotationDelta,
            threeFingerTapCandidate = gestureEntryPointerCount >= profile.systemGestureMinPointers
        )
    }

    // ==================================================================
    //  工具
    // ==================================================================

    private fun activeTrack(): TouchTrack? =
        if (activePenPointerId == TouchPacket.INVALID) null else tracks[activePenPointerId]

    private fun clearActivePen() {
        activePenPointerId = TouchPacket.INVALID
        if (engineState == EngineState.WRITING_LOCKED || engineState == EngineState.CANDIDATE_BUFFER) {
            engineState = EngineState.IDLE
        }
    }

    private fun trailOf(pointerId: Int): List<TouchFeatures> {
        val track = tracks[pointerId] ?: return emptyList()
        val prev = track.previousFeatures
        return if (prev != null) listOf(prev, track.lastFeatures) else listOf(track.lastFeatures)
    }

    private fun refreshLastFeatures(packet: TouchPacket) {
        for (pid in packet.pointerIds) {
            if (pid in rejectedPointers) continue
            val samples = packet.pointsOf(pid)
            if (samples.isEmpty()) continue
            val featuresList = extractor.extractSequence(samples, trailOf(pid), profile.handednessMode)
            for (feat in featuresList) {
                tracks[pid]?.append(feat)
            }
            lastFeatures[pid] = featuresList.last()
        }
    }

    private fun registerAnchor(pointerId: Int, feat: TouchFeatures, source: PalmAnchorSource) {
        palmAnchor = PalmAnchor(
            pointerId = pointerId,
            x = feat.x,
            y = feat.y,
            diameterMm = feat.diameterMm,
            spatialScore = feat.spatialScore,
            timeMs = feat.timeMs,
            source = source
        )
    }

    private fun rejectDecision(
        pointerId: Int,
        feat: TouchFeatures,
        reason: PalmRejectReason,
        shouldCancelExisting: Boolean = false
    ) = DispatchDecision.RejectPalm(
        pointerId = pointerId,
        x = feat.x,
        y = feat.y,
        diameterMm = feat.diameterMm,
        eccentricity = feat.eccentricity,
        reason = reason,
        reasonText = reason.name,
        shouldCancelExisting = shouldCancelExisting
    )

    private fun recordRejection(
        feat: TouchFeatures,
        reason: PalmRejectReason,
        source: PalmAnchorSource
    ) {
        rejectedPalmCount++
        rejectionRecords.addLast(
            PalmContactRecord(
                x = feat.x,
                y = feat.y,
                timeMs = feat.timeMs,
                diameterMm = feat.diameterMm,
                eccentricity = feat.eccentricity,
                reason = reason,
                source = source
            )
        )
        while (rejectionRecords.size > MAX_REJECTION_RECORDS) {
            rejectionRecords.removeFirst()
        }
    }

    private fun trailingEdgeOverrun(feat: TouchFeatures, pointerId: Int): Float? {
        if (!profile.handednessMode.spatialEnabled) return null
        val anchorSnapshot = palmAnchor ?: return null
        if (anchorSnapshot.pointerId == pointerId) return null
        return extractor.trailingEdgeOverrunDp(
            features = feat,
            anchorSpatialScore = anchorSnapshot.spatialScore,
            anchorX = anchorSnapshot.x,
            anchorY = anchorSnapshot.y,
            marginDp = profile.trailingEdgeMarginDp,
            proximityDp = profile.trailingEdgeProximityDp
        )
    }

    private fun synchronizedPointerIds(nowMs: Long, candidateIds: List<Int>): List<Int> {
        val withTimes = candidateIds.mapNotNull { pid ->
            val down = downTimes[pid] ?: return@mapNotNull null
            if (nowMs - down <= profile.gestureDownWindowMs) pid to down else null
        }
        if (withTimes.size < 2) return emptyList()
        val minDown = withTimes.minOf { it.second }
        val maxDown = withTimes.maxOf { it.second }
        return if (maxDown - minDown <= profile.gestureDownWindowMs) withTimes.map { it.first } else emptyList()
    }

    private fun maxPairwiseSpanPx(pointerIds: List<Int>): Float {
        val ids = pointerIds.filter { lastFeatures.containsKey(it) }
        var span = 0f
        for (i in ids.indices) {
            for (j in i + 1 until ids.size) {
                val a = lastFeatures.getValue(ids[i])
                val b = lastFeatures.getValue(ids[j])
                span = max(span, hypot(a.x - b.x, a.y - b.y))
            }
        }
        return span
    }

    private fun label(text: String) {
        lastDecisionLabel = text
    }

    // ==================================================================
    //  遥测
    // ==================================================================

    private fun updateTelemetry(packet: TouchPacket) {
        val track = activeTrack()
        val actionPid = packet.actionPointerId
        val focus = track?.lastFeatures
            ?: lastFeatures[actionPid]
            ?: lastFeatures.values.lastOrNull()
            ?: TouchFeatures.EMPTY

        val anchorSnapshot = palmAnchor
        val headroomDp = if (anchorSnapshot != null && profile.handednessMode.spatialEnabled) {
            extractor.spatialHeadroomDp(focus.spatialScore, anchorSnapshot.spatialScore)
        } else {
            0f
        }

        currentTelemetry = TouchTelemetry(
            state = engineState,
            lastDecision = lastDecisionLabel,
            candidateDiameterMm = focus.diameterMm,
            penMaxThresholdMm = profile.penMaxMm,
            palmHardThresholdMm = profile.palmHardMinMm,
            equivalentAreaMm2 = focus.areaMm2,
            touchX = focus.x,
            touchY = focus.y,
            eccentricity = focus.eccentricity,
            maxEccentricity = profile.maxEccentricity,
            areaExpansionDpPerMs = focus.areaExpansionDpPerMs,
            velocityDpPerSec = focus.velocityDpPerSec,
            accelerationDpPerSec2 = focus.accelerationDpPerSec2,
            turnAngleDeg = focus.turnAngleDeg,
            curvaturePerMm = focus.curvaturePerMm,
            spatialScore = focus.spatialScore,
            spatialHeadroomDp = headroomDp,
            handednessMode = profile.handednessMode,
            sensitivityLevel = profile.sensitivityLevel,
            activePenPointerId = activePenPointerId,
            pointerCount = packet.pointerCount,
            rejectedPalmCount = rejectedPalmCount,
            rejectedPointerCount = rejectedPointers.size,
            palmAnchorX = anchorSnapshot?.x,
            palmAnchorY = anchorSnapshot?.y,
            isWritingLocked = engineState == EngineState.WRITING_LOCKED,
            strokeAliveMs = track?.aliveMs(packet.eventTimeMs) ?: 0L,
            strokePathDp = track?.totalPathDp ?: 0f,
            simulatedPressure = 0f,
            simulatedWidthPx = 0f,
            diameterReportAvailable = packet.diameterReportAvailable,
            motionOnlyMode = !packet.diameterReportAvailable
        )
    }

    private fun normalizeAngleDeg(angle: Float): Float {
        var a = angle
        while (a > 180f) a -= 360f
        while (a < -180f) a += 360f
        return a
    }

    private companion object {
        const val MAX_REJECTION_RECORDS = 512
        const val SAME_DIRECTION_MIN_COSINE = 0.2f
        const val MIN_DIRECTION_LENGTH_PX = 3f
        const val TWO_FINGER_TAP_POINTERS = 2
    }
}
