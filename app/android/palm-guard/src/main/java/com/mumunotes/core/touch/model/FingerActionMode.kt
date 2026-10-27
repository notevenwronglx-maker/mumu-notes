package com.mumunotes.core.touch.model

/**
 * 手指尺寸触点（直径介于笔尖上限与掌根下限之间）的处置策略。
 *
 * 对应文档 1.3 规则 E 中的 `fingerActionMode` 与 5.1 节的「单指书写 / 单指漫游模式切换」。
 */
enum class FingerActionMode(val label: String, val hint: String) {
    /** 手指用于平移画布（默认） */
    PAN_CANVAS("单指漫游", "手指拖动平移画布"),

    /** 手指直接书写（戴手套 / 指甲书写 / 无笔应急场景） */
    WRITE_WITH_FINGER("单指书写", "手指尺寸触点直接作为笔尖"),

    /** 一律按误触拒绝（最严格的拇指防误触） */
    REJECT_FINGERS("拒绝所有手指", "仅接受笔尖尺寸触点");

    val allowsFingerStroke: Boolean get() = this == WRITE_WITH_FINGER
    val allowsFingerPan: Boolean get() = this == PAN_CANVAS

    companion object {
        /** 别名兼容：仅笔书写模式下禁用手指 */
        val DISABLED_WHEN_PEN_ONLY: FingerActionMode get() = REJECT_FINGERS

        /** 别名兼容：仅平移与缩放 */
        val PAN_AND_ZOOM_ONLY: FingerActionMode get() = PAN_CANVAS

        /** 别名兼容：允许手指直接绘画 */
        val ALL_ALLOWED: FingerActionMode get() = WRITE_WITH_FINGER

        /** 别名兼容：仅笔书写模式下手指平移画布 */
        val PEN_ONLY_PAN: FingerActionMode get() = PAN_CANVAS

        /** 别名兼容：允许手指直接书写 */
        val ALLOW_FINGER_WRITE: FingerActionMode get() = WRITE_WITH_FINGER
    }
}
