package com.mumunotes.core.touch.model

/**
 * 与 [android.view.MotionEvent] 动作常量数值**完全一致**的本地镜像。
 *
 * 存在的意义：让 :core:touch-arbiter 的裁决状态机完全不依赖 Android 框架类，
 * 从而可以在纯 JVM 单元测试中以合成 [TouchPacket] 直接驱动状态机，
 * 覆盖「小指抢先落屏」「三指截屏打断」等难以在真机上复现的边界场景。
 */
object TouchAction {
    const val DOWN = 0
    const val UP = 1
    const val MOVE = 2
    const val CANCEL = 3
    const val OUTSIDE = 4
    const val POINTER_DOWN = 5
    const val POINTER_UP = 6

    fun isDown(action: Int): Boolean = action == DOWN || action == POINTER_DOWN
    fun isUp(action: Int): Boolean = action == UP || action == POINTER_UP

    fun label(action: Int): String = when (action) {
        DOWN -> "ACTION_DOWN"
        UP -> "ACTION_UP"
        MOVE -> "ACTION_MOVE"
        CANCEL -> "ACTION_CANCEL"
        OUTSIDE -> "ACTION_OUTSIDE"
        POINTER_DOWN -> "ACTION_POINTER_DOWN"
        POINTER_UP -> "ACTION_POINTER_UP"
        else -> "ACTION_$action"
    }
}
