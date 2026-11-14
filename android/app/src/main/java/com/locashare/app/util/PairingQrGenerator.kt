package com.locashare.app.util

import android.graphics.Bitmap
import android.graphics.Color

/**
 * Self-contained ISO/IEC 18004 QR Code generator (Byte mode, ECC Level L, Version 2 & 3)
 * for rendering one-time pairing QR codes on the Android screen without external dependencies.
 */
object PairingQrGenerator {

    /**
     * Generate a boolean matrix (true = dark module, false = light module) for [payload].
     */
    fun encodeMatrix(payload: String): Array<BooleanArray> {
        val bytes = payload.toByteArray(Charsets.UTF_8)
        require(bytes.isNotEmpty() && bytes.size <= 53) {
            "QR payload length must be between 1 and 53 bytes."
        }

        // Version 2 (25x25, 34 data codewords, 10 ECC codewords) or Version 3 (29x29, 55 data, 15 ECC)
        val version = if (bytes.size <= 32) 2 else 3
        val size = 17 + version * 4
        val dataCodewordsCount = if (version == 2) 34 else 55
        val eccCodewordsCount = if (version == 2) 10 else 15

        val dataCodewords = buildDataCodewords(bytes, dataCodewordsCount)
        val eccCodewords = computeReedSolomonEcc(dataCodewords, eccCodewordsCount)
        val allCodewords = IntArray(dataCodewords.size + eccCodewords.size)
        System.arraycopy(dataCodewords, 0, allCodewords, 0, dataCodewords.size)
        System.arraycopy(eccCodewords, 0, allCodewords, dataCodewords.size, eccCodewords.size)

        val modules = Array(size) { BooleanArray(size) }
        val isFunction = Array(size) { BooleanArray(size) }

        placeFinderPattern(modules, isFunction, 0, 0)
        placeFinderPattern(modules, isFunction, size - 7, 0)
        placeFinderPattern(modules, isFunction, 0, size - 7)

        // Timing patterns
        for (i in 8 until size - 8) {
            val dark = (i % 2 == 0)
            modules[6][i] = dark
            isFunction[6][i] = true
            modules[i][6] = dark
            isFunction[i][6] = true
        }

        // Alignment pattern (center at 18,18 for v2, 22,22 for v3)
        val alignCenter = if (version == 2) 18 else 22
        placeAlignmentPattern(modules, isFunction, alignCenter, alignCenter)

        // Dark module and reserved format information areas
        modules[size - 8][8] = true
        isFunction[size - 8][8] = true
        reserveFormatAreas(isFunction, size)

        // Place data and ECC bits in upward/downward 2-column zigzag
        placeCodewordBits(modules, isFunction, allCodewords)

        // Apply Mask Pattern 0: (row + col) % 2 == 0
        for (r in 0 until size) {
            for (c in 0 until size) {
                if (!isFunction[r][c] && ((r + c) % 2 == 0)) {
                    modules[r][c] = !modules[r][c]
                }
            }
        }

        // Write Format Information for ECC Level L (01) + Mask 0 (000) -> 0x77C4
        writeFormatBits(modules, size, 0x77C4)

        return modules
    }

    /**
     * Render a scannable QR Code [Bitmap] for [payload].
     */
    fun createQrBitmap(payload: String, sizePx: Int = 360, quietZoneModules: Int = 3): Bitmap {
        val matrix = encodeMatrix(payload)
        val matrixSize = matrix.size
        val totalModules = matrixSize + quietZoneModules * 2
        val bitmapSize = maxOf(sizePx, totalModules * 4)

        val pixels = IntArray(bitmapSize * bitmapSize) { Color.WHITE }
        for (y in 0 until bitmapSize) {
            val moduleY = (y * totalModules) / bitmapSize - quietZoneModules
            for (x in 0 until bitmapSize) {
                val moduleX = (x * totalModules) / bitmapSize - quietZoneModules
                val isDark = if (moduleY in 0 until matrixSize && moduleX in 0 until matrixSize) {
                    matrix[moduleY][moduleX]
                } else {
                    false
                }
                pixels[y * bitmapSize + x] = if (isDark) Color.BLACK else Color.WHITE
            }
        }

        return Bitmap.createBitmap(pixels, bitmapSize, bitmapSize, Bitmap.Config.ARGB_8888)
    }

    private fun buildDataCodewords(bytes: ByteArray, capacityCodewords: Int): IntArray {
        val bits = ArrayList<Int>(capacityCodewords * 8)

        fun appendBits(value: Int, numBits: Int) {
            for (i in numBits - 1 downTo 0) {
                bits.add((value ushr i) and 1)
            }
        }

        // Byte mode indicator (0100) + 8-bit character count
        appendBits(0b0100, 4)
        appendBits(bytes.size, 8)
        for (b in bytes) {
            appendBits(b.toInt() and 0xFF, 8)
        }

        // Terminator (up to 4 zero bits)
        val maxBits = capacityCodewords * 8
        val terminatorLen = minOf(4, maxBits - bits.size)
        appendBits(0, terminatorLen)

        // Pad to byte boundary
        while (bits.size % 8 != 0) {
            bits.add(0)
        }

        // Pad codewords 0xEC, 0x11
        val padBytes = intArrayOf(0xEC, 0x11)
        var padIdx = 0
        while (bits.size < maxBits) {
            appendBits(padBytes[padIdx % 2], 8)
            padIdx++
        }

        val result = IntArray(capacityCodewords)
        for (i in 0 until capacityCodewords) {
            var byteVal = 0
            for (b in 0 until 8) {
                byteVal = (byteVal shl 1) or bits[i * 8 + b]
            }
            result[i] = byteVal
        }
        return result
    }

    private fun computeReedSolomonEcc(data: IntArray, degree: Int): IntArray {
        val gen = IntArray(degree)
        gen[degree - 1] = 1
        var root = 1
        for (i in 0 until degree) {
            for (j in 0 until degree) {
                gen[j] = gfMultiply(gen[j], root)
                if (j + 1 < degree) {
                    gen[j] = gen[j] xor gen[j + 1]
                }
            }
            root = gfMultiply(root, 0x02)
        }

        val result = IntArray(degree)
        for (b in data) {
            val factor = b xor result[0]
            System.arraycopy(result, 1, result, 0, degree - 1)
            result[degree - 1] = 0
            for (j in 0 until degree) {
                result[j] = result[j] xor gfMultiply(gen[j], factor)
            }
        }
        return result
    }

    private fun gfMultiply(x: Int, y: Int): Int {
        var z = 0
        for (i in 7 downTo 0) {
            z = (z shl 1) xor ((z ushr 7) * 0x11D)
            z = z xor (((y ushr i) and 1) * x)
        }
        return z
    }

    private fun placeFinderPattern(
        modules: Array<BooleanArray>,
        isFunction: Array<BooleanArray>,
        top: Int,
        left: Int
    ) {
        val size = modules.size
        for (dy in -1..7) {
            for (dx in -1..7) {
                val r = top + dy
                val c = left + dx
                if (r in 0 until size && c in 0 until size) {
                    val inOuter = dy in 0..6 && dx in 0..6
                    val isBorder = dy == 0 || dy == 6 || dx == 0 || dx == 6
                    val isInner = dy in 2..4 && dx in 2..4
                    modules[r][c] = inOuter && (isBorder || isInner)
                    isFunction[r][c] = true
                }
            }
        }
    }

    private fun placeAlignmentPattern(
        modules: Array<BooleanArray>,
        isFunction: Array<BooleanArray>,
        centerR: Int,
        centerC: Int
    ) {
        for (dy in -2..2) {
            for (dx in -2..2) {
                val r = centerR + dy
                val c = centerC + dx
                val dist = maxOf(kotlin.math.abs(dy), kotlin.math.abs(dx))
                modules[r][c] = (dist != 1)
                isFunction[r][c] = true
            }
        }
    }

    private fun reserveFormatAreas(isFunction: Array<BooleanArray>, size: Int) {
        for (i in 0..8) {
            if (i != 6) {
                isFunction[8][i] = true
                isFunction[i][8] = true
            }
        }
        for (i in 0..7) {
            isFunction[8][size - 1 - i] = true
            isFunction[size - 1 - i][8] = true
        }
    }

    private fun placeCodewordBits(
        modules: Array<BooleanArray>,
        isFunction: Array<BooleanArray>,
        codewords: IntArray
    ) {
        val size = modules.size
        var bitIndex = 0
        val totalBits = codewords.size * 8

        var right = size - 1
        var upward = true
        while (right >= 1) {
            if (right == 6) {
                right = 5
            }
            for (vert in 0 until size) {
                val r = if (upward) (size - 1 - vert) else vert
                for (j in 0..1) {
                    val c = right - j
                    if (!isFunction[r][c]) {
                        val bit = if (bitIndex < totalBits) {
                            ((codewords[bitIndex ushr 3] ushr (7 - (bitIndex and 7))) and 1) == 1
                        } else {
                            false
                        }
                        modules[r][c] = bit
                        bitIndex++
                    }
                }
            }
            upward = !upward
            right -= 2
        }
    }

    private fun writeFormatBits(modules: Array<BooleanArray>, size: Int, formatBits: Int) {
        fun bit(i: Int): Boolean = ((formatBits ushr i) and 1) == 1

        // Around top-left finder
        for (i in 0..5) modules[8][i] = bit(i)
        modules[8][7] = bit(6)
        modules[8][8] = bit(7)
        modules[7][8] = bit(8)
        for (i in 9..14) modules[14 - i][8] = bit(i)

        // Around top-right and bottom-left finders
        for (i in 0..7) modules[8][size - 1 - i] = bit(i)
        for (i in 8..14) modules[size - 15 + i][8] = bit(i)
    }
}
