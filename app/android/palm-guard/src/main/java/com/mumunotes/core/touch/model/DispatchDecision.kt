package com.mumunotes.core.touch.model

/**
 * 手掌误触拒绝原因（供遥测胶囊、诊断回放与热力图着色使用）。
 */
enum class PalmRejectReason(val label: String) {
    /** 等效直径突破硬手掌下限 T_palm_hard */
    DIAMETER_HARD("面积超掌根上限"),

    /** 椭圆偏心率突破 1.75，狭长条带状侧掌 / 鱼际肌 */
    ECCENTRICITY("狭长侧掌偏心率"),

    /** 位于已登记手掌锚点的右下方，判定为小指侧掌边缘余波 */
    TRAILING_EDGE("掌根右下余波"),

    /** 35ms~80ms 观察窗内面积膨胀速率超标，手掌由虚到实的压实过程 */
    EXPANSION_GROWTH("手掌压实膨胀"),

    /** 观察窗内高频原地锐角折返（θ > 135° 且净位移极小），典型手掌电容网格质心跳变 */
    CENTROID_JITTER("电容质心高频抖动"),

    /** 35ms 观察窗内 N≥2 触点同步落屏且无书写锁定，判为多指手势占用 */
    OBSERVE_WINDOW_MULTI("多指同步落屏"),

    /** 强书写锁定态下的并发触点绝对免疫 */
    MID_STROKE_IMMUNITY("书写中并发免疫"),

    /** 尺寸落在手指区间但未开启单指漫游模式 */
    FINGER_RANGE_NO_PAN("手指尺寸且未开漫游"),

    /** 落在虚拟防误触手垫区域内 */
    VIRTUAL_SHIELD("虚拟手垫吸收"),

    /** 幽灵短笔迹回滚后，原触点被拉黑 */
    GHOST_ROLLBACK("幽灵笔迹回滚"),

    /** 三指系统中截屏等手势引发的触点在锁定态被吞掉 */
    SYSTEM_GESTURE_GUARD("系统手势防护"),

    /** 主动笔悬停/提笔 400ms 护盾冷却期内拦截单指或手掌误触 */
    STYLUS_ACTIVE_SHIELD("主动笔冷却护盾拦截"),

    /** 屏幕边缘 8.5mm 防误触带拦截低速倚靠手掌 */
    SCREEN_EDGE_GUARD("屏幕边缘防误触带拦截"),

    /** 形态学低速膨胀大斑块拦截 */
    MORPHOLOGY_BLOB("形态学低速膨胀斑块")
}

/** 笔迹提交原因 */
enum class CommitReason(val label: String) {
    /** 正常抬笔 */
    POINTER_UP("正常抬笔"),

    /** 系统三指手势下发 ACTION_CANCEL，已正常保存前半段合法笔迹（防丢字保护） */
    SYSTEM_CANCEL_PARTIAL("系统手势打断保护性保存")
}

/** 笔迹取消原因 */
enum class StrokeCancelReason(val label: String) {
    /** 面积膨胀判定为手掌压实 */
    EXPANSION_PALM("手掌压实膨胀"),

    /** 电容网格质心原地高频折返跳变 */
    CENTROID_JITTER_PALM("电容质心高频抖动"),

    /** 幽灵短笔迹（小指抢先落屏）被真笔尖抢占回滚 */
    GHOST_PREEMPTED("幽灵笔迹被真笔尖抢占"),

    /** 交由多指手势接管 */
    GESTURE_TAKEOVER("多指手势接管"),

    /** 系统取消且不满足保护性保存条件 */
    SYSTEM_CANCEL_DISCARDED("系统取消且长度不足"),

    /** 引擎复位 */
    ENGINE_RESET("引擎复位")
}

/** 幽灵笔迹回滚描述：渲染层据此瞬间擦除小指抢先落屏产生的短误触线段 */
data class RollbackDescriptor(
    /** 被判定为幽灵的触点已累计的笔迹长度（dp） */
    val cancelledPathDp: Float,
    /** 该幽灵触点的存活时长（ms） */
    val cancelledAliveMs: Long,
    /** 需要从尾部截断的时长（ms），用于系统手势打断时抹掉末尾抖动 */
    val tailTruncateMs: Long
)

/** 多指手势描述：交由画布缩放 / 平移 / 撤销识别器 */
data class GestureDescriptor(
    val pointerCount: Int,
    val centroidX: Float,
    val centroidY: Float,
    /** 触点两两最大间距（px），双指缩放的关键量 */
    val spanPx: Float,
    /** 相对上一帧的旋转角增量（度） */
    val rotationDeltaDeg: Float,
    /** 是否为三指轻点撤销候选 */
    val threeFingerTapCandidate: Boolean
) {
    companion object {
        val NONE = GestureDescriptor(0, 0f, 0f, 0f, 0f, false)
    }
}

/**
 * 防误触引擎输出的唯一裁决结果。
 */
sealed interface DispatchDecision {

    /** 主动笔（Stylus / Eraser）无条件立即放行 */
    data class AllowStylus(val pointerId: Int) : DispatchDecision

    /** 允许手指直接绘画 */
    data class AllowFingerDraw(val pointerId: Int) : DispatchDecision

    /** 仅允许平移缩放手势 */
    data class AllowGestureOnly(val pointerId: Int) : DispatchDecision

    /** 8~12ms 微延迟判定窗口（Hold Buffer）：临界触点暂缓派发，等待下一帧确认面积变化 */
    data class HoldPending(val pointerId: Int) : DispatchDecision

    /** 笔尖书写候选建立（进入 CANDIDATE_BUFFER，可绘制虚影） */
    data class StartStylusStroke(
        val pointerId: Int,
        val features: TouchFeatures
    ) : DispatchDecision

    /** 追加一批（历史 + 当前）笔迹采样点，还原原始高频触控流 */
    data class AppendStylusBatch(
        val pointerId: Int,
        val batch: List<TouchFeatures>
    ) : DispatchDecision

    /**
     * 提交整条笔迹（含收笔出锋由渲染层完成）。
     */
    data class CommitStylusStroke(
        val pointerId: Int,
        val reason: CommitReason,
        val totalPathDp: Float,
        val tailTruncateMs: Long = 0L
    ) : DispatchDecision

    /** 取消 / 擦除当前候选笔迹 */
    data class CancelStroke(
        val pointerId: Int,
        val reason: StrokeCancelReason,
        val descriptor: RollbackDescriptor
    ) : DispatchDecision

    /** 160ms 空间几何抢占：擦除幽灵笔迹并把书写焦点无缝移交给真笔尖 */
    data class RollbackAndSwitchStylus(
        val cancelledPointerId: Int,
        val newStylusPointerId: Int,
        val startPoint: TouchFeatures,
        val rollback: RollbackDescriptor
    ) : DispatchDecision

    /** 拒绝一个触点（手掌 / 掌根 / 侧掌 / 手指），并更新手掌锚点 */
    data class RejectPalm(
        val pointerId: Int,
        val x: Float = 0f,
        val y: Float = 0f,
        val diameterMm: Float = 0f,
        val eccentricity: Float = 1f,
        val reason: PalmRejectReason = PalmRejectReason.DIAMETER_HARD,
        val reasonText: String = reason.name,
        val shouldCancelExisting: Boolean = false
    ) : DispatchDecision {
        constructor(
            pointerId: Int,
            reason: String,
            shouldCancelExisting: Boolean
        ) : this(
            pointerId = pointerId,
            x = 0f,
            y = 0f,
            diameterMm = 0f,
            eccentricity = 1f,
            reason = PalmRejectReason.MORPHOLOGY_BLOB,
            reasonText = reason,
            shouldCancelExisting = shouldCancelExisting
        )
    }

    /** 被虚拟防误触手垫吸收（静默丢弃，并登记为手掌锚点） */
    data class PalmShieldAbsorbed(
        val pointerId: Int,
        val x: Float,
        val y: Float
    ) : DispatchDecision

    /** 触点落在 UI 热区，交由控件响应 */
    data class FingerUiTap(
        val pointerId: Int,
        val x: Float,
        val y: Float
    ) : DispatchDecision

    /** 启动单指漫游（手指尺寸触点平移画布） */
    data class StartFingerPan(
        val pointerId: Int,
        val features: TouchFeatures
    ) : DispatchDecision

    /** 更新单指漫游位移 */
    data class UpdateFingerPan(
        val pointerId: Int,
        val dx: Float,
        val dy: Float
    ) : DispatchDecision

    /** 切换到多指手势锁（清空候选笔迹，交由缩放/平移识别器） */
    data class SwitchToMultiFingerGesture(
        val pointerIds: List<Int>,
        val gesture: GestureDescriptor
    ) : DispatchDecision

    /** 多指手势进行中的逐帧更新 */
    data class UpdateMultiFingerGesture(
        val gesture: GestureDescriptor
    ) : DispatchDecision

    /** 三指轻点重做（三指单击 = 重做） */
    data object ThreeFingerTapRedo : DispatchDecision

    /**
     * 双指轻点撤销（双指单击 = 撤销）。
     */
    data object TwoFingerTapUndo : DispatchDecision

    /** 本帧无需任何处理 */
    data object NoOp : DispatchDecision
}

/** 裁决集合：主裁决 + 全部裁决 + 本帧状态快照 */
data class ArbiterOutcome(
    val primary: DispatchDecision,
    val decisions: List<DispatchDecision>
) {
    /** 是否存在需要渲染层立即擦除整条笔迹的取消类裁决 */
    val hasStrokeInvalidation: Boolean
        get() = decisions.any {
            it is DispatchDecision.CancelStroke ||
                it is DispatchDecision.RollbackAndSwitchStylus ||
                (it is DispatchDecision.RejectPalm && it.shouldCancelExisting)
        }

    /** 是否需要把触点从笔迹流中剔除 */
    val hasRejection: Boolean
        get() = decisions.any {
            it is DispatchDecision.RejectPalm ||
                it is DispatchDecision.PalmShieldAbsorbed ||
                it is DispatchDecision.HoldPending
        }

    companion object {
        val NONE = ArbiterOutcome(DispatchDecision.NoOp, emptyList())

        fun single(decision: DispatchDecision): ArbiterOutcome = ArbiterOutcome(decision, listOf(decision))
    }
}
