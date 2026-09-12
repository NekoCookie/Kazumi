import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/quality/media_bitrate_meter.dart';
import 'package:kazumi/services/quality/source_quality_models.dart';
import 'package:kazumi/services/video_source/video_source_resolver_pool.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

/// 一个待探测的来源：规则加上它在这部番剧下的搜索结果。
class SourceQualityProbeTarget {
  const SourceQualityProbeTarget({required this.plugin, required this.item});

  final Plugin plugin;
  final SearchItem item;
}

enum SourceQualityProbePhase {
  pending,
  loadingRoads,
  resolvingVideo,
  measuring,
  done,
  failed,
}

/// 单个来源的探测进度，供界面刷新。
class SourceQualityProbeState {
  const SourceQualityProbeState({
    required this.pluginName,
    required this.phase,
    this.entry,
  });

  final String pluginName;
  final SourceQualityProbePhase phase;

  /// 结束后（成功或失败）才有值。
  final SourceQualityEntry? entry;

  bool get isFinished =>
      phase == SourceQualityProbePhase.done ||
      phase == SourceQualityProbePhase.failed;

  String get phaseLabel => switch (phase) {
        SourceQualityProbePhase.pending => '等待中',
        SourceQualityProbePhase.loadingRoads => '获取播放列表',
        SourceQualityProbePhase.resolvingVideo => '解析视频地址',
        SourceQualityProbePhase.measuring => '测量码率',
        SourceQualityProbePhase.done => entry?.qualityLabel ?? '完成',
        SourceQualityProbePhase.failed => entry?.error ?? '失败',
      };

  SourceQualityProbeState copyWith({
    SourceQualityProbePhase? phase,
    SourceQualityEntry? entry,
    bool clearEntry = false,
  }) =>
      SourceQualityProbeState(
        pluginName: pluginName,
        phase: phase ?? this.phase,
        entry: clearEntry ? null : (entry ?? this.entry),
      );
}

/// 对一部番剧的所有来源逐个嗅探视频地址并实测码率。
///
/// 嗅探复用下载功能的 [VideoSourceResolverPool]（隐藏 WebView 池），
/// 码率测量走 [MediaBitrateMeter]。每个来源只测第一条线路的目标集。
class SourceQualityProbeService {
  SourceQualityProbeService({
    required this.bangumiId,
    this.episodeNumber = 1,
    int? maxParallel,
    MediaBitrateMeter? meter,
    Duration resolveTimeout = const Duration(seconds: 30),
  })  : _meter = meter ?? MediaBitrateMeter(),
        _resolveTimeout = resolveTimeout,
        maxParallel = _clampParallel(maxParallel);

  final int bangumiId;
  final int episodeNumber;
  final int maxParallel;

  final MediaBitrateMeter _meter;
  final Duration _resolveTimeout;
  final VideoSourceResolverPool _pool = VideoSourceResolverPool();
  final CancelToken _cancelToken = CancelToken();

  final ValueNotifier<List<SourceQualityProbeState>> states =
      ValueNotifier(const []);

  bool _running = false;
  bool _cancelled = false;
  bool _disposed = false;

  bool get isRunning => _running;
  bool get isCancelled => _cancelled;

  static int _clampParallel(int? requested) {
    final mobile = Platform.isAndroid || Platform.isIOS;
    final upper = mobile ? 2 : 5;
    return (requested ?? (mobile ? 2 : 3)).clamp(1, upper);
  }

  /// 依次探测 [targets]，返回可持久化的排名；全部失败时仍返回（用于展示原因），
  /// 被取消时返回 null。
  Future<SourceQualityRank?> run(List<SourceQualityProbeTarget> targets) async {
    if (_running || _disposed || _cancelled) {
      throw StateError('SourceQualityProbeService is busy or finished');
    }
    _running = true;
    states.value = [
      for (final target in targets)
        SourceQualityProbeState(
          pluginName: target.plugin.name,
          phase: SourceQualityProbePhase.pending,
        ),
    ];

    _pool.resize(maxParallel);
    final queue = List<SourceQualityProbeTarget>.of(targets);
    final workers = List.generate(
      maxParallel.clamp(1, targets.isEmpty ? 1 : targets.length),
      (_) => _worker(queue),
    );
    try {
      await Future.wait(workers);
    } finally {
      _running = false;
    }
    if (_cancelled) return null;
    return _buildRank();
  }

  /// 只重探一个来源（通常是超时的那条），其余结果保留，返回合并后的排名。
  /// 服务被取消或释放后返回 null。
  Future<SourceQualityRank?> retry(SourceQualityProbeTarget target) async {
    if (_disposed || _cancelled) return null;
    if (_running) {
      throw StateError('SourceQualityProbeService is busy');
    }
    _running = true;
    _update(
      target.plugin.name,
      phase: SourceQualityProbePhase.pending,
      clearEntry: true,
    );
    try {
      await _probeOne(target);
    } finally {
      _running = false;
    }
    if (_cancelled) return null;
    return _buildRank();
  }

  SourceQualityRank _buildRank() => SourceQualityRank(
        bangumiId: bangumiId,
        episodeNumber: episodeNumber,
        probedAt: DateTime.now(),
        entries: [
          for (final state in states.value)
            state.entry ??
                SourceQualityEntry(pluginName: state.pluginName, error: '未完成'),
        ],
      );

  Future<void> _worker(List<SourceQualityProbeTarget> queue) async {
    while (queue.isNotEmpty && !_cancelled) {
      final target = queue.removeAt(0);
      await _probeOne(target);
    }
  }

  Future<void> _probeOne(SourceQualityProbeTarget target) async {
    final plugin = target.plugin;
    final name = plugin.name;
    try {
      _update(name, phase: SourceQualityProbePhase.loadingRoads);
      final roads = await plugin.queryChapterRoads(
        target.item.src,
        cancelToken: _cancelToken,
      );
      _throwIfCancelled();
      final road = roads.where((r) => r.data.isNotEmpty).firstOrNull;
      if (road == null) throw const _ProbeFailure('没有可用线路');
      final index = (episodeNumber - 1).clamp(0, road.data.length - 1);
      final episodeUrl = plugin.buildFullUrl(road.data[index]);
      if (episodeUrl.isEmpty) throw const _ProbeFailure('播放页地址为空');

      _update(name, phase: SourceQualityProbePhase.resolvingVideo);
      final videoUrl = await _resolveVideoUrl(name, plugin, episodeUrl);
      _throwIfCancelled();

      _update(name, phase: SourceQualityProbePhase.measuring);
      final result = await _meter.measure(
        videoUrl,
        plugin.buildHttpHeaders(),
        cancelToken: _cancelToken,
      );
      _throwIfCancelled();

      _update(
        name,
        phase: SourceQualityProbePhase.done,
        entry: SourceQualityEntry(
          pluginName: name,
          searchItemName: target.item.name,
          searchItemSrc: target.item.src,
          kbps: result.kbps,
          width: result.width,
          height: result.height,
          downloadMbps: result.downloadMbps,
          container: result.container,
          videoHost: Uri.tryParse(videoUrl)?.host ?? '',
        ),
      );
      KazumiLogger().i(
        'SourceQualityProbe: $name ${result.kbps} kbps '
        '${result.width}x${result.height} ${result.container} $videoUrl',
      );
    } catch (error) {
      if (_cancelled) return;
      final reason = _describeError(error);
      KazumiLogger().w('SourceQualityProbe: $name failed: $reason');
      _update(
        name,
        phase: SourceQualityProbePhase.failed,
        entry: SourceQualityEntry(
          pluginName: name,
          searchItemName: target.item.name,
          searchItemSrc: target.item.src,
          error: reason,
        ),
      );
    }
  }

  Future<String> _resolveVideoUrl(
    String name,
    Plugin plugin,
    String episodeUrl,
  ) async {
    // 工作协程数等于池容量，这里一般能立刻拿到；拿不到就等一个空位。
    VideoSourceResolverLease? lease;
    final key = 'quality:$bangumiId:$name';
    while (lease == null) {
      _throwIfCancelled();
      lease = _pool.tryAcquire(key);
      if (lease == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    try {
      final source = await lease.resolve(
        episodeUrl,
        useLegacyParser: plugin.useLegacyParser,
        timeout: _resolveTimeout,
      );
      if (source.url.isEmpty) throw const _ProbeFailure('没有嗅探到视频地址');
      return source.url;
    } on VideoSourceTimeoutException {
      throw const _ProbeFailure('嗅探超时');
    } on VideoSourceNotFoundException {
      throw const _ProbeFailure('没有嗅探到视频地址');
    } catch (error) {
      if (error is VideoSourceCancelledException) rethrow;
      lease.retire();
      rethrow;
    } finally {
      _pool.release(lease);
    }
  }

  void _update(
    String name, {
    required SourceQualityProbePhase phase,
    SourceQualityEntry? entry,
    bool clearEntry = false,
  }) {
    if (_disposed) return;
    states.value = [
      for (final state in states.value)
        if (state.pluginName == name)
          state.copyWith(phase: phase, entry: entry, clearEntry: clearEntry)
        else
          state,
    ];
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const VideoSourceCancelledException();
  }

  static String _describeError(Object error) {
    if (error is _ProbeFailure) return error.message;
    if (error is MediaBitrateException) return error.message;
    if (error is ChapterErrorException) return '获取播放列表失败';
    if (error is NetworkException) {
      return switch (error.type) {
        NetworkExceptionType.connectionTimeout ||
        NetworkExceptionType.receiveTimeout ||
        NetworkExceptionType.sendTimeout =>
          '网络超时',
        NetworkExceptionType.badResponse => '服务端返回 ${error.statusCode ?? '错误'}',
        NetworkExceptionType.cancel => '请求被取消',
        _ => '网络错误',
      };
    }
    if (error is DioException) return '网络错误';
    final text = error.toString();
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancelToken.cancel('probe cancelled');
    _pool.cancelAll();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cancel();
    await _pool.dispose();
    states.dispose();
  }
}

class _ProbeFailure implements Exception {
  const _ProbeFailure(this.message);

  final String message;
}
