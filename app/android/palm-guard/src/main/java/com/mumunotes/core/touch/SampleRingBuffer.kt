package com.mumunotes.core.touch

import com.mumunotes.core.touch.model.TouchSample

/**
 * 单个 pointerId 的定长零分配环形时间序列缓冲区（Zero-Allocation Ring Buffer）。
 *
 * 在 240Hz/360Hz 高刷触控采样下，通过预分配 [TouchSample] 槽位并原地覆写（In-place Mutation），
 * 避免每次 MotionEvent 都分配新对象，实现零 GC 抖动开销。
 */
class SampleRingBuffer(val capacity: Int = DEFAULT_CAPACITY) {

    init {
        require(capacity > 0) { "Capacity must be positive" }
    }

    // 预分配样本槽位，避免 240Hz 高频触控下的对象分配与 GC 抖动
    private val buffer = Array(capacity) {
        TouchSample(
            pointerId = -1,
            timestampMillis = 0L,
            x = 0f,
            y = 0f,
            pressure = 0f,
            touchMajor = 0f,
            touchMinor = 0f,
            size = 0f,
            orientation = 0f,
            toolType = 0
        )
    }

    private var head = 0
    var size = 0
        private set

    val isFull: Boolean get() = size == capacity

    /**
     * 零分配原地写入采样点。
     */
    fun push(
        pointerId: Int,
        timestampMillis: Long,
        x: Float,
        y: Float,
        pressure: Float,
        touchMajor: Float,
        touchMinor: Float,
        size: Float,
        orientation: Float,
        toolType: Int,
        isHistorical: Boolean = false,
        contentX: Float = x,
        contentY: Float = y
    ): TouchSample {
        val currentCount = this.size
        val index = (head + currentCount) % capacity
        if (currentCount == capacity) {
            head = (head + 1) % capacity
        } else {
            this.size = currentCount + 1
        }
        val sample = buffer[index]
        sample.update(
            pointerId = pointerId,
            timestampMillis = timestampMillis,
            x = x,
            y = y,
            pressure = pressure,
            touchMajor = touchMajor,
            touchMinor = touchMinor,
            size = size,
            orientation = orientation,
            toolType = toolType,
            isHistorical = isHistorical,
            contentX = contentX,
            contentY = contentY
        )
        return sample
    }

    /**
     * 兼容写入：从传入的 [sample] 提取基本数值原地覆写至预分配槽位，绝不直接持有外部引用。
     */
    fun push(sample: TouchSample): TouchSample = push(
        pointerId = sample.pointerId,
        timestampMillis = sample.timeMs,
        x = sample.x,
        y = sample.y,
        pressure = sample.pressure,
        touchMajor = sample.touchMajorPx,
        touchMinor = sample.touchMinorPx,
        size = sample.normalizedSize,
        orientation = sample.orientation,
        toolType = sample.toolType,
        isHistorical = sample.isHistorical,
        contentX = sample.contentX,
        contentY = sample.contentY
    )

    operator fun get(index: Int): TouchSample {
        if (index < 0 || index >= size) throw IndexOutOfBoundsException("Index $index, size $size")
        return buffer[(head + index) % capacity]
    }

    fun latest(): TouchSample? = if (size == 0) null else get(size - 1)

    val latest: TouchSample? get() = latest()
    val oldest: TouchSample? get() = if (size == 0) null else get(0)

    /** index = 0 表示最新采样，1 表示次新，依此类推 */
    fun recent(index: Int): TouchSample? {
        if (index < 0 || index >= size) return null
        return get(size - 1 - index)
    }

    /**
     * 按时间升序返回最近 [maxCount] 个采样快照。
     */
    fun snapshot(maxCount: Int = size): List<TouchSample> {
        val n = minOf(maxCount, size).coerceAtLeast(0)
        if (n == 0) return emptyList()
        val out = ArrayList<TouchSample>(n)
        val startIdx = size - n
        for (i in startIdx until size) {
            out.add(get(i).copySnapshot())
        }
        return out
    }

    /** 时间升序全量快照 */
    fun snapshotAll(): List<TouchSample> = snapshot(size)

    /** 最近一段时间窗内的采样（时间升序） */
    fun window(fromTimeMsExclusive: Long): List<TouchSample> {
        if (size == 0) return emptyList()
        val out = ArrayList<TouchSample>(size)
        for (i in 0 until size) {
            val s = get(i)
            if (s.timeMs > fromTimeMsExclusive) out.add(s.copySnapshot())
        }
        return out
    }

    fun clear() {
        head = 0
        size = 0
    }

    companion object {
        /** 64 帧：在 360Hz 采样下覆盖约 178ms 历史，足以支撑 160ms 抢占窗口判定 */
        const val DEFAULT_CAPACITY = 64
    }
}
