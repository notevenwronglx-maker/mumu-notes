package com.mumunotes.core.touch.model

/**
 * 主流平板与常见电容笔头出厂预设参数库。
 */
data class DevicePreset(
    val id: String,
    val label: String,
    /** 归一化后的机型关键词（全部小写，命中任意一个即采用） */
    val modelPatterns: List<String>,
    val penMaxMm: Float,
    val palmHardMinMm: Float,
    val maxEccentricity: Float,
    /** 该机型触控驱动的实测备注 */
    val note: String
)

/**
 * L2 双模态校准结果。
 */
data class CalibrationResult(
    val success: Boolean,
    val penMaxMm: Float,
    val palmHardMinMm: Float,
    val penMeanMm: Float,
    val penSigmaMm: Float,
    val palmMinMm: Float,
    val penSampleCount: Int,
    val palmSampleCount: Int,
    val message: String
) {
    companion object {
        fun rejected(message: String) = CalibrationResult(
            success = false,
            penMaxMm = 0f,
            palmHardMinMm = 0f,
            penMeanMm = 0f,
            penSigmaMm = 0f,
            palmMinMm = 0f,
            penSampleCount = 0,
            palmSampleCount = 0,
            message = message
        )
    }
}

/**
 * 可持久化的阈值档位快照（支持通过 [ com.mumunotes.core.touch.CalibrationPreferences ] 一键落盘到 SharedPreferences）。
 */
data class CalibrationSnapshot(
    val penMaxMm: Float,
    val palmHardMinMm: Float,
    val palmHardDp: Float,
    val maxEccentricity: Float,
    val emaPenDiameterMm: Float,
    val sensitivityLevel: Int,
    val handednessMode: HandednessMode,
    val devicePresetId: String,
    val penSampleCount: Int,
    val palmSampleCount: Int,
    val lastCalibratedAtMs: Long,
    val isCalibrated: Boolean,

    // ---------- 恢复用的原始基准（不叠加灵敏度缩放） ----------

    /** L2 校准得到的笔尖上限基准（未叠加灵敏度缩放） */
    val penMaxCalibratedMm: Float,

    /** L2 校准得到的掌根下限基准（未叠加灵敏度缩放） */
    val palmHardCalibratedMm: Float,

    /** 偏心率上限基准（未叠加灵敏度缩放） */
    val eccentricityBase: Float,

    /** L2 校准时的笔尖直径均值锚点，用于计算 L3 在线 EMA 相对漂移比 */
    val calibratedPenMeanMm: Float = emaPenDiameterMm
)
