package com.mumunotes.core.touch

import android.view.MotionEvent
import com.mumunotes.core.touch.model.FingerActionMode
import com.mumunotes.core.touch.model.HandednessMode
import com.mumunotes.core.touch.model.TouchFeatures
import com.mumunotes.core.touch.model.TouchPacket
import com.mumunotes.core.touch.model.TouchSample
import com.mumunotes.core.touch.model.TouchTrack

/**
 * 坐标映射器：把 View 坐标系下的触点映射到画布内容坐标系。
 */
fun interface TouchPointMapper {
    /** @return 长度为 2 的数组 `[contentX, contentY]` */
    fun map(viewX: Float, viewY: Float): FloatArray
}

/**
 * 四级流水线 **Stage 1 — 数据采集层 (RawTouchCollector)**。
 *
 * 职责与修复增强：
 * 1. 遍历解包 [MotionEvent.historySize] 历史批处理采样点（还原 240Hz~360Hz 原始触控流），
 *    仅提取基本数值写入预分配的 [SampleRingBuffer]，绝不持有原始 [MotionEvent] 引用（防止对象池回收后坐标被篡改）。
 * 2. 严格区分 `pointerIndex`（`0 until event.pointerCount`）与 `pointerId`（`event.getPointerId(idx)`），
 *    杜绝 `ACTION_POINTER_DOWN` / `ACTION_POINTER_UP` 交替时传入 `pointerId` 引发 `IllegalArgumentException: pointerIndex out of range`。
 * 3. 每次收到 `ACTION_DOWN`（代表全新手势序列开始）时强制清空所有残留轨迹，并通过 [pruneStaleTracks]
 *    剔除超过 450ms~500ms 无更新的陈旧轨迹（Stale Track），防止系统弹窗或三指截屏打断后污染手掌护盾。
 */
class RawTouchCollector(
    var displayProfile: DisplayProfile,
    ringCapacity: Int = SampleRingBuffer.DEFAULT_CAPACITY
) {

    private val ringCapacity = ringCapacity
    private val buffers = HashMap<Int, SampleRingBuffer>()
    private val lastTimestampByPointer = HashMap<Int, Long>()
    private val activeTracks = LinkedHashMap<Int, TouchTrack>()
    private val featureExtractor = TouchFeatureExtractor(displayProfile)

    /** 当前用户手指行为模式（供桥接器直接读取） */
    var currentFingerMode: FingerActionMode = FingerActionMode.PAN_CANVAS

    /** 当前握笔姿态模式 */
    var currentHandednessMode: HandednessMode = HandednessMode.DEFAULT

    /** 是否曾观察到非零的 touchMajor 上报；为 false 时面积维度整体不可信 */
    var diameterReportAvailable: Boolean = false
        private set

    /** 驱动的 getTouchMajor 与 getSize 是否同时缺失（此时只能靠运动学） */
    var sizeFallbackUsed: Boolean = false
        private set

    /** 累计解包出的采样点总数（遥测与诊断用） */
    var totalSamplesCollected: Long = 0L
        private set

    /** 已处理的事件帧数 */
    var totalPacketsCollected: Long = 0L
        private set

    fun bufferOf(pointerId: Int): SampleRingBuffer? = buffers[pointerId]

    /** 某 pointerId 的时间升序历史采样（含最近一次已采集的当前点） */
    fun historyOf(pointerId: Int): List<TouchSample> =
        buffers[pointerId]?.snapshotAll() ?: emptyList()

    /**
     * 清理超过 [timeoutMs]（默认 450ms~500ms）未更新的陈旧残留轨迹（Stale Tracks）。
     */
    fun pruneStaleTracks(currentTimeMs: Long, timeoutMs: Long = DEFAULT_STALE_TIMEOUT_MS) {
        val staleIds = ArrayList<Int>(4)
        for ((pid, lastTime) in lastTimestampByPointer) {
            if (currentTimeMs > lastTime && (currentTimeMs - lastTime) > timeoutMs) {
                staleIds.add(pid)
            }
        }
        for ((pid, track) in activeTracks) {
            if (track.isStale(currentTimeMs, timeoutMs) && pid !in staleIds) {
                staleIds.add(pid)
            }
        }
        for (pid in staleIds) {
            buffers[pid]?.clear()
            buffers.remove(pid)
            lastTimestampByPointer.remove(pid)
            activeTracks.remove(pid)
        }
    }

    /**
     * 解包一帧 [MotionEvent]，返回完整 [TouchPacket]。
     */
    fun collect(event: MotionEvent, pointMapper: TouchPointMapper? = null): TouchPacket {
        val action = event.actionMasked
        val pointerCount = event.pointerCount.coerceAtLeast(0)
        val actionIndex = if (pointerCount > 0) {
            event.actionIndex.coerceIn(0, pointerCount - 1)
        } else {
            0
        }
        val eventTime = event.eventTime

        // 每次收到 ACTION_DOWN（代表全新手势序列开始）时强制清空所有残留轨迹，并清理超时轨迹
        if (action == MotionEvent.ACTION_DOWN) {
            buffers.values.forEach { it.clear() }
            buffers.clear()
            lastTimestampByPointer.clear()
            activeTracks.clear()
        } else {
            pruneStaleTracks(eventTime, DEFAULT_STALE_TIMEOUT_MS)
            if (action == MotionEvent.ACTION_POINTER_DOWN && pointerCount > 0) {
                val downPid = event.getPointerId(actionIndex)
                buffers[downPid]?.clear()
                lastTimestampByPointer.remove(downPid)
                activeTracks.remove(downPid)
            }
        }

        val pointerIds = ArrayList<Int>(pointerCount)
        val points = LinkedHashMap<Int, MutableList<TouchSample>>(pointerCount)
        val historySize = event.historySize.coerceAtLeast(0)

        for (idx in 0 until pointerCount) {
            // 严格使用 pointerIndex (idx) 读取 MotionEvent 坐标与历史点，转化为 pointerId 索引环形缓冲区
            val pointerId = event.getPointerId(idx)
            val toolType = event.getToolType(idx)
            pointerIds.add(pointerId)

            val ring = buffers.getOrPut(pointerId) { SampleRingBuffer(ringCapacity) }
            val samples = ArrayList<TouchSample>(historySize + 1)

            // ---- 历史批处理点：还原被系统合并掉的 240Hz~360Hz 高频采样 ----
            for (h in 0 until historySize) {
                val rawMajor = maxOf(
                    event.getHistoricalTouchMajor(idx, h),
                    event.getHistoricalToolMajor(idx, h)
                )
                val rawMinor = maxOf(
                    event.getHistoricalTouchMinor(idx, h),
                    event.getHistoricalToolMinor(idx, h)
                )
                val histTime = event.getHistoricalEventTime(h)
                val viewX = event.getHistoricalX(idx, h)
                val viewY = event.getHistoricalY(idx, h)
                val normSize = event.getHistoricalSize(idx, h)
                val pressure = event.getHistoricalPressure(idx, h)
                val orientation = event.getHistoricalOrientation(idx, h)

                val slot = pushSampleIntoRing(
                    ring = ring,
                    pointerId = pointerId,
                    viewX = viewX,
                    viewY = viewY,
                    touchMajorPx = rawMajor,
                    touchMinorPx = rawMinor,
                    timeMs = histTime,
                    normalizedSize = normSize,
                    pressure = pressure,
                    orientation = orientation,
                    toolType = toolType,
                    isHistorical = true,
                    pointMapper = pointMapper
                )
                samples.add(slot.copySnapshot())
            }

            // ---- 当前点 ----
            val curMajor = maxOf(event.getTouchMajor(idx), event.getToolMajor(idx))
            val curMinor = maxOf(event.getTouchMinor(idx), event.getToolMinor(idx))
            val curSlot = pushSampleIntoRing(
                ring = ring,
                pointerId = pointerId,
                viewX = event.getX(idx),
                viewY = event.getY(idx),
                touchMajorPx = curMajor,
                touchMinorPx = curMinor,
                timeMs = eventTime,
                normalizedSize = event.getSize(idx),
                pressure = event.getPressure(idx),
                orientation = event.getOrientation(idx),
                toolType = toolType,
                isHistorical = false,
                pointMapper = pointMapper
            )
            samples.add(curSlot.copySnapshot())

            points[pointerId] = samples
            lastTimestampByPointer[pointerId] = eventTime
            totalSamplesCollected += samples.size

            // 同步更新 activeTracks
            updateActiveTrack(pointerId, samples)
        }

        if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
            buffers.values.forEach { it.clear() }
            buffers.clear()
            lastTimestampByPointer.clear()
            activeTracks.clear()
        } else if (action == MotionEvent.ACTION_POINTER_UP && pointerCount > 0) {
            val upPid = event.getPointerId(actionIndex)
            buffers[upPid]?.clear()
            buffers.remove(upPid)
            lastTimestampByPointer.remove(upPid)
            activeTracks.remove(upPid)
        }

        totalPacketsCollected++

        return TouchPacket(
            action = action,
            actionIndex = actionIndex,
            eventTimeMs = eventTime,
            pointerIds = pointerIds,
            points = points,
            diameterReportAvailable = diameterReportAvailable
        )
    }

    /**
     * 解包并返回当前所有活动指针的 [TouchTrack] 列表（供直接轨迹评估模式调用）。
     */
    fun collectTracks(event: MotionEvent, pointMapper: TouchPointMapper? = null): List<TouchTrack> {
        collect(event, pointMapper)
        return activeTracks.values.toList()
    }

    private fun updateActiveTrack(pointerId: Int, samples: List<TouchSample>) {
        if (samples.isEmpty()) return
        val existing = activeTracks[pointerId]
        val trail = if (existing != null) {
            listOfNotNull(existing.previousFeatures, existing.lastFeatures)
        } else {
            emptyList<TouchFeatures>()
        }
        val extracted = featureExtractor.extractSequence(samples, trail, currentHandednessMode)
        if (extracted.isEmpty()) return

        if (existing == null) {
            val first = extracted.first()
            val track = TouchTrack(
                pointerId = pointerId,
                startFeatures = first,
                startTimeMs = first.timeMs,
                density = displayProfile.density
            )
            for (i in 1 until extracted.size) {
                track.append(extracted[i])
            }
            activeTracks[pointerId] = track
        } else {
            for (feat in extracted) {
                existing.append(feat)
            }
        }
    }

    private fun pushSampleIntoRing(
        ring: SampleRingBuffer,
        pointerId: Int,
        viewX: Float,
        viewY: Float,
        touchMajorPx: Float,
        touchMinorPx: Float,
        timeMs: Long,
        normalizedSize: Float,
        pressure: Float,
        orientation: Float,
        toolType: Int,
        isHistorical: Boolean,
        pointMapper: TouchPointMapper? = null
    ): TouchSample {
        var major = touchMajorPx
        var minor = touchMinorPx

        if (major > 0f) {
            diameterReportAvailable = true
        } else {
            val fallback = displayProfile.fallbackDiameterPx(normalizedSize)
            if (fallback > 0f) {
                major = fallback
                sizeFallbackUsed = true
            }
        }
        if (minor <= 0f) minor = major

        val mapped = pointMapper?.map(viewX, viewY)
        val contentX = mapped?.getOrNull(0) ?: viewX
        val contentY = mapped?.getOrNull(1) ?: viewY

        return ring.push(
            pointerId = pointerId,
            timestampMillis = timeMs,
            x = viewX,
            y = viewY,
            pressure = pressure,
            touchMajor = major,
            touchMinor = minor,
            size = normalizedSize,
            orientation = orientation,
            toolType = toolType,
            isHistorical = isHistorical,
            contentX = contentX,
            contentY = contentY
        )
    }

    /** 某个 pointerId 抬起后回收其环形缓冲区 */
    fun release(pointerId: Int) {
        buffers[pointerId]?.clear()
        buffers.remove(pointerId)
        lastTimestampByPointer.remove(pointerId)
        activeTracks.remove(pointerId)
    }

    /** 全部清空（例如 Activity 重建、画布尺寸变化） */
    fun reset() {
        buffers.values.forEach { it.clear() }
        buffers.clear()
        lastTimestampByPointer.clear()
        activeTracks.clear()
        totalSamplesCollected = 0L
        totalPacketsCollected = 0L
        sizeFallbackUsed = false
        diameterReportAvailable = false
    }

    companion object {
        const val DEFAULT_STALE_TIMEOUT_MS = 450L
    }
}
