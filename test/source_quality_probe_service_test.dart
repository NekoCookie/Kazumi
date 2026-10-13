import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/quality/media_bitrate_meter.dart';
import 'package:kazumi/services/quality/source_quality_probe_service.dart';
import 'package:kazumi/services/video_source/video_source_resolver_pool.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

void main() {
  final logLevel = Logger.level;
  setUp(() => Logger.level = Level.off);
  tearDown(() => Logger.level = logLevel);

  List<SourceQualityProbeTarget> targets() => [
        for (var i = 0; i < 8; i++)
          SourceQualityProbeTarget(
            plugin: _Plugin('site-$i'),
            item: SearchItem(name: 'episode', src: 'detail'),
          ),
      ];

  test(
      'all eight sources resolve concurrently; one failure does not block others',
      () async {
    final batch = _Batch(8)..failures.add('site-2');
    final meter = _Meter();
    final service = SourceQualityProbeService(
        bangumiId: 1, resolverPool: batch.pool, meter: meter);
    addTearDown(service.dispose);
    final items = targets();
    final run = service.run(items);
    await batch.allStarted.future.timeout(const Duration(seconds: 2));
    expect(batch.started.length, 8);
    expect(
        service.states.value
            .every((s) => s.phase == SourceQualityProbePhase.resolvingVideo),
        isTrue);
    batch.release.complete();
    final rank = (await run)!;
    expect(rank.measured.length, 7);
    expect(rank.byPlugin['site-2']!.error, '没有嗅探到视频地址');
    expect(meter.measured.length, 7);
    expect(service.states.value.every((s) => s.isFinished), isTrue);

    batch.failures.clear();
    final retried = (await service.retry(items[2]))!;
    expect(retried.measured.length, 8);
    for (final entry in rank.entries.where((e) => e.pluginName != 'site-2')) {
      expect(retried.byPlugin[entry.pluginName], same(entry));
    }
  });

  test(
      'cancelling an eight-source batch stops every resolver before measurement',
      () async {
    final batch = _Batch(8);
    final meter = _Meter();
    final service = SourceQualityProbeService(
        bangumiId: 1, resolverPool: batch.pool, meter: meter);
    addTearDown(service.dispose);
    final run = service.run(targets());
    await batch.allStarted.future.timeout(const Duration(seconds: 2));
    service.cancel();
    expect(await run.timeout(const Duration(seconds: 2)), isNull);
    expect(batch.resolvers.every((r) => r.cancelled.isCompleted), isTrue);
    expect(meter.measured, isEmpty);
    expect(service.isRunning, isFalse);
  });

  test('the default download resolver pool still limits capacity to five',
      () async {
    final batch = _Batch(0);
    final pool = VideoSourceResolverPool(createService: batch.createResolver);
    addTearDown(pool.dispose);
    pool.resize(8);
    final leases = [for (var i = 0; i < 5; i++) pool.tryAcquire('$i')!];
    expect(pool.tryAcquire('sixth'), isNull);
    pool.release(leases.first);
    expect(pool.tryAcquire('sixth'), isNotNull);
  });
}

class _Batch {
  _Batch(this.expected);
  final int expected;
  final started = <String>[];
  final failures = <String>{};
  final resolvers = <_Resolver>[];
  final allStarted = Completer<void>();
  final release = Completer<void>();
  late final pool =
      VideoSourceResolverPool(workerLimit: null, createService: createResolver);

  _Resolver createResolver() {
    final resolver = _Resolver(this);
    resolvers.add(resolver);
    return resolver;
  }
}

class _Resolver implements IVideoSourceService {
  _Resolver(this.batch);
  final _Batch batch;
  final cancelled = Completer<void>();

  @override
  Future<VideoSource> resolve(String episodeUrl,
      {required bool useLegacyParser,
      int offset = 0,
      Duration timeout = const Duration(seconds: 30)}) async {
    final name = Uri.parse(episodeUrl).host;
    batch.started.add(name);
    if (batch.started.length == batch.expected &&
        !batch.allStarted.isCompleted) {
      batch.allStarted.complete();
    }
    await Future.any([batch.release.future, cancelled.future]);
    if (cancelled.isCompleted) throw const VideoSourceCancelledException();
    if (batch.failures.contains(name)) {
      throw const VideoSourceNotFoundException();
    }
    return VideoSource(
        url: 'https://$name/video.mp4',
        offset: 0,
        type: VideoSourceType.online);
  }

  @override
  void cancel() {
    if (!cancelled.isCompleted) cancelled.complete();
  }

  @override
  Future<void> dispose() async => cancel();
}

class _Plugin implements Plugin {
  _Plugin(this.name);
  @override
  final String name;
  @override
  bool get useLegacyParser => false;
  @override
  Future<List<Road>> queryChapterRoads(String source,
          {CancelToken? cancelToken}) async =>
      [
        Road(name: 'road', data: ['episode'], identifier: ['1'])
      ];
  @override
  String buildFullUrl(String item) => 'https://$name/$item';
  @override
  Map<String, String> buildHttpHeaders() => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Meter extends MediaBitrateMeter {
  final measured = <String>[];
  @override
  Future<MediaBitrateResult> measure(String url, Map<String, String> headers,
      {CancelToken? cancelToken}) async {
    measured.add(url);
    return const MediaBitrateResult(kbps: 2000, container: 'mp4');
  }
}
