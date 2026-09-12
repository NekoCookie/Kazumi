import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/quality/mp4_header_probe.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

/// 单个视频地址的实测结果。
class MediaBitrateResult {
  const MediaBitrateResult({
    required this.kbps,
    required this.container,
    this.width,
    this.height,
    this.downloadMbps,
  });

  /// 实测视频码率（kbps）。
  final int kbps;

  /// `hls` 或 `mp4`。
  final String container;
  final int? width;
  final int? height;

  /// 采样期间的实际下载速率（Mbps）。
  final double? downloadMbps;
}

class MediaBitrateException implements Exception {
  const MediaBitrateException(this.message);

  final String message;

  @override
  String toString() => 'MediaBitrateException: $message';
}

/// 一次带范围的字节读取结果。
class RangeFetchResult {
  const RangeFetchResult({required this.bytes, required this.totalLength});

  final Uint8List bytes;

  /// 整个资源的总长度；服务端没给出时为 null。
  final int? totalLength;
}

typedef TextFetcher = Future<String> Function(
  String url,
  Map<String, String> headers,
  CancelToken? cancelToken,
);

typedef RangeFetcher = Future<RangeFetchResult> Function(
  String url,
  Map<String, String> headers,
  String? range,
  int maxBytes,
  CancelToken? cancelToken,
);

/// 给一个嗅探到的视频地址，实测它的码率和分辨率。
///
/// - HLS：取播放列表中段几个分片整段下载，字节数除以分片时长得到码率，
///   分辨率取主列表的 RESOLUTION。
/// - MP4：Range 读文件头（必要时再读文件尾）解析时长和尺寸，
///   总字节数除以时长得到码率。
class MediaBitrateMeter {
  MediaBitrateMeter({
    TextFetcher? fetchText,
    RangeFetcher? fetchRange,
    this.sampleSegments = 3,
  })  : _fetchText = fetchText ?? _defaultFetchText,
        _fetchRange = fetchRange ?? _defaultFetchRange;

  final TextFetcher _fetchText;
  final RangeFetcher _fetchRange;

  /// HLS 采样的分片数。
  final int sampleSegments;

  static const int _playlistMaxBytes = 2 * 1024 * 1024;
  static const int _sniffBytes = 4 * 1024;
  static const int _mp4HeadBytes = 1024 * 1024;
  static const int _mp4TailBytes = 4 * 1024 * 1024;
  static const int _mp4MoovBytes = 4 * 1024 * 1024;

  Future<MediaBitrateResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancelToken,
  }) async {
    if (_looksLikePlaylist(url)) {
      return _measureHls(url, headers, cancelToken);
    }
    // 没有扩展名的地址只取开头几 KB 判断类型，避免把整段 mp4 当文本下载。
    final head = await _fetchRange(
      url,
      headers,
      'bytes=0-${_sniffBytes - 1}',
      _sniffBytes,
      cancelToken,
    );
    if (isPlaylistPrefix(head.bytes)) {
      return _measureHls(url, headers, cancelToken);
    }
    return _measureMp4(url, headers, cancelToken);
  }

  /// 开头是否为 `#EXTM3U`（允许 BOM 和空白）。
  static bool isPlaylistPrefix(Uint8List bytes) {
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    while (start < bytes.length &&
        (bytes[start] == 0x20 ||
            bytes[start] == 0x0A ||
            bytes[start] == 0x0D ||
            bytes[start] == 0x09)) {
      start++;
    }
    const marker = [0x23, 0x45, 0x58, 0x54, 0x4D, 0x33, 0x55]; // #EXTM3U
    if (bytes.length - start < marker.length) return false;
    for (var i = 0; i < marker.length; i++) {
      if (bytes[start + i] != marker[i]) return false;
    }
    return true;
  }

  static bool _looksLikePlaylist(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  Future<String> _fetchPlaylist(
    String url,
    Map<String, String> headers,
    CancelToken? cancelToken,
  ) async {
    final String content;
    try {
      content = await _fetchText(url, headers, cancelToken);
    } on NetworkException catch (error) {
      if (error.type == NetworkExceptionType.cancel &&
          !(cancelToken?.isCancelled ?? false)) {
        throw const MediaBitrateException('播放列表过大，不是 m3u8');
      }
      rethrow;
    }
    if (!content.trimLeft().startsWith('#EXTM3U')) {
      throw const MediaBitrateException('返回内容不是 m3u8 播放列表');
    }
    return content;
  }

  Future<MediaBitrateResult> _measureHls(
    String url,
    Map<String, String> headers,
    CancelToken? cancelToken,
  ) async {
    var playlistUrl = url;
    var content = await _fetchPlaylist(playlistUrl, headers, cancelToken);
    int? width;
    int? height;

    if (M3u8Parser.detectType(content) == M3u8Type.master) {
      final master = M3u8Parser.parseMasterPlaylist(content, playlistUrl);
      if (master.variants.isEmpty) {
        throw const MediaBitrateException('主列表没有可用清晰度');
      }
      final variant = master.bestVariant;
      final resolution = parseResolution(variant.resolution);
      width = resolution?.$1;
      height = resolution?.$2;
      playlistUrl = variant.uri;
      content = await _fetchPlaylist(playlistUrl, headers, cancelToken);
    }

    final playlist = M3u8Parser.parseMediaPlaylist(content, playlistUrl);
    final segments = await M3u8Parser.resolveNestedSegments(
      playlist.segments,
      (nested) => _fetchPlaylist(nested, headers, cancelToken),
    );
    if (segments.isEmpty) {
      throw const MediaBitrateException('播放列表没有分片');
    }

    final picked = pickSampleSegments(segments, sampleSegments);
    var totalBytes = 0;
    var totalDuration = 0.0;
    final stopwatch = Stopwatch()..start();
    for (final segment in picked) {
      _throwIfCancelled(cancelToken);
      final result = await _fetchRange(
        segment.uri,
        headers,
        null,
        64 * 1024 * 1024,
        cancelToken,
      );
      totalBytes += result.bytes.length;
      totalDuration += segment.duration;
    }
    stopwatch.stop();

    if (totalDuration <= 0) {
      throw const MediaBitrateException('分片没有时长信息');
    }
    if (totalBytes <= 0) {
      throw const MediaBitrateException('分片下载为空');
    }

    return MediaBitrateResult(
      kbps: computeKbps(totalBytes, totalDuration),
      container: 'hls',
      width: width,
      height: height,
      downloadMbps:
          computeDownloadMbps(totalBytes, stopwatch.elapsedMilliseconds),
    );
  }

  Future<MediaBitrateResult> _measureMp4(
    String url,
    Map<String, String> headers,
    CancelToken? cancelToken,
  ) async {
    final stopwatch = Stopwatch()..start();
    final head = await _fetchRange(
      url,
      headers,
      'bytes=0-${_mp4HeadBytes - 1}',
      _mp4HeadBytes,
      cancelToken,
    );
    stopwatch.stop();

    var info = Mp4HeaderProbe.parse(head.bytes);
    final total = head.totalLength;
    if (total == null || total <= 0) {
      throw const MediaBitrateException('服务端未给出文件大小');
    }

    // moov 常在超大的 mdat 之后，头尾各读一段可能都碰不到。
    // 按顶层 box 大小跳过 mdat 算出 moov 位置，再精准拉一段。
    if (!info.hasDuration) {
      final moovOffset = Mp4HeaderProbe.locateMoovOffset(head.bytes);
      if (moovOffset != null &&
          moovOffset >= head.bytes.length &&
          moovOffset < total) {
        _throwIfCancelled(cancelToken);
        final end =
            (moovOffset + _mp4MoovBytes - 1).clamp(moovOffset, total - 1);
        final moov = await _fetchRange(
          url,
          headers,
          'bytes=$moovOffset-$end',
          _mp4MoovBytes,
          cancelToken,
        );
        info = _mergeInfo(info, Mp4HeaderProbe.parse(moov.bytes));
      }
    }

    if (!info.hasDuration && total > head.bytes.length) {
      _throwIfCancelled(cancelToken);
      final tailStart =
          total > _mp4TailBytes ? total - _mp4TailBytes : head.bytes.length;
      final tail = await _fetchRange(
        url,
        headers,
        'bytes=$tailStart-${total - 1}',
        _mp4TailBytes,
        cancelToken,
      );
      info = _mergeInfo(info, Mp4HeaderProbe.parse(tail.bytes));
    }

    if (!info.hasDuration) {
      throw const MediaBitrateException('无法读取 mp4 时长');
    }

    return MediaBitrateResult(
      kbps: computeKbps(total, info.durationSeconds!),
      container: 'mp4',
      width: info.width,
      height: info.height,
      downloadMbps: computeDownloadMbps(
        head.bytes.length,
        stopwatch.elapsedMilliseconds,
      ),
    );
  }

  static Mp4HeaderInfo _mergeInfo(Mp4HeaderInfo base, Mp4HeaderInfo extra) =>
      Mp4HeaderInfo(
        durationSeconds: base.durationSeconds ?? extra.durationSeconds,
        width: base.width ?? extra.width,
        height: base.height ?? extra.height,
      );

  static void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken?.isCancelled ?? false) {
      throw const MediaBitrateException('已取消');
    }
  }

  // ---- 纯函数，便于单元测试 ----

  static int computeKbps(int bytes, double seconds) {
    if (seconds <= 0) return 0;
    return (bytes * 8 / seconds / 1000).round();
  }

  static double? computeDownloadMbps(int bytes, int elapsedMs) {
    if (elapsedMs <= 0) return null;
    final mbps = bytes * 8 / (elapsedMs / 1000) / 1e6;
    return (mbps * 10).round() / 10;
  }

  static (int, int)? parseResolution(String? text) {
    if (text == null) return null;
    final match = RegExp(r'^(\d+)x(\d+)$').firstMatch(text.trim());
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  /// 避开片头广告和片尾，从列表中段均匀取 [count] 个分片。
  static List<M3u8Segment> pickSampleSegments(
    List<M3u8Segment> segments,
    int count,
  ) {
    if (segments.isEmpty || count <= 0) return const [];
    if (segments.length <= count) return List.of(segments);
    final n = segments.length;
    // 采样区间取 30% 到 70%，最少留出前后各两个分片。
    final start = (n * 0.3).floor().clamp(0, n - 1);
    final end = (n * 0.7).ceil().clamp(start + 1, n);
    final span = end - start;
    final picked = <M3u8Segment>[];
    for (var i = 0; i < count; i++) {
      final index =
          start + ((span - 1) * i / (count - 1).clamp(1, count)).round();
      picked.add(segments[index.clamp(start, end - 1)]);
    }
    return picked;
  }

  // ---- 默认网络实现 ----

  static Future<String> _defaultFetchText(
    String url,
    Map<String, String> headers,
    CancelToken? cancelToken,
  ) async {
    final token = CancelToken();
    cancelToken?.whenCancel.then((_) => token.cancel('cancelled'));
    return DownloadHttpClient.instance.getPlain(
      url,
      headers: headers,
      receiveTimeout: const Duration(seconds: 15),
      cancelToken: token,
      onReceiveProgress: (received, total) {
        if (received > _playlistMaxBytes) token.cancel('too large');
      },
    );
  }

  static Future<RangeFetchResult> _defaultFetchRange(
    String url,
    Map<String, String> headers,
    String? range,
    int maxBytes,
    CancelToken? cancelToken,
  ) async {
    final requestHeaders = Map<String, String>.of(headers);
    if (range != null) requestHeaders['range'] = range;
    final response = await DownloadHttpClient.instance.getStream(
      url,
      headers: requestHeaders,
      receiveTimeout: const Duration(seconds: 30),
      cancelToken: cancelToken,
    );

    int? totalLength;
    final contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(r'/(\d+)').firstMatch(contentRange);
      if (match != null) totalLength = int.tryParse(match.group(1)!);
    } else {
      totalLength = int.tryParse(
          response.headers.value(Headers.contentLengthHeader) ?? '');
    }

    final builder = BytesBuilder(copy: false);
    final body = response.data;
    if (body != null) {
      await for (final chunk in body.stream) {
        builder.add(chunk);
        if (builder.length >= maxBytes) break;
        if (cancelToken?.isCancelled ?? false) break;
      }
    }
    final bytes = builder.takeBytes();
    return RangeFetchResult(
      bytes: bytes.length > maxBytes
          ? Uint8List.sublistView(bytes, 0, maxBytes)
          : bytes,
      totalLength: totalLength,
    );
  }
}
