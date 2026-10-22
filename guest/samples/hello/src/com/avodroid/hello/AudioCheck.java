package com.avodroid.hello;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.widget.TextView;

/** Speaker and microphone through Android's audio stack (Avo plays them on the Mac). */
final class AudioCheck {
    private static final int RATE = 48000;

    private AudioCheck() {}

    /** One second of A4 on the media stream. */
    static void playTone() {
        new Thread(() -> {
            short[] samples = new short[RATE * 2];
            int fade = RATE / 50;
            for (int i = 0; i < RATE; i++) {
                double envelope = Math.min(1, Math.min(i, RATE - i) / (double) fade);
                short value = (short) (0.25 * Short.MAX_VALUE * envelope * Math.sin(2 * Math.PI * 440 * i / RATE));
                samples[2 * i] = value;
                samples[2 * i + 1] = value;
            }
            play(samples, AudioFormat.CHANNEL_OUT_STEREO);
        }, "tone").start();
    }

    /** Records three seconds, shows how loud it was and plays it back. */
    static void testMicrophone(TextView status) {
        Handler main = new Handler(Looper.getMainLooper());
        status.setText("Mikrofon: merekam 3 detik…");
        new Thread(() -> {
            int minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
            short[] samples = new short[RATE * 3];
            AudioRecord record;
            try {
                record = new AudioRecord(MediaRecorder.AudioSource.MIC, RATE, AudioFormat.CHANNEL_IN_MONO,
                        AudioFormat.ENCODING_PCM_16BIT, Math.max(minimum, RATE / 5 * 2));
            } catch (SecurityException | IllegalArgumentException e) {
                main.post(() -> status.setText("Mikrofon: tidak bisa dibuka (" + e.getMessage() + ")"));
                return;
            }
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                record.release();
                main.post(() -> status.setText("Mikrofon: tidak ada"));
                return;
            }
            record.startRecording();
            int read = 0;
            while (read < samples.length) {
                int n = record.read(samples, read, samples.length - read);
                if (n <= 0) break;
                read += n;
            }
            record.stop();
            record.release();
            int peak = 0;
            for (int i = 0; i < read; i++) peak = Math.max(peak, Math.abs((int) samples[i]));
            String level = peak == 0 ? "hening — izinkan mikrofon untuk Avo di Pengaturan Sistem macOS"
                    : String.format("puncak %.0f dBFS", 20 * Math.log10(peak / 32768.0));
            int frames = read;
            Log.i("AvoHello", "microphone: " + frames * 1000 / RATE + " ms recorded, peak " + peak);
            main.post(() -> status.setText("Mikrofon: " + frames * 1000 / RATE + " ms, " + level + " · memutar ulang"));
            short[] recorded = new short[frames];
            System.arraycopy(samples, 0, recorded, 0, frames);
            play(recorded, AudioFormat.CHANNEL_OUT_MONO);
            main.post(() -> status.setText("Mikrofon: " + level));
        }, "microphone").start();
    }

    private static void play(short[] samples, int channels) {
        AudioTrack track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(RATE)
                        .setChannelMask(channels)
                        .build())
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build();
        track.play();
        track.write(samples, 0, samples.length);
        // Wait for it to play out before letting go of the track.
        int frames = channels == AudioFormat.CHANNEL_OUT_STEREO ? samples.length / 2 : samples.length;
        long deadline = System.currentTimeMillis() + frames * 1000L / RATE + 1000;
        while (track.getPlaybackHeadPosition() < frames && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(20);
            } catch (InterruptedException e) {
                break;
            }
        }
        track.stop();
        track.release();
    }
}
