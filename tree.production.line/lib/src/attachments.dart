/// 附件探测与边界（Task 6.1）：纯函数，不读盘、不写盘。
///
/// 口径：
/// - 只按**文件头**判断格式，不信任扩展名 / `type`；
/// - 图片给出宽高、透明、动画、EXIF 等确定性命中项；解不出结构即 `corrupt`；
/// - SVG 只做静态危险特征检查（脚本 / 事件 / `javascript:`），不做完整清洗；
/// - 单文件 ≤ 10 MiB、每任务 ≤ 20 个、图片像素 ≤ 4096×4096（4096²）。
library;

import 'dart:convert';

/// 单个附件大小上限（10 MiB）。
const int kMaxAttachmentBytes = 10 * 1024 * 1024;

/// 单个任务可登记的附件数量上限。
const int kMaxAttachmentsPerTask = 20;

/// 图片像素上限（4096 × 4096）。
const int kMaxImagePixels = 4096 * 4096;

/// 一次探测的确定性命中项。
///
/// 非图片（PDF / Office / 文本 / 其它二进制）返回全零 + `format=''`，
/// 由调用方按 `kind` 决定是否展示；不会把未知格式当成坏图。
class AttachmentProbe {
  const AttachmentProbe({
    this.width = 0,
    this.height = 0,
    this.animated = false,
    this.transparent = false,
    this.hasExif = false,
    this.corrupt = false,
    this.unsafeSvg = false,
    this.format = '',
  });

  final int width;
  final int height;
  final bool animated;
  final bool transparent;
  final bool hasExif;
  final bool corrupt;
  final bool unsafeSvg;

  /// `png / jpeg / gif / webp / svg`；非图片为空串。
  final String format;

  /// 是否识别为图片格式。
  bool get isImage =>
      const <String>{'png', 'jpeg', 'gif', 'webp', 'svg'}.contains(format);

  Map<String, Object?> toJson() => <String, Object?>{
    'format': format,
    'width': width,
    'height': height,
    'animated': animated,
    'transparent': transparent,
    'has_exif': hasExif,
    'corrupt': corrupt,
    'unsafe_svg': unsafeSvg,
  };
}

/// 按文件头探测附件；解不出结构时给出 `corrupt`，不抛异常。
AttachmentProbe probeAttachment(List<int> bytes, String type) {
  final String lowerType = type.trim().toLowerCase();
  if (_startsWith(bytes, const <int>[0x89, 0x50, 0x4E, 0x47])) {
    return _probePng(bytes);
  }
  if (_startsWith(bytes, const <int>[0xFF, 0xD8])) {
    return _probeJpeg(bytes);
  }
  if (_startsWith(bytes, asciiBytes('GIF87a')) ||
      _startsWith(bytes, asciiBytes('GIF89a'))) {
    return _probeGif(bytes);
  }
  if (bytes.length >= 12 &&
      _ascii(bytes, 0, 4) == 'RIFF' &&
      _ascii(bytes, 8, 12) == 'WEBP') {
    return _probeWebp(bytes);
  }
  if (lowerType.contains('svg') || _containsAscii(bytes, '<svg')) {
    return _probeSvg(utf8.decode(bytes, allowMalformed: true));
  }
  return const AttachmentProbe();
}

/// 稳定顺序的告警码；非图片返回空列表。
///
/// [vision] 为 false（默认）时，图片只作为人工参考，不送模型。
List<String> attachmentWarningsOf({
  required AttachmentProbe probe,
  required bool vision,
}) {
  if (!probe.isImage) return const <String>[];
  return <String>[
    if (probe.animated) 'image_animated_first_frame',
    if (probe.transparent) 'image_transparent',
    if (probe.hasExif) 'image_exif_present',
    if (!vision) 'image_manual_reference',
  ];
}

/// 附件拒绝码；通过返回 `null`。
///
/// 顺序固定：大小 → 坏图 → 像素 → 不安全 SVG。
String? attachmentRejectionOf({
  required AttachmentProbe probe,
  required int bytesLength,
  required bool isImage,
}) {
  if (bytesLength > kMaxAttachmentBytes) return 'attachment_too_large';
  if (!isImage) return null;
  if (probe.corrupt) return 'image_corrupt';
  if (probe.width * probe.height > kMaxImagePixels) return 'image_too_large';
  if (probe.unsafeSvg) return 'attachment_unsafe_svg';
  return null;
}

/// `String` → ASCII 字节（SVG 检查等内部用途）。
List<int> asciiBytes(String text) => text.codeUnits;

// ── PNG ──────────────────────────────────────────────────────────────

AttachmentProbe _probePng(List<int> bytes) {
  // 8 字节签名 + IHDR 长度 / 类型 + 13 字节数据（宽高在 16..24）。
  if (bytes.length < 26 || _ascii(bytes, 12, 16) != 'IHDR') {
    return const AttachmentProbe(format: 'png', corrupt: true);
  }
  final int width = _u32be(bytes, 16);
  final int height = _u32be(bytes, 20);
  if (width <= 0 || height <= 0) {
    return const AttachmentProbe(format: 'png', corrupt: true);
  }
  final int colorType = bytes[25];
  bool transparent = colorType == 4 || colorType == 6;
  bool hasExif = false;
  int pos = 8;
  while (pos + 8 <= bytes.length) {
    final int length = _u32be(bytes, pos);
    if (length < 0 || pos + 12 + length > bytes.length) break;
    final String chunkType = _ascii(bytes, pos + 4, pos + 8);
    if (chunkType == 'tRNS') transparent = true;
    if (chunkType == 'eXIf') hasExif = true;
    if (chunkType == 'IEND') break;
    pos += 12 + length;
  }
  return AttachmentProbe(
    format: 'png',
    width: width,
    height: height,
    transparent: transparent,
    hasExif: hasExif,
  );
}

// ── JPEG ─────────────────────────────────────────────────────────────

AttachmentProbe _probeJpeg(List<int> bytes) {
  bool hasExif = false;
  bool sawSof = false;
  bool corrupt = false;
  int width = 0;
  int height = 0;
  int pos = 2;
  while (pos < bytes.length) {
    if (bytes[pos] != 0xFF) {
      corrupt = true;
      break;
    }
    if (pos + 1 >= bytes.length) {
      corrupt = true;
      break;
    }
    final int marker = bytes[pos + 1];
    if (marker == 0xFF) {
      pos += 1;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2;
      continue;
    }
    if (marker == 0xD9) break;
    if (pos + 4 > bytes.length) {
      corrupt = true;
      break;
    }
    final int length = (bytes[pos + 2] << 8) | bytes[pos + 3];
    if (length < 2 || pos + 2 + length > bytes.length) {
      corrupt = true;
      break;
    }
    final int payload = pos + 4;
    if (marker == 0xE1 &&
        length >= 8 &&
        _ascii(bytes, payload, payload + 4) == 'Exif' &&
        bytes[payload + 4] == 0 &&
        bytes[payload + 5] == 0) {
      hasExif = true;
    }
    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2) {
      if (length < 7) {
        corrupt = true;
        break;
      }
      height = (bytes[payload + 1] << 8) | bytes[payload + 2];
      width = (bytes[payload + 3] << 8) | bytes[payload + 4];
      sawSof = true;
      break;
    }
    if (marker == 0xDA) {
      // SOS 之前没有 SOF：拿不到尺寸。
      corrupt = true;
      break;
    }
    pos += 2 + length;
  }
  if (!sawSof || width <= 0 || height <= 0) corrupt = true;
  return AttachmentProbe(
    format: 'jpeg',
    width: width > 0 ? width : 0,
    height: height > 0 ? height : 0,
    hasExif: hasExif,
    corrupt: corrupt,
  );
}

// ── GIF ──────────────────────────────────────────────────────────────

AttachmentProbe _probeGif(List<int> bytes) {
  if (bytes.length < 10) {
    return const AttachmentProbe(format: 'gif', corrupt: true);
  }
  final int width = bytes[6] | (bytes[7] << 8);
  final int height = bytes[8] | (bytes[9] << 8);
  if (width <= 0 || height <= 0) {
    return const AttachmentProbe(format: 'gif', corrupt: true);
  }
  bool animated = false;
  bool transparent = false;
  int pos = 10;
  if (pos < bytes.length) {
    final int packed = bytes[pos];
    pos += 3;
    if (packed & 0x80 != 0) {
      pos += 3 * (1 << ((packed & 0x07) + 1));
    }
  }
  int images = 0;
  while (pos < bytes.length) {
    final int block = bytes[pos];
    if (block == 0x3B) break;
    if (block == 0x21) {
      if (pos + 2 > bytes.length) break;
      final int label = bytes[pos + 1];
      pos += 2;
      bool first = true;
      while (pos < bytes.length) {
        final int size = bytes[pos];
        pos += 1;
        if (size == 0) break;
        if (pos + size > bytes.length) {
          return AttachmentProbe(
            format: 'gif',
            width: width,
            height: height,
            corrupt: true,
          );
        }
        if (label == 0xF9 && first) {
          transparent = transparent || bytes[pos] & 0x01 != 0;
        }
        if (label == 0xFF &&
            _ascii(bytes, pos, pos + size).contains('NETSCAPE2.0')) {
          animated = true;
        }
        pos += size;
        first = false;
      }
      continue;
    }
    if (block == 0x2C) {
      images += 1;
      if (pos + 10 > bytes.length) {
        return AttachmentProbe(
          format: 'gif',
          width: width,
          height: height,
          corrupt: true,
        );
      }
      final int packed = bytes[pos + 9];
      pos += 10;
      if (packed & 0x80 != 0) {
        pos += 3 * (1 << ((packed & 0x07) + 1));
      }
      if (pos >= bytes.length) {
        return AttachmentProbe(
          format: 'gif',
          width: width,
          height: height,
          corrupt: true,
        );
      }
      pos += 1; // LZW 最小码长
      while (pos < bytes.length) {
        final int size = bytes[pos];
        pos += 1;
        if (size == 0) break;
        pos += size;
      }
      continue;
    }
    break;
  }
  if (images > 1) animated = true;
  return AttachmentProbe(
    format: 'gif',
    width: width,
    height: height,
    animated: animated,
    transparent: transparent,
  );
}

// ── WebP ─────────────────────────────────────────────────────────────

AttachmentProbe _probeWebp(List<int> bytes) {
  if (bytes.length < 20) {
    return const AttachmentProbe(format: 'webp', corrupt: true);
  }
  final String chunk = _ascii(bytes, 12, 16);
  if (chunk == 'VP8X') {
    if (bytes.length < 30) {
      return const AttachmentProbe(format: 'webp', corrupt: true);
    }
    final int flags = bytes[20];
    return AttachmentProbe(
      format: 'webp',
      width: _u24le(bytes, 24) + 1,
      height: _u24le(bytes, 27) + 1,
      animated: flags & 0x02 != 0,
      transparent: flags & 0x10 != 0,
      hasExif: flags & 0x08 != 0,
    );
  }
  if (chunk == 'VP8 ') {
    if (bytes.length < 30) {
      return const AttachmentProbe(format: 'webp', corrupt: true);
    }
    final int width = (bytes[26] | (bytes[27] << 8)) & 0x3FFF;
    final int height = (bytes[28] | (bytes[29] << 8)) & 0x3FFF;
    if (width <= 0 || height <= 0) {
      return const AttachmentProbe(format: 'webp', corrupt: true);
    }
    return AttachmentProbe(format: 'webp', width: width, height: height);
  }
  if (chunk == 'VP8L') {
    if (bytes.length < 25 || bytes[20] != 0x2F) {
      return const AttachmentProbe(format: 'webp', corrupt: true);
    }
    final int bits =
        bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return AttachmentProbe(
      format: 'webp',
      width: (bits & 0x3FFF) + 1,
      height: ((bits >> 14) & 0x3FFF) + 1,
    );
  }
  return const AttachmentProbe(format: 'webp', corrupt: true);
}

// ── SVG ──────────────────────────────────────────────────────────────

final RegExp _svgTagPattern = RegExp(
  r'<svg\b[^>]*>',
  caseSensitive: false,
  dotAll: true,
);
final RegExp _svgWidthPattern = RegExp(
  r'''width\s*=\s*["']?\s*([0-9]+(?:\.[0-9]+)?)''',
  caseSensitive: false,
);
final RegExp _svgHeightPattern = RegExp(
  r'''height\s*=\s*["']?\s*([0-9]+(?:\.[0-9]+)?)''',
  caseSensitive: false,
);

AttachmentProbe _probeSvg(String text) {
  final String lower = text.toLowerCase();
  final bool unsafe =
      lower.contains('<script') ||
      lower.contains('onload=') ||
      lower.contains('onerror=') ||
      lower.contains('javascript:');
  int width = 0;
  int height = 0;
  final RegExpMatch? tag = _svgTagPattern.firstMatch(text);
  if (tag != null) {
    final String value = tag.group(0)!;
    width = _dimensionOf(_svgWidthPattern, value);
    height = _dimensionOf(_svgHeightPattern, value);
  }
  return AttachmentProbe(
    format: 'svg',
    width: width,
    height: height,
    unsafeSvg: unsafe,
  );
}

int _dimensionOf(RegExp pattern, String tag) {
  final String raw = pattern.firstMatch(tag)?.group(1) ?? '';
  return double.tryParse(raw)?.toInt() ?? 0;
}

// ── 字节工具 ────────────────────────────────────────────────────────

bool _startsWith(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

bool _containsAscii(List<int> bytes, String needle) {
  final List<int> want = asciiBytes(needle);
  if (want.isEmpty || bytes.length < want.length) return false;
  for (int i = 0; i + want.length <= bytes.length; i++) {
    bool hit = true;
    for (int j = 0; j < want.length; j++) {
      if (bytes[i + j] != want[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

int _u32be(List<int> bytes, int offset) =>
    (bytes[offset] << 24) |
    (bytes[offset + 1] << 16) |
    (bytes[offset + 2] << 8) |
    bytes[offset + 3];

int _u24le(List<int> bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);

String _ascii(List<int> bytes, int start, int end) {
  if (start < 0 || end > bytes.length || start >= end) return '';
  return String.fromCharCodes(bytes.sublist(start, end));
}
