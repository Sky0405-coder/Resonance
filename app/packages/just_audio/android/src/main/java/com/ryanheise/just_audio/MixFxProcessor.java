package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Random;

/**
 * Resonance's mix effects for one player (transition editor): a three-band EQ, high- and low-pass filters, an echo,
 * a reverb, a noise riser, a beat loop and the dry level, all following an automation keyed by the song's own
 * position. It runs before the speed change, so its times are song times and an echo or loop stays on the beat when
 * the song is time-stretched.
 *
 * <p>The song position of the audio arriving here comes from the sink ({@link #markPosition}): the audio is processed
 * well before it is heard, so a change sent "now" would be early; keyed by song time it is heard exactly where planned.
 */
final class MixFxProcessor extends BaseAudioProcessor {
    /** The values of one automation step. */
    static final int DRY = 0, LOW = 1, MID = 2, HIGH = 3, HIGHPASS = 4, LOWPASS = 5, FX_IN = 6, ECHO = 7,
        REVERB = 8, NOISE = 9, PARAMS = 10;

    /** An automation: values every [stepUs] from [startUs] (song time), constant before and after. */
    static final class Automation {
        long startUs;
        long stepUs;
        float[][] values = new float[PARAMS][];
        double echoDelaySeconds = 0.5;
        double echoFeedback = 0.5;
        /** The loop: from [loopAtUs] on, the [loopSeconds] before it repeat (none when negative). */
        long loopAtUs = -1;
        double loopSeconds;

        int count() {
            return values[DRY].length;
        }

        float value(int param, double positionUs) {
            float[] v = values[param];
            double i = (positionUs - startUs) / stepUs;
            if (i <= 0) return v[0];
            int n = v.length;
            if (i >= n - 1) return v[n - 1];
            int a = (int) i;
            double f = i - a;
            return (float) (v[a] + (v[a + 1] - v[a]) * f);
        }
    }

    private static final int BLOCK = 32;
    private static final double MAX_ECHO_SECONDS = 3;

    private volatile Automation pending;
    private volatile boolean clearRequested;
    private Automation automation;

    /** Song position of the next input frame (µs), set by the sink when a new buffer comes in. */
    private volatile long markedUs = Long.MIN_VALUE;
    private double positionUs = Double.NaN;

    /** Fades the processed sound in and out (no click when an automation starts or ends mid-song). */
    private double engage;
    private double engageTarget;

    private int sampleRate;
    private int channels;
    private boolean isFloat;

    // DSP state per channel.
    private Biquad[] low, mid, high, highpass, lowpass;
    private float[][] echoLines;
    private int echoWrite;
    private Freeverb reverb;
    private final Random random = new Random();
    private float noiseState;

    // Loop: a ring of the recent input and the looped stretch.
    private float[][] ring;
    private int ringWrite;
    private long ringFilled;
    private float[][] loop;
    private int loopLength;
    private int loopRead;
    private boolean looping;

    private final float[] current = new float[PARAMS];

    void setAutomation(Automation automation) {
        pending = automation;
        clearRequested = false;
    }

    void clearAutomation() {
        clearRequested = true;
        pending = null;
    }

    void markPosition(long positionUs) {
        markedUs = positionUs;
    }

    /** The song position of the audio being processed (µs), or null before any. */
    Long position() {
        double p = positionUs;
        return Double.isNaN(p) ? null : (long) p;
    }

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat) {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            return AudioFormat.NOT_SET;
        }
        if (inputAudioFormat.channelCount < 1 || inputAudioFormat.channelCount > 8) return AudioFormat.NOT_SET;
        return inputAudioFormat;
    }

    @Override
    protected void onFlush() {
        sampleRate = inputAudioFormat.sampleRate;
        channels = inputAudioFormat.channelCount;
        isFloat = inputAudioFormat.encoding == C.ENCODING_PCM_FLOAT;
        positionUs = Double.NaN;
        int fx = Math.min(channels, 2);
        low = new Biquad[channels];
        mid = new Biquad[channels];
        high = new Biquad[channels];
        highpass = new Biquad[channels];
        lowpass = new Biquad[channels];
        for (int c = 0; c < channels; c++) {
            low[c] = new Biquad();
            mid[c] = new Biquad();
            high[c] = new Biquad();
            highpass[c] = new Biquad();
            lowpass[c] = new Biquad();
        }
        echoLines = new float[fx][(int) (MAX_ECHO_SECONDS * sampleRate) + 1];
        echoWrite = 0;
        reverb = new Freeverb(sampleRate);
        ring = null;
        loop = null;
        looping = false;
        // A seek or new stream starts clean; a running automation fades back in.
        engage = 0;
    }

    @Override
    protected void onReset() {
        automation = null;
        pending = null;
        ring = null;
        loop = null;
        looping = false;
    }

    @Override
    public void queueInput(ByteBuffer input) {
        int bytesPerFrame = inputAudioFormat.bytesPerFrame;
        int frames = input.remaining() / bytesPerFrame;
        if (frames == 0) return;
        ByteBuffer output = replaceOutputBuffer(frames * bytesPerFrame);
        input.order(ByteOrder.nativeOrder());

        long mark = markedUs;
        if (mark != Long.MIN_VALUE) {
            markedUs = Long.MIN_VALUE;
            positionUs = mark;
        }
        Automation next = pending;
        if (next != null) {
            pending = null;
            startAutomation(next);
        }
        if (clearRequested) {
            clearRequested = false;
            engageTarget = 0;
        }

        Automation a = automation;
        if (a == null && engage == 0) {
            // Nothing to do: pass the audio through unchanged.
            output.put(input);
            output.flip();
            advance(frames);
            return;
        }

        float[] in = new float[channels];
        float[] out = new float[channels];
        double framesPerUs = sampleRate / 1e6;
        int done = 0;
        while (done < frames) {
            int block = Math.min(BLOCK, frames - done);
            double at = Double.isNaN(positionUs) ? Double.NaN : positionUs;
            if (a != null) {
                for (int p = 0; p < PARAMS; p++) current[p] = Double.isNaN(at) ? a.values[p][0] : a.value(p, at);
                updateFilters();
                if (!looping && a.loopAtUs >= 0 && !Double.isNaN(at) && at >= a.loopAtUs) startLoop(a);
            }
            double engageStep = 1.0 / (0.02 * sampleRate);
            for (int i = 0; i < block; i++) {
                for (int c = 0; c < channels; c++) in[c] = read(input);
                if (ring != null) record(in);
                if (looping) {
                    for (int c = 0; c < channels; c++) in[c] = loop[Math.min(c, loop.length - 1)][loopRead];
                    loopRead = (loopRead + 1) % loopLength;
                }
                if (engage != engageTarget) {
                    engage = engage < engageTarget
                        ? Math.min(engageTarget, engage + engageStep)
                        : Math.max(engageTarget, engage - engageStep);
                }
                process(in, out);
                for (int c = 0; c < channels; c++) {
                    float sample = (float) (in[c] + (out[c] - in[c]) * engage);
                    write(output, sample);
                }
            }
            done += block;
            if (!Double.isNaN(positionUs)) positionUs += block / framesPerUs;
        }
        output.flip();
        // A cleared automation ends once its sound has faded back to the plain input.
        if (engage == 0 && engageTarget == 0) {
            automation = null;
            looping = false;
            loop = null;
            ring = null;
        }
    }

    private void advance(int frames) {
        if (!Double.isNaN(positionUs)) positionUs += frames * 1e6 / sampleRate;
    }

    private void startAutomation(Automation a) {
        automation = a;
        engageTarget = 1;
        looping = false;
        loop = null;
        if (a.loopAtUs >= 0 && a.loopSeconds > 0) {
            int length = (int) Math.round(a.loopSeconds * sampleRate);
            ring = new float[channels][length + sampleRate / 2];
            ringWrite = 0;
            ringFilled = 0;
        } else {
            ring = null;
        }
        float delay = (float) Math.max(0.01, Math.min(MAX_ECHO_SECONDS, a.echoDelaySeconds));
        a.echoDelaySeconds = delay;
    }

    private void record(float[] frame) {
        int size = ring[0].length;
        for (int c = 0; c < channels; c++) ring[c][ringWrite] = frame[c];
        ringWrite = (ringWrite + 1) % size;
        ringFilled++;
    }

    /** Takes the last [loopSeconds] of input as the loop; its end blends into the audio before it (no click). */
    private void startLoop(Automation a) {
        if (ring == null) return;
        int size = ring[0].length;
        int length = (int) Math.min(Math.round(a.loopSeconds * sampleRate), Math.min(size - 1, ringFilled));
        if (length < sampleRate / 20) return;
        int blend = Math.min(256, length / 4);
        loop = new float[channels][length];
        int start = ((ringWrite - length) % size + size) % size;
        for (int c = 0; c < channels; c++) {
            for (int i = 0; i < length; i++) loop[c][i] = ring[c][(start + i) % size];
            // The loop's last samples fade into those just before its start, so the jump back is seamless.
            for (int i = 0; i < blend; i++) {
                int at = length - blend + i;
                int before = ((start - blend + i) % size + size) % size;
                double w = (i + 1) / (double) blend;
                loop[c][at] = (float) (loop[c][at] * (1 - w) + ring[c][before] * w);
            }
        }
        loopLength = length;
        loopRead = 0;
        looping = true;
        ring = null;
    }

    private void updateFilters() {
        double nyquist = sampleRate / 2.0;
        for (int c = 0; c < channels; c++) {
            low[c].lowShelf(150, current[LOW], sampleRate);
            mid[c].peaking(1000, 0.7, current[MID], sampleRate);
            high[c].highShelf(4000, current[HIGH], sampleRate);
            highpass[c].highpass(Math.max(10, Math.min(current[HIGHPASS], nyquist * 0.9)), sampleRate);
            lowpass[c].lowpass(Math.max(40, Math.min(current[LOWPASS], nyquist * 0.9)), sampleRate);
        }
    }

    private void process(float[] in, float[] out) {
        Automation a = automation;
        boolean lowpassOn = a != null && current[LOWPASS] < 19000;
        boolean highpassOn = a != null && current[HIGHPASS] > 12;
        for (int c = 0; c < channels; c++) {
            double s = in[c];
            if (a != null) {
                s = low[c].process(s);
                s = mid[c].process(s);
                s = high[c].process(s);
                double h = highpass[c].process(s);
                double l = lowpass[c].process(highpassOn ? h : s);
                s = lowpassOn ? l : highpassOn ? h : s;
            }
            out[c] = (float) s;
        }
        if (a == null) return;
        float dry = current[DRY], fxIn = current[FX_IN], echo = current[ECHO], verb = current[REVERB];
        float noise = current[NOISE];
        int fxChannels = Math.min(channels, 2);
        double left = out[0] * fxIn, right = out[fxChannels - 1] * fxIn;
        // Echo: a delay line with feedback, on the beat.
        int size = echoLines[0].length;
        int delay = (int) Math.round(a.echoDelaySeconds * sampleRate);
        int read = ((echoWrite - delay) % size + size) % size;
        double el = echoLines[0][read], er = echoLines[fxChannels - 1][read];
        echoLines[0][echoWrite] = (float) (left + el * a.echoFeedback);
        if (fxChannels > 1) echoLines[1][echoWrite] = (float) (right + er * a.echoFeedback);
        echoWrite = (echoWrite + 1) % size;
        // Reverb (always fed, so its tail rings on after the input stops).
        double[] wet = reverb.process(left, right);
        // Noise: white noise, brighter as it gets louder.
        double n = 0;
        if (noise > 0) {
            double white = random.nextFloat() * 2 - 1;
            noiseState += (float) ((white - noiseState) * (0.08 + 0.8 * Math.min(1, noise)));
            n = noiseState * noise * 0.25;
        }
        for (int c = 0; c < channels; c++) {
            boolean right2 = c % 2 == 1 && fxChannels > 1;
            double e = right2 ? er : el;
            double w = right2 ? wet[1] : wet[0];
            out[c] = (float) (out[c] * dry + e * echo + w * verb + n);
        }
    }

    private float read(ByteBuffer input) {
        return isFloat ? input.getFloat() : input.getShort() / 32768f;
    }

    private void write(ByteBuffer output, float sample) {
        if (isFloat) {
            output.putFloat(sample);
        } else {
            int v = Math.round(sample * 32767f);
            output.putShort((short) Math.max(-32768, Math.min(32767, v)));
        }
    }

    /** RBJ cookbook biquad, transposed direct form II. */
    static final class Biquad {
        double b0 = 1, b1, b2, a1, a2, z1, z2;
        private double lastF = -1, lastG = Double.NaN, lastQ = -1;
        private int kind = -1;

        double process(double x) {
            double y = b0 * x + z1;
            z1 = b1 * x - a1 * y + z2;
            z2 = b2 * x - a2 * y;
            return y;
        }

        private boolean same(int kind, double f, double g, double q) {
            if (this.kind == kind && lastF == f && lastG == g && lastQ == q) return true;
            this.kind = kind;
            lastF = f;
            lastG = g;
            lastQ = q;
            return false;
        }

        private void set(double nb0, double nb1, double nb2, double na0, double na1, double na2) {
            b0 = nb0 / na0;
            b1 = nb1 / na0;
            b2 = nb2 / na0;
            a1 = na1 / na0;
            a2 = na2 / na0;
        }

        void lowShelf(double f, double gainDb, int rate) {
            if (same(0, f, gainDb, 0)) return;
            double A = Math.pow(10, gainDb / 40), w = 2 * Math.PI * f / rate;
            double cos = Math.cos(w), alpha = Math.sin(w) / 2 * Math.sqrt(2), s = 2 * Math.sqrt(A) * alpha;
            set(A * ((A + 1) - (A - 1) * cos + s), 2 * A * ((A - 1) - (A + 1) * cos), A * ((A + 1) - (A - 1) * cos - s),
                (A + 1) + (A - 1) * cos + s, -2 * ((A - 1) + (A + 1) * cos), (A + 1) + (A - 1) * cos - s);
        }

        void highShelf(double f, double gainDb, int rate) {
            if (same(1, f, gainDb, 0)) return;
            double A = Math.pow(10, gainDb / 40), w = 2 * Math.PI * f / rate;
            double cos = Math.cos(w), alpha = Math.sin(w) / 2 * Math.sqrt(2), s = 2 * Math.sqrt(A) * alpha;
            set(A * ((A + 1) + (A - 1) * cos + s), -2 * A * ((A - 1) + (A + 1) * cos), A * ((A + 1) + (A - 1) * cos - s),
                (A + 1) - (A - 1) * cos + s, 2 * ((A - 1) - (A + 1) * cos), (A + 1) - (A - 1) * cos - s);
        }

        void peaking(double f, double q, double gainDb, int rate) {
            if (same(2, f, gainDb, q)) return;
            double A = Math.pow(10, gainDb / 40), w = 2 * Math.PI * f / rate;
            double alpha = Math.sin(w) / (2 * q), cos = Math.cos(w);
            set(1 + alpha * A, -2 * cos, 1 - alpha * A, 1 + alpha / A, -2 * cos, 1 - alpha / A);
        }

        void highpass(double f, int rate) {
            if (same(3, f, 0, 0.7071)) return;
            double w = 2 * Math.PI * f / rate, alpha = Math.sin(w) / (2 * 0.7071), cos = Math.cos(w);
            set((1 + cos) / 2, -(1 + cos), (1 + cos) / 2, 1 + alpha, -2 * cos, 1 - alpha);
        }

        void lowpass(double f, int rate) {
            if (same(4, f, 0, 0.7071)) return;
            double w = 2 * Math.PI * f / rate, alpha = Math.sin(w) / (2 * 0.7071), cos = Math.cos(w);
            set((1 - cos) / 2, 1 - cos, (1 - cos) / 2, 1 + alpha, -2 * cos, 1 - alpha);
        }
    }

    /** A small Freeverb (Jezar's public-domain design): eight combs and four all-passes per side. */
    static final class Freeverb {
        private static final int[] COMBS = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
        private static final int[] ALLPASSES = {556, 441, 341, 225};
        private static final int SPREAD = 23;
        private final float[][][] comb = new float[2][COMBS.length][];
        private final int[][] combIndex = new int[2][COMBS.length];
        private final float[][] combStore = new float[2][COMBS.length];
        private final float[][][] allpass = new float[2][ALLPASSES.length][];
        private final int[][] allpassIndex = new int[2][ALLPASSES.length];
        private final double feedback = 0.84, damp = 0.25;
        private final double[] out = new double[2];

        Freeverb(int rate) {
            double scale = rate / 44100.0;
            for (int s = 0; s < 2; s++) {
                for (int i = 0; i < COMBS.length; i++) {
                    comb[s][i] = new float[(int) ((COMBS[i] + s * SPREAD) * scale) + 1];
                }
                for (int i = 0; i < ALLPASSES.length; i++) {
                    allpass[s][i] = new float[(int) ((ALLPASSES[i] + s * SPREAD) * scale) + 1];
                }
            }
        }

        double[] process(double left, double right) {
            double input = (left + right) * 0.015;
            for (int s = 0; s < 2; s++) {
                double acc = 0;
                for (int i = 0; i < COMBS.length; i++) {
                    float[] buf = comb[s][i];
                    int idx = combIndex[s][i];
                    float y = buf[idx];
                    combStore[s][i] = (float) (y * (1 - damp) + combStore[s][i] * damp);
                    buf[idx] = (float) (input + combStore[s][i] * feedback);
                    combIndex[s][i] = (idx + 1) % buf.length;
                    acc += y;
                }
                for (int i = 0; i < ALLPASSES.length; i++) {
                    float[] buf = allpass[s][i];
                    int idx = allpassIndex[s][i];
                    float b = buf[idx];
                    buf[idx] = (float) (acc + b * 0.5);
                    acc = b - acc;
                    allpassIndex[s][i] = (idx + 1) % buf.length;
                }
                out[s] = acc * 3;
            }
            return out;
        }
    }
}
