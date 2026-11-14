import 'dart:convert';
import 'package:flutter/material.dart';

/// Pure-Dart ISO/IEC 18004 QR Code encoder (Byte mode, ECC Level M, Versions 1-4).
///
/// Used to display one-time pairing codes offline without third-party native
/// dependencies or sending secrets/tokens to external QR generation services.
class QrMatrixEncoder {
  QrMatrixEncoder._();

  // Version 1..4 parameters for Error Correction Level M:
  // [version, matrixSize, totalDataBytes, blockCount, ecBytesPerBlock, maxPayloadBytes]
  static const List<List<int>> _versionSpecs = [
    [1, 21, 16, 1, 10, 14],
    [2, 25, 28, 1, 16, 26],
    [3, 29, 44, 1, 26, 42],
    [4, 33, 64, 2, 18, 62],
  ];

  static final List<int> _gfExp = _buildGfExp();
  static final List<int> _gfLog = _buildGfLog(_gfExp);

  static List<int> _buildGfExp() {
    final exp = List<int>.filled(512, 0);
    var v = 1;
    for (var i = 0; i < 255; i++) {
      exp[i] = v;
      exp[i + 255] = v;
      v <<= 1;
      if ((v & 0x100) != 0) {
        v ^= 0x11D;
      }
    }
    exp[510] = exp[0];
    exp[511] = exp[1];
    return exp;
  }

  static List<int> _buildGfLog(List<int> exp) {
    final log = List<int>.filled(256, 0);
    for (var i = 0; i < 255; i++) {
      log[exp[i]] = i;
    }
    return log;
  }

  static int _gfMul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return _gfExp[_gfLog[a] + _gfLog[b]];
  }

  static List<int> _rsGeneratorPoly(int ecCount) {
    var poly = <int>[1];
    for (var i = 0; i < ecCount; i++) {
      final factor = <int>[1, _gfExp[i]];
      final next = List<int>.filled(poly.length + 1, 0);
      for (var p = 0; p < poly.length; p++) {
        for (var f = 0; f < factor.length; f++) {
          next[p + f] ^= _gfMul(poly[p], factor[f]);
        }
      }
      poly = next;
    }
    return poly;
  }

  static List<int> _rsComputeRemainder(List<int> data, int ecCount) {
    final gen = _rsGeneratorPoly(ecCount);
    final work = List<int>.filled(data.length + ecCount, 0);
    for (var i = 0; i < data.length; i++) {
      work[i] = data[i];
    }
    for (var i = 0; i < data.length; i++) {
      final coef = work[i];
      if (coef == 0) continue;
      for (var j = 1; j < gen.length; j++) {
        work[i + j] ^= _gfMul(gen[j], coef);
      }
    }
    return work.sublist(data.length);
  }

  /// Generates an N x N boolean module matrix (`true` = dark module).
  static List<List<bool>> encode(String text) {
    final bytes = utf8.encode(text);
    List<int>? spec;
    for (final candidate in _versionSpecs) {
      if (bytes.length <= candidate[5]) {
        spec = candidate;
        break;
      }
    }
    if (spec == null) {
      throw ArgumentError(
        'QR payload too long (${bytes.length} bytes, max 62 bytes supported).',
      );
    }

    final version = spec[0];
    final size = spec[1];
    final totalDataBytes = spec[2];
    final blockCount = spec[3];
    final ecPerBlock = spec[4];

    // Encode byte-mode bit stream
    final bits = <int>[];
    void appendBits(int value, int count) {
      for (var i = count - 1; i >= 0; i--) {
        bits.add((value >> i) & 1);
      }
    }

    appendBits(0x4, 4); // Byte mode indicator
    appendBits(bytes.length, 8); // 8-bit length for Versions 1-9
    for (final b in bytes) {
      appendBits(b, 8);
    }

    final maxBits = totalDataBytes * 8;
    final terminatorLen = (maxBits - bits.length).clamp(0, 4);
    for (var i = 0; i < terminatorLen; i++) {
      bits.add(0);
    }
    while (bits.length % 8 != 0) {
      bits.add(0);
    }

    final dataCodewords = <int>[];
    for (var i = 0; i < bits.length; i += 8) {
      var val = 0;
      for (var j = 0; j < 8; j++) {
        val = (val << 1) | bits[i + j];
      }
      dataCodewords.add(val);
    }
    const padBytes = [0xEC, 0x11];
    var padIdx = 0;
    while (dataCodewords.length < totalDataBytes) {
      dataCodewords.add(padBytes[padIdx % 2]);
      padIdx++;
    }

    // Compute Reed-Solomon blocks & interleave
    final dataPerBlock = totalDataBytes ~/ blockCount;
    final dataBlocks = <List<int>>[];
    final ecBlocks = <List<int>>[];
    for (var b = 0; b < blockCount; b++) {
      final blockData = dataCodewords.sublist(
        b * dataPerBlock,
        (b + 1) * dataPerBlock,
      );
      dataBlocks.add(blockData);
      ecBlocks.add(_rsComputeRemainder(blockData, ecPerBlock));
    }

    final interleaved = <int>[];
    for (var i = 0; i < dataPerBlock; i++) {
      for (var b = 0; b < blockCount; b++) {
        interleaved.add(dataBlocks[b][i]);
      }
    }
    for (var i = 0; i < ecPerBlock; i++) {
      for (var b = 0; b < blockCount; b++) {
        interleaved.add(ecBlocks[b][i]);
      }
    }

    final streamBits = <int>[];
    for (final cw in interleaved) {
      for (var i = 7; i >= 0; i--) {
        streamBits.add((cw >> i) & 1);
      }
    }

    final isFunction = List.generate(size, (_) => List<bool>.filled(size, false));
    final baseModules = List.generate(size, (_) => List<bool>.filled(size, false));

    void setFn(int row, int col, bool dark) {
      baseModules[row][col] = dark;
      isFunction[row][col] = true;
    }

    void drawFinder(int top, int left) {
      for (var dy = -1; dy <= 7; dy++) {
        for (var dx = -1; dx <= 7; dx++) {
          final r = top + dy;
          final c = left + dx;
          if (r < 0 || r >= size || c < 0 || c >= size) continue;
          final inOuter = dy >= 0 && dy <= 6 && dx >= 0 && dx <= 6;
          final onBorder = dy == 0 || dy == 6 || dx == 0 || dx == 6;
          final inCenter = dy >= 2 && dy <= 4 && dx >= 2 && dx <= 4;
          setFn(r, c, inOuter && (onBorder || inCenter));
        }
      }
    }

    void drawAlignment(int centerRow, int centerCol) {
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final dist = dy.abs() > dx.abs() ? dy.abs() : dx.abs();
          setFn(centerRow + dy, centerCol + dx, dist != 1);
        }
      }
    }

    drawFinder(0, 0);
    drawFinder(0, size - 7);
    drawFinder(size - 7, 0);

    if (version >= 2) {
      drawAlignment(size - 7, size - 7);
    }

    // Timing patterns
    for (var i = 8; i < size - 8; i++) {
      final dark = i % 2 == 0;
      if (!isFunction[6][i]) setFn(6, i, dark);
      if (!isFunction[i][6]) setFn(i, 6, dark);
    }

    // Dark module + reserve format info locations
    setFn(size - 8, 8, true);
    for (var i = 0; i <= 8; i++) {
      if (i != 6) {
        if (!isFunction[8][i]) setFn(8, i, false);
        if (!isFunction[i][8]) setFn(i, 8, false);
      }
    }
    for (var i = size - 8; i < size; i++) {
      if (!isFunction[8][i]) setFn(8, i, false);
      if (i > size - 8 && !isFunction[i][8]) setFn(i, 8, false);
    }

    // Zigzag place data/EC bits
    var bitCursor = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      final upward = ((right + 1) & 2) == 0;
      for (var step = 0; step < size; step++) {
        final row = upward ? size - 1 - step : step;
        for (var dx = 0; dx < 2; dx++) {
          final col = right - dx;
          if (!isFunction[row][col]) {
            final dark = bitCursor < streamBits.length && streamBits[bitCursor] == 1;
            baseModules[row][col] = dark;
            bitCursor++;
          }
        }
      }
    }

    // Choose best mask (0..7) by lowest penalty
    var bestScore = 1 << 30;
    late List<List<bool>> bestMatrix;

    for (var mask = 0; mask < 8; mask++) {
      final candidate = List.generate(size, (r) {
        return List<bool>.generate(size, (c) {
          if (isFunction[r][c]) return baseModules[r][c];
          final invert = _maskCondition(mask, r, c);
          return invert ? !baseModules[r][c] : baseModules[r][c];
        });
      });
      _drawFormatBitsM(candidate, mask);
      final score = _penaltyScore(candidate);
      if (score < bestScore) {
        bestScore = score;
        bestMatrix = candidate;
      }
    }

    return bestMatrix;
  }

  static bool _maskCondition(int mask, int r, int c) {
    switch (mask) {
      case 0:
        return (r + c) % 2 == 0;
      case 1:
        return r % 2 == 0;
      case 2:
        return c % 3 == 0;
      case 3:
        return (r + c) % 3 == 0;
      case 4:
        return ((r ~/ 2) + (c ~/ 3)) % 2 == 0;
      case 5:
        return ((r * c) % 2 + (r * c) % 3) == 0;
      case 6:
        return (((r * c) % 2 + (r * c) % 3) % 2) == 0;
      case 7:
        return (((r + c) % 2 + (r * c) % 3) % 2) == 0;
      default:
        return false;
    }
  }

  static void _drawFormatBitsM(List<List<bool>> modules, int mask) {
    final size = modules.length;
    // ECC level M = 00
    final data = mask & 0x7;
    var rem = data << 10;
    for (var i = 14; i >= 10; i--) {
      if ((rem & (1 << i)) != 0) {
        rem ^= 0x537 << (i - 10);
      }
    }
    final bits = ((data << 10) | rem) ^ 0x5412;

    for (var i = 0; i <= 5; i++) {
      modules[8][i] = ((bits >> i) & 1) != 0;
    }
    modules[8][7] = ((bits >> 6) & 1) != 0;
    modules[8][8] = ((bits >> 7) & 1) != 0;
    modules[7][8] = ((bits >> 8) & 1) != 0;
    for (var i = 9; i <= 14; i++) {
      modules[14 - i][8] = ((bits >> i) & 1) != 0;
    }

    for (var i = 0; i <= 6; i++) {
      modules[size - 1 - i][8] = ((bits >> i) & 1) != 0;
    }
    for (var i = 7; i <= 14; i++) {
      modules[8][size - 15 + i] = ((bits >> i) & 1) != 0;
    }
  }

  static int _penaltyScore(List<List<bool>> m) {
    final size = m.length;
    var penalty = 0;

    // 1. Adjacent same-color modules in rows & columns
    for (var r = 0; r < size; r++) {
      var run = 1;
      for (var c = 1; c < size; c++) {
        if (m[r][c] == m[r][c - 1]) {
          run++;
        } else {
          if (run >= 5) penalty += 3 + (run - 5);
          run = 1;
        }
      }
      if (run >= 5) penalty += 3 + (run - 5);
    }
    for (var c = 0; c < size; c++) {
      var run = 1;
      for (var r = 1; r < size; r++) {
        if (m[r][c] == m[r - 1][c]) {
          run++;
        } else {
          if (run >= 5) penalty += 3 + (run - 5);
          run = 1;
        }
      }
      if (run >= 5) penalty += 3 + (run - 5);
    }

    // 2. 2x2 blocks
    for (var r = 0; r < size - 1; r++) {
      for (var c = 0; c < size - 1; c++) {
        final v = m[r][c];
        if (m[r][c + 1] == v && m[r + 1][c] == v && m[r + 1][c + 1] == v) {
          penalty += 3;
        }
      }
    }

    // 3. Dark ratio balance
    var darkCount = 0;
    for (var r = 0; r < size; r++) {
      for (var c = 0; c < size; c++) {
        if (m[r][c]) darkCount++;
      }
    }
    final pct = (darkCount * 100) ~/ (size * size);
    penalty += ((pct - 50).abs() ~/ 5) * 10;

    return penalty;
  }
}

class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.data,
    this.size = 188,
  });

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final matrix = QrMatrixEncoder.encode(data);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFD0D7DE)),
      ),
      child: CustomPaint(
        painter: _QrPainter(matrix),
        size: Size.square(size - 20),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.matrix);

  final List<List<bool>> matrix;

  @override
  void paint(Canvas canvas, Size size) {
    final count = matrix.length;
    if (count == 0) return;
    final cell = size.width / count;
    final paint = Paint()
      ..color = const Color(0xFF0F172A)
      ..style = PaintingStyle.fill;

    for (var r = 0; r < count; r++) {
      for (var c = 0; c < count; c++) {
        if (matrix[r][c]) {
          canvas.drawRect(
            Rect.fromLTWH(c * cell, r * cell, cell + 0.15, cell + 0.15),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _QrPainter oldDelegate) =>
      oldDelegate.matrix != matrix;
}
