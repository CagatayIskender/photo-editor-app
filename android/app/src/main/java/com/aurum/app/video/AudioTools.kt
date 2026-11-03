package com.aurum.app.video

import android.media.AudioFormat as PlatformAudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import com.aurum.core.BeatDetector
import com.aurum.core.BeatGrid
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes a song to mono PCM with MediaExtractor and MediaCodec and finds its
 * tempo with the shared [BeatDetector] (onset envelope and autocorrelation,
 * the same method as iOS). Only the first minute is analysed.
 */
object BeatAnalyzer {
    private const val MAX_SECONDS = 60

    fun analyze(file: File): BeatGrid? = runCatching { decode(file) }.getOrNull()?.let { (samples, rate) ->
        BeatDetector.detect(samples, rate.toDouble())
    }

    private fun decode(file: File): Pair<FloatArray, Int>? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(file.absolutePath)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var isFloat = false
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()

            var out = FloatArray(sampleRate * 10)
            var count = 0
            val info = MediaCodec.BufferInfo()
            var inputDone = false
            var outputDone = false
            while (!outputDone) {
                if (!inputDone) {
                    val inIndex = decoder.dequeueInputBuffer(10_000)
                    if (inIndex >= 0) {
                        val buffer = decoder.getInputBuffer(inIndex) ?: break
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0 || extractor.sampleTime > MAX_SECONDS * 1_000_000L) {
                            decoder.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                when (val outIndex = decoder.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val f = decoder.outputFormat
                        sampleRate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        channels = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        isFloat = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                            f.getInteger(MediaFormat.KEY_PCM_ENCODING) == PlatformAudioFormat.ENCODING_PCM_FLOAT
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (outIndex >= 0) {
                        val buffer = decoder.getOutputBuffer(outIndex)
                        if (buffer != null && info.size > 0) {
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            val pcm = buffer.slice().order(ByteOrder.nativeOrder())
                            val frames = if (isFloat) info.size / (4 * channels) else info.size / (2 * channels)
                            if (count + frames > out.size) out = out.copyOf(maxOf(out.size * 2, count + frames))
                            for (f in 0 until frames) {
                                var sum = 0f
                                for (c in 0 until channels) {
                                    sum += if (isFloat) pcm.getFloat((f * channels + c) * 4) else pcm.getShort((f * channels + c) * 2) / 32768f
                                }
                                out[count++] = sum / channels
                            }
                        }
                        decoder.releaseOutputBuffer(outIndex, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                    }
                }
            }
            return out.copyOf(count) to sampleRate
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            extractor.release()
        }
    }
}

/**
 * Multiplies audio by a gain that changes over time (seconds since the
 * stream started): clip volume with its fade-in, or music with its fades.
 * Handles 16-bit and float PCM.
 */
@UnstableApi
class GainAudioProcessor(private val gainAt: (Double) -> Float) : BaseAudioProcessor() {
    private var framesDone = 0L

    override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
        }
        return inputAudioFormat
    }

    override fun queueInput(inputBuffer: ByteBuffer) {
        val format = inputAudioFormat
        val remaining = inputBuffer.remaining()
        if (remaining == 0) return
        val out = replaceOutputBuffer(remaining)
        val channels = maxOf(1, format.channelCount)
        val rate = maxOf(1, format.sampleRate).toDouble()
        val isFloat = format.encoding == C.ENCODING_PCM_FLOAT
        val bytesPerSample = if (isFloat) 4 else 2
        val frames = remaining / (bytesPerSample * channels)
        val order = inputBuffer.order()
        inputBuffer.order(ByteOrder.nativeOrder())
        for (f in 0 until frames) {
            val g = gainAt((framesDone + f) / rate)
            for (c in 0 until channels) {
                if (isFloat) {
                    out.putFloat(inputBuffer.float * g)
                } else {
                    val v = (inputBuffer.short * g).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    out.putShort(v.toShort())
                }
            }
        }
        // Any trailing partial frame is passed through unchanged.
        while (inputBuffer.hasRemaining()) out.put(inputBuffer.get())
        inputBuffer.order(order)
        framesDone += frames
        out.flip()
    }

    override fun onFlush() {
        framesDone = 0
    }

    override fun onReset() {
        framesDone = 0
    }
}
