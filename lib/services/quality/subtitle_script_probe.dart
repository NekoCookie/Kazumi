import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/quality/subtitle_characters.dart';
import 'package:kazumi/services/quality/subtitle_probe_models.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

typedef SubtitleTextFetcher = Future<String> Function(
    String url, Map<String, String> headers, CancelToken token);
typedef SubtitleBytesFetcher = Future<Uint8List> Function(
    String url, Map<String, String> headers, String? range, CancelToken token);
typedef SubtitleVideoRecognizer = Future<String> Function(
    SubtitleProbeInput input, CancelToken token);

/// Prefer explicit subtitle tracks, then recognize only the sampled video.
/// Script detection never relies on the site's name or the Chinese anime title.
class SubtitleScriptProbe {
  SubtitleScriptProbe({
    SubtitleTextFetcher? fetchText,
    SubtitleBytesFetcher? fetchBytes,
    SubtitleVideoRecognizer? recognizeVideo,
    this.ocrExecutable,
    this.ffmpegExecutable,
    this.timeout = const Duration(seconds: 45),
    int? maxParallel,
  })  : _fetchText = fetchText ?? _defaultFetchText,
        _fetchBytes = fetchBytes ?? _defaultFetchBytes,
        _recognizeVideo = recognizeVideo,
        maxParallel = maxParallel ?? defaultParallelism,
        assert(maxParallel == null || maxParallel > 0);

  final SubtitleTextFetcher _fetchText;
  final SubtitleBytesFetcher _fetchBytes;
  final SubtitleVideoRecognizer? _recognizeVideo;
  final String? ocrExecutable;
  final String? ffmpegExecutable;
  final Duration timeout;
  final int maxParallel;
  int _active = 0;

  // Scale Windows subtitle workers with the logical processor count,
  // keeping concurrency between two and eight.
  static int get defaultParallelism => Platform.isWindows
      ? (Platform.numberOfProcessors ~/ 2).clamp(2, 8).toInt()
      : 2;

  // Keep the original positions first, then cover other parts of the episode
  // only when they did not provide enough subtitle evidence.
  static const sampleFractions = [0.4, 0.25, 0.55, 0.7, 0.15, 0.85, 0.33, 0.62];

  static final _simplified = simplifiedEvidenceCharacters.runes.toSet();
  static final _traditional = traditionalEvidenceCharacters.runes.toSet();

  /// At least three different script-specific characters, with enough Chinese
  /// context. Shared characters and Japanese kana cannot prove Chinese script.
  static SubtitleScript classifyText(String text) {
    final simplified = <int>{};
    final traditional = <int>{};
    var hanCount = 0;
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      if (RegExp(r'[\u3040-\u30ff]').hasMatch(line)) continue;
      final han = line.runes.where((c) => c >= 0x4e00 && c < 0xa000).toList();
      if (han.length < 6) continue;
      hanCount += han.length;
      simplified.addAll(han.where(_simplified.contains));
      traditional.addAll(han.where(_traditional.contains));
    }
    if (hanCount < 8) return SubtitleScript.unknown;
    final s = simplified.length;
    final t = traditional.length;
    if (s >= 4 && t >= 4 && s / (s + t) >= 0.3 && t / (s + t) >= 0.3) {
      return SubtitleScript.mixed;
    }
    if (s >= 3 && s / (s + t) >= 0.8) return SubtitleScript.simplified;
    if (t >= 3 && t / (s + t) >= 0.8) return SubtitleScript.traditional;
    return SubtitleScript.unknown;
  }

  static Map<String, String> parseAttributes(String text) => {
        for (final match
            in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(text))
          match.group(1)!: match.group(2)!.replaceAll('"', ''),
      };

  static SubtitleScript scriptFromHint(Map<String, String> attributes) {
    final language = (attributes['LANGUAGE'] ?? '').toLowerCase();
    final name = (attributes['NAME'] ?? '').toLowerCase();
    if (RegExp(r'^zh[-_](hans|cn|sg)(?:[-_]|$)').hasMatch(language) ||
        RegExp(r'简体|簡體|simplified|\bchs\b').hasMatch(name)) {
      return SubtitleScript.simplified;
    }
    if (RegExp(r'^zh[-_](hant|tw|hk|mo)(?:[-_]|$)').hasMatch(language) ||
        RegExp(r'繁体|繁體|traditional|\bcht\b').hasMatch(name)) {
      return SubtitleScript.traditional;
    }
    return SubtitleScript.unknown;
  }

  Future<SubtitleProbeResult> probe(SubtitleProbeInput input,
      {CancelToken? cancelToken}) async {
    while (_active >= maxParallel) {
      if (cancelToken?.isCancelled ?? false) {
        return const SubtitleProbeResult(SubtitleScript.unknown);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (cancelToken?.isCancelled ?? false) {
      return const SubtitleProbeResult(SubtitleScript.unknown);
    }
    _active++;
    final token = CancelToken();
    var finished = false;
    cancelToken?.whenCancel.then((_) {
      if (!finished) token.cancel('probe cancelled');
    });
    final deadline = Timer(timeout, () => token.cancel('subtitle timeout'));
    try {
      final track = await _probeTracks(input, token);
      if (track != null) return track;
      if (input.container == 'mp4' &&
          Platform.isWindows &&
          _recognizeVideo == null) {
        final embedded = await _probeMp4Tracks(input, token);
        if (embedded != null) return embedded;
      }
      _check(token);
      if (_recognizeVideo == null) return await _recognizeSamples(input, token);
      final text = await _recognizeVideo(input, token);
      _check(token);
      final script = classifyText(text);
      return SubtitleProbeResult(script,
          evidence: script == SubtitleScript.unknown
              ? '抽样画面中没有足够的可辨识字幕'
              : '根据抽样画面中的字幕文字识别，仅代表本次抽样');
    } on _SubtitleProbeFailure catch (error) {
      return SubtitleProbeResult(SubtitleScript.unknown,
          evidence: token.isCancelled ? '字幕识别超时或已取消' : error.message);
    } on ProcessException {
      return const SubtitleProbeResult(SubtitleScript.unknown,
          evidence: '无法启动字幕探测组件，请检查 FFmpeg/FFprobe');
    } catch (_) {
      return SubtitleProbeResult(SubtitleScript.unknown,
          evidence: token.isCancelled ? '字幕识别超时或已取消' : '未能读取足够的字幕文字');
    } finally {
      finished = true;
      deadline.cancel();
      _active--;
    }
  }

  Future<SubtitleProbeResult?> _probeMp4Tracks(
      SubtitleProbeInput input, CancelToken token) async {
    final executableDir = path.dirname(Platform.resolvedExecutable);
    final bundled = path.join(executableDir, 'tools', 'ffprobe.exe');
    final ffprobe = File(bundled).existsSync() ? bundled : 'ffprobe';
    final headers =
        input.headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join();
    try {
      final result = await _run(
          ffprobe,
          [
            '-v',
            'error',
            '-rw_timeout',
            '3000000',
            if (headers.isNotEmpty) ...['-headers', headers],
            '-show_entries',
            'stream=index,codec_type:stream_tags=language,title',
            '-of',
            'json',
            input.videoUrl,
          ],
          token,
          const Duration(seconds: 4));
      if (result.$1 != 0) return null;
      final streams = (jsonDecode(result.$2) as Map)['streams'] as List? ?? [];
      final subtitles = streams
          .whereType<Map>()
          .where((s) => s['codec_type'] == 'subtitle')
          .toList();
      final hints = <SubtitleScript>{};
      for (final subtitle in subtitles) {
        final tags = subtitle['tags'] as Map? ?? {};
        final hint = scriptFromHint({
          'LANGUAGE': '${tags['language'] ?? ''}',
          'NAME': '${tags['title'] ?? ''}'
        });
        if (hint != SubtitleScript.unknown) hints.add(hint);
      }
      if (hints.isNotEmpty) {
        return SubtitleProbeResult(
            hints.length > 1 ? SubtitleScript.selectable : hints.single,
            evidence: '视频内独立字幕轨的标注');
      }
      for (final subtitle in subtitles.take(2)) {
        _check(token);
        final text = await _run(
            ffmpegExecutable ?? 'ffmpeg',
            [
              '-hide_banner',
              '-loglevel',
              'error',
              '-nostdin',
              '-rw_timeout',
              '3000000',
              if (headers.isNotEmpty) ...['-headers', headers],
              '-ss',
              ((input.durationSeconds ?? 0) * 0.4).toStringAsFixed(2),
              '-i',
              input.videoUrl,
              '-t',
              '20',
              '-map',
              '0:${subtitle['index']}',
              '-c:s',
              'webvtt',
              '-f',
              'webvtt',
              'pipe:1',
            ],
            token,
            const Duration(seconds: 4));
        if (text.$1 != 0) continue;
        final script =
            classifyText(text.$2.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), ''));
        if (script != SubtitleScript.unknown) {
          return SubtitleProbeResult(script, evidence: '根据视频内独立字幕轨的文字识别');
        }
      }
    } catch (_) {
      _check(token);
    }
    return null;
  }

  Future<SubtitleProbeResult?> _probeTracks(
      SubtitleProbeInput input, CancelToken token) async {
    final master = input.masterPlaylist;
    if (master == null || input.masterUrl == null) return null;
    final lines = master.split('\n').map((line) => line.trim()).toList();
    String? group;
    for (var i = 0; i + 1 < lines.length; i++) {
      if (lines[i].startsWith('#EXT-X-STREAM-INF:') &&
          M3u8Parser.resolveUrl(input.masterUrl!, lines[i + 1]) ==
              input.variantUrl) {
        group = parseAttributes(lines[i])['SUBTITLES'];
        break;
      }
    }
    // Ignore tracks belonging to other video variants.
    if (group == null || group == 'NONE') return null;
    final tracks = [
      for (final line in lines)
        if (line.startsWith('#EXT-X-MEDIA:')) parseAttributes(line),
    ]
        .where((attrs) =>
            attrs['TYPE'] == 'SUBTITLES' && attrs['GROUP-ID'] == group)
        .toList();
    final scripts = tracks.map(scriptFromHint).toSet()
      ..remove(SubtitleScript.unknown);
    if (scripts.isNotEmpty) {
      return SubtitleProbeResult(
        scripts.length > 1 ? SubtitleScript.selectable : scripts.single,
        evidence: '播放列表的独立字幕轨标注',
      );
    }
    for (final track in tracks.take(2)) {
      final uri = track['URI'];
      if (uri == null || uri.isEmpty) continue;
      try {
        final url = M3u8Parser.resolveUrl(input.masterUrl!, uri);
        var text = await _fetchText(url, input.headers, token);
        if (text.trimLeft().startsWith('#EXTM3U')) {
          final playlist = M3u8Parser.parseMediaPlaylist(text, url);
          final picked = playlist.segments;
          final parts = <String>[];
          if (picked.isNotEmpty) {
            final middle = picked.length ~/ 2;
            for (final segment in picked.skip(middle).take(2)) {
              parts.add(await _fetchText(segment.uri, input.headers, token));
            }
          }
          text = parts.join('\n');
        }
        final script =
            classifyText(text.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), ''));
        if (script != SubtitleScript.unknown) {
          return SubtitleProbeResult(script, evidence: '根据独立字幕文件的文字识别');
        }
      } catch (_) {
        _check(token);
      }
    }
    return null;
  }

  Future<SubtitleProbeResult> _recognizeSamples(
      SubtitleProbeInput input, CancelToken token) async {
    if (!Platform.isWindows) {
      throw const _SubtitleProbeFailure('当前平台不支持画面字幕识别');
    }
    final executableDir = path.dirname(Platform.resolvedExecutable);
    final ocr =
        ocrExecutable ?? path.join(executableDir, 'kazumi_subtitle_ocr.exe');
    if (!File(ocr).existsSync()) {
      throw const _SubtitleProbeFailure('缺少字幕识别组件');
    }
    final bundledFfmpeg = path.join(executableDir, 'tools', 'ffmpeg.exe');
    final ffmpeg = ffmpegExecutable ??
        (File(bundledFfmpeg).existsSync() ? bundledFfmpeg : 'ffmpeg');
    final directory = await Directory.systemTemp.createTemp('kazumi-subtitle-');
    final texts = <String, String>{};
    var frameCount = 0;
    var decodeFailures = 0;
    var readFailures = 0;
    final failures = <String>{};
    const modes = ['', '--color', '--white', '--gray'];

    List<String> imagesFor(String prefix) => directory
        .listSync()
        .whereType<File>()
        .where((f) =>
            (prefix == 'frame'
                ? RegExp(r'^frame\d+-').hasMatch(path.basename(f.path))
                : path.basename(f.path).startsWith('$prefix-')) &&
            f.path.endsWith('.png'))
        .map((f) => f.path)
        .toList()
      ..sort();

    Future<String?> recognize(List<String> images) async {
      frameCount += images.length;
      if (images.isEmpty) return null;
      for (final mode in modes) {
        final result = await _run(ocr, [if (mode.isNotEmpty) mode, ...images],
            token, const Duration(seconds: 8));
        if (result.$1 == 3) {
          throw const _SubtitleProbeFailure('未安装 Windows 中文 OCR 语言包');
        }
        if (result.$1 != 0) {
          throw const _SubtitleProbeFailure('字幕 OCR 组件执行失败');
        }
        // Accumulate evidence across positions, but keep different image
        // transformations separate so noise from one does not pollute another.
        texts[mode] = '${texts[mode] ?? ''}\n${result.$2}';
        if (classifyText(texts[mode]!) != SubtitleScript.unknown) {
          return texts[mode];
        }
      }
      return null;
    }

    (List<String>, List<String>) splitFrames(List<String> images) {
      final sparse = <String>[];
      final remaining = <String>[];
      for (var frame = 0; frame < images.length; frame++) {
        (frame % 4 == 0 ? sparse : remaining).add(images[frame]);
      }
      return (sparse, remaining);
    }

    Future<String?> recognizeWindow(String prefix) async {
      final (sparse, remaining) = splitFrames(imagesFor(prefix));
      return await recognize(sparse) ?? await recognize(remaining);
    }

    SubtitleProbeResult detected(String text) =>
        SubtitleProbeResult(classifyText(text),
            evidence: '根据抽样画面中的字幕文字识别，仅代表本次抽样（$frameCount 帧）');

    Future<void> extractSample(SubtitleVideoSample sample, int i,
        {String? prefix}) async {
      _check(token);
      if (sample.key != null && sample.key!.method != 'AES-128') {
        throw const _SubtitleProbeFailure('字幕抽样不支持该视频加密方式');
      }
      final bytes = sample.url == null
          ? sample.bytes
          : await _fetchBytes(sample.url!, input.headers, null, token);
      final segmentName =
          sample.initUrl == null ? 'sample$i.ts' : 'sample$i.m4s';
      await File(path.join(directory.path, segmentName)).writeAsBytes(bytes);
      final manifest = StringBuffer('#EXTM3U\n#EXT-X-VERSION:7\n')
        ..writeln(
            '#EXT-X-TARGETDURATION:${sample.duration.ceil().clamp(1, 3600)}')
        ..writeln('#EXT-X-MEDIA-SEQUENCE:${sample.sequence}');
      if (sample.initUrl != null) {
        final init = await _fetchBytes(
            sample.initUrl!, input.headers, sample.initRange, token);
        await File(path.join(directory.path, 'init$i.mp4')).writeAsBytes(init);
        manifest.writeln('#EXT-X-MAP:URI="init$i.mp4"');
      }
      final key = sample.key;
      if (key != null) {
        final keyBytes = await _fetchBytes(key.uri, input.headers, null, token);
        if (keyBytes.length != 16) {
          throw const _SubtitleProbeFailure('视频抽样密钥无效');
        }
        await File(path.join(directory.path, 'key$i.bin'))
            .writeAsBytes(keyBytes);
        manifest.writeln(
            '#EXT-X-KEY:METHOD=AES-128,URI="key$i.bin"${key.iv == null ? '' : ',IV=${key.iv}'}');
      }
      manifest
        ..writeln('#EXTINF:${sample.duration},')
        ..writeln(segmentName)
        ..writeln('#EXT-X-ENDLIST');
      final playlist = File(path.join(directory.path, 'sample$i.m3u8'));
      await playlist.writeAsString(manifest.toString());
      await _extractFrames(
          ffmpeg, playlist.path, directory.path, prefix ?? 'frame$i', token,
          local: true,
          seek: 0,
          sampleDuration: sample.duration,
          frameInterval: (sample.duration / 16).clamp(0.1, 0.5),
          maxFrames: 16);
    }

    try {
      if (input.container == 'hls') {
        final samples = input.samples.take(3).toList();
        for (var i = 0; i < samples.length; i++) {
          try {
            await extractSample(samples[i], i);
          } catch (error) {
            _check(token);
            if (error is ProcessException) rethrow;
            decodeFailures++;
            failures.add(_sampleFailureReason(error));
          }
        }
        // All retained samples share this prefix; assess them before making
        // any additional media requests.
        final sparse = <String>[];
        final remaining = <String>[];
        for (var j = 0; j < samples.length; j++) {
          final frames = splitFrames(imagesFor('frame$j'));
          sparse.addAll(frames.$1);
          remaining.addAll(frames.$2);
        }
        final text = await recognize(sparse) ?? await recognize(remaining);
        if (text != null) return detected(text);
        var i = samples.length;
        for (final sample in input.fallbackSamples.take(8)) {
          final prefix = 'extra$i';
          try {
            await extractSample(sample, i, prefix: prefix);
          } catch (error) {
            _check(token);
            if (error is ProcessException) rethrow;
            readFailures++;
            failures.add(_sampleFailureReason(error));
          }
          final text = await recognizeWindow(prefix);
          if (text != null) return detected(text);
          i++;
        }
      } else {
        final duration = input.durationSeconds ?? 0;
        final positions = duration > 0
            ? sampleFractions.map((f) => duration * f).toList()
            : [60.0, 180.0, 300.0, 420.0, 90.0, 600.0, 240.0, 540.0];
        for (var i = 0; i < positions.length; i++) {
          final prefix = 'frame$i';
          try {
            // Seek using range requests, read at most eight seconds.
            await _extractFrames(
                ffmpeg, input.videoUrl, directory.path, prefix, token,
                headers: input.headers,
                seek: positions[i],
                frameInterval: 0.5,
                maxFrames: 16);
          } catch (error) {
            _check(token);
            if (error is ProcessException) rethrow;
            decodeFailures++;
            failures.add(_sampleFailureReason(error));
          }
          // Decode the same bounded eight-second window once. Try four
          // distributed frames first, then the intervening frames only if
          // evidence is insufficient. Brief captions can fall entirely
          // between two-second samples; another seek is unnecessary.
          final text = await recognizeWindow(prefix);
          if (text != null) return detected(text);
        }
      }
      if (frameCount == 0) {
        throw _SubtitleProbeFailure(decodeFailures > 0 || readFailures > 0
            ? failures.join('；')
            : '未取得可用于识别的画面');
      }
      final hasText =
          texts.values.any((text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text));
      return SubtitleProbeResult(SubtitleScript.unknown,
          evidence: '${hasText ? '识别到文字，但不足以判断简繁' : '未读到可辨识字幕'}'
              '（抽样 $frameCount 帧）'
              '${failures.isNotEmpty ? '，部分抽样失败：${failures.join('；')}' : ''}');
    } finally {
      await directory.delete(recursive: true);
    }
  }

  static String _sampleFailureReason(Object error) {
    if (error is _SubtitleProbeFailure) return error.message;
    if (error is NetworkException) {
      return switch (error.type) {
        NetworkExceptionType.connectionTimeout ||
        NetworkExceptionType.receiveTimeout ||
        NetworkExceptionType.sendTimeout =>
          '字幕抽样网络读取超时',
        NetworkExceptionType.badResponse =>
          '字幕抽样服务器返回 HTTP ${error.statusCode ?? '错误'}',
        NetworkExceptionType.badCertificate => '字幕抽样连接证书异常',
        _ => '字幕抽样网络读取失败',
      };
    }
    if (error is FormatException) return '字幕抽样资源过大或无效';
    return '视频抽样读取或解码失败';
  }

  Future<void> _extractFrames(String ffmpeg, String input, String directory,
      String prefix, CancelToken token,
      {bool local = false,
      Map<String, String> headers = const {},
      double seek = 0,
      double? sampleDuration,
      double? frameInterval,
      int maxFrames = 4}) async {
    // At least one frame even in a sub-second HLS segment. Four frames span
    // the segment; long remote samples retain the normal two-second interval.
    final interval = frameInterval ??
        (local && sampleDuration != null
            ? (sampleDuration / 4).clamp(0.1, 2.0)
            : 2.0);
    final result = await _run(
        ffmpeg,
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-nostdin',
          '-y',
          if (local) ...[
            '-protocol_whitelist',
            'file,crypto,data',
            '-allowed_extensions',
            'ALL'
          ],
          if (!local) ...[
            '-rw_timeout',
            '4000000',
            if (headers.isNotEmpty) ...[
              '-headers',
              headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()
            ],
          ],
          '-ss',
          seek.toStringAsFixed(2),
          '-i',
          input,
          '-t',
          '8',
          '-vf',
          "fps=1/$interval:start_time=0,crop=iw:ih*0.32:0:ih*0.68,scale=w='min(1600,iw)':h=-1",
          '-frames:v',
          '$maxFrames',
          '-an',
          '-threads',
          '1',
          path.join(directory, '$prefix-%02d.png'),
        ],
        token,
        Duration(seconds: local ? 5 : 10));
    if (result.$1 != 0) {
      throw const _SubtitleProbeFailure('视频抽样解码失败');
    }
  }

  static Future<(int, String)> _run(String executable, List<String> arguments,
      CancelToken token, Duration timeout) async {
    _check(token);
    final process = await Process.start(executable, arguments);
    var finished = false;
    var timedOut = false;
    void kill() {
      if (!finished) process.kill();
    }

    token.whenCancel.then((_) => kill());
    final timer = Timer(timeout, () {
      timedOut = true;
      kill();
    });
    try {
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.drain<void>();
      final code = await process.exitCode;
      final text = await stdout;
      await stderr;
      _check(token);
      if (timedOut) throw const _SubtitleProbeFailure('字幕抽样处理超时');
      return (code, text);
    } finally {
      finished = true;
      timer.cancel();
    }
  }

  static void _check(CancelToken token) {
    if (token.isCancelled) {
      throw const FormatException('Subtitle probe cancelled');
    }
  }

  static Future<String> _defaultFetchText(
          String url, Map<String, String> headers, CancelToken token) =>
      DownloadHttpClient.instance.getPlain(url,
          headers: headers,
          cancelToken: token,
          receiveTimeout: const Duration(seconds: 4),
          onReceiveProgress: (received, _) {
        if (received > 1024 * 1024) token.cancel('subtitle resource too large');
      });

  static Future<Uint8List> _defaultFetchBytes(String url,
      Map<String, String> headers, String? range, CancelToken token) async {
    final response = await DownloadHttpClient.instance.getStream(url,
        headers: {...headers, if (range != null) 'range': range},
        cancelToken: token,
        receiveTimeout: const Duration(seconds: 4));
    final bytes = BytesBuilder(copy: false);
    if (response.data != null) {
      await for (final chunk in response.data!.stream) {
        _check(token);
        bytes.add(chunk);
        if (bytes.length > 6 * 1024 * 1024) {
          throw const FormatException('Subtitle auxiliary resource too large');
        }
      }
    }
    return bytes.takeBytes();
  }
}

class _SubtitleProbeFailure implements Exception {
  const _SubtitleProbeFailure(this.message);
  final String message;
}
