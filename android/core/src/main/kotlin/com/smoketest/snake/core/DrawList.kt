package com.smoketest.snake.core

import kotlin.math.sqrt

// The portable draw-list seam — the Kotlin twin of main.swift's DrawList.
// Instances are stored as a flat FloatArray, 24 floats each (six float4
// slots: a, b, color, glow, uv, misc), ready for direct GL buffer upload.

object ShapeID {
    const val RECT = 0f
    const val CIRCLE = 1f
    const val RING = 2f
    const val GLYPH = 3f
    const val BG = 4f
    const val FRAME = 5f
}

data class Vec2(val x: Float, val y: Float) {
    operator fun plus(o: Vec2) = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2) = Vec2(x - o.x, y - o.y)
    operator fun times(s: Float) = Vec2(x * s, y * s)
    operator fun div(s: Float) = Vec2(x / s, y / s)
}

data class Vec3(val x: Float, val y: Float, val z: Float) {
    operator fun plus(o: Vec3) = Vec3(x + o.x, y + o.y, z + o.z)
    operator fun minus(o: Vec3) = Vec3(x - o.x, y - o.y, z - o.z)
    operator fun times(s: Float) = Vec3(x * s, y * s, z * s)
    operator fun div(s: Float) = Vec3(x / s, y / s, z / s)
}

data class Vec4(val x: Float, val y: Float, val z: Float, val w: Float)

val V3_ZERO = Vec3(0f, 0f, 0f)

fun length(v: Vec2): Float = sqrt(v.x * v.x + v.y * v.y)
fun lengthSquared(v: Vec2): Float = v.x * v.x + v.y * v.y

class DrawList {
    var data = FloatArray(24 * 2048)
        private set
    var count = 0
        private set

    private fun slot(): Int {
        if ((count + 1) * 24 > data.size) data = data.copyOf(data.size * 2)
        val base = count * 24
        count += 1
        return base
    }

    private fun write(base: Int,
                      a0: Float, a1: Float, a2: Float, a3: Float,
                      b0: Float, b1: Float, b2: Float, b3: Float,
                      c0: Float, c1: Float, c2: Float, c3: Float,
                      g0: Float, g1: Float, g2: Float, g3: Float,
                      u0: Float, u1: Float, u2: Float, u3: Float,
                      m0: Float, m1: Float, m2: Float, m3: Float) {
        val d = data
        d[base] = a0; d[base + 1] = a1; d[base + 2] = a2; d[base + 3] = a3
        d[base + 4] = b0; d[base + 5] = b1; d[base + 6] = b2; d[base + 7] = b3
        d[base + 8] = c0; d[base + 9] = c1; d[base + 10] = c2; d[base + 11] = c3
        d[base + 12] = g0; d[base + 13] = g1; d[base + 14] = g2; d[base + 15] = g3
        d[base + 16] = u0; d[base + 17] = u1; d[base + 18] = u2; d[base + 19] = u3
        d[base + 20] = m0; d[base + 21] = m1; d[base + 22] = m2; d[base + 23] = m3
    }

    fun add(shape: Float, center: Vec2, halfShape: Vec2,
            corner: Float = 0f,
            color: Vec4,
            glowColor: Vec3 = V3_ZERO, glowStrength: Float = 0f,
            glowRadius: Float = 0f, soft: Float = 1f, strokeThk: Float = 0f,
            rot: Float = 0f) {
        val margin = glowRadius * 3f + soft + 1f
        val bound = if (rot == 0f) halfShape
                    else Vec2(length(halfShape), length(halfShape))
        val halfQuadX = bound.x + margin
        val halfQuadY = bound.y + margin
        write(slot(),
              center.x, center.y, halfQuadX, halfQuadY,
              halfShape.x, halfShape.y, corner, shape,
              color.x, color.y, color.z, color.w,
              glowColor.x, glowColor.y, glowColor.z, glowStrength,
              0f, 0f, 0f, 0f,
              soft, glowRadius, strokeThk, rot)
    }

    fun addBackground(viewSize: Vec2, a: Vec3, b: Vec3, c: Vec3) {
        val hx = viewSize.x * 0.5f
        val hy = viewSize.y * 0.5f
        write(slot(),
              hx, hy, hx, hy,
              hx, hy, 0f, ShapeID.BG,
              a.x, a.y, a.z, 1f,
              b.x, b.y, b.z, 1f,
              c.x, c.y, c.z, 1f,
              0f, 0f, 0f, 0f)
    }

    fun addGlyph(center: Vec2, size: Vec2, uvOrigin: Vec2, uvSize: Vec2,
                 color: Vec4) {
        val hx = size.x * 0.5f
        val hy = size.y * 0.5f
        write(slot(),
              center.x, center.y, hx, hy,
              hx, hy, 0f, ShapeID.GLYPH,
              color.x, color.y, color.z, color.w,
              0f, 0f, 0f, 0f,
              uvOrigin.x, uvOrigin.y, uvSize.x, uvSize.y,
              0f, 0f, 0f, 0f)
    }
}

// ---- Color helpers (twins of main.swift's) ----------------------------------

fun rgba(r: Double, g: Double, b: Double, a: Double = 1.0): Vec4 =
    Vec4(r.toFloat(), g.toFloat(), b.toFloat(), a.toFloat())

/** HSV → RGB (h, s, v in 0...1), matching the Swift helper exactly. */
fun hsv2rgb(h: Double, s: Double, v: Double): Vec3 {
    val hh = ((h % 1.0) + 1.0) % 1.0 * 6.0
    val i = hh.toInt()
    val f = hh - i.toDouble()
    val p = v * (1 - s)
    val q = v * (1 - s * f)
    val t = v * (1 - s * (1 - f))
    val r: Double; val g: Double; val b: Double
    when (i % 6) {
        0 -> { r = v; g = t; b = p }
        1 -> { r = q; g = v; b = p }
        2 -> { r = p; g = v; b = t }
        3 -> { r = p; g = q; b = v }
        4 -> { r = t; g = p; b = v }
        else -> { r = v; g = p; b = q }
    }
    return Vec3(r.toFloat(), g.toFloat(), b.toFloat())
}

fun mix3(a: Vec3, b: Vec3, t: Float): Vec3 = a + (b - a) * t
