package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.CommitReason
import com.mumunotes.core.touch.model.DispatchDecision
import com.mumunotes.core.touch.model.EngineState
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.HandednessMode
import com.mumunotes.core.touch.model.PalmAnchorSource
import com.mumunotes.core.touch.model.PalmRect
import com.mumunotes.core.touch.model.PalmRejectReason
import com.mumunotes.core.touch.model.StrokeCancelReason
import com.mumunotes.core.touch.model.TouchPacket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 防误触状态机核心行为回归测试。
 *
 * 覆盖架构文档 2.1 节的四个边界场景与 1.2 节五阶段状态机的关键分支，
 * 这些场景在真机上极难稳定复现（依赖毫秒级时序），因此全部以合成触控流断言。
 */
class PalmAndGestureArbiterTest {

    private val pen = TouchFixture.PEN_MM
    private val finger = TouchFixture.FINGER_MM
    private val palm = TouchFixture.PALM_MM
    private val fingerMode = FingerActionMode.PAN_CANVAS

    // ------------------------------------------------------------------
    // 基础书写链路
    // ------------------------------------------------------------------

    @Test
    fun `pen stroke produces start append and commit`() {
        val arbiter = TouchFixture.arbiter()

        val down = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 500f, 500f, pen, 0L))
        )
        assertTrue(
            "笔尖落屏必须进入候选书写态",
            down.decisions.any { it is DispatchDecision.StartStylusStroke }
        )
        assertEquals(EngineState.CANDIDATE_BUFFER, arbiter.state)

        val move = arbiter.process(
            TouchFixture.single(TouchFixture.MOVE, TouchFixture.pointer(0, 560f, 500f, pen, 32L))
        )
        assertTrue(
            "移动必须追加原始采样批次",
            move.decisions.any { it is DispatchDecision.AppendStylusBatch }
        )
        assertEquals(EngineState.WRITING_LOCKED, arbiter.state)

        val up = arbiter.process(
            TouchFixture.single(TouchFixture.UP, TouchFixture.pointer(0, 560f, 500f, pen, 64L))
        )
        val commit = up.decisions.filterIsInstance<DispatchDecision.CommitStylusStroke>().firstOrNull()
        assertNotNull("抬笔必须提交笔迹", commit)
        assertEquals(CommitReason.POINTER_UP, commit!!.reason)
        assertTrue("已累计笔迹长度应大于 0", commit.totalPathDp > 0f)
        assertEquals(EngineState.IDLE, arbiter.state)
    }

    // ------------------------------------------------------------------
    // 阶段 2：0ms 形态硬阈值
    // ------------------------------------------------------------------

    @Test
    fun `palm root is rejected by hard diameter threshold`() {
        val arbiter = TouchFixture.arbiter()
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 800f, 1400f, palm, 0L))
        )
        val reject = outcome.decisions.filterIsInstance<DispatchDecision.RejectPalm>().firstOrNull()
        assertNotNull("30mm 掌根必须被硬阈值拦截", reject)
        assertEquals(PalmRejectReason.DIAMETER_HARD, reject!!.reason)
        assertNotNull("被拒触点必须登记为手掌锚点", arbiter.anchor)
        assertFalse(outcome.decisions.any { it is DispatchDecision.StartStylusStroke })
    }

    @Test
    fun `elongated side palm is rejected by eccentricity`() {
        val arbiter = TouchFixture.arbiter()
        // 8mm × 3mm 的狭长条带：直径未超掌根上限，但偏心率 2.67 > 1.75
        val outcome = arbiter.process(
            TouchFixture.single(
                TouchFixture.DOWN,
                TouchFixture.pointer(0, 700f, 1500f, 8f, 0L, minorRatio = 3f / 8f)
            )
        )
        val reject = outcome.decisions.filterIsInstance<DispatchDecision.RejectPalm>().firstOrNull()
        assertNotNull("狭长侧掌必须被偏心率拦截", reject)
        assertEquals(PalmRejectReason.ECCENTRICITY, reject!!.reason)
    }

    // ------------------------------------------------------------------
    // 阶段 4：160ms 幽灵笔迹回滚（文档 2.1 场景 2）
    // ------------------------------------------------------------------

    @Test
    fun `pinky landing first is rolled back when real stylus lands upper left`() {
        val arbiter = TouchFixture.arbiter()

        // 小指尖抢先落屏（右下），面积落在笔尖区间，因此通过了形态初筛
        val ghost = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(1, 800f, 900f, pen, 0L))
        )
        assertTrue(ghost.decisions.any { it is DispatchDecision.StartStylusStroke })

        // 80ms 后真笔尖落在左上方
        val real = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(1, 800f, 900f, pen, 80L),
                    TouchFixture.pointer(2, 500f, 500f, pen, 80L)
                ),
                actionPointerId = 2
            )
        )

        val rollback = real.decisions
            .filterIsInstance<DispatchDecision.RollbackAndSwitchStylus>()
            .firstOrNull()
        assertNotNull("真笔尖落屏必须抢占并回滚幽灵笔迹", rollback)
        assertEquals(1, rollback!!.cancelledPointerId)
        assertEquals(2, rollback.newStylusPointerId)

        val cancel = real.decisions.filterIsInstance<DispatchDecision.CancelStroke>().firstOrNull()
        assertNotNull("幽灵笔迹必须被取消擦除", cancel)
        assertEquals(StrokeCancelReason.GHOST_PREEMPTED, cancel!!.reason)

        assertEquals("焦点必须无缝移交给真笔尖", 2, arbiter.activePenId)
        assertEquals(PalmAnchorSource.GHOST_ROLLBACK, arbiter.anchor?.source)
    }

    @Test
    fun `geometric rollback does not trigger after preempt window expires`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(1, 800f, 900f, pen, 0L)))
        // 300ms 后（远超 160ms 抢占窗口）真笔尖才落屏
        val later = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(1, 800f, 900f, pen, 300L),
                    TouchFixture.pointer(2, 500f, 500f, pen, 300L)
                ),
                actionPointerId = 2
            )
        )
        assertFalse(
            "超出 160ms 抢占窗口后不得再回滚已成立的笔迹",
            later.decisions.any { it is DispatchDecision.RollbackAndSwitchStylus }
        )
    }

    @Test
    fun `geometric rollback is disabled in area only mode`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.profile.handednessMode = HandednessMode.AREA_ONLY

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(1, 800f, 900f, pen, 0L)))
        val outcome = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(1, 800f, 900f, pen, 60L),
                    TouchFixture.pointer(2, 500f, 500f, pen, 60L)
                ),
                actionPointerId = 2
            )
        )
        assertFalse(
            "纯面积模式下必须完全关闭空间几何抢占",
            outcome.decisions.any { it is DispatchDecision.RollbackAndSwitchStylus }
        )
    }

    // ------------------------------------------------------------------
    // 阶段 5：书写中并发多点绝对免疫（文档 2.1 场景 1）
    // ------------------------------------------------------------------

    @Test
    fun `mid stroke immunity swallows concurrent palm without breaking the stroke`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 500f, 500f, pen, 0L)))
        // 连续书写 100px（≈36dp，超过 24dp 锁定阈值）
        for ((i, t) in listOf(16L, 32L, 48L, 64L).withIndex()) {
            arbiter.process(
                TouchFixture.single(
                    TouchFixture.MOVE,
                    TouchFixture.pointer(0, 500f + (i + 1) * 25f, 500f, pen, t)
                )
            )
        }
        assertTrue("笔迹应已进入强书写锁定", arbiter.isWritingLocked)

        // 手掌突然多点接触
        val sudden = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 600f, 500f, pen, 80L),
                    TouchFixture.pointer(1, 900f, 900f, finger, 80L)
                ),
                actionPointerId = 1
            )
        )
        val reject = sudden.decisions.filterIsInstance<DispatchDecision.RejectPalm>().firstOrNull()
        assertNotNull("书写中并发触点必须被吞掉", reject)
        assertEquals(PalmRejectReason.MID_STROKE_IMMUNITY, reject!!.reason)

        assertFalse(
            "书写锁定期间绝不能进入多指手势",
            sudden.decisions.any { it is DispatchDecision.SwitchToMultiFingerGesture }
        )
        assertFalse(
            "书写锁定期间绝不能中断当前笔画",
            sudden.decisions.any { it is DispatchDecision.CancelStroke }
        )
        assertEquals(0, arbiter.activePenId)

        // 后续移动仍然正常出墨
        val stillWriting = arbiter.process(
            TouchFixture.single(TouchFixture.MOVE, TouchFixture.pointer(0, 640f, 500f, pen, 96L))
        )
        assertTrue(
            "笔画必须丝滑不断触",
            stillWriting.decisions.any { it is DispatchDecision.AppendStylusBatch }
        )
    }

    // ------------------------------------------------------------------
    // 阶段 3：35ms 同步观察窗与多指手势（文档 2.1 场景 3）
    // ------------------------------------------------------------------

    @Test
    fun `two synchronized fingers enter pinch gesture instead of writing`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 800f, finger, 0L)))
        val second = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 800f, finger, 20L),
                    TouchFixture.pointer(1, 900f, 800f, finger, 20L)
                ),
                actionPointerId = 1
            )
        )

        val gesture = second.decisions
            .filterIsInstance<DispatchDecision.SwitchToMultiFingerGesture>()
            .firstOrNull()
        assertNotNull("双指同步落屏必须进入手势锁", gesture)
        assertEquals(2, gesture!!.gesture.pointerCount)
        assertEquals(EngineState.GESTURE_LOCKED, arbiter.state)

        val move = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.MOVE,
                pointers = listOf(
                    TouchFixture.pointer(0, 380f, 800f, finger, 40L),
                    TouchFixture.pointer(1, 920f, 800f, finger, 40L)
                ),
                actionPointerId = 0
            )
        )
        val update = move.decisions
            .filterIsInstance<DispatchDecision.UpdateMultiFingerGesture>()
            .firstOrNull()
        assertNotNull("手势进行中必须逐帧上报描述", update)
        assertTrue("缩放间距应随两指外扩而增大", update!!.gesture.spanPx > gesture.gesture.spanPx)
    }

    @Test
    fun `three finger quick tap triggers undo`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 300f, 700f, finger, 0L)))
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 300f, 700f, finger, 10L),
                    TouchFixture.pointer(1, 900f, 700f, finger, 10L)
                ),
                actionPointerId = 1
            )
        )
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 300f, 700f, finger, 20L),
                    TouchFixture.pointer(1, 900f, 700f, finger, 20L),
                    TouchFixture.pointer(2, 600f, 1100f, finger, 20L)
                ),
                actionPointerId = 2
            )
        )
        assertEquals(EngineState.GESTURE_LOCKED, arbiter.state)

        // 三指同步轻抬（总时长 120ms，位移为 0）
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(0, 300f, 700f, finger, 100L),
                    TouchFixture.pointer(1, 900f, 700f, finger, 100L),
                    TouchFixture.pointer(2, 600f, 1100f, finger, 100L)
                ),
                actionPointerId = 2
            )
        )
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(0, 300f, 700f, finger, 110L),
                    TouchFixture.pointer(1, 900f, 700f, finger, 110L)
                ),
                actionPointerId = 1
            )
        )
        val last = arbiter.process(
            TouchFixture.single(TouchFixture.UP, TouchFixture.pointer(0, 300f, 700f, finger, 120L))
        )
        assertTrue(
            "三指轻点必须在最后一指抬起时触发重做",
            last.decisions.any { it is DispatchDecision.ThreeFingerTapRedo }
        )
        assertEquals(EngineState.IDLE, arbiter.state)
    }

    @Test
    fun `two finger quick tap triggers undo`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 800f, finger, 0L)))
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 800f, finger, 10L),
                    TouchFixture.pointer(1, 700f, 800f, finger, 10L)
                ),
                actionPointerId = 1
            )
        )
        assertEquals(EngineState.GESTURE_LOCKED, arbiter.state)

        // 双指几乎不动、短促抬起
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 800f, finger, 90L),
                    TouchFixture.pointer(1, 700f, 800f, finger, 90L)
                ),
                actionPointerId = 1
            )
        )
        val last = arbiter.process(
            TouchFixture.single(TouchFixture.UP, TouchFixture.pointer(0, 400f, 800f, finger, 110L))
        )
        assertTrue(
            "双指轻点必须在最后一指抬起时触发撤销",
            last.decisions.any { it is DispatchDecision.TwoFingerTapUndo }
        )
        assertFalse(
            "双指轻点不得被误判为三指重做",
            last.decisions.any { it is DispatchDecision.ThreeFingerTapRedo }
        )
    }

    @Test
    fun `two finger drag is not treated as undo`() {
        val arbiter = TouchFixture.arbiter()

        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 800f, finger, 0L)))
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 800f, finger, 10L),
                    TouchFixture.pointer(1, 700f, 800f, finger, 10L)
                ),
                actionPointerId = 1
            )
        )
        // 两指同向拖动 200px —— 这是平移手势，绝不能撤销
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.MOVE,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 650f, finger, 80L),
                    TouchFixture.pointer(1, 700f, 650f, finger, 80L)
                ),
                actionPointerId = 0
            )
        )
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(0, 400f, 650f, finger, 140L),
                    TouchFixture.pointer(1, 700f, 650f, finger, 140L)
                ),
                actionPointerId = 1
            )
        )
        val last = arbiter.process(
            TouchFixture.single(TouchFixture.UP, TouchFixture.pointer(0, 400f, 650f, finger, 160L))
        )
        assertFalse(
            "有实际位移的双指手势是平移，不得触发撤销",
            last.decisions.any { it is DispatchDecision.TwoFingerTapUndo }
        )
    }

    @Test
    fun `two synchronous pen sized contacts do not become a gesture`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 100f, 100f, pen, 0L))
        )
        // 两个笔尖尺寸触点间距很小、且都不在手指区间 → 不应判为手势
        val outcome = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 100f, 100f, pen, 10L),
                    TouchFixture.pointer(1, 130f, 100f, pen, 10L)
                ),
                actionPointerId = 1
            )
        )
        assertFalse(
            "两个紧邻的笔尖尺寸触点不得被误判为缩放手势",
            outcome.decisions.any { it is DispatchDecision.SwitchToMultiFingerGesture }
        )
    }

    // ------------------------------------------------------------------
    // 系统三指截屏 ACTION_CANCEL 防丢字保护（文档 4.2 节）
    // ------------------------------------------------------------------

    @Test
    fun `system cancel protects long legitimate stroke from being lost`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 600f, pen, 0L)))
        for ((i, t) in listOf(32L, 64L, 96L, 128L, 160L, 192L, 224L).withIndex()) {
            arbiter.process(
                TouchFixture.single(
                    TouchFixture.MOVE,
                    TouchFixture.pointer(0, 400f + (i + 1) * 30f, 600f, pen, t)
                )
            )
        }

        val cancel = arbiter.process(
            TouchFixture.single(TouchFixture.CANCEL, TouchFixture.pointer(0, 610f, 600f, pen, 240L))
        )
        val commit = cancel.decisions.filterIsInstance<DispatchDecision.CommitStylusStroke>().firstOrNull()
        assertNotNull("已写超过 180ms 且超过 35dp 的笔迹必须保护性保存", commit)
        assertEquals(CommitReason.SYSTEM_CANCEL_PARTIAL, commit!!.reason)
        assertFalse(
            "保护性保存时不得同时取消笔迹",
            cancel.decisions.any { it is DispatchDecision.CancelStroke }
        )
    }

    @Test
    fun `system cancel discards very short ghost stroke`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 600f, pen, 0L)))
        arbiter.process(TouchFixture.single(TouchFixture.MOVE, TouchFixture.pointer(0, 405f, 600f, pen, 10L)))

        val cancel = arbiter.process(
            TouchFixture.single(TouchFixture.CANCEL, TouchFixture.pointer(0, 405f, 600f, pen, 20L))
        )
        assertTrue(
            "落屏不足 180ms 的短笔迹遇系统取消必须直接清空，纸面不留划痕",
            cancel.decisions.any { it is DispatchDecision.CancelStroke }
        )
        assertFalse(
            "短笔迹不得被提交",
            cancel.decisions.any { it is DispatchDecision.CommitStylusStroke }
        )
        assertEquals(EngineState.IDLE, arbiter.state)
    }

    // ------------------------------------------------------------------
    // 阶段 1：区域预检与手指模式
    // ------------------------------------------------------------------

    @Test
    fun `virtual palm shield absorbs contacts inside its region`() {
        val arbiter = TouchFixture.arbiter()
        val shieldRect = PalmRect(0f, 1400f, 2880f, 1800f)
        arbiter.configureRegions(uiRegions = emptyList(), palmShield = shieldRect)

        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 1400f, 1600f, finger, 0L))
        )
        assertTrue(
            "手垫区域内触点必须被静默吸收",
            outcome.decisions.any { it is DispatchDecision.PalmShieldAbsorbed }
        )
        assertEquals(PalmAnchorSource.VIRTUAL_SHIELD, arbiter.anchor?.source)
    }

    @Test
    fun `ui region contacts are handed to controls`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.configureRegions(
            uiRegions = listOf(PalmRect(0f, 0f, 2880f, 160f)),
            palmShield = null
        )
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 1200f, 80f, finger, 0L))
        )
        assertTrue(
            "顶部工具栏热区触点必须交由 UI 响应",
            outcome.decisions.any { it is DispatchDecision.FingerUiTap }
        )
    }

    @Test
    fun `finger sized contact starts canvas pan in pan mode`() {
        val arbiter = TouchFixture.arbiter(fingerMode = fingerMode)
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 600f, 900f, finger, 0L))
        )
        assertTrue(
            "手指尺寸触点应启动单指漫游",
            outcome.decisions.any { it is DispatchDecision.StartFingerPan }
        )
        assertEquals(EngineState.FINGER_PANNING, arbiter.state)
    }

    @Test
    fun `finger sized contact writes when finger write mode enabled`() {
        val arbiter = TouchFixture.arbiter(fingerMode = FingerActionMode.WRITE_WITH_FINGER)
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 600f, 900f, finger, 0L))
        )
        assertTrue(
            "开启单指书写后手指应作为笔尖候选",
            outcome.decisions.any { it is DispatchDecision.StartStylusStroke }
        )
    }

    // ------------------------------------------------------------------
    // 文档 2.1 场景 4：手掌全程紧贴屏幕不抬手，连续书写
    // ------------------------------------------------------------------

    @Test
    fun `continuous writing with palm resting on screen never lifts anchor`() {
        val arbiter = TouchFixture.arbiter()

        // 手掌先贴屏
        arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(9, 1500f, 1500f, palm, 0L))
        )
        assertNotNull(arbiter.anchor)

        // 连续写三个字：笔尖反复抬起又落下，手掌始终按住
        var timeMs = 100L
        repeat(3) { index ->
            val penY = 500f + index * 60f
            arbiter.process(
                TouchFixture.packet(
                    action = TouchFixture.POINTER_DOWN,
                    pointers = listOf(
                        TouchFixture.pointer(9, 1500f, 1500f, palm, timeMs),
                        TouchFixture.pointer(index, 500f, penY, pen, timeMs)
                    ),
                    actionPointerId = index
                )
            )
            assertEquals("第 ${index + 1} 次落笔都必须正常开始书写", index, arbiter.activePenId)

            arbiter.process(
                TouchFixture.packet(
                    action = TouchFixture.MOVE,
                    pointers = listOf(
                        TouchFixture.pointer(9, 1500f, 1500f, palm, timeMs + 32L),
                        TouchFixture.pointer(index, 580f, penY, pen, timeMs + 32L)
                    ),
                    actionPointerId = index
                )
            )
            val up = arbiter.process(
                TouchFixture.packet(
                    action = TouchFixture.POINTER_UP,
                    pointers = listOf(
                        TouchFixture.pointer(9, 1500f, 1500f, palm, timeMs + 64L),
                        TouchFixture.pointer(index, 580f, penY, pen, timeMs + 64L)
                    ),
                    actionPointerId = index
                )
            )
            assertTrue(
                "第 ${index + 1} 个字的笔迹必须正常提交",
                up.decisions.any { it is DispatchDecision.CommitStylusStroke }
            )
            assertNotNull("手掌按住期间锚点必须持续有效", arbiter.anchor)
            timeMs += 100L
        }
    }

    // ------------------------------------------------------------------
    // 面积膨胀拦截（阶段 3 情况 A）
    // ------------------------------------------------------------------

    @Test
    fun `growing contact is cancelled as palm press`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 700f, 900f, pen, 0L)))

        // 40ms 后面积从 2.0mm 暴涨到 9.0mm —— 手掌由虚到实的压实过程
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.MOVE, TouchFixture.pointer(0, 702f, 902f, 9.0f, 40L))
        )
        val cancel = outcome.decisions.filterIsInstance<DispatchDecision.CancelStroke>().firstOrNull()
        assertNotNull("面积骤增的触点必须被判为手掌压实并擦除", cancel)
        assertEquals(StrokeCancelReason.EXPANSION_PALM, cancel!!.reason)
        assertEquals(EngineState.IDLE, arbiter.state)
        assertNotNull("压实手掌必须登记为锚点", arbiter.anchor)
    }

    @Test
    fun `stable pen contact never triggers expansion cancel`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 700f, 900f, pen, 0L)))
        val outcome = arbiter.process(
            TouchFixture.single(TouchFixture.MOVE, TouchFixture.pointer(0, 740f, 900f, pen + 0.1f, 40L))
        )
        assertFalse(
            "面积稳定的硬质笔尖不得被膨胀规则误杀",
            outcome.decisions.any { it is DispatchDecision.CancelStroke }
        )
    }

    // ------------------------------------------------------------------
    // 遥测
    // ------------------------------------------------------------------

    @Test
    fun `telemetry reports thresholds and rejected counts`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 800f, 1400f, palm, 0L)))
        val telemetry = arbiter.telemetry

        assertEquals(1, telemetry.rejectedPalmCount)
        assertTrue(telemetry.penMaxThresholdMm > 0f)
        assertTrue(
            "掌根下限必须显著大于笔尖上限",
            telemetry.palmHardThresholdMm > telemetry.penMaxThresholdMm
        )
        assertFalse(telemetry.motionOnlyMode)
        assertEquals(EngineState.IDLE, telemetry.state)
    }

    @Test
    fun `driver without diameter reporting degrades to motion only mode`() {
        val arbiter = TouchFixture.arbiter()
        val packet: TouchPacket = TouchFixture.packet(
            action = TouchFixture.DOWN,
            pointers = listOf(TouchFixture.pointer(0, 500f, 500f, pen, 0L)),
            diameterReportAvailable = false
        )
        arbiter.process(packet)
        assertTrue(
            "驱动未上报面积时必须如实标记为纯运动学降级模式",
            arbiter.telemetry.motionOnlyMode
        )
    }

    @Test
    fun `reset clears all transient state`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 500f, 500f, pen, 0L)))
        arbiter.reset()

        assertEquals(EngineState.IDLE, arbiter.state)
        assertEquals(TouchPacket.INVALID, arbiter.activePenId)
        assertNull(arbiter.anchor)
        assertEquals(0, arbiter.rejectedPointerCount)
    }

    // ------------------------------------------------------------------
    // 回归测试：手掌与笔尖在 35ms 内先后落屏绝不误触发双指捏合手势
    // ------------------------------------------------------------------

    @Test
    fun `palm and stylus landing within 35ms never triggers false multi finger gesture`() {
        val arbiter = TouchFixture.arbiter()

        // t=0ms：掌根先落屏，被阶段 2 硬阈值拒绝
        val palmDown = arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 1200f, 1300f, palm, 0L))
        )
        assertTrue(palmDown.decisions.any { it is DispatchDecision.RejectPalm })

        // t=18ms（在 35ms 同步观察窗内！）：真笔尖落在左上方
        val penDown = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(0, 1200f, 1300f, palm, 18L),
                    TouchFixture.pointer(1, 500f, 500f, pen, 18L)
                ),
                actionPointerId = 1
            )
        )

        assertFalse(
            "已被拒绝的掌根触点绝不能与笔尖凑成双指缩放手势",
            penDown.decisions.any { it is DispatchDecision.SwitchToMultiFingerGesture }
        )
        assertTrue(
            "笔尖必须正常建立书写候选",
            penDown.decisions.any { it is DispatchDecision.StartStylusStroke }
        )
        assertEquals(1, arbiter.activePenId)
    }

    @Test
    fun `two finger tap undo completes properly even while rejected palm stays on screen`() {
        val arbiter = TouchFixture.arbiter()

        // 掌根一直贴在屏幕上不抬起
        arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(9, 1500f, 1500f, palm, 0L))
        )

        // 200ms 后另一只手双指同时落屏轻点
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(9, 1500f, 1500f, palm, 200L),
                    TouchFixture.pointer(1, 400f, 800f, finger, 200L)
                ),
                actionPointerId = 1
            )
        )
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_DOWN,
                pointers = listOf(
                    TouchFixture.pointer(9, 1500f, 1500f, palm, 210L),
                    TouchFixture.pointer(1, 400f, 800f, finger, 210L),
                    TouchFixture.pointer(2, 700f, 800f, finger, 210L)
                ),
                actionPointerId = 2
            )
        )
        assertEquals(EngineState.GESTURE_LOCKED, arbiter.state)

        // 双指依次抬起，但手掌 pointer 9 依然贴在屏幕上
        arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(9, 1500f, 1500f, palm, 290L),
                    TouchFixture.pointer(1, 400f, 800f, finger, 290L),
                    TouchFixture.pointer(2, 700f, 800f, finger, 290L)
                ),
                actionPointerId = 2
            )
        )
        val secondFingerUp = arbiter.process(
            TouchFixture.packet(
                action = TouchFixture.POINTER_UP,
                pointers = listOf(
                    TouchFixture.pointer(9, 1500f, 1500f, palm, 305L),
                    TouchFixture.pointer(1, 400f, 800f, finger, 305L)
                ),
                actionPointerId = 1
            )
        )

        assertTrue(
            "即使手掌仍贴在屏幕上，双指抬起瞬间也必须正常触发撤销并退出手势锁",
            secondFingerUp.decisions.any { it is DispatchDecision.TwoFingerTapUndo }
        )
        assertEquals(EngineState.IDLE, arbiter.state)
    }

    @Test
    fun `high frequency in place centroid jitter is cancelled as palm noise`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(
            TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 600f, 600f, pen, 0L))
        )

        // 模拟侧掌边缘电容质心在 3px 范围内高频来回折返跳变（每次折返 180°）
        val jitterCoords = listOf(
            604f to 600f,
            600f to 600f,
            604f to 600f,
            600f to 600f,
            604f to 600f
        )
        var cancelled = false
        for ((idx, xy) in jitterCoords.withIndex()) {
            val outcome = arbiter.process(
                TouchFixture.single(
                    TouchFixture.MOVE,
                    TouchFixture.pointer(0, xy.first, xy.second, pen, (idx + 1) * 10L)
                )
            )
            if (outcome.decisions.any {
                    it is DispatchDecision.CancelStroke &&
                        it.reason == StrokeCancelReason.CENTROID_JITTER_PALM
                }
            ) {
                cancelled = true
                break
            }
        }
        assertTrue("原地高频锐角折返跳变必须被识别为电容质心抖动并取消", cancelled)
        assertEquals(EngineState.IDLE, arbiter.state)
    }

    @Test
    fun `content coordinates are preserved alongside physical view coordinates`() {
        val arbiter = TouchFixture.arbiter()
        val down = arbiter.process(
            TouchFixture.single(
                TouchFixture.DOWN,
                TouchFixture.pointer(
                    id = 0,
                    x = 500f,
                    y = 600f,
                    diameterMm = pen,
                    timeMs = 0L,
                    contentX = 2500f,
                    contentY = 3000f
                )
            )
        )
        val start = down.decisions.filterIsInstance<DispatchDecision.StartStylusStroke>().firstOrNull()
        assertNotNull(start)
        assertEquals(500f, start!!.features.x, 0.01f)
        assertEquals(600f, start.features.y, 0.01f)
        assertEquals(2500f, start.features.contentX, 0.01f)
        assertEquals(3000f, start.features.contentY, 0.01f)
    }

    @Test
    fun `system cancel partial commit carries tailTruncateMs`() {
        val arbiter = TouchFixture.arbiter()
        arbiter.process(TouchFixture.single(TouchFixture.DOWN, TouchFixture.pointer(0, 400f, 600f, pen, 0L)))
        for ((i, t) in listOf(32L, 64L, 96L, 128L, 160L, 192L, 224L).withIndex()) {
            arbiter.process(
                TouchFixture.single(
                    TouchFixture.MOVE,
                    TouchFixture.pointer(0, 400f + (i + 1) * 30f, 600f, pen, t)
                )
            )
        }
        val cancel = arbiter.process(
            TouchFixture.single(TouchFixture.CANCEL, TouchFixture.pointer(0, 610f, 600f, pen, 240L))
        )
        val commit = cancel.decisions.filterIsInstance<DispatchDecision.CommitStylusStroke>().firstOrNull()
        assertNotNull(commit)
        assertEquals(CommitReason.SYSTEM_CANCEL_PARTIAL, commit!!.reason)
        assertEquals(
            "保护性保存必须携带 30ms 尾部截断时长",
            AdaptiveThresholdProfile.CANCEL_TAIL_TRUNCATE_MS,
            commit.tailTruncateMs
        )
    }
}
