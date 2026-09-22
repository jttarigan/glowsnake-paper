package com.smoketest.snake

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.opengl.GLES30
import android.opengl.GLUtils
import com.smoketest.snake.core.DrawList
import com.smoketest.snake.core.GlyphAtlas
import com.smoketest.snake.core.Vec2
import com.smoketest.snake.core.Vec4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.ceil

// The Android platform layer below the DrawList seam: ONE GLES3 program,
// one instanced draw call per frame — the twin of main.swift's 192-line
// Metal renderer. The GLSL is a near-verbatim port of the MSL string.

private const val VS = """#version 300 es
layout(location=0) in vec4 ia;     // center.xy, halfQuad.xy
layout(location=1) in vec4 ib;     // halfShape.xy, corner, shapeID
layout(location=2) in vec4 icolor;
layout(location=3) in vec4 iglow;
layout(location=4) in vec4 iuv;
layout(location=5) in vec4 imisc;  // soft, glowRadius, strokeThk, rotation
uniform vec2 viewport;
out vec2 vLocal;
out vec2 vUv;
out vec3 vBgC;
out vec2 vNdc01;
out vec4 vColor;
out vec4 vGlow;
out vec4 vB;
out vec4 vMisc;
void main() {
    vec2 c = vec2((gl_VertexID == 1 || gl_VertexID == 3) ? 0.5 : -0.5,
                  (gl_VertexID >= 2) ? 0.5 : -0.5);
    vec2 center = ia.xy;
    vec2 halfQuad = ia.zw;
    vec2 px = center + c * (halfQuad * 2.0);
    vec2 ndc = (px / viewport) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    gl_Position = vec4(ndc, 0.0, 1.0);
    vLocal = c * (halfQuad * 2.0);
    vUv = iuv.xy + (c + 0.5) * iuv.zw;
    vBgC = iuv.xyz;
    vNdc01 = c + 0.5;
    vColor = icolor;
    vGlow = iglow;
    vB = ib;
    vMisc = imisc;
}
"""

private const val FS = """#version 300 es
precision highp float;
in vec2 vLocal;
in vec2 vUv;
in vec3 vBgC;
in vec2 vNdc01;
in vec4 vColor;
in vec4 vGlow;
in vec4 vB;
in vec4 vMisc;
uniform sampler2D atlas;
out vec4 frag;

float sdRoundBox(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

void main() {
    float shape = vB.w;
    vec2 halfShape = vB.xy;
    float corner = vB.z;
    float soft = max(vMisc.x, 0.75);
    float glowR = vMisc.y;
    float strokeThk = vMisc.z;
    vec4 col = vColor;

    if (shape == 3.0) {                       // glyph
        float a = texture(atlas, vUv).a;
        frag = vec4(col.rgb, col.a * a);
        return;
    }
    if (shape == 4.0) {                       // background gradient
        float t = clamp((vNdc01.x + vNdc01.y) * 0.5, 0.0, 1.0);
        vec3 A = vColor.rgb; vec3 B = vGlow.rgb; vec3 C = vBgC;
        vec3 g = (t < 0.5) ? mix(A, B, t * 2.0) : mix(B, C, (t - 0.5) * 2.0);
        frag = vec4(g, 1.0);
        return;
    }

    vec2 lp = vLocal;
    float rot = vMisc.w;
    if (rot != 0.0) {
        float ca = cos(rot), sa = sin(rot);
        lp = vec2(ca * lp.x + sa * lp.y, -sa * lp.x + ca * lp.y);
    }

    float d;
    if (shape == 1.0) {                       // circle
        d = length(lp) - halfShape.x;
    } else if (shape == 2.0) {                // ring
        d = abs(length(lp) - halfShape.x) - strokeThk;
    } else if (shape == 5.0) {                // rounded-rect stroke
        d = abs(sdRoundBox(lp, halfShape, corner)) - strokeThk;
    } else {                                  // rounded/solid rect
        d = sdRoundBox(lp, halfShape, corner);
    }

    float fill = 1.0 - smoothstep(0.0, soft, d);
    float gA = (glowR > 0.0) ? exp(-max(d, 0.0) / glowR) * vGlow.a * 0.5 : 0.0;
    float fa = col.a * fill;
    float ga = gA * (1.0 - fill);
    float aout = fa + ga;
    if (aout <= 0.0001) discard;
    vec3 rgb = (col.rgb * fa + vGlow.rgb * ga) / aout;
    frag = vec4(rgb, aout);
}
"""

/** Bakes the HUD bitmap font and provides metrics — the Android twin of
 *  main.swift's GlyphAtlas (call [upload] on the GL thread). */
class AndroidGlyphAtlas : GlyphAtlas {
    private class Glyph(val u0: Float, val uw: Float, val advance: Float)

    private val chars = "Score: Time3.4589/-01267GavOpstYuWn!dh"
        .toSet().toList()   // superset of every HUD string's characters
    private val glyphs = HashMap<Char, Glyph>()
    override var lineHeight = 0f
        private set
    private var bitmap: Bitmap
    var textureId = 0
        private set
    private var texH = 0f

    init {
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            typeface = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
            textSize = 64f
            color = 0xFFFFFFFF.toInt()
        }
        lineHeight = ceil(paint.fontMetrics.descent - paint.fontMetrics.ascent)
        val pad = 4f
        var totalW = 0f
        val widths = HashMap<Char, Float>()
        for (ch in chars) {
            val w = ceil(paint.measureText(ch.toString())) + pad
            widths[ch] = w
            totalW += w
        }
        val atlasW = totalW.toInt().coerceAtLeast(1)
        val atlasH = lineHeight.toInt().coerceAtLeast(1)
        texH = atlasH.toFloat()
        bitmap = Bitmap.createBitmap(atlasW, atlasH, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        var penX = 0f
        for (ch in chars) {
            val w = widths[ch]!!
            canvas.drawText(ch.toString(), penX + pad * 0.5f,
                            -paint.fontMetrics.ascent, paint)
            glyphs[ch] = Glyph(penX / atlasW, w / atlasW, w)
            penX += w
        }
    }

    /** GL-thread: create and fill the atlas texture. */
    fun upload() {
        val ids = IntArray(1)
        GLES30.glGenTextures(1, ids, 0)
        textureId = ids[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textureId)
        GLUtils.texImage2D(GLES30.GL_TEXTURE_2D, 0, bitmap, 0)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER,
                               GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER,
                               GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S,
                               GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T,
                               GLES30.GL_CLAMP_TO_EDGE)
    }

    override fun width(s: String, pixelHeight: Float): Float {
        val scale = pixelHeight / lineHeight
        var w = 0f
        for (ch in s) w += (glyphs[ch]?.advance ?: 0f) * scale
        return w
    }

    override fun append(s: String, list: DrawList, topLeftX: Float, topLeftY: Float,
                        pixelHeight: Float, color: Vec4) {
        val scale = pixelHeight / lineHeight
        var penX = topLeftX
        for (ch in s) {
            val g = glyphs[ch] ?: continue
            val w = g.advance * scale
            if (ch != ' ') {
                list.addGlyph(Vec2(penX + w * 0.5f, topLeftY + pixelHeight * 0.5f),
                              Vec2(w, pixelHeight),
                              Vec2(g.u0, 0f), Vec2(g.uw, 1f), color)
            }
            penX += w
        }
    }
}

/** One program, one dynamic instance VBO, one glDrawArraysInstanced. */
class GlRenderer(val atlas: AndroidGlyphAtlas) {
    private var program = 0
    private var vao = 0
    private var vbo = 0
    private var viewportLoc = 0
    private var buffer: FloatBuffer =
        ByteBuffer.allocateDirect(24 * 4 * 4096).order(ByteOrder.nativeOrder())
            .asFloatBuffer()

    fun setup() {
        program = link(compile(GLES30.GL_VERTEX_SHADER, VS),
                       compile(GLES30.GL_FRAGMENT_SHADER, FS))
        viewportLoc = GLES30.glGetUniformLocation(program, "viewport")
        atlas.upload()

        val ids = IntArray(1)
        GLES30.glGenVertexArrays(1, ids, 0)
        vao = ids[0]
        GLES30.glGenBuffers(1, ids, 0)
        vbo = ids[0]
        GLES30.glBindVertexArray(vao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        for (i in 0 until 6) {
            GLES30.glEnableVertexAttribArray(i)
            GLES30.glVertexAttribPointer(i, 4, GLES30.GL_FLOAT, false, 96, i * 16)
            GLES30.glVertexAttribDivisor(i, 1)
        }
        GLES30.glEnable(GLES30.GL_BLEND)
        GLES30.glBlendFunc(GLES30.GL_SRC_ALPHA, GLES30.GL_ONE_MINUS_SRC_ALPHA)
    }

    fun render(list: DrawList, viewW: Float, viewH: Float) {
        if (list.count == 0) return
        val floats = list.count * 24
        if (buffer.capacity() < floats) {
            buffer = ByteBuffer.allocateDirect(floats * 4 * 2)
                .order(ByteOrder.nativeOrder()).asFloatBuffer()
        }
        buffer.clear()
        buffer.put(list.data, 0, floats)
        buffer.flip()

        GLES30.glClearColor(0f, 0f, 0f, 1f)
        GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT)
        GLES30.glUseProgram(program)
        GLES30.glUniform2f(viewportLoc, viewW, viewH)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, atlas.textureId)
        GLES30.glBindVertexArray(vao)
        GLES30.glBindBuffer(GLES30.GL_ARRAY_BUFFER, vbo)
        GLES30.glBufferData(GLES30.GL_ARRAY_BUFFER, floats * 4, buffer,
                            GLES30.GL_DYNAMIC_DRAW)
        GLES30.glDrawArraysInstanced(GLES30.GL_TRIANGLE_STRIP, 0, 4, list.count)
    }

    private fun compile(type: Int, src: String): Int {
        val id = GLES30.glCreateShader(type)
        GLES30.glShaderSource(id, src)
        GLES30.glCompileShader(id)
        val ok = IntArray(1)
        GLES30.glGetShaderiv(id, GLES30.GL_COMPILE_STATUS, ok, 0)
        check(ok[0] != 0) { "shader: " + GLES30.glGetShaderInfoLog(id) }
        return id
    }

    private fun link(vs: Int, fs: Int): Int {
        val id = GLES30.glCreateProgram()
        GLES30.glAttachShader(id, vs)
        GLES30.glAttachShader(id, fs)
        GLES30.glLinkProgram(id)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(id, GLES30.GL_LINK_STATUS, ok, 0)
        check(ok[0] != 0) { "link: " + GLES30.glGetProgramInfoLog(id) }
        return id
    }
}
