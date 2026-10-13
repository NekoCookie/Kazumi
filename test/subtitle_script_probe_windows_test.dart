import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:kazumi/services/quality/subtitle_probe_models.dart';
import 'package:kazumi/services/quality/subtitle_script_probe.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

/// Opt in after building the OCR helper and running the fixture generator:
/// KAZUMI_SUBTITLE_OCR_EXE=... flutter test test/subtitle_script_probe_windows_test.dart
void main() {
  final executable = Platform.environment['KAZUMI_SUBTITLE_OCR_EXE'];
  final enabled = Platform.isWindows && executable != null;
  final folder = Directory('build/subtitle-verification').absolute.path;
  for (final (name, expected) in [
    ('simplified', SubtitleScript.simplified),
    ('traditional', SubtitleScript.traditional),
    ('blank', SubtitleScript.unknown),
    ('encrypted', SubtitleScript.traditional),
    ('styled-simplified', SubtitleScript.simplified),
    ('styled-traditional', SubtitleScript.traditional),
  ]) {
    test('real FFmpeg decode and Windows OCR: $name', () async {
      var keyFetches = 0;
      final probe = SubtitleScriptProbe(
        ocrExecutable: executable,
        fetchBytes: (url, headers, range, token) async {
          keyFetches++;
          expect(url, 'https://example.com/key');
          return File('$folder/key.bin').readAsBytes();
        },
      );
      final watch = Stopwatch()..start();
      final result = await probe.probe(SubtitleProbeInput(
        videoUrl: 'https://example.com/sample.m3u8',
        headers: const {},
        container: 'hls',
        samples: [
          SubtitleVideoSample(
            bytes: await File('$folder/$name.ts').readAsBytes(),
            duration: name.startsWith('styled-') ? 0.8 : 6,
            sequence: 37,
            key: name == 'encrypted'
                ? M3u8Key(method: 'AES-128', uri: 'https://example.com/key')
                : null,
          ),
        ],
      ));
      stdout.writeln('$name sample: ${watch.elapsedMilliseconds} ms');
      expect(result.script, expected,
          reason: '${result.evidence}; ${watch.elapsed}');
      expect(keyFetches, name == 'encrypted' ? 1 : 0);
    }, skip: !enabled);
  }

  test(
      'real fragmented MP4 sample reuses downloaded media and fetches only init',
      () async {
    var fetches = 0;
    final probe = SubtitleScriptProbe(
      ocrExecutable: executable,
      fetchBytes: (url, headers, range, token) async {
        fetches++;
        expect(url, 'https://example.com/init.mp4');
        return File('$folder/init.mp4').readAsBytes();
      },
    );
    final result = await probe.probe(SubtitleProbeInput(
      videoUrl: 'https://example.com/video.m3u8',
      headers: const {},
      container: 'hls',
      samples: [
        SubtitleVideoSample(
          bytes: await File('$folder/fragment0.m4s').readAsBytes(),
          duration: 6,
          sequence: 0,
          initUrl: 'https://example.com/init.mp4',
        )
      ],
    ));
    expect(result.script, SubtitleScript.traditional, reason: result.evidence);
    expect(fetches, 1);
  }, skip: !enabled);

  test('real MP4 soft subtitles are read without being burned into the frame',
      () async {
    final probe = SubtitleScriptProbe(ocrExecutable: executable);
    final result = await probe.probe(SubtitleProbeInput(
      videoUrl: '$folder/soft-subtitle.mp4',
      headers: const {},
      container: 'mp4',
      durationSeconds: 6,
    ));
    expect(result.script, SubtitleScript.simplified, reason: result.evidence);
    expect(result.evidence, contains('独立字幕轨'));
  }, skip: !enabled);

  for (final recognizedInitially in [false, true]) {
    test(
        'HLS fallback downloads only on insufficient evidence: $recognizedInitially',
        () async {
      var fetches = 0;
      final probe = SubtitleScriptProbe(
        ocrExecutable: executable,
        fetchBytes: (url, headers, range, token) async {
          fetches++;
          expect(url, 'https://example.com/fallback.ts');
          expect(headers['Referer'], 'https://example.com/');
          return File('$folder/styled-simplified.ts').readAsBytes();
        },
      );
      final result = await probe.probe(SubtitleProbeInput(
        videoUrl: 'https://example.com/video.m3u8',
        headers: const {'Referer': 'https://example.com/'},
        container: 'hls',
        samples: [
          SubtitleVideoSample(
            bytes: await File(
                    '$folder/${recognizedInitially ? 'simplified' : 'blank'}.ts')
                .readAsBytes(),
            duration: 6,
            sequence: 0,
          )
        ],
        fallbackSamples: [
          SubtitleVideoSample(
            bytes: Uint8List(0),
            url: 'https://example.com/fallback.ts',
            duration: 0.8,
            sequence: 1,
          )
        ],
      ));
      expect(result.script, SubtitleScript.simplified, reason: result.evidence);
      expect(fetches, recognizedInitially ? 0 : 1);
    }, skip: !enabled);
  }

  test('MP4 falls back to another position when the first is blank', () async {
    final result = await SubtitleScriptProbe(ocrExecutable: executable).probe(
        SubtitleProbeInput(
            videoUrl: '$folder/fallback.mp4',
            headers: const {},
            container: 'mp4',
            durationSeconds: 20));
    expect(result.script, SubtitleScript.simplified, reason: result.evidence);
  }, skip: !enabled);

  test('color separation preserves simplified and traditional glyphs',
      () async {
    for (final (name, script) in [
      ('styled-simplified', SubtitleScript.simplified),
      ('styled-traditional', SubtitleScript.traditional),
    ]) {
      final result = await Process.run(
          executable!, ['--color', path.normalize('$folder/$name-video.png')],
          stdoutEncoding: utf8, stderrEncoding: utf8);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(SubtitleScriptProbe.classifyText(result.stdout as String), script);
    }
  }, skip: !enabled);

  test('brief MP4 caption between sparse frames is found in the same window',
      () async {
    final result = await SubtitleScriptProbe(ocrExecutable: executable).probe(
        SubtitleProbeInput(
            videoUrl: '$folder/brief-subtitle.mp4',
            headers: const {},
            container: 'mp4',
            durationSeconds: 20));
    expect(result.script, SubtitleScript.simplified, reason: result.evidence);
    expect(result.evidence, contains('16 帧'));
  }, skip: !enabled);

  test('MP4 expands beyond all three blank original windows', () async {
    final result = await SubtitleScriptProbe(ocrExecutable: executable).probe(
        SubtitleProbeInput(
            videoUrl: '$folder/expanded-subtitle.mp4',
            headers: const {},
            container: 'mp4',
            durationSeconds: 80));
    expect(result.script, SubtitleScript.simplified, reason: result.evidence);
    expect(result.evidence, contains('52 帧'));
  }, skip: !enabled);

  test('HLS expands after two blank fallback segments and stops on evidence',
      () async {
    final fetched = <int>[];
    final result = await SubtitleScriptProbe(
      ocrExecutable: executable,
      fetchBytes: (url, headers, range, token) async {
        final index = int.parse(Uri.parse(url).pathSegments.last);
        fetched.add(index);
        return File('$folder/${index == 2 ? 'simplified' : 'blank'}.ts')
            .readAsBytes();
      },
    ).probe(SubtitleProbeInput(
      videoUrl: 'https://example.com/video.m3u8',
      headers: const {},
      container: 'hls',
      samples: [
        SubtitleVideoSample(
            bytes: await File('$folder/blank.ts').readAsBytes(),
            duration: 6,
            sequence: 0),
      ],
      fallbackSamples: [
        for (var i = 0; i < 4; i++)
          SubtitleVideoSample(
              bytes: Uint8List(0),
              duration: 6,
              sequence: i + 1,
              url: 'https://example.com/$i'),
      ],
    ));
    expect(result.script, SubtitleScript.simplified, reason: result.evidence);
    expect(fetched, [0, 1, 2]);
  }, skip: !enabled);

  test('corrupt media and unreadable text report different reasons', () async {
    final probe = SubtitleScriptProbe(ocrExecutable: executable);
    Future<SubtitleProbeResult> check(Uint8List bytes) =>
        probe.probe(SubtitleProbeInput(
            videoUrl: 'https://example.com/video.m3u8',
            headers: const {},
            container: 'hls',
            samples: [
              SubtitleVideoSample(bytes: bytes, duration: 0.8, sequence: 0),
            ]));
    final blank = await check(await File('$folder/blank.ts').readAsBytes());
    expect(blank.script, SubtitleScript.unknown);
    expect(blank.evidence, contains('未读到'));
    final corrupt = await check(Uint8List.fromList([1, 2, 3, 4]));
    expect(corrupt.script, SubtitleScript.unknown);
    expect(corrupt.evidence, contains('解码失败'));
  }, skip: !enabled);
}
