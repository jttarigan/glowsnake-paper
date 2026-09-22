package com.smoketest.snake

import android.app.Activity
import android.opengl.GLSurfaceView
import android.os.Bundle
import android.util.Log
import android.view.MotionEvent
import com.smoketest.snake.core.Direction
import com.smoketest.snake.core.GameModel
import com.smoketest.snake.core.Layout
import com.smoketest.snake.core.SceneBuilder
import com.smoketest.snake.core.ShapeID
import com.smoketest.snake.core.Vec2
import com.smoketest.snake.core.Vec3
import com.smoketest.snake.core.Vec4
import com.smoketest.snake.core.hsv2rgb
import java.io.File
import java.util.Locale
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import javax.microedition.khronos.egl.EGLConfig
import javax.microedition.khronos.opengles.GL10

// The Android host: GLSurfaceView + touch → intents → the ported model.
// Controls (for now): swipe to steer, tap to restart after the finale.
// A D-pad port matching the iOS host is a TODO.
class MainActivity : Activity() {
    private lateinit var surface: GLSurfaceView
    private lateinit var renderer: GameRenderer

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Benchmarking hook: `adb shell am start ... --ei fx 8` sets the
        // Sparks tier for this launch (1/2/4/8; default 1).
        val fx = intent?.getIntExtra("fx", 1) ?: 1
        if (fx in listOf(1, 2, 4, 8)) GameModel.fxScale = fx
        // Perf CSVs go to the external files dir so `adb pull` can reach
        // them on a non-debuggable release build.
        renderer = GameRenderer(getExternalFilesDir(null) ?: filesDir)
        surface = GLSurfaceView(this).apply {
            setEGLContextClientVersion(3)
            setRenderer(renderer)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        setContentView(surface)
        // Edge-to-edge AFTER setContentView: the insets controller needs the
        // decor view to exist (HyperOS NPEs on the lazy path stock Android
        // tolerates).
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            window.attributes.layoutInDisplayCutoutMode = android.view.WindowManager
                .LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.apply {
                hide(android.view.WindowInsets.Type.statusBars() or
                     android.view.WindowInsets.Type.navigationBars())
                systemBarsBehavior = android.view.WindowInsetsController
                    .BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        }
    }

    override fun onPause() { super.onPause(); surface.onPause() }
    override fun onResume() { super.onResume(); surface.onResume() }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (e.actionMasked != MotionEvent.ACTION_DOWN &&
            e.actionMasked != MotionEvent.ACTION_POINTER_DOWN) return true
        val idx = e.actionIndex
        val x = e.getX(idx)
        val y = e.getY(idx)
        val r = renderer
        // D-pad hit test (touchDown steering, like the iOS host); a tap
        // anywhere else only restarts after the finale.
        val pad = r.padButtonAt(x, y)
        surface.queueEvent {
            if (pad >= 0 && !r.game.isGameOver) {
                r.pressPad(pad)
            } else if (r.game.isGameOver) {
                r.game.reset()
            }
        }
        if (pad >= 0) surface.performHapticFeedback(
            android.view.HapticFeedbackConstants.KEYBOARD_TAP)
        return true
    }
}

class GameRenderer(private val filesDir: File) : GLSurfaceView.Renderer {
    val game = GameModel()
    private val atlas = AndroidGlyphAtlas()
    private val gl = GlRenderer(atlas)
    private val scene = SceneBuilder(atlas)

    private var viewW = 0f
    private var viewH = 0f
    private var layout: Layout? = null
    private var lastNanos = 0L
    private var startNanos = 0L
    private var hueShift = 0.0
    private var fluidPhase = 0.0
    private var scoreAnim = 0.0
    private var lastScore = 0

    // Perf log (twin of the iOS FX.debugHud profiler): frame/tick/build ms,
    // dumped to filesDir as CSV when a run ends — pull via `adb pull`.
    private val perf = StringBuilder("t,frameMs,tickMs,buildMs,instances\n")
    private var perfFrames = 0
    private var wasGameOver = false

    override fun onSurfaceCreated(unused: GL10?, config: EGLConfig?) {
        gl.setup()
    }

    override fun onSurfaceChanged(unused: GL10?, w: Int, h: Int) {
        android.opengl.GLES30.glViewport(0, 0, w, h)
        viewW = w.toFloat()
        viewH = h.toFloat()
        layout = buildLayout()
    }

    /** Ports the iOS host's sizeGridToFillScreen + makeLayout (dpad branch),
     *  with a fixed top inset standing in for the safe area + HUD offset. */
    private fun buildLayout(): Layout {
        val topInset = viewH * 0.06f
        val availH0 = viewH * 0.76f - topInset
        val cell0 = viewW / (GameModel.cols + 2).toFloat()
        GameModel.rows = max(8, (availH0 / cell0).toInt())
        val availH = viewH * 0.72f - topInset
        val cell = min(viewW / (GameModel.cols + 2).toFloat(),
                       availH / GameModel.rows.toFloat())
        val boardW = cell * GameModel.cols.toFloat()
        val boardH = cell * GameModel.rows.toFloat()
        val boardX = (viewW - boardW) * 0.5f
        val boardY = topInset + (availH - boardH) * 0.5f
        val l = Layout(viewW, viewH, cell, viewW * 0.05f, boardX, boardY, boardW, boardH)
        GameModel.skyAbove = (l.boardY / l.cell).toDouble()
        GameModel.skyBelow = ((viewH - l.boardY - l.boardH) / l.cell).toDouble()
        return l
    }

    override fun onDrawFrame(unused: GL10?) {
        val l = layout ?: return
        val nanos = System.nanoTime()
        if (lastNanos == 0L) { lastNanos = nanos; startNanos = nanos }
        val dtRaw = (nanos - lastNanos) / 1e9
        val dt = min(dtRaw, 0.1)
        lastNanos = nanos
        val now = (nanos - startNanos) / 1e9

        game.tick(dt)
        val tTick = System.nanoTime()

        hueShift = (hueShift + dt * 0.076) % 1.0
        val foodPulse = (0.5 + 0.5 * sin(now * (2 * Math.PI / 1.4))).toFloat()
        val headPulse = (0.5 + 0.5 * sin(now * (2 * Math.PI / 0.9))).toFloat()
        fluidPhase = (fluidPhase + dt * 0.10 * game.effectiveSpeed) % 1.0
        if (game.score > lastScore) scoreAnim = 0.5
        lastScore = game.score
        scoreAnim = max(0.0, scoreAnim - dt)
        val scoreScale = (1 + 0.6 * sin((1 - scoreAnim / 0.5) * Math.PI)).toFloat()

        val list = scene.build(game, l, hueShift, foodPulse, headPulse,
                               dashTint = 0f,
                               pathPhase = (now * 0.9).toFloat(),
                               fluidPhase = fluidPhase,
                               scoreScale = scoreScale, emberTime = now)
        for (i in 0 until 4) padPress[i] = max(0f, padPress[i] - dt.toFloat() / 0.4f)
        appendDPad(list, now)
        val tBuild = System.nanoTime()

        gl.render(list, viewW, viewH)

        if (perfFrames < 60_000) {
            perf.append(String.format(Locale.US, "%.3f,%.2f,%.2f,%.2f,%d\n",
                now, dtRaw * 1000, (tTick - nanos) / 1e6,
                (tBuild - tTick) / 1e6, list.count))
            perfFrames += 1
        }
        if (game.isGameOver && !wasGameOver) dumpPerf()
        if (!game.isGameOver && wasGameOver) {
            perf.setLength(0)
            perf.append("t,frameMs,tickMs,buildMs,instances\n")
            perfFrames = 0
        }
        wasGameOver = game.isGameOver
    }

    // ---- D-pad (port of the iOS host's Metal-rendered neon cross) -----------
    // Order: up, down, left, right — matching the iOS padOffsets/padHues.
    private val padDirs = listOf(Direction.UP, Direction.DOWN,
                                 Direction.LEFT, Direction.RIGHT)
    private val padOffX = floatArrayOf(0f, 0f, -1f, 1f)
    private val padOffY = floatArrayOf(-1f, 1f, 0f, 0f)
    private val padHues = doubleArrayOf(0.5, 0.75, 0.08, 0.87)
    private val padAngles = floatArrayOf(0f, Math.PI.toFloat(),
                                         (-Math.PI / 2).toFloat(),
                                         (Math.PI / 2).toFloat())
    val padPress = FloatArray(4)

    private data class PadGeom(val cx: Float, val cy: Float, val hOff: Float,
                               val vOff: Float, val size: Float)

    private fun padGeometry(): PadGeom {
        val l = layout ?: return PadGeom(0f, 0f, 0f, 0f, 0f)
        val stripTop = l.boardY + l.boardH
        val stripH = viewH - stripTop
        val size = viewW * 0.165f
        val hOff = viewW * 0.22f
        // Vertical spread clamps to the strip so the down button stays on.
        val vOff = min(hOff, (stripH - size) * 0.5f - viewH * 0.015f)
        return PadGeom(viewW * 0.28f, stripTop + stripH * 0.5f, hOff, vOff, size)
    }

    /** Which pad button (or -1) a screen touch lands on, with slop. */
    fun padButtonAt(x: Float, y: Float): Int {
        val g = padGeometry()
        if (g.size == 0f) return -1
        val hit = g.size + viewW * 0.04f
        for (i in 0 until 4) {
            val cx = g.cx + padOffX[i] * g.hOff
            val cy = g.cy + padOffY[i] * g.vOff
            if (abs(x - cx) < hit / 2 && abs(y - cy) < hit / 2) return i
        }
        return -1
    }

    /** GL-thread: steer + press flare + sparks (mirrors the iOS touchDown). */
    fun pressPad(i: Int) {
        game.turn(padDirs[i])
        padPress[i] = 1f
        val l = layout ?: return
        val g = padGeometry()
        game.emitSparks(
            ((g.cx + padOffX[i] * g.hOff - l.boardX) / l.cell).toDouble(),
            ((g.cy + padOffY[i] * g.vOff - l.boardY) / l.cell).toDouble(),
            padHues[i], 10)
    }

    private fun appendDPad(list: com.smoketest.snake.core.DrawList, now: Double) {
        val g = padGeometry()
        if (g.size == 0f) return
        val k = viewW / 390f          // pt-equivalent scale (iOS metrics × 3)
        for (i in 0 until 4) {
            val cx = g.cx + padOffX[i] * g.hOff
            val cy = g.cy + padOffY[i] * g.vOff
            val press = padPress[i]
            val breath = 0.5f + 0.5f * sin(now * 1.8 + i.toDouble() * 1.6).toFloat()
            val rgb = hsv2rgb(padHues[i], 0.8, 1.0)
            val half = g.size * 0.5f * (1 + 0.12f * press)
            list.add(ShapeID.RECT, Vec2(cx, cy), Vec2(half, half),
                     corner = half * 0.35f,
                     color = Vec4(rgb.x, rgb.y, rgb.z,
                                  0.10f + 0.06f * breath + 0.45f * press),
                     glowColor = rgb,
                     glowStrength = 0.2f + 0.15f * breath + 1.0f * press,
                     glowRadius = (5f + 4f * breath + 24f * press) * k)
            val theta = padAngles[i]
            val ca = kotlin.math.cos(theta)
            val sa = sin(theta)
            for (s in floatArrayOf(-1f, 1f)) {
                val lx = s * 6.6f * k
                val ly = 1.8f * k
                val rx = lx * ca - ly * sa
                val ry = lx * sa + ly * ca
                list.add(ShapeID.RECT, Vec2(cx + rx, cy + ry),
                         Vec2(8.4f * k, 2.4f * k), corner = 2.4f * k,
                         color = Vec4(1f, 1f, 1f, 0.55f + 0.45f * press),
                         glowColor = rgb, glowStrength = 0.3f + 0.7f * press,
                         glowRadius = 3f * k,
                         rot = s * 0.7f + theta)
            }
        }
    }

    private fun dumpPerf() {
        val f = File(filesDir, "perf_${System.currentTimeMillis() / 1000}" +
                               "_fx${GameModel.fxScale}.csv")
        f.writeText(perf.toString())
        Log.i("SnakePerf", "PERF CSV written: ${f.absolutePath} ($perfFrames frames)")
    }
}
