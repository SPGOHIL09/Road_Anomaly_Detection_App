package com.example.road_anomaly_detector;

import android.graphics.SurfaceTexture;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLExt;
import android.opengl.EGLSurface;
import android.opengl.GLES11Ext;
import android.opengl.GLES30;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Decodes a video with the phone's hardware decoder (MediaCodec) straight
 * into a GPU texture, rotates and area-downscales it there with OpenGL ES,
 * and reads back only the small RGB frame the detector needs.
 *
 * Frames that are not sampled are decoded and dropped without touching the
 * GPU or the CPU, so a 4K video costs little more than the decoder itself.
 *
 * All methods except {@link #run} and {@link #shutdown} must be called on
 * the decoder's own thread (use {@link #run}); the EGL context lives there.
 */
final class HwVideoDecoder {
    /** A downscaled, upright RGB frame. */
    static final class Frame {
        final long relUs;       // presentation time relative to the first frame
        final int index;        // decode order index (output order)
        final byte[] rgb;       // width * height * 3, top row first
        Frame(long relUs, int index, byte[] rgb) {
            this.relUs = relUs;
            this.index = index;
            this.rgb = rgb;
        }
    }

    private final ExecutorService executor = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "HwVideoDecoder");
        t.setPriority(Thread.NORM_PRIORITY + 1);
        return t;
    });
    private HandlerThread frameThread;

    private MediaExtractor extractor;
    private MediaCodec codec;
    private final MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
    private boolean inputDone;
    private boolean outputDone;

    private EGLDisplay eglDisplay = EGL14.EGL_NO_DISPLAY;
    private EGLContext eglContext = EGL14.EGL_NO_CONTEXT;
    private EGLSurface eglSurface = EGL14.EGL_NO_SURFACE;
    private int oesTex;
    private SurfaceTexture surfaceTexture;
    private Surface surface;
    private final Object frameLock = new Object();
    private boolean frameAvailable;

    private int program;
    boolean preferYuv = true;
    private int aPos, uTex, uST, uOut, uRot, uTaps;
    private FloatBuffer quad;
    private int fbo, fboTex, fboW, fboH;
    private ByteBuffer readBuf;
    private byte[] rgbaScratch;
    boolean readRgb;        // packed RGB readback supported by the driver
    private final float[] stMatrix = new float[16];

    // Video properties.
    String codecName;
    int width;           // decoded picture width (before rotation)
    int height;
    int meta;            // container rotation tag (clockwise degrees)
    int rotation;        // rotation applied to frames (clockwise degrees)
    long durationUs;
    float frameRate;

    private long firstPtsUs = Long.MIN_VALUE;
    private long lastRelUs = Long.MIN_VALUE;
    int decodedFrames;   // frames output by the decoder so far
    int renderedFrames;

    // Timing (nanoseconds) for diagnostics.
    long waitNs, drawNs, readNs;

    interface Task<T> { T call() throws Exception; }
    interface Callback<T> { void done(T value, Exception error); }

    <T> void run(Task<T> task, Callback<T> cb) {
        executor.execute(() -> {
            T value = null;
            Exception error = null;
            try {
                value = task.call();
            } catch (Exception e) {
                error = e;
            }
            cb.done(value, error);
        });
    }

    /** Releases everything on the decoder thread, then stops the thread. */
    void shutdown() {
        executor.execute(this::release);
        executor.shutdown();
    }

    // ───────────────────────────── open ─────────────────────────────

    /**
     * Opens [path]. When [expectPortrait] is given, frames are rotated so
     * their orientation matches what the player shows (same rule as the
     * FFmpeg path in VideoAnalysisService).
     */
    void open(String path, Boolean expectPortrait) throws IOException {
        extractor = new MediaExtractor();
        extractor.setDataSource(path);
        int track = -1;
        MediaFormat format = null;
        for (int i = 0; i < extractor.getTrackCount(); i++) {
            MediaFormat f = extractor.getTrackFormat(i);
            String mime = f.getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith("video/")) {
                track = i;
                format = f;
                break;
            }
        }
        if (track < 0) throw new IOException("No video track");
        extractor.selectTrack(track);

        String mime = format.getString(MediaFormat.KEY_MIME);
        width = format.getInteger(MediaFormat.KEY_WIDTH);
        height = format.getInteger(MediaFormat.KEY_HEIGHT);
        int rot = format.containsKey(MediaFormat.KEY_ROTATION)
                ? format.getInteger(MediaFormat.KEY_ROTATION) : 0;
        meta = ((rot % 360) + 360) % 360;
        rotation = meta;
        if (expectPortrait != null) {
            boolean rawPortrait = height > width;
            rotation = rawPortrait == expectPortrait
                    ? (meta == 180 ? 180 : 0)
                    : (meta == 270 ? 270 : 90);
        }
        // We rotate in our own shader; keep the codec from rotating too.
        if (format.containsKey(MediaFormat.KEY_ROTATION)) {
            format.setInteger(MediaFormat.KEY_ROTATION, 0);
        }
        durationUs = format.containsKey(MediaFormat.KEY_DURATION)
                ? format.getLong(MediaFormat.KEY_DURATION) : 0;
        frameRate = 0;
        if (format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
            try {
                frameRate = format.getInteger(MediaFormat.KEY_FRAME_RATE);
            } catch (ClassCastException e) {
                frameRate = format.getFloat(MediaFormat.KEY_FRAME_RATE);
            }
        }

        setUpGl();

        codec = MediaCodec.createDecoderByType(mime);
        codecName = codec.getName();
        codec.configure(format, surface, null, 0);
        codec.start();
    }

    /** Width of the upright frame. */
    int uprightWidth() {
        return (rotation == 90 || rotation == 270) ? height : width;
    }

    int uprightHeight() {
        return (rotation == 90 || rotation == 270) ? width : height;
    }

    // ───────────────────────────── decode ─────────────────────────────

    /**
     * Decodes (and drops) frames until one whose time relative to the first
     * frame is at least [minRelUs], then returns it rotated and downscaled to
     * [outW] x [outH] RGB. Returns null at the end of the video.
     */
    Frame next(long minRelUs, int outW, int outH) {
        while (!outputDone) {
            feedInput();
            int index = codec.dequeueOutputBuffer(info, 5000);
            if (index < 0) continue; // try again / format or buffers changed
            boolean eos = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            if (eos) outputDone = true;
            if (info.size == 0 && eos) {
                codec.releaseOutputBuffer(index, false);
                break;
            }
            long pts = info.presentationTimeUs;
            if (firstPtsUs == Long.MIN_VALUE) firstPtsUs = pts;
            long rel = pts - firstPtsUs;
            // Keep timestamps strictly increasing whatever the container says.
            if (lastRelUs != Long.MIN_VALUE && rel <= lastRelUs) rel = lastRelUs + 1;
            lastRelUs = rel;
            int frameIndex = decodedFrames++;
            if (rel < minRelUs) {
                codec.releaseOutputBuffer(index, false);
                continue;
            }
            codec.releaseOutputBuffer(index, true);
            byte[] rgb = renderLatest(outW, outH);
            renderedFrames++;
            return new Frame(rel, frameIndex, rgb);
        }
        return null;
    }

    private void feedInput() {
        while (!inputDone) {
            int in = codec.dequeueInputBuffer(0);
            if (in < 0) return;
            ByteBuffer buf = codec.getInputBuffer(in);
            int size = extractor.readSampleData(buf, 0);
            if (size < 0) {
                codec.queueInputBuffer(in, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                inputDone = true;
                return;
            }
            codec.queueInputBuffer(in, 0, size, extractor.getSampleTime(), 0);
            extractor.advance();
        }
    }

    private byte[] renderLatest(int outW, int outH) {
        long t0 = System.nanoTime();
        synchronized (frameLock) {
            long deadline = System.currentTimeMillis() + 2000;
            while (!frameAvailable) {
                long left = deadline - System.currentTimeMillis();
                if (left <= 0) throw new IllegalStateException("Decoded frame never arrived");
                try {
                    frameLock.wait(left);
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException(e);
                }
            }
            frameAvailable = false;
        }
        surfaceTexture.updateTexImage();
        surfaceTexture.getTransformMatrix(stMatrix);
        long t1 = System.nanoTime();

        ensureTarget(outW, outH);
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo);
        GLES30.glViewport(0, 0, outW, outH);
        GLES30.glUseProgram(program);
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0);
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex);
        GLES30.glUniform1i(uTex, 0);
        GLES30.glUniformMatrix4fv(uST, 1, false, stMatrix, 0);
        GLES30.glUniform2f(uOut, outW, outH);
        GLES30.glUniform1i(uRot, rotation / 90);
        // Area filter: each bilinear tap averages 2x2 source pixels, so
        // ceil(scale / 2) taps per axis cover the whole source footprint.
        float sx = (float) uprightWidth() / outW;
        float sy = (float) uprightHeight() / outH;
        GLES30.glUniform2i(uTaps,
                Math.max(1, (int) Math.ceil(sx / 2 - 1e-3)),
                Math.max(1, (int) Math.ceil(sy / 2 - 1e-3)));
        GLES30.glEnableVertexAttribArray(aPos);
        GLES30.glVertexAttribPointer(aPos, 2, GLES30.GL_FLOAT, false, 0, quad);
        GLES30.glDrawArrays(GLES30.GL_TRIANGLE_STRIP, 0, 4);
        long t2 = System.nanoTime();

        // Framebuffer row 0 holds the image's top row, so the readback is
        // already top-down.
        int n = outW * outH;
        byte[] rgb = new byte[n * 3];
        readBuf.clear();
        if (readRgb) {
            GLES30.glReadPixels(0, 0, outW, outH, GLES30.GL_RGB, GLES30.GL_UNSIGNED_BYTE, readBuf);
            readBuf.get(rgb, 0, n * 3);
        } else {
            GLES30.glReadPixels(0, 0, outW, outH, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE, readBuf);
            readBuf.get(rgbaScratch, 0, n * 4);
            for (int i = 0, j = 0, k = 0; i < n; i++, j += 4, k += 3) {
                rgb[k] = rgbaScratch[j];
                rgb[k + 1] = rgbaScratch[j + 1];
                rgb[k + 2] = rgbaScratch[j + 2];
            }
        }
        long t3 = System.nanoTime();
        waitNs += t1 - t0;
        drawNs += t2 - t1;
        readNs += t3 - t2;
        return rgb;
    }

    // ───────────────────────────── GL ─────────────────────────────

    private static final String VERTEX =
            "#version 300 es\n"
            + "in vec2 aPos;\n"
            + "void main() { gl_Position = vec4(aPos, 0.0, 1.0); }\n";

    // uv is in output-image space with (0,0) at the top-left. uRot rotates
    // the source clockwise by uRot quarter turns (as OpenCV's ROTATE_*), and
    // uST is the SurfaceTexture transform (GL convention: origin bottom-left).
    private static final String FRAGMENT =
            "#version 300 es\n"
            + "#extension GL_OES_EGL_image_external_essl3 : require\n"
            + "precision highp float;\n"
            + "uniform samplerExternalOES uTex;\n"
            + "uniform mat4 uST;\n"
            + "uniform vec2 uOut;\n"
            + "uniform int uRot;\n"
            + "uniform ivec2 uTaps;\n"
            + "out vec4 outColor;\n"
            + "vec2 srcCoord(vec2 uv) {\n"
            + "  vec2 s;\n"
            + "  if (uRot == 1) s = vec2(uv.y, 1.0 - uv.x);\n"
            + "  else if (uRot == 2) s = vec2(1.0 - uv.x, 1.0 - uv.y);\n"
            + "  else if (uRot == 3) s = vec2(1.0 - uv.y, uv.x);\n"
            + "  else s = uv;\n"
            + "  return (uST * vec4(s.x, 1.0 - s.y, 0.0, 1.0)).xy;\n"
            + "}\n"
            + "void main() {\n"
            + "  vec2 px = floor(gl_FragCoord.xy);\n"
            + "  vec2 n = vec2(uTaps);\n"
            + "  vec4 acc = vec4(0.0);\n"
            + "  for (int j = 0; j < uTaps.y; j++) {\n"
            + "    for (int i = 0; i < uTaps.x; i++) {\n"
            + "      vec2 o = (vec2(float(i), float(j)) + 0.5) / n;\n"
            + "      acc += texture(uTex, srcCoord((px + o) / uOut));\n"
            + "    }\n"
            + "  }\n"
            + "  outColor = vec4((acc / (n.x * n.y)).rgb, 1.0);\n"
            + "}\n";

    // Raw YUV sampling (GL_EXT_YUV_target) converted with the BT.601
    // limited-range matrix, which is what OpenCV's FFmpeg backend (swscale
    // defaults) uses, so frames match the software path's colours.
    private static final String FRAGMENT_YUV = FRAGMENT
            .replace("#extension GL_OES_EGL_image_external_essl3 : require\n",
                    "#extension GL_EXT_YUV_target : require\n")
            .replace("uniform samplerExternalOES uTex;\n",
                    "uniform __samplerExternal2DY2YEXT uTex;\n"
                    + "vec4 rgb601(vec4 yuv) {\n"
                    + "  float y = 1.164383 * (yuv.x * 255.0 - 16.0);\n"
                    + "  float u = yuv.y * 255.0 - 128.0;\n"
                    + "  float v = yuv.z * 255.0 - 128.0;\n"
                    + "  return clamp(vec4(y + 1.596027 * v, y - 0.391762 * u - 0.812968 * v,\n"
                    + "      y + 2.017232 * u, 255.0) / 255.0, 0.0, 1.0);\n"
                    + "}\n")
            .replace("acc += texture(uTex, srcCoord((px + o) / uOut));",
                    "acc += rgb601(texture(uTex, srcCoord((px + o) / uOut)));");

    /** Whether frames are converted from raw YUV with BT.601 (else the driver's RGB). */
    boolean yuv601;
    String glExtensions;

    private void setUpGl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
        int[] version = new int[2];
        if (!EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) {
            throw new IllegalStateException("eglInitialize failed");
        }
        int[] attribs = {
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8,
                EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
                EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE,
        };
        EGLConfig[] configs = new EGLConfig[1];
        int[] count = new int[1];
        if (!EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, count, 0)
                || count[0] == 0) {
            throw new IllegalStateException("No EGL config");
        }
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT,
                new int[]{EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE}, 0);
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw new IllegalStateException("No EGL context");
        eglSurface = EGL14.eglCreatePbufferSurface(eglDisplay, configs[0],
                new int[]{EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE}, 0);
        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw new IllegalStateException("eglMakeCurrent failed");
        }

        int[] tex = new int[1];
        GLES30.glGenTextures(1, tex, 0);
        oesTex = tex[0];
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTex);
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR);
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE);
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE);

        frameThread = new HandlerThread("HwVideoDecoderFrames");
        frameThread.start();
        surfaceTexture = new SurfaceTexture(oesTex);
        surfaceTexture.setOnFrameAvailableListener(st -> {
            synchronized (frameLock) {
                frameAvailable = true;
                frameLock.notifyAll();
            }
        }, new Handler(frameThread.getLooper()));
        surface = new Surface(surfaceTexture);

        glExtensions = GLES30.glGetString(GLES30.GL_EXTENSIONS);
        program = 0;
        if (preferYuv && glExtensions != null && glExtensions.contains("GL_EXT_YUV_target")) {
            try {
                program = buildProgram(VERTEX, FRAGMENT_YUV);
                yuv601 = true;
            } catch (IllegalStateException e) {
                program = 0;
            }
        }
        if (program == 0) program = buildProgram(VERTEX, FRAGMENT);
        aPos = GLES30.glGetAttribLocation(program, "aPos");
        uTex = GLES30.glGetUniformLocation(program, "uTex");
        uST = GLES30.glGetUniformLocation(program, "uST");
        uOut = GLES30.glGetUniformLocation(program, "uOut");
        uRot = GLES30.glGetUniformLocation(program, "uRot");
        uTaps = GLES30.glGetUniformLocation(program, "uTaps");
        float[] verts = {-1, -1, 1, -1, -1, 1, 1, 1};
        quad = ByteBuffer.allocateDirect(verts.length * 4)
                .order(ByteOrder.nativeOrder()).asFloatBuffer();
        quad.put(verts).position(0);
    }

    private void ensureTarget(int w, int h) {
        if (fbo != 0 && w == fboW && h == fboH) return;
        if (fbo != 0) {
            GLES30.glDeleteFramebuffers(1, new int[]{fbo}, 0);
            GLES30.glDeleteTextures(1, new int[]{fboTex}, 0);
        }
        int[] ids = new int[1];
        GLES30.glGenTextures(1, ids, 0);
        fboTex = ids[0];
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTex);
        GLES30.glGenFramebuffers(1, ids, 0);
        fbo = ids[0];
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, fbo);
        // Prefer an RGB8 target the driver can read back as packed RGB
        // (no per-pixel repacking on the CPU); fall back to RGBA8.
        readRgb = false;
        GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGB8, w, h);
        GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                GLES30.GL_TEXTURE_2D, fboTex, 0);
        if (GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) == GLES30.GL_FRAMEBUFFER_COMPLETE) {
            int[] fmt = new int[2];
            GLES30.glGetIntegerv(GLES30.GL_IMPLEMENTATION_COLOR_READ_FORMAT, fmt, 0);
            GLES30.glGetIntegerv(GLES30.GL_IMPLEMENTATION_COLOR_READ_TYPE, fmt, 1);
            readRgb = fmt[0] == GLES30.GL_RGB && fmt[1] == GLES30.GL_UNSIGNED_BYTE;
        }
        if (!readRgb) {
            // Immutable storage cannot be respecified: start over with RGBA8.
            GLES30.glDeleteTextures(1, ids, 0);
            GLES30.glGenTextures(1, ids, 0);
            fboTex = ids[0];
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, fboTex);
            GLES30.glTexStorage2D(GLES30.GL_TEXTURE_2D, 1, GLES30.GL_RGBA8, w, h);
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0,
                    GLES30.GL_TEXTURE_2D, fboTex, 0);
        }
        int status = GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER);
        if (status != GLES30.GL_FRAMEBUFFER_COMPLETE) {
            throw new IllegalStateException("Framebuffer incomplete: " + status);
        }
        GLES30.glPixelStorei(GLES30.GL_PACK_ALIGNMENT, 1);
        fboW = w;
        fboH = h;
        readBuf = ByteBuffer.allocateDirect(w * h * 4).order(ByteOrder.nativeOrder());
        rgbaScratch = readRgb ? null : new byte[w * h * 4];
    }

    private static int buildProgram(String vs, String fs) {
        int v = compile(GLES30.GL_VERTEX_SHADER, vs);
        int f = compile(GLES30.GL_FRAGMENT_SHADER, fs);
        int p = GLES30.glCreateProgram();
        GLES30.glAttachShader(p, v);
        GLES30.glAttachShader(p, f);
        GLES30.glLinkProgram(p);
        int[] ok = new int[1];
        GLES30.glGetProgramiv(p, GLES30.GL_LINK_STATUS, ok, 0);
        if (ok[0] == 0) {
            String log = GLES30.glGetProgramInfoLog(p);
            GLES30.glDeleteProgram(p);
            throw new IllegalStateException("Link failed: " + log);
        }
        GLES30.glDeleteShader(v);
        GLES30.glDeleteShader(f);
        return p;
    }

    private static int compile(int type, String src) {
        int s = GLES30.glCreateShader(type);
        GLES30.glShaderSource(s, src);
        GLES30.glCompileShader(s);
        int[] ok = new int[1];
        GLES30.glGetShaderiv(s, GLES30.GL_COMPILE_STATUS, ok, 0);
        if (ok[0] == 0) {
            String log = GLES30.glGetShaderInfoLog(s);
            GLES30.glDeleteShader(s);
            throw new IllegalStateException("Shader compile failed: " + log);
        }
        return s;
    }

    // ───────────────────────────── release ─────────────────────────────

    private void release() {
        if (renderedFrames > 0) {
            Log.i("HwVideoDecoder", String.format(java.util.Locale.US,
                    "%s: %d frames decoded, %d read back (rgb readback %b, BT.601 %b); "
                    + "per readback: wait %.2f ms, draw %.2f ms, read %.2f ms",
                    codecName, decodedFrames, renderedFrames, readRgb, yuv601,
                    waitNs / 1e6 / renderedFrames, drawNs / 1e6 / renderedFrames,
                    readNs / 1e6 / renderedFrames));
        }
        if (codec != null) {
            try {
                codec.stop();
            } catch (Exception ignored) {
            }
            codec.release();
            codec = null;
        }
        if (extractor != null) {
            extractor.release();
            extractor = null;
        }
        if (surface != null) {
            surface.release();
            surface = null;
        }
        if (surfaceTexture != null) {
            surfaceTexture.release();
            surfaceTexture = null;
        }
        if (frameThread != null) {
            frameThread.quitSafely();
            frameThread = null;
        }
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            if (program != 0) GLES30.glDeleteProgram(program);
            if (fbo != 0) GLES30.glDeleteFramebuffers(1, new int[]{fbo}, 0);
            if (fboTex != 0) GLES30.glDeleteTextures(1, new int[]{fboTex}, 0);
            if (oesTex != 0) GLES30.glDeleteTextures(1, new int[]{oesTex}, 0);
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT);
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface);
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext);
            EGL14.eglReleaseThread();
            EGL14.eglTerminate(eglDisplay);
            eglDisplay = EGL14.EGL_NO_DISPLAY;
        }
    }
}
