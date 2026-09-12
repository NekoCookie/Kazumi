import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/quality/media_bitrate_meter.dart';
import 'package:kazumi/services/quality/mp4_header_probe.dart';
import 'package:kazumi/services/quality/source_quality_models.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

Uint8List _box(String type, List<int> body) {
  final size = 8 + body.length;
  final bytes = BytesBuilder()
    ..add([size >> 24 & 0xff, size >> 16 & 0xff, size >> 8 & 0xff, size & 0xff])
    ..add(type.codeUnits)
    ..add(body);
  return bytes.takeBytes();
}

List<int> _u32(int value) =>
    [value >> 24 & 0xff, value >> 16 & 0xff, value >> 8 & 0xff, value & 0xff];

/// 构造一个只含 mvhd 和 tkhd 的 moov，时长 [seconds]，画面 [width]x[height]。
Uint8List _fakeMoov({
  required double seconds,
  required int width,
  required int height,
}) {
  const timescale = 1000;
  final mvhdBody = <int>[
    0, 0, 0, 0, // version + flags
    ..._u32(0), ..._u32(0), // ctime, mtime
    ..._u32(timescale),
    ..._u32((seconds * timescale).round()),
  ];
  final tkhdBody = <int>[
    0, 0, 0, 0,
    ..._u32(0), ..._u32(0), ..._u32(1), ..._u32(0), ..._u32(0),
    ..._u32(0), ..._u32(0), // reserved 8
    0, 0, 0, 0, 0, 0, 0, 0, // layer, alt, volume, reserved
    ...List<int>.filled(36, 0), // matrix
    ..._u32(width << 16),
    ..._u32(height << 16),
  ];
  final trak = _box('trak', _box('tkhd', tkhdBody));
  final moov = _box('moov', [..._box('mvhd', mvhdBody), ...trak]);
  return Uint8List.fromList([..._box('ftyp', 'isom'.codeUnits), ...moov]);
}

void main() {
  group('Mp4HeaderProbe', () {
    test('reads duration and resolution from a synthetic moov', () {
      final info = Mp4HeaderProbe.parse(
        _fakeMoov(seconds: 1234.5, width: 1920, height: 804),
      );
      expect(info.durationSeconds, closeTo(1234.5, 0.01));
      expect(info.width, 1920);
      expect(info.height, 804);
    });

    test('locateMoovOffset jumps over a huge mdat to the moov start', () {
      final ftyp = _box('ftyp', 'isom'.codeUnits);
      // mdat 头声称 50,000,008 字节，内容不在 head 里。
      final mdatHeader = [..._u32(50000008), ...'mdat'.codeUnits];
      final head = Uint8List.fromList([...ftyp, ...mdatHeader]);
      expect(
        Mp4HeaderProbe.locateMoovOffset(head),
        ftyp.length + 50000008,
      );
    });

    test('locateMoovOffset returns moov offset when it sits in the head', () {
      final head = _fakeMoov(seconds: 10, width: 640, height: 360);
      expect(Mp4HeaderProbe.locateMoovOffset(head), 8 + 4); // ftyp 占 12 字节
    });

    test('returns empty info for random bytes', () {
      final info = Mp4HeaderProbe.parse(Uint8List.fromList(List.filled(64, 7)));
      expect(info.isEmpty, isTrue);
    });
  });

  group('MediaBitrateMeter helpers', () {
    test('computeKbps', () {
      // 3 MB over 10 s = 2400 kbps
      expect(MediaBitrateMeter.computeKbps(3 * 1000 * 1000, 10), 2400);
      expect(MediaBitrateMeter.computeKbps(100, 0), 0);
    });

    test('parseResolution', () {
      expect(MediaBitrateMeter.parseResolution('1920x804'), (1920, 804));
      expect(MediaBitrateMeter.parseResolution('bad'), isNull);
      expect(MediaBitrateMeter.parseResolution(null), isNull);
    });

    test('pickSampleSegments stays in the middle of the list', () {
      final segments = List.generate(
        100,
        (i) => M3u8Segment(duration: 5, uri: 's$i', discontinuityGroup: 0),
      );
      final picked = MediaBitrateMeter.pickSampleSegments(segments, 3);
      expect(picked.length, 3);
      final indexes = picked.map((s) => int.parse(s.uri.substring(1))).toList();
      expect(indexes.first, greaterThanOrEqualTo(30));
      expect(indexes.last, lessThan(70));
      expect(indexes, orderedEquals(indexes.toSet().toList()));
    });

    test('pickSampleSegments returns everything for short lists', () {
      final segments = List.generate(
        2,
        (i) => M3u8Segment(duration: 5, uri: 's$i', discontinuityGroup: 0),
      );
      expect(MediaBitrateMeter.pickSampleSegments(segments, 3).length, 2);
    });
  });

  group('MediaBitrateMeter.measure', () {
    test('hls: master → media → sampled segments', () async {
      const master = '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1920x804\n'
          'media.m3u8\n';
      final media = StringBuffer('#EXTM3U\n#EXT-X-TARGETDURATION:5\n');
      for (var i = 0; i < 10; i++) {
        media.writeln('#EXTINF:4.0,');
        media.writeln('seg$i.ts');
      }
      media.writeln('#EXT-X-ENDLIST');
      final fetchedSegments = <String>[];
      final meter = MediaBitrateMeter(
        sampleSegments: 2,
        fetchText: (url, headers, token) async =>
            url.endsWith('master.m3u8') ? master : media.toString(),
        fetchRange: (url, headers, range, maxBytes, token) async {
          fetchedSegments.add(url);
          // 每个分片 2,000,000 字节，4 秒 → 4000 kbps
          return RangeFetchResult(
            bytes: Uint8List(2000000),
            totalLength: 2000000,
          );
        },
      );
      final result = await meter.measure('https://cdn/x/master.m3u8', {});
      expect(result.container, 'hls');
      expect(result.width, 1920);
      expect(result.height, 804);
      expect(result.kbps, 4000);
      expect(fetchedSegments.length, 2);
      expect(fetchedSegments.first, startsWith('https://cdn/x/seg'));
    });

    test('mp4: total size over duration', () async {
      final header = _fakeMoov(seconds: 100, width: 1280, height: 536);
      final meter = MediaBitrateMeter(
        fetchText: (url, headers, token) async => 'not a playlist',
        fetchRange: (url, headers, range, maxBytes, token) async =>
            RangeFetchResult(bytes: header, totalLength: 25 * 1000 * 1000),
      );
      final result = await meter.measure('https://cdn/v/1.mp4', {});
      expect(result.container, 'mp4');
      expect(result.width, 1280);
      expect(result.height, 536);
      // 25 MB * 8 / 100 s = 2000 kbps
      expect(result.kbps, 2000);
    });

    test('mp4 with moov after a huge mdat is located by box walk', () async {
      final ftyp = _box('ftyp', 'isom'.codeUnits);
      final mdatSize = 50000008;
      final moovFile = _fakeMoov(seconds: 100, width: 1920, height: 1080);
      final moov = Uint8List.sublistView(moovFile, ftyp.length); // 去掉 ftyp
      final moovOffset = ftyp.length + mdatSize;
      final total = moovOffset + moov.length;
      final ranges = <String?>[];
      final meter = MediaBitrateMeter(
        fetchText: (url, headers, token) async => '',
        fetchRange: (url, headers, range, maxBytes, token) async {
          ranges.add(range);
          if (range == 'bytes=0-4095' || range == 'bytes=0-1048575') {
            return RangeFetchResult(
              bytes: Uint8List.fromList(
                  [...ftyp, ..._u32(mdatSize), ...'mdat'.codeUnits]),
              totalLength: total,
            );
          }
          if (range != null && range.startsWith('bytes=$moovOffset-')) {
            return RangeFetchResult(bytes: moov, totalLength: total);
          }
          return RangeFetchResult(bytes: Uint8List(0), totalLength: total);
        },
      );
      final result = await meter.measure('https://cdn/v/big.mp4', {});
      expect(ranges, contains(startsWith('bytes=$moovOffset-')));
      expect(result.container, 'mp4');
      expect(result.height, 1080);
      expect(result.kbps, MediaBitrateMeter.computeKbps(total, 100));
    });

    test('mp4 without extension is sniffed by prefix, never fetched as text',
        () async {
      final header = _fakeMoov(seconds: 50, width: 640, height: 360);
      var textCalls = 0;
      final ranges = <String?>[];
      final meter = MediaBitrateMeter(
        fetchText: (url, headers, token) async {
          textCalls++;
          return '';
        },
        fetchRange: (url, headers, range, maxBytes, token) async {
          ranges.add(range);
          return RangeFetchResult(
            bytes: Uint8List.sublistView(
                header, 0, maxBytes.clamp(0, header.length)),
            totalLength: 5 * 1000 * 1000,
          );
        },
      );
      final result = await meter.measure('https://cdn/video/tos/abc/', {});
      expect(textCalls, 0);
      expect(ranges.first, 'bytes=0-4095');
      expect(result.container, 'mp4');
      expect(result.kbps, 800);
    });

    test('playlist without extension is detected by #EXTM3U prefix', () async {
      const media = '#EXTM3U\n#EXTINF:4.0,\na.ts\n#EXTINF:4.0,\nb.ts\n';
      final meter = MediaBitrateMeter(
        sampleSegments: 2,
        fetchText: (url, headers, token) async => media,
        fetchRange: (url, headers, range, maxBytes, token) async {
          if (range != null) {
            return RangeFetchResult(
              bytes: Uint8List.fromList(media.codeUnits),
              totalLength: media.length,
            );
          }
          return RangeFetchResult(bytes: Uint8List(1000000), totalLength: null);
        },
      );
      final result = await meter.measure('https://cdn/play/xyz', {});
      expect(result.container, 'hls');
      expect(result.kbps, 2000);
    });

    test('isPlaylistPrefix tolerates BOM and whitespace', () {
      expect(
        MediaBitrateMeter.isPlaylistPrefix(
            Uint8List.fromList([0xEF, 0xBB, 0xBF, ...'\n#EXTM3U'.codeUnits])),
        isTrue,
      );
      expect(
        MediaBitrateMeter.isPlaylistPrefix(
            Uint8List.fromList('ftyp'.codeUnits)),
        isFalse,
      );
    });
  });

  group('SourceQualityRank', () {
    test('sortPluginNames puts measured first by kbps, rest keep order', () {
      final rank = SourceQualityRank(
        bangumiId: 1,
        episodeNumber: 1,
        probedAt: DateTime(2026, 9, 12),
        entries: const [
          SourceQualityEntry(pluginName: 'a', kbps: 1000),
          SourceQualityEntry(pluginName: 'b', error: 'x'),
          SourceQualityEntry(pluginName: 'c', kbps: 3000),
        ],
      );
      expect(rank.sortPluginNames(['a', 'b', 'c', 'd']), ['c', 'a', 'b', 'd']);
      // 探测失败的 b 要排在没参与探测的 x、d 前面，即使配置顺序在它们之后。
      expect(rank.sortPluginNames(['x', 'd', 'b', 'a']), ['a', 'b', 'x', 'd']);
      expect(rank.rankOf('c'), 1);
      expect(rank.rankOf('a'), 2);
      expect(rank.rankOf('b'), isNull);
    });

    test('json round trip', () {
      final rank = SourceQualityRank(
        bangumiId: 42,
        episodeNumber: 3,
        probedAt: DateTime.utc(2026, 9, 12, 1, 2, 3),
        entries: const [
          SourceQualityEntry(
            pluginName: 'p',
            kbps: 1140,
            width: 1920,
            height: 804,
            downloadMbps: 2.5,
            container: 'hls',
            videoHost: 'cdn.example',
          ),
        ],
      );
      final restored = SourceQualityRank.fromJson(rank.toJson());
      expect(restored.bangumiId, 42);
      expect(restored.episodeNumber, 3);
      expect(restored.probedAt, rank.probedAt);
      expect(restored.entries.single.qualityLabel, '1140 kbps · 1920x804');
    });
  });
}
