package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.CalibrationResult
import com.mumunotes.core.touch.model.HandednessMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 三阶自适应阈值引擎回归测试（文档 1.4 节）。
 *
 * 重点验证三件事：
 * 1. L2 双模态校准的公式确实收敛到「笔尖均值与手掌最小值之间」的合理分割点；
 * 2. 灵敏度档位的单调性（等级越高越严格）；
 * 3. 阈值不变量始终成立——掌根下限必须显著高于笔尖上限（否则算法会自相矛盾）。
 */
class AdaptiveThresholdProfileTest {

    private fun profile(
        model: String = "23043RP34C",
        sensitivity: Int = AdaptiveThresholdProfile.DEFAULT_SENSITIVITY
    ) = AdaptiveThresholdProfile(
        displayProfile = TouchFixture.displayProfile,
        deviceModel = model,
        initialSensitivity = sensitivity
    )

    @Test
    fun `device preset matches xiaomi pad 6 pro`() {
        val p = profile("23043RP34C")
        assertEquals("xiaomi_pad_6_pro", p.devicePreset.id)
        assertEquals(4.2f, p.penMaxMm, 0.001f)
        assertEquals(11.5f, p.palmHardMinMm, 0.001f)
    }

    @Test
    fun `unknown model falls back to generic preset`() {
        val p = profile("Some Unknown Tablet 9000")
        assertEquals("generic", p.devicePreset.id)
    }

    @Test
    fun `palm threshold always exceeds pen threshold`() {
        for (level in 1..5) {
            val p = profile(sensitivity = level)
            assertTrue(
                "灵敏度 L$level 下掌根下限必须高于笔尖上限",
                p.palmHardMinMm > p.penMaxMm
            )
            assertTrue(
                "笔尖与掌根之间必须保留安全间隔",
                p.palmHardMinMm - p.penMaxMm >= AdaptiveThresholdProfile.MIN_PEN_PALM_GAP_MM - 0.001f
            )
        }
    }

    @Test
    fun `higher sensitivity level produces stricter pen threshold`() {
        val loose = profile(sensitivity = 1).penMaxMm
        val strict = profile(sensitivity = 5).penMaxMm
        assertTrue("L5 应比 L1 更严格（笔尖上限更小）", strict < loose)

        val loosePalm = profile(sensitivity = 1).palmHardMinMm
        val strictPalm = profile(sensitivity = 5).palmHardMinMm
        assertTrue("L5 应比 L1 更早拦截掌根", strictPalm < loosePalm)
    }

    @Test
    fun `l2 calibration computes a separating threshold`() {
        val p = profile()
        // 笔尖点画 5 次：2.0mm 上下小幅波动
        val penSamples = listOf(1.9f, 2.1f, 2.0f, 2.05f, 1.95f)
        // 手掌贴屏 3 次：最小 17mm
        val palmSamples = listOf(17f, 22f, 26f)

        val result: CalibrationResult = p.calibrateFromSamples(penSamples, palmSamples, nowMs = 1_000L)

        assertTrue(result.success)
        assertEquals(5, result.penSampleCount)
        assertEquals(3, result.palmSampleCount)
        assertTrue("笔尖上限必须高于实测笔尖均值", result.penMaxMm > result.penMeanMm)
        assertTrue("笔尖上限必须低于实测手掌最小值", result.penMaxMm < result.palmMinMm)
        assertTrue("掌根下限必须低于实测手掌最小值", result.palmHardMinMm <= result.palmMinMm)
        assertTrue(p.isCalibrated)

        // 文档公式：T_pen_max = min(μp + 3.2σp + 0.8, 0.62μp + 0.38·h_min)
        val expectedUpper = result.penMeanMm + 3.2f * result.penSigmaMm + 0.8f
        val expectedSplit = 0.62f * result.penMeanMm + 0.38f * result.palmMinMm
        val expected = minOf(expectedUpper, expectedSplit)
        assertEquals(expected, result.penMaxMm, 0.05f)
    }

    @Test
    fun `l2 calibration rejects insufficient samples`() {
        val p = profile()
        val tooFewPens = p.calibrateFromSamples(listOf(2.0f), listOf(20f, 22f), nowMs = 1L)
        assertFalse(tooFewPens.success)
        assertTrue(tooFewPens.message.contains("笔尖样本不足"))

        val tooFewPalms = p.calibrateFromSamples(listOf(2.0f, 2.1f, 1.9f), listOf(20f), nowMs = 1L)
        assertFalse(tooFewPalms.success)
        assertTrue(tooFewPalms.message.contains("手掌样本不足"))
    }

    @Test
    fun `l2 calibration converges overlapping samples`() {
        val p = profile()
        // 笔尖样本异常大（例如换了粗圆盘笔头），与手掌样本几乎重叠
        val result = p.calibrateFromSamples(
            penSamplesMm = listOf(9f, 9.5f, 10f, 9.2f, 9.8f),
            palmSamplesMm = listOf(11f, 12f, 13f),
            nowMs = 1L
        )
        assertTrue(result.success)
        assertTrue(
            "样本重叠时必须收敛到实测手掌下限之下，绝不允许笔尖上限超过手掌下限",
            result.penMaxMm < result.palmMinMm
        )
        assertNotNull(result.message)
    }

    @Test
    fun `l3 online ema drifts threshold within band`() {
        val p = profile()
        p.calibrateFromSamples(listOf(2.0f, 2.0f, 2.0f), listOf(20f, 22f, 24f), nowMs = 1L)
        val calibratedPenMax = p.penMaxMm
        val lowerBound = calibratedPenMax * (1f - AdaptiveThresholdProfile.ONLINE_DRIFT_BAND)
        val upperBound = calibratedPenMax * (1f + AdaptiveThresholdProfile.ONLINE_DRIFT_BAND)

        // 连续观察到偏大的笔尖直径（握笔倾角变大 / 笔头磨损）
        repeat(80) { p.updateOnlinePenStats(3.4f) }

        assertTrue("EMA 基准应被推高", p.emaPenDiameterMm > 2.0f)
        assertTrue(
            "T_pen_max 必须在 ±15% 漂移带内，当前 ${p.penMaxMm} 应在 [$lowerBound, $upperBound]",
            p.penMaxMm in lowerBound..upperBound
        )
    }

    @Test
    fun `l3 ignores invalid observations`() {
        val p = profile()
        val before = p.emaPenDiameterMm
        p.updateOnlinePenStats(Float.NaN)
        p.updateOnlinePenStats(0f)
        p.updateOnlinePenStats(-1f)
        assertEquals(before, p.emaPenDiameterMm, 0.0001f)
    }

    @Test
    fun `reset to device preset clears calibration state`() {
        val p = profile()
        p.calibrateFromSamples(listOf(2.0f, 2.1f, 1.9f), listOf(20f, 22f, 24f), nowMs = 5L)
        assertTrue(p.isCalibrated)

        p.resetToDevicePreset()
        assertFalse(p.isCalibrated)
        assertEquals(0, p.penSampleCount)
        assertEquals(0, p.palmSampleCount)
        assertEquals(p.devicePreset.penMaxMm, p.penMaxMm, 0.001f)
    }

    @Test
    fun `snapshot round trips all tunables`() {
        val p = profile(sensitivity = 4)
        p.handednessMode = HandednessMode.LEFT_DIAGONAL
        p.calibrateFromSamples(listOf(2.2f, 2.3f, 2.1f), listOf(18f, 20f, 23f), nowMs = 9L)

        val snapshot = p.snapshot(nowMs = 9L)
        val restored = AdaptiveThresholdProfile(
            displayProfile = TouchFixture.displayProfile,
            deviceModel = "unknown",
            initialSensitivity = 3
        )
        restored.restore(snapshot)

        assertEquals(p.penMaxMm, restored.penMaxMm, 0.01f)
        assertEquals(p.palmHardMinMm, restored.palmHardMinMm, 0.01f)
        assertEquals(4, restored.sensitivityLevel)
        assertEquals(HandednessMode.LEFT_DIAGONAL, restored.handednessMode)
        assertTrue(restored.isCalibrated)
    }

    @Test
    fun `handedness spatial score ordering matches grip geometry`() {
        // 右手斜握：笔尖在左上方 → 左上得分必须小于右下
        val upperLeft = HandednessMode.RIGHT_DIAGONAL.spatialScore(300f, 300f)
        val lowerRight = HandednessMode.RIGHT_DIAGONAL.spatialScore(900f, 900f)
        assertTrue(upperLeft < lowerRight)

        // 左手斜握：笔尖在右上方 → 右上得分必须小于左下
        val upperRight = HandednessMode.LEFT_DIAGONAL.spatialScore(900f, 300f)
        val lowerLeft = HandednessMode.LEFT_DIAGONAL.spatialScore(300f, 900f)
        assertTrue(upperRight < lowerLeft)

        // 纯面积模式下空间几何必须完全关闭
        assertFalse(HandednessMode.AREA_ONLY.spatialEnabled)
        assertEquals(0f, HandednessMode.AREA_ONLY.spatialScore(123f, 456f), 0.0001f)
    }

    @Test
    fun `describe exposes current thresholds`() {
        val text = profile().describe()
        assertTrue(text.contains("mm"))
        assertTrue(text.contains("灵敏度"))
    }

    @Test
    fun `l2 calibration matches effective penMaxMm immediately without jump`() {
        val p = profile(sensitivity = AdaptiveThresholdProfile.DEFAULT_SENSITIVITY)
        val result = p.calibrateFromSamples(
            penSamplesMm = listOf(1.6f, 1.8f, 1.7f, 1.5f, 1.9f),
            palmSamplesMm = listOf(18f, 21f, 24f),
            nowMs = 42L
        )
        assertTrue(result.success)
        assertEquals(
            "刚完成 L2 校准且尚未产生 L3 在线漂移时，profile.penMaxMm 必须与 CalibrationResult.penMaxMm 完全相等",
            result.penMaxMm,
            p.penMaxMm,
            0.0001f
        )
    }
}
