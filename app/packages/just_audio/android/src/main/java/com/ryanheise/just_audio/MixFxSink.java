package com.ryanheise.just_audio;

import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;
import java.nio.ByteBuffer;

/** Tells the mix processor the song position of each buffer as it enters the sink (and its effects). */
final class MixFxSink extends ForwardingAudioSink {
    private final MixFxProcessor processor;
    private long outputStreamOffsetUs;
    private ByteBuffer lastBuffer;
    private long lastPresentationTimeUs = Long.MIN_VALUE;

    MixFxSink(AudioSink sink, MixFxProcessor processor) {
        super(sink);
        this.processor = processor;
    }

    @Override
    public void setOutputStreamOffsetUs(long outputStreamOffsetUs) {
        this.outputStreamOffsetUs = outputStreamOffsetUs;
        super.setOutputStreamOffsetUs(outputStreamOffsetUs);
    }

    @Override
    public boolean handleBuffer(ByteBuffer buffer, long presentationTimeUs, int encodedAccessUnitCount)
        throws InitializationException, WriteException {
        // The sink is handed the same buffer again until it took all of it; only a new one starts a new position.
        if (buffer != lastBuffer || presentationTimeUs != lastPresentationTimeUs) {
            lastBuffer = buffer;
            lastPresentationTimeUs = presentationTimeUs;
            processor.markPosition(presentationTimeUs - outputStreamOffsetUs);
        }
        return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount);
    }

    @Override
    public void flush() {
        lastBuffer = null;
        lastPresentationTimeUs = Long.MIN_VALUE;
        super.flush();
    }
}
