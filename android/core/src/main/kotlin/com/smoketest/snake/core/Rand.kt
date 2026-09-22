package com.smoketest.snake.core

/**
 * Deterministic randomness — the exact twin of `Rand` in main.swift.
 * SplitMix64 with explicit range mapping; given the same seed, the Swift
 * and Kotlin streams are bit-identical (all scaling is by powers of two,
 * which is lossless in IEEE 754).
 */
object Rand {
    private const val TWO_POW_53 = 9007199254740992.0   // 2^53, exact

    var state: ULong = kotlin.random.Random.nextLong().toULong()

    fun seed(s: ULong) { state = s }

    fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }

    /** Uniform in [0, 1): the top 53 bits, scaled. */
    fun unit(): Double = (next() shr 11).toDouble() / TWO_POW_53

    fun d(lo: Double, hi: Double): Double = lo + unit() * (hi - lo)

    /** Uniform integer in [lo, hi) — mirrors Swift's `i(Range)`. */
    fun iExcl(lo: Int, hiExclusive: Int): Int =
        lo + (unit() * (hiExclusive - lo).toDouble()).toInt()

    /** Uniform integer in [lo, hi] — mirrors Swift's `i(ClosedRange)`. */
    fun i(lo: Int, hi: Int): Int = iExcl(lo, hi + 1)

    fun <T> pick(a: List<T>): T? = if (a.isEmpty()) null else a[iExcl(0, a.size)]

    fun <T> shuffled(a: List<T>): List<T> {
        val c = a.toMutableList()
        var k = c.size - 1
        while (k >= 1) {
            val j = iExcl(0, k + 1)
            val tmp = c[k]; c[k] = c[j]; c[j] = tmp
            k -= 1
        }
        return c
    }
}
