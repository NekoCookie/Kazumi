import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/quality/source_quality_models.dart';
import 'package:kazumi/services/quality/subtitle_probe_models.dart';
import 'package:kazumi/services/quality/subtitle_script_probe.dart';

const simplified = '欢迎观看这个故事，我们已经准备好了，请继续前进。';
const traditional = '歡迎觀看這個故事，我們已經準備好了，請繼續前進。';

SubtitleProbeInput input({String? master}) => SubtitleProbeInput(
      videoUrl: 'https://example.com/master.m3u8',
      headers: const {'Referer': 'https://example.com/'},
      container: 'hls',
      masterUrl: 'https://example.com/master.m3u8',
      masterPlaylist: master,
      variantUrl: 'https://example.com/video.m3u8',
    );

void main() {
  test('classifies script from actual Chinese text', () {
    expect(SubtitleScriptProbe.classifyText(simplified),
        SubtitleScript.simplified);
    expect(SubtitleScriptProbe.classifyText(traditional),
        SubtitleScript.traditional);
    expect(SubtitleScriptProbe.classifyText('$simplified\n$traditional'),
        SubtitleScript.mixed);
  });

  test('shared, repeated, short and Japanese characters do not prove script',
      () {
    for (final text in [
      '你好今天大家一起出去走走',
      '这这这这这这这这这这',
      '欢迎',
      '今日は物語の続きを見ましょう',
      '1080p English subtitles'
    ]) {
      expect(SubtitleScriptProbe.classifyText(text), SubtitleScript.unknown,
          reason: text);
    }
  });

  test('parses quoted commas and does not infer script from generic Chinese',
      () {
    final attrs = SubtitleScriptProbe.parseAttributes(
        'TYPE=SUBTITLES,LANGUAGE="zh",NAME="中文,默认",URI="sub.m3u8"');
    expect(attrs['NAME'], '中文,默认');
    expect(SubtitleScriptProbe.scriptFromHint(attrs), SubtitleScript.unknown);
    expect(SubtitleScriptProbe.scriptFromHint({'LANGUAGE': 'zh-Hant'}),
        SubtitleScript.traditional);
    expect(SubtitleScriptProbe.scriptFromHint({'LANGUAGE': 'zh-Hans-CN'}),
        SubtitleScript.simplified);
  });

  test('uses selected variant subtitle hints without OCR or extra downloads',
      () async {
    var ocr = false;
    final probe = SubtitleScriptProbe(
      fetchText: (_, __, ___) => throw StateError('not needed'),
      recognizeVideo: (_, __) async {
        ocr = true;
        return traditional;
      },
    );
    final result = await probe.probe(input(
        master: '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="zh-Hans",NAME="中文",URI="sub.m3u8"\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="other",LANGUAGE="zh-Hant",NAME="繁体",URI="other.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"\nvideo.m3u8\n'));
    expect(result.script, SubtitleScript.simplified);
    expect(ocr, isFalse);
  });

  test('two selectable tracks are distinct from mixed text in one image',
      () async {
    final result = await SubtitleScriptProbe().probe(input(
        master: '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="zh-Hans",NAME="简体"\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="zh-Hant",NAME="繁体"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"\nvideo.m3u8\n'));
    expect(result.script, SubtitleScript.selectable);
  });

  test('generic Chinese track reads actual subtitle text with original headers',
      () async {
    final requested = <String>[];
    final probe = SubtitleScriptProbe(
        fetchText: (url, headers, _) async {
          expect(headers['Referer'], 'https://example.com/');
          requested.add(url);
          return url.endsWith('sub.m3u8')
              ? '#EXTM3U\n#EXTINF:5,\nfirst.vtt\n#EXTINF:5,\nsecond.vtt\n'
              : 'WEBVTT\n\n00:00:01.000 --> 00:00:04.000\n$traditional\n';
        },
        recognizeVideo: (_, __) => throw StateError('not needed'));
    final result = await probe.probe(input(
        master: '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="zh",NAME="中文",URI="sub.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000,SUBTITLES="subs"\nvideo.m3u8\n'));
    expect(result.script, SubtitleScript.traditional);
    expect(requested,
        ['https://example.com/sub.m3u8', 'https://example.com/second.vtt']);
  });

  test('OCR failure is unknown and cancellation prevents queued OCR', () async {
    final probe = SubtitleScriptProbe(
        recognizeVideo: (_, __) => throw StateError('decode failed'));
    expect((await probe.probe(input())).script, SubtitleScript.unknown);
    final token = CancelToken()..cancel();
    var called = false;
    final cancelled = SubtitleScriptProbe(recognizeVideo: (_, __) async {
      called = true;
      return simplified;
    });
    expect((await cancelled.probe(input(), cancelToken: token)).script,
        SubtitleScript.unknown);
    expect(called, isFalse);
  });

  test('limits OCR concurrency and cancels a waiting probe', () async {
    final gate = Completer<void>();
    var calls = 0;
    final probe = SubtitleScriptProbe(recognizeVideo: (_, token) async {
      calls++;
      await gate.future;
      return simplified;
    });
    final first = probe.probe(input());
    final second = probe.probe(input());
    final token = CancelToken();
    final third = probe.probe(input(), cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(calls, 2);
    token.cancel();
    gate.complete();
    final results = await Future.wait([first, second, third]);
    expect(results.last.script, SubtitleScript.unknown);
    expect(calls, 2);
  });

  test('timeout cancels subtitle work and falls back to unknown', () async {
    final probe = SubtitleScriptProbe(
      timeout: const Duration(milliseconds: 15),
      recognizeVideo: (_, token) async {
        await token.whenCancel;
        throw StateError('cancelled');
      },
    );
    final result = await probe.probe(input());
    expect(result.script, SubtitleScript.unknown);
    expect(result.evidence, contains('超时'));
  });

  test('persists labels and reads old records without subtitle fields', () {
    const entry = SourceQualityEntry(pluginName: 'test', kbps: 1234);
    expect(SourceQualityEntry.fromJson(entry.toJson()).subtitleScript, isNull);
    final updated = entry.withSubtitle(const SubtitleProbeResult(
        SubtitleScript.traditional,
        evidence: 'sample'));
    final restored = SourceQualityEntry.fromJson(updated.toJson());
    expect(restored.subtitleScript, SubtitleScript.traditional);
    expect(restored.subtitleEvidence, 'sample');
    expect(restored.kbps, 1234);
  });
}
