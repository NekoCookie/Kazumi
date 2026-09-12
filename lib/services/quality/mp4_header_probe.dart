import 'dart:typed_data';

/// 从 MP4 文件头（或尾）的 `moov` 数据里读时长和画面尺寸。
///
/// 只做线性扫描找 `mvhd` / `tkhd` 两个 box，不完整解析容器结构，
/// 因此对 moov 在文件头或文件尾的普通点播 mp4 都适用。
class Mp4HeaderInfo {
  const Mp4HeaderInfo({this.durationSeconds, this.width, this.height});

  final double? durationSeconds;
  final int? width;
  final int? height;

  bool get hasDuration => durationSeconds != null && durationSeconds! > 0;

  bool get hasResolution => width != null && height != null;

  bool get isEmpty => !hasDuration && !hasResolution;
}

class Mp4HeaderProbe {
  const Mp4HeaderProbe._();

  static const _mvhd = [0x6D, 0x76, 0x68, 0x64]; // 'mvhd'
  static const _tkhd = [0x74, 0x6B, 0x68, 0x64]; // 'tkhd'

  static Mp4HeaderInfo parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    double? duration;
    int? width;
    int? height;

    for (final offset in _findAll(bytes, _mvhd)) {
      final parsed = _parseMvhd(data, offset + 4);
      if (parsed != null) {
        duration = parsed;
        break;
      }
    }

    for (final offset in _findAll(bytes, _tkhd)) {
      final parsed = _parseTkhd(data, offset + 4);
      if (parsed != null) {
        width = parsed.$1;
        height = parsed.$2;
        break;
      }
    }

    return Mp4HeaderInfo(
        durationSeconds: duration, width: width, height: height);
  }

  /// 按顶层 box 顺序走一遍 [head]，返回 moov box 在文件中的起始偏移。
  ///
  /// moov 在 [head] 内时直接返回它的偏移；若某个 box（通常是超大的 mdat）
  /// 延伸到 [head] 之外，则返回它的结束位置，即下一个 box 的起点，调用方
  /// 从那里再拉一段解析。无法判断时返回 null。
  static int? locateMoovOffset(Uint8List head) {
    final data = ByteData.sublistView(head);
    var offset = 0;
    while (offset + 8 <= head.length) {
      var size = data.getUint32(offset);
      var headerSize = 8;
      if (size == 1) {
        if (offset + 16 > head.length) return null;
        size = data.getUint64(offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        // 该 box 延伸到文件末尾，后面不会再有 box。
        return null;
      }
      if (size < headerSize) return null;
      final type = String.fromCharCodes(head, offset + 4, offset + 8);
      if (type == 'moov') return offset;
      final next = offset + size;
      if (next > head.length) return next;
      offset = next;
    }
    return null;
  }

  /// [body] 指向 box type 之后（即 version 字节）。
  static double? _parseMvhd(ByteData data, int body) {
    if (body + 4 > data.lengthInBytes) return null;
    final version = data.getUint8(body);
    int timescale;
    double duration;
    if (version == 0) {
      // version(1) flags(3) ctime(4) mtime(4) timescale(4) duration(4)
      if (body + 20 > data.lengthInBytes) return null;
      timescale = data.getUint32(body + 12);
      duration = data.getUint32(body + 16).toDouble();
    } else if (version == 1) {
      // version(1) flags(3) ctime(8) mtime(8) timescale(4) duration(8)
      if (body + 32 > data.lengthInBytes) return null;
      timescale = data.getUint32(body + 20);
      duration = data.getUint64(body + 24).toDouble();
    } else {
      return null;
    }
    if (timescale <= 0 || duration <= 0) return null;
    final seconds = duration / timescale;
    // 超过 24 小时基本是误匹配。
    if (seconds > 24 * 3600) return null;
    return seconds;
  }

  /// 返回 (width, height)，取第一条画面尺寸非零的轨道。
  static (int, int)? _parseTkhd(ByteData data, int body) {
    if (body + 4 > data.lengthInBytes) return null;
    final version = data.getUint8(body);
    // 到 matrix 之前的固定字段长度（含 version/flags）。
    final int prefix;
    if (version == 0) {
      // 4 + ctime 4 + mtime 4 + trackId 4 + reserved 4 + duration 4
      //   + reserved 8 + layer 2 + altGroup 2 + volume 2 + reserved 2
      prefix = 4 + 4 + 4 + 4 + 4 + 4 + 8 + 2 + 2 + 2 + 2;
    } else if (version == 1) {
      prefix = 4 + 8 + 8 + 4 + 4 + 8 + 8 + 2 + 2 + 2 + 2;
    } else {
      return null;
    }
    final widthOffset = body + prefix + 36; // matrix 占 36 字节
    if (widthOffset + 8 > data.lengthInBytes) return null;
    final width = data.getUint32(widthOffset) >> 16; // 16.16 定点
    final height = data.getUint32(widthOffset + 4) >> 16;
    if (width < 16 || height < 16 || width > 16384 || height > 16384) {
      return null;
    }
    return (width, height);
  }

  static Iterable<int> _findAll(Uint8List bytes, List<int> pattern) sync* {
    final last = bytes.length - pattern.length;
    for (var i = 4; i <= last; i++) {
      if (bytes[i] != pattern[0]) continue;
      var matched = true;
      for (var j = 1; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
          matched = false;
          break;
        }
      }
      if (matched) yield i;
    }
  }
}
