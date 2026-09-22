package com.smoketest.snake.core

import java.io.File
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.fail
import org.junit.Assume.assumeTrue

/**
 * Golden-trace verification: replays the exact scripted, seeded run the
 * Swift harness recorded (`harness trace <out> 12345`) and requires the
 * Kotlin port to emit the same DrawList — identical instance counts and
 * per-kind histograms every frame, and near-identical floats (tolerance
 * covers last-ulp libm/StrictMath differences in transcendentals) on the
 * dumped frames.
 */
class GoldenTraceTest {

    private val tracePath = "../../paper/data/golden_trace_seed12345.txt"

    // The Mac harness's iPhone 12 geometry, reproduced in Float math.
    private fun makeLayout(): Layout {
        val viewW = 1170f
        val viewH = 2532f
        val topInset = (47f + 34f) * 3f
        // fitRows (nominal 0.76h region)
        val availH0 = viewH * 0.76f - topInset
        val cell0 = viewW / (GameModel.cols + 2).toFloat()
        GameModel.rows = max(8, (availH0 / cell0).toInt())
        // makeLayout (0.72h display region)
        val availH = viewH * 0.72f - topInset
        val cell = min(viewW / (GameModel.cols + 2).toFloat(),
                       availH / GameModel.rows.toFloat())
        val boardW = cell * GameModel.cols.toFloat()
        val boardH = cell * GameModel.rows.toFloat()
        val boardX = (viewW - boardW) * 0.5f
        val boardY = topInset + (availH - boardH) * 0.5f
        return Layout(viewW, viewH, cell, viewW * 0.05f, boardX, boardY, boardW, boardH)
    }

    private fun steer(g: GameModel) {
        if (g.isDying || g.isGameOver || g.won) return
        val head = g.snake.lastOrNull() ?: return
        val target = g.foods.minByOrNull {
            abs(it.point.x - head.x) + abs(it.point.y - head.y)
        } ?: return
        g.aim(target.point)
    }

    @Test
    fun replayMatchesSwiftTrace() {
        val file = File(tracePath)
        assumeTrue("golden trace not found at ${file.absolutePath}", file.exists())
        val lines = file.readLines()
        require(lines[0].startsWith("SNAKETRACE v1")) { "bad trace header" }
        val seed = lines[0].substringAfter("seed=").substringBefore(" ").toULong()

        val layout = makeLayout()
        GameModel.skyAbove = (layout.boardY / layout.cell).toDouble()
        GameModel.skyBelow =
            ((layout.viewH - layout.boardY - layout.boardH) / layout.cell).toDouble()
        GameModel.fxScale = 1
        Rand.seed(seed)

        val g = GameModel()
        val scene = SceneBuilder(StubGlyphAtlas())
        val dt = 1.0 / 60.0

        var li = 1     // trace cursor
        var frame = 0
        var framesChecked = 0
        var floatsChecked = 0L
        while (frame < 1500) {
            if (frame >= 600) g.foods.clear() else steer(g)
            g.tick(dt)
            val t = frame.toDouble() / 60.0
            val hueShift = (t * 0.008) % 1.0
            val list = scene.build(
                g, layout, hueShift,
                foodPulse = (0.5 + 0.5 * sin(t * 5.0)).toFloat(),
                headPulse = (0.5 + 0.5 * sin(t * 6.0)).toFloat(),
                dashTint = 0f,
                pathPhase = (t % 1.0).toFloat(),
                fluidPhase = (t * 0.1 * g.effectiveSpeed) % 1.0,
                scoreScale = 1f, emberTime = t)

            // Expected frame line.
            check(li < lines.size) { "trace ended early at frame $frame" }
            val parts = lines[li].split(" ")
            li += 1
            if (parts[0] == "END") {
                fail("trace ended at frame ${parts[1]} but replay still running at $frame")
            }
            check(parts[0] == "F" && parts[1].toInt() == frame) {
                "trace desync at line $li (frame $frame): ${lines[li - 1]}"
            }
            val expCount = parts[2].toInt()
            if (expCount != list.count) {
                fail("frame $frame: instance count ${list.count}, Swift $expCount")
            }
            val hist = IntArray(6)
            for (n in 0 until list.count) {
                hist[list.data[n * 24 + 7].toInt()] += 1
            }
            for (k in 0 until 6) {
                if (hist[k] != parts[3 + k].toInt()) {
                    fail("frame $frame: shape-kind $k count ${hist[k]}, " +
                         "Swift ${parts[3 + k]}")
                }
            }

            // Dumped instances on sampled frames.
            if (frame < 10 || frame % 20 == 0) {
                for (n in 0 until expCount) {
                    val floats = lines[li].removePrefix("I ").split(" ")
                    li += 1
                    for (s in 0 until 24) {
                        val ref = floats[s].toFloat()
                        val got = list.data[n * 24 + s]
                        val tol = max(0.01f, 1e-4f * abs(ref))
                        if (abs(got - ref) > tol) {
                            fail("frame $frame instance $n slot $s: " +
                                 "got $got, Swift $ref")
                        }
                        floatsChecked += 1
                    }
                }
            }
            framesChecked += 1
            if (g.isGameOver) break
            frame += 1
        }
        println("golden trace OK: $framesChecked frames, " +
                "$floatsChecked floats compared, final score ${g.score}")
    }
}
