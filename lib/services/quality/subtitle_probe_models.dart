import 'dart:typed_data';

import 'package:kazumi/utils/m3u8_parser.dart';

enum SubtitleScript {
  pending,
  simplified,
  traditional,
  mixed,
  selectable,
  unknown;

  String get label => switch (this) {
        pending => '字幕识别中',
        simplified => '简体字幕',
        traditional => '繁体字幕',
        mixed => '简繁混合',
        selectable => '简繁可选',
        unknown => '字幕未识别',
      };
}

class SubtitleProbeResult {
  const SubtitleProbeResult(this.script, {this.evidence = ''});

  final SubtitleScript script;
  final String evidence;
}

/// A retained bitrate sample or a location to fetch for fallback recognition.
class SubtitleVideoSample {
  const SubtitleVideoSample({
    required this.bytes,
    required this.duration,
    required this.sequence,
    this.key,
    this.initUrl,
    this.initRange,
    this.url,
  });

  final Uint8List bytes;
  final double duration;
  final int sequence;
  final M3u8Key? key;
  final String? initUrl;
  final String? initRange;

  /// Only fallback samples need a media request; ordinary samples reuse bytes.
  final String? url;
}

class SubtitleProbeInput {
  const SubtitleProbeInput({
    required this.videoUrl,
    required this.headers,
    required this.container,
    this.masterUrl,
    this.masterPlaylist,
    this.variantUrl,
    this.samples = const [],
    this.fallbackSamples = const [],
    this.durationSeconds,
  });

  final String videoUrl;
  final Map<String, String> headers;
  final String container;
  final String? masterUrl;
  final String? masterPlaylist;
  final String? variantUrl;
  final List<SubtitleVideoSample> samples;
  final List<SubtitleVideoSample> fallbackSamples;
  final double? durationSeconds;
}
