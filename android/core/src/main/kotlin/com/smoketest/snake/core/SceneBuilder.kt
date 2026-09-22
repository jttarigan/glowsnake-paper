package com.smoketest.snake.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.PI

// The scene-construction layer — a line-faithful Kotlin port of main.swift's
// SceneBuilder. Model state + animation phases in, flat DrawList out.

/** Pixel geometry of the play area within the view. */
data class Layout(
    val viewW: Float, val viewH: Float,
    val cell: Float,
    val textUnit: Float,
    val boardX: Float, val boardY: Float,
    val boardW: Float, val boardH: Float,
) {
    fun cellCenter(x: Double, y: Double): Vec2 =
        Vec2(boardX + (x + 0.5).toFloat() * cell, boardY + (y + 0.5).toFloat() * cell)
}

/**
 * HUD text metrics + emission. The Android app bakes a real font atlas; the
 * stub mirrors the Mac harness stub (lineHeight 76, advance 42) so golden
 * traces line up.
 */
interface GlyphAtlas {
    val lineHeight: Float
    fun width(s: String, pixelHeight: Float): Float
    fun append(s: String, list: DrawList, topLeftX: Float, topLeftY: Float,
               pixelHeight: Float, color: Vec4)

    fun appendCentered(s: String, list: DrawList, centerX: Float, top: Float,
                       pixelHeight: Float, color: Vec4) {
        val w = width(s, pixelHeight)
        append(s, list, centerX - w * 0.5f, top, pixelHeight, color)
    }
}

/** Count-faithful stand-in: one glyph quad per non-space character. */
class StubGlyphAtlas : GlyphAtlas {
    override val lineHeight = 76f
    private val advance = 42f

    override fun width(s: String, pixelHeight: Float): Float {
        val scale = pixelHeight / lineHeight
        return s.length.toFloat() * advance * scale
    }

    override fun append(s: String, list: DrawList, topLeftX: Float, topLeftY: Float,
                        pixelHeight: Float, color: Vec4) {
        val scale = pixelHeight / lineHeight
        var penX = topLeftX
        for (ch in s) {
            val w = advance * scale
            if (ch != ' ') {
                list.addGlyph(Vec2(penX + w * 0.5f, topLeftY + pixelHeight * 0.5f),
                              Vec2(w, pixelHeight),
                              Vec2(0f, 0f), Vec2(0f, 0f), color)
            }
            penX += w
        }
    }
}

private data class D2(val x: Double, val y: Double) {
    operator fun plus(o: D2) = D2(x + o.x, y + o.y)
    operator fun minus(o: D2) = D2(x - o.x, y - o.y)
    operator fun times(s: Double) = D2(x * s, y * s)
}

class SceneBuilder(private val atlas: GlyphAtlas) {

    fun build(game: GameModel, layout: Layout,
              hueShift: Double, foodPulse: Float, headPulse: Float,
              dashTint: Float, pathPhase: Float, fluidPhase: Double,
              scoreScale: Float, emberTime: Double): DrawList {
        val list = DrawList()
        val cell = layout.cell
        val viewSize = Vec2(layout.viewW, layout.viewH)

        // --- Ambient embers ---------------------------------------------------
        data class Ember(val pos: Vec2, val rgb: Vec3, val alpha: Float, val size: Float)
        val embers = mutableListOf<Ember>()
        if (FX.ambientEmbers) {
            val top = -GameModel.skyAbove
            val span = GameModel.rows.toDouble() + GameModel.skyBelow - top
            for (i in 0 until (40 * GameModel.fxScale)) {
                val fi = i.toDouble()
                val fx = (fi * 0.6180339887) % 1.0
                val fy = (fi * 0.3819660113) % 1.0
                val fz = (fi * 0.7548776662) % 1.0
                val phase = fi * 2.399963
                val speed = 0.15 + 0.35 * fz
                var y = (fy * span - emberTime * speed) % span
                if (y < 0) y += span
                y += top
                val x = fx * (GameModel.cols + 2).toDouble() - 1 +
                    0.6 * sin(emberTime * (0.3 + 0.2 * fx) + phase)
                val pulse = 0.5 + 0.5 * sin(emberTime * (0.8 + fx) + phase * 1.7)
                embers.add(Ember(layout.cellCenter(x, y),
                                 hsv2rgb(0.42 + 0.13 * fz, 0.6, 1.0),
                                 (0.10 + 0.16 * pulse).toFloat(),
                                 cell * (0.04 + 0.05 * fy).toFloat()))
            }
        }

        // --- Background -------------------------------------------------------
        if (FX.animatedBackground) {
            val scoreHue = if (FX.reactiveMood) game.score.toDouble() * 14.0 / 360.0 else 0.0
            val h = hueShift + scoreHue
            val a = rotatedStop(0.10, 0.02, 0.20, h)
            val b = rotatedStop(0.20, 0.03, 0.30, h)
            val c = rotatedStop(0.02, 0.10, 0.22, h)
            list.addBackground(viewSize, a, b, c)
        } else {
            list.addBackground(viewSize, V3_ZERO, V3_ZERO, V3_ZERO)
        }

        // --- Board surface ----------------------------------------------------
        val boardCenter = Vec2(layout.boardX + layout.boardW * 0.5f,
                               layout.boardY + layout.boardH * 0.5f)
        list.add(ShapeID.RECT, boardCenter,
                 Vec2(layout.boardW * 0.5f, layout.boardH * 0.5f),
                 corner = cell * 0.6f,
                 color = if (FX.animatedBackground) rgba(0.0, 0.0, 0.0, 0.45)
                         else rgba(0.12, 0.12, 0.12))

        for (e in embers) {
            list.add(ShapeID.CIRCLE, e.pos, Vec2(e.size, e.size),
                     color = Vec4(e.rgb.x, e.rgb.y, e.rgb.z, e.alpha),
                     glowColor = e.rgb, glowStrength = e.alpha * 0.8f,
                     glowRadius = e.size * 2f)
        }

        // --- Snake ribbon path ------------------------------------------------
        val count = game.snake.size
        val t = game.moveProgress
        val hop = t + 0.35 * (t * t * (3 - 2 * t) - t)
        val colsD = GameModel.cols.toDouble()
        val rowsD = GameModel.rows.toDouble()

        val chainCells = mutableListOf<Point>()
        if (game.prevSnake.size == count) {
            val oldTail = game.prevSnake.firstOrNull()
            if (oldTail != null && oldTail != game.snake.firstOrNull()) {
                chainCells.add(oldTail)
            }
        }
        chainCells.addAll(game.snake)
        val chain = mutableListOf(
            chainCells.firstOrNull()?.let { D2(it.x.toDouble(), it.y.toDouble()) }
                ?: D2(0.0, 0.0))
        for (k in 1 until max(1, chainCells.size)) {
            var dx = (chainCells[k].x - chainCells[k - 1].x).toDouble()
            var dy = (chainCells[k].y - chainCells[k - 1].y).toDouble()
            if (dx > 1) dx -= colsD
            if (dx < -1) dx += colsD
            if (dy > 1) dy -= rowsD
            if (dy < -1) dy += rowsD
            chain.add(chain[k - 1] + D2(dx, dy))
        }
        val totalArc = (chain.size - 1).toDouble()
        val headMoved = game.prevSnake.lastOrNull() != game.snake.lastOrNull()
        val sHead = if (headMoved) totalArc - (1 - hop) else totalArc
        val sTail = max(0.0, sHead - (count - 1).toDouble())

        fun chainPoint(s: Double): D2 {
            if (chain.size <= 1) return chain[0]
            val sc = min(max(s, 0.0), totalArc)
            val i = min(sc.toInt(), chain.size - 2)
            return chain[i] + (chain[i + 1] - chain[i]) * (sc - i.toDouble())
        }

        fun ribbonPoint(s: Double): D2 =
            (chainPoint(s - 0.35) + chainPoint(s) * 2.0 + chainPoint(s + 0.35)) * 0.25

        fun wrap1(v: Double, n: Double): Double = ((v + 0.5) % n + n) % n - 0.5
        fun wrapPoint(p: D2): D2 = D2(wrap1(p.x, colsD), wrap1(p.y, rowsD))

        fun beadPositions(p: D2): List<D2> {
            val w = wrapPoint(p)
            val xs = mutableListOf(w.x)
            val ys = mutableListOf(w.y)
            if (w.x < 0) xs.add(w.x + colsD) else if (w.x > colsD - 1) xs.add(w.x - colsD)
            if (w.y < 0) ys.add(w.y + rowsD) else if (w.y > rowsD - 1) ys.add(w.y - rowsD)
            val out = mutableListOf<D2>()
            for (x in xs) { for (y in ys) { out.add(D2(x, y)) } }
            return out
        }

        // --- Light sources for the grid --------------------------------------
        val palette = game.recentMeals.toMutableList()
        while (palette.size < 5) palette.add(0, GameModel.baseSegmentHue)
        val statusHue: Double? = if (game.redRush) FoodKind.PENALTY.hue
                                 else if (game.fastDrain) FoodKind.TIME.hue else null

        fun fluidColor(f: Double, isHead: Boolean): Vec3 {
            val v = if (isHead) 1.0 else 0.88
            if (statusHue != null) {
                return hsv2rgb(statusHue, 0.92, v * (0.72 + 0.28 * headPulse.toDouble()))
            }
            val u = f * 2.0 + fluidPhase + 0.25 * sin(f * 9.0 + fluidPhase * 1.7)
            val x = ((u % 1.0) + 1.0) % 1.0 * 5
            val i = min(x.toInt(), 4)
            val tt0 = x - i.toDouble()
            val tt = tt0 * tt0 * (3 - 2 * tt0)
            return mix3(hsv2rgb(palette[i], 0.85, v),
                        hsv2rgb(palette[(i + 1) % 5], 0.85, v), tt.toFloat())
        }

        val snakeColors = mutableListOf<Vec3>()
        for (idx in 0 until count) {
            val isHead = idx == count - 1
            val f = if (count > 1) idx.toDouble() / (count - 1).toDouble() else 1.0
            val base = fluidColor(f, isHead)
            val yellow = if (isHead) Vec3(1.0f, 0.9f, 0.25f) else Vec3(0.95f, 0.8f, 0.15f)
            snakeColors.add(mix3(base, yellow, dashTint))
        }

        data class Light(val pos: Vec2, val rgb: Vec3, val radius: Float, val strength: Float)
        val lights = mutableListOf<Light>()
        for (idx in 0 until count) {
            val isHead = idx == count - 1
            val s = max(sTail, sHead - (count - 1 - idx).toDouble())
            val pos = wrapPoint(ribbonPoint(s))
            lights.add(Light(layout.cellCenter(pos.x, pos.y), snakeColors[idx],
                             cell * (if (isHead) 2.2f else 1.6f),
                             if (isHead) 1.0f else 0.6f))
        }
        for (c in game.dyingCells) {
            lights.add(Light(layout.cellCenter(c.point.x.toDouble(), c.point.y.toDouble()),
                             hsv2rgb(c.hue, 0.8, 1.0), cell * 1.6f, 0.7f))
        }
        for (f in game.foods) {
            lights.add(Light(layout.cellCenter(f.point.x.toDouble(), f.point.y.toDouble()),
                             hsv2rgb(f.shade, 0.95, 1.0), cell * 2.4f,
                             0.8f + 0.4f * foodPulse))
        }
        if (FX.eatParticles) {
            for (part in game.particles) {
                val fresh = (max(0.0, 1 - part.age / 2)).toFloat()
                if (fresh <= 0.02f) continue
                lights.add(Light(layout.cellCenter(part.x - 0.5, part.y - 0.5),
                                 hsv2rgb(part.hue, 0.9, 1.0), cell * 1.1f, 0.7f * fresh))
            }
        }
        if (FX.ambientEmbers && FX.emberLights) {
            for (e in embers) {
                lights.add(Light(e.pos, e.rgb, cell * 0.9f, 0.45f * e.alpha))
            }
        }

        // --- Eat-ripple wavefronts -------------------------------------------
        data class Wave(val center: Vec2, val radius: Float, val strength: Float, val rgb: Vec3)
        val waves = game.ripples.map { r ->
            val prog = (r.age / GameModel.rippleLifetime).toFloat()
            Wave(layout.cellCenter(r.center.x.toDouble(), r.center.y.toDouble()),
                 cell * (0.5f + GameModel.rippleTravel.toFloat() * prog),
                 1 - prog,
                 if (r.hue >= 0) hsv2rgb(r.hue, 0.75, 1.0) else Vec3(1f, 1f, 1f))
        }

        data class WaveFx(val offset: Vec2, val boost: Float, val rgb: Vec3)
        fun waveEffect(p: Vec2): WaveFx {
            var offset = Vec2(0f, 0f)
            var boost = 0f
            var rgb = Vec3(0f, 0f, 0f)
            for (w in waves) {
                val d = p - w.center
                val dist = max(length(d), 0.001f)
                val x = (dist - w.radius) / (cell * 0.9f)
                if (abs(x) >= 3f) continue
                val g = exp((-x * x).toDouble()).toFloat()
                offset += (d / dist) * (cell * 0.35f * w.strength * g)
                boost += w.strength * g
                rgb += w.rgb * (w.strength * g)
            }
            return WaveFx(offset, boost, rgb)
        }

        // --- Neon grid lines --------------------------------------------------
        if (FX.neonGrid) {
            fun addGridSegment(center: Vec2, halfShape: Vec2) {
                val (off, boost, waveRGB) = waveEffect(center)
                var w = boost
                var acc = waveRGB
                for (l in lights) {
                    val d2 = lengthSquared(center - l.pos)
                    val r2 = l.radius * l.radius
                    if (d2 >= r2 * 9) continue
                    val f = exp((-d2 / r2).toDouble()).toFloat() * l.strength
                    w += f
                    acc += l.rgb * f
                }
                val edgeDist = min(min(center.x - layout.boardX,
                                       layout.boardX + layout.boardW - center.x),
                                   min(center.y - layout.boardY,
                                       layout.boardY + layout.boardH - center.y))
                val intensity = min(1f, w) * min(1f, edgeDist / cell + 0.25f)
                if (intensity <= 0.02f) return
                val rgb = mix3(Vec3(0f, 1f, 1f), acc / w, intensity)
                list.add(ShapeID.RECT, center + off, halfShape,
                         color = Vec4(rgb.x, rgb.y, rgb.z, 0.65f * intensity),
                         glowColor = rgb, glowStrength = 0.9f * intensity,
                         glowRadius = 1.5f + 4f * intensity)
            }
            val vHalf = cell * 0.5f
            val hHalf = cell * 0.5f - 1.5f
            for (i in 0..GameModel.cols) {
                val x = layout.boardX + i.toFloat() * cell
                for (j in 0 until GameModel.rows) {
                    addGridSegment(Vec2(x, layout.boardY + (j.toFloat() + 0.5f) * cell),
                                   Vec2(0.5f, vHalf))
                }
            }
            for (j in 0..GameModel.rows) {
                val y = layout.boardY + j.toFloat() * cell
                for (i in 0 until GameModel.cols) {
                    addGridSegment(Vec2(layout.boardX + (i.toFloat() + 0.5f) * cell, y),
                                   Vec2(hHalf, 0.5f))
                }
            }
        }

        // --- Path preview -----------------------------------------------------
        run {
            val dest = game.destination
            val head = game.snake.lastOrNull()
            if (dest != null && head != null && head != dest) {
                val path = previewPath(head, dest)
                for ((i, p) in path.withIndex()) {
                    val wave = 0.5f + 0.5f * sin(((i.toFloat() * 0.35f - pathPhase)
                        * 2f * PI.toFloat()).toDouble()).toFloat()
                    val half = cell * 0.32f
                    list.add(ShapeID.RECT,
                             layout.cellCenter(p.x.toDouble(), p.y.toDouble()),
                             Vec2(half, half), corner = cell * 0.3f,
                             color = rgba(0.35, 0.85, 1.0, (0.12f + 0.30f * wave).toDouble()),
                             glowColor = Vec3(0.3f, 0.85f, 1.0f),
                             glowStrength = 0.25f + 0.5f * wave,
                             glowRadius = cell * 0.28f)
                }
            }
        }

        // --- Foods ------------------------------------------------------------
        val foodScale = 0.9f + 0.22f * foodPulse
        val foodHalf = cell * 0.45f * foodScale
        val foodGlowR = cell * (0.3f + 0.7f * foodPulse)
        for (f in game.foods) {
            val rgb = hsv2rgb(f.shade, 0.95, 1.0)
            val blink: Float = if (f.age > GameModel.foodWarnTime)
                0.5f + 0.5f * sin(f.age * 2 * PI * 4).toFloat() else 0f
            val core = mix3(rgb, Vec3(1f, 1f, 1f), 0.45f * blink)
            val half = foodHalf * (1 + 0.12f * blink)
            list.add(ShapeID.CIRCLE,
                     layout.cellCenter(f.point.x.toDouble(), f.point.y.toDouble()),
                     Vec2(half, half),
                     color = Vec4(core.x, core.y, core.z, 1f),
                     glowColor = rgb, glowStrength = 0.9f + 0.7f * blink,
                     glowRadius = foodGlowR * (1 + 0.5f * blink))
        }

        // --- Destination marker ----------------------------------------------
        game.destination?.let { dest ->
            val pulse = 0.5f + 0.5f * foodPulse
            val radius = cell * (0.5f + 0.2f * pulse)
            list.add(ShapeID.RING,
                     layout.cellCenter(dest.x.toDouble(), dest.y.toDouble()),
                     Vec2(radius, radius),
                     color = rgba(0.5, 0.95, 1.0, 0.9),
                     glowColor = Vec3(0.3f, 0.9f, 1.0f), glowStrength = 0.5f,
                     glowRadius = cell * 0.3f, strokeThk = max(1f, cell * 0.12f))
        }

        // --- Tail wake trail --------------------------------------------------
        for (mark in game.trail) {
            val life = (max(0.0, 1 - mark.age / GameModel.trailLifetime)).toFloat()
            val boost = 1 + game.dashGlow.toFloat()
            val half = (cell - 1) * 0.5f * life
            if (half <= 0.5f) continue
            list.add(ShapeID.RECT,
                     layout.cellCenter(mark.point.x.toDouble(), mark.point.y.toDouble()),
                     Vec2(half, half), corner = cell * 0.2f,
                     color = rgba(0.7, 1.0, 0.75, min(1f, 0.5f * life * boost).toDouble()),
                     glowColor = Vec3(0.3f, 1f, 0.45f),
                     glowStrength = min(1f, 0.6f * life * boost),
                     glowRadius = cell * 0.5f * life * boost)
        }

        // --- Snake ribbon (dying blocks + beads) ------------------------------
        for (c in game.dyingCells) {
            val rgb = hsv2rgb(c.hue, 0.8, 0.9)
            val half = (cell - 1) * 0.5f
            list.add(ShapeID.RECT,
                     layout.cellCenter(c.point.x.toDouble(), c.point.y.toDouble()),
                     Vec2(half, half), corner = cell * 0.2f,
                     color = Vec4(rgb.x, rgb.y, rgb.z, 1f),
                     glowColor = rgb, glowStrength = 0.7f, glowRadius = cell * 0.3f)
        }

        val dashBoost = 1 + game.dashGlow.toFloat()
        val bodySpan = sHead - sTail
        val beadCount = max(1, Math.round(bodySpan * 3).toInt())
        val beadTop = if (count > 0) beadCount + 1 else 0
        for (k in 0 until beadTop) {
            val f = k.toDouble() / beadCount.toDouble()
            val s = sTail + bodySpan * f
            val p = ribbonPoint(s)
            val tangent = chainPoint(s + 0.2) - chainPoint(s - 0.2)
            val rot = atan2(tangent.y, tangent.x).toFloat()
            val isHead = k == beadCount

            val fi = f * (count - 1).toDouble()
            val i0 = min(fi.toInt(), count - 1)
            val core = mix3(snakeColors[i0], snakeColors[min(i0 + 1, count - 1)],
                            (fi - i0.toDouble()).toFloat())

            val glowScale: Float = if (isHead && game.dashReady) (1 + headPulse) else 1f
            val baseOpacity: Float = if (isHead) 0.95f else 0.55f
            val half = (cell - 1) * 0.5f
            val glowR = (if (isHead) cell * 0.5f else cell * 0.25f) * glowScale * dashBoost
            for (pos in beadPositions(p)) {
                list.add(ShapeID.RECT, layout.cellCenter(pos.x, pos.y),
                         Vec2(half, half), corner = cell * 0.2f,
                         color = Vec4(core.x, core.y, core.z, 1f),
                         glowColor = core,
                         glowStrength = baseOpacity + (1 - baseOpacity) * game.dashGlow.toFloat(),
                         glowRadius = glowR, rot = rot)
            }
        }

        // --- Eat-ripples: expanding rings ------------------------------------
        for ((w, r) in waves.zip(game.ripples)) {
            val prog = (r.age / GameModel.rippleLifetime).toFloat()
            val fade = w.strength * w.strength
            val thk = max(0.5f, cell * 0.16f * (1 - 0.6f * prog))
            list.add(ShapeID.RING, w.center,
                     Vec2(w.radius, w.radius),
                     color = Vec4(w.rgb.x, w.rgb.y, w.rgb.z, fade * 0.9f),
                     glowColor = w.rgb, glowStrength = 0.5f * fade,
                     glowRadius = cell * 0.4f, strokeThk = thk)
        }

        // --- Food shards ------------------------------------------------------
        if (FX.eatParticles) {
            for (part in game.particles) {
                val life = (max(0.0, 1 - part.age / part.lifetime)).toFloat()
                var flicker = 1f
                if (part.twinkle && life < 0.45f) {
                    flicker = 0.3f + 0.7f * (0.5 + 0.5 * sin(part.age * 26
                        + part.id.toDouble() * 2.7)).toFloat()
                }
                val base = cell * part.size.toFloat() * (0.4f + 0.6f * life) + 1f
                val rgb = hsv2rgb(part.hue, 0.85, 1.0)
                list.add(ShapeID.RECT, layout.cellCenter(part.x - 0.5, part.y - 0.5),
                         Vec2(base, base * 0.72f), corner = base * 0.3f,
                         color = Vec4(rgb.x, rgb.y, rgb.z, life * flicker),
                         glowColor = rgb, glowStrength = life * flicker,
                         glowRadius = cell * 0.2f * life, rot = part.angle.toFloat())
            }
        }

        // --- Finale fireworks: streaks and rings ------------------------------
        if (FX.finaleFireworks && game.isDying) {
            for (fw in game.fireworks) {
                val dtIgnite = game.finaleClock - fw.ignition
                if (dtIgnite < 0 && dtIgnite > -GameModel.streakDuration) {
                    val tt = 1 + dtIgnite / GameModel.streakDuration
                    val y0 = fw.y + 3.0
                    val y = y0 + (fw.y - y0) * tt
                    val rgb = hsv2rgb(fw.shade, 0.55, 1.0)
                    list.add(ShapeID.RECT,
                             layout.cellCenter(fw.x - 0.5, y - 0.5),
                             Vec2(cell * 0.05f, cell * 0.35f),
                             corner = cell * 0.05f,
                             color = Vec4(rgb.x, rgb.y, rgb.z, 0.9f),
                             glowColor = rgb, glowStrength = 0.8f,
                             glowRadius = cell * 0.3f)
                } else if (dtIgnite >= 0 && dtIgnite < 0.6) {
                    val a = (dtIgnite / 0.6).toFloat()
                    val rgb = hsv2rgb(fw.shade, 0.8, 1.0)
                    val radius = cell * (0.4f + 5.5f * a)
                    list.add(ShapeID.RING,
                             layout.cellCenter(fw.x - 0.5, fw.y - 0.5),
                             Vec2(radius, radius),
                             color = Vec4(rgb.x, rgb.y, rgb.z, (1 - a) * 0.9f),
                             glowColor = rgb, glowStrength = 1 - a,
                             glowRadius = cell * 0.5f,
                             strokeThk = cell * 0.06f * (1 - a) + 1f)
                }
            }
        }

        // --- HUD text ---------------------------------------------------------
        val cx = layout.viewW * 0.5f
        val tu = layout.textUnit
        val hudTop = layout.boardY - tu * 1.5f
        val danger = game.timeRemaining <= 3
        val timeText = String.format(Locale.US, "%.1f", game.timeRemaining)
        val timeLeft = tu * 1.2f
        val timeW = atlas.width(timeText, tu * 1.0f)
        if (game.fastDrain || danger) {
            val glowRGB = if (danger) Vec3(1f, 0.15f, 0.1f) else Vec3(0.57f, 0f, 0.8f)
            list.add(ShapeID.RECT, Vec2(timeLeft + timeW * 0.5f, hudTop + tu * 0.5f),
                     Vec2(timeW * 0.5f + tu * 0.5f, tu * 0.75f),
                     corner = tu * 0.6f,
                     color = Vec4(glowRGB.x, glowRGB.y, glowRGB.z, 0.10f + 0.12f * headPulse),
                     glowColor = glowRGB,
                     glowStrength = 0.7f + 0.5f * headPulse,
                     glowRadius = tu * (0.6f + 0.4f * headPulse))
        }
        val timeColor = if (danger) rgba(1.0, 0.25, 0.2)
                        else if (game.fastDrain) rgba(0.8, 0.45, 1.0) else rgba(1.0, 1.0, 1.0)
        atlas.append(timeText, list, timeLeft, hudTop, tu * 1.0f, timeColor)
        val scoreText = "${game.score}/${GameModel.winScore}"
        val scoreH = tu * 1.0f * scoreScale
        val scoreW = atlas.width(scoreText, scoreH)
        atlas.append(scoreText, list,
                     layout.viewW - tu * 3.2f - scoreW,
                     hudTop - (scoreH - tu * 1.0f) * 0.5f,
                     scoreH, rgba(1.0, 1.0, 1.0))

        // --- Eat-flash overlay ------------------------------------------------
        if (FX.reactiveMood && game.eatFlash > 0) {
            list.add(ShapeID.RECT, viewSize * 0.5f,
                     viewSize * 0.5f, corner = 0f,
                     color = rgba(1.0, 0.5, 0.35, game.eatFlash * 0.28), soft = 0f)
        }

        // --- Game-over panel --------------------------------------------------
        if (game.isGameOver) {
            list.add(ShapeID.RECT, boardCenter,
                     Vec2(layout.boardW * 0.46f, tu * 4.5f),
                     corner = tu * 0.6f, color = rgba(0.0, 0.0, 0.0, 0.72))
            atlas.appendCentered(if (game.won) "You Win!" else "Game Over", list,
                                 cx, boardCenter.y - tu * 3.2f, tu * 2.0f,
                                 if (game.won) rgba(0.5, 1.0, 0.6) else rgba(1.0, 1.0, 1.0))
            atlas.appendCentered("Score: ${game.score}", list, cx,
                                 boardCenter.y - tu * 0.6f, tu * 1.2f, rgba(1.0, 1.0, 1.0))
            atlas.appendCentered("Tap to restart", list, cx,
                                 boardCenter.y + tu * 1.6f, tu * 1.1f, rgba(1.0, 0.9, 0.2))
        }

        return list
    }

    private fun previewPath(head: Point, dest: Point): List<Point> {
        val cells = mutableListOf<Point>()
        var x = head.x
        val sx = if (dest.x > x) 1 else if (dest.x < x) -1 else 0
        while (x != dest.x) { x += sx; cells.add(Point(x, head.y)) }
        var y = head.y
        val sy = if (dest.y > y) 1 else if (dest.y < y) -1 else 0
        while (y != dest.y) { y += sy; cells.add(Point(dest.x, y)) }
        return cells
    }

    private fun rotatedStop(r: Double, g: Double, b: Double, turns: Double): Vec3 {
        val mx = max(r, max(g, b))
        val mn = min(r, min(g, b))
        val v = mx
        val d = mx - mn
        val s = if (mx == 0.0) 0.0 else d / mx
        var h = 0.0
        if (d != 0.0) {
            h = when {
                mx == r -> ((g - b) / d) % 6.0
                mx == g -> (b - r) / d + 2
                else -> (r - g) / d + 4
            }
            h /= 6
        }
        return hsv2rgb(h + turns, s, v)
    }
}
