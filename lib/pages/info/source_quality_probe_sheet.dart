import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/split_list_row.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/services/quality/source_quality_models.dart';
import 'package:kazumi/services/quality/source_quality_probe_service.dart';
import 'package:kazumi/services/quality/source_quality_store.dart';
import 'package:kazumi/services/storage/storage.dart';

/// "码率探测"面板：检索所有来源，逐个嗅探并实测码率，结果按番剧保存。
///
/// 探测完成后点"开始观看"会以 `true` 关闭面板，调用方据此打开播放来源列表。
class SourceQualityProbeSheet extends StatefulWidget {
  const SourceQualityProbeSheet({
    super.key,
    required this.infoController,
    this.episodeNumber = 1,
  });

  final InfoController infoController;
  final int episodeNumber;

  @override
  State<SourceQualityProbeSheet> createState() =>
      _SourceQualityProbeSheetState();
}

enum _ProbeStage { searching, probing, done, cancelled, empty }

class _SourceQualityProbeSheetState extends State<SourceQualityProbeSheet> {
  final PluginsController _pluginsController = inject<PluginsController>();
  final SourceQualityStore _store = const SourceQualityStore();

  late final PluginSearchService _searchService;
  SourceQualityProbeService? _probe;
  _ProbeStage _stage = _ProbeStage.searching;
  SourceQualityRank? _result;
  SourceQualityRank? _previous;

  /// 本轮探测的目标，按规则名索引，供单条重试使用。
  final Map<String, SourceQualityProbeTarget> _targets = {};
  bool _retrying = false;

  /// 探测尚未开始时给头部用的空进度。
  final ValueNotifier<List<SourceQualityProbeState>> _idleStates =
      ValueNotifier(const []);

  @override
  void initState() {
    super.initState();
    _searchService = PluginSearchService(
      infoController: widget.infoController,
      pluginsController: _pluginsController,
    );
    _previous = _store.get(widget.infoController.bangumiItem.id);
    unawaited(_start());
  }

  @override
  void dispose() {
    _searchService.cancel();
    final probe = _probe;
    _probe = null;
    unawaited(probe?.dispose());
    _idleStates.dispose();
    super.dispose();
  }

  bool get _hasFreshSearch {
    final status = widget.infoController.pluginSearchStatus;
    if (status.isEmpty) return false;
    for (final plugin in _pluginsController.pluginList) {
      final value = status[plugin.name];
      if (value == null || value == PluginSearchStatus.pending) return false;
    }
    return true;
  }

  Future<void> _start() async {
    final item = widget.infoController.bangumiItem;
    final keyword = item.nameCn.isEmpty ? item.name : item.nameCn;

    if (!_hasFreshSearch) {
      await _searchService.queryAllSource(keyword);
      if (!mounted) return;
    }

    final targets = <SourceQualityProbeTarget>[];
    _targets.clear();
    final responses = widget.infoController.pluginSearchResponseList;
    for (final plugin in _pluginsController.pluginList) {
      if (widget.infoController.pluginSearchStatus[plugin.name] !=
          PluginSearchStatus.success) {
        continue;
      }
      SearchItem? first;
      for (final response in responses) {
        if (response.pluginName == plugin.name && response.data.isNotEmpty) {
          first = response.data.first;
          break;
        }
      }
      if (first == null) continue;
      final target = SourceQualityProbeTarget(plugin: plugin, item: first);
      targets.add(target);
      _targets[plugin.name] = target;
    }

    if (targets.isEmpty) {
      setState(() => _stage = _ProbeStage.empty);
      return;
    }

    final probe = SourceQualityProbeService(
      bangumiId: item.id,
      episodeNumber: widget.episodeNumber,
      maxParallel: GStorage.getSetting(SettingsKeys.downloadParallelEpisodes),
    );
    setState(() {
      _probe = probe;
      _stage = _ProbeStage.probing;
    });

    SourceQualityRank? rank;
    try {
      rank = await probe.run(targets);
    } catch (error) {
      KazumiLogger().e('SourceQualityProbeSheet: probe crashed', error: error);
    }
    if (!mounted) return;

    if (rank == null) {
      setState(() => _stage = _ProbeStage.cancelled);
      return;
    }
    await _store.put(rank);
    if (!mounted) return;
    setState(() {
      _result = rank;
      _stage = _ProbeStage.done;
    });
  }

  Future<void> _restart() async {
    final probe = _probe;
    _probe = null;
    _result = null;
    setState(() => _stage = _ProbeStage.searching);
    await probe?.dispose();
    if (!mounted) return;
    await _start();
  }

  void _cancel() {
    _probe?.cancel();
  }

  /// 只重探一个失败的来源，结果合并进已保存的排名。
  Future<void> _retryOne(String pluginName) async {
    final probe = _probe;
    final target = _targets[pluginName];
    if (probe == null || target == null || _retrying) return;
    setState(() => _retrying = true);
    SourceQualityRank? rank;
    try {
      rank = await probe.retry(target);
    } catch (error) {
      KazumiLogger().e('SourceQualityProbeSheet: retry crashed', error: error);
    }
    if (!mounted) return;
    if (rank != null) {
      await _store.put(rank);
      if (!mounted) return;
    }
    setState(() {
      _retrying = false;
      if (rank != null) _result = rank;
    });
  }

  String get _description {
    final item = widget.infoController.bangumiItem;
    final episode = '第 ${widget.episodeNumber} 集';
    switch (_stage) {
      case _ProbeStage.searching:
        return '正在检索来源 · $episode';
      case _ProbeStage.probing:
        final states = _probe?.states.value ?? const [];
        final finished = states.where((state) => state.isFinished).length;
        return '探测中 $finished/${states.length} · $episode';
      case _ProbeStage.done:
        final measured = _result?.measured.length ?? 0;
        if (_retrying) return '重试中 · $measured 个来源已测出码率';
        return '完成，$measured 个来源测出码率 · 已按此排序';
      case _ProbeStage.cancelled:
        return '已取消';
      case _ProbeStage.empty:
        return '没有来源检索到「${item.nameCn.isEmpty ? item.name : item.nameCn}」';
    }
  }

  @override
  Widget build(BuildContext context) {
    final probe = _probe;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          ValueListenableBuilder<List<SourceQualityProbeState>>(
            valueListenable: probe?.states ?? _idleStates,
            builder: (context, _, __) => MaterialBottomSheetHeader(
              title: '码率探测',
              description: _description,
              compact: true,
              onClose: () => Navigator.of(context).pop(false),
              trailing: _stage == _ProbeStage.probing
                  ? TextButton(onPressed: _cancel, child: const Text('取消'))
                  : null,
            ),
          ),
          Expanded(child: _buildBody(context)),
          _buildFooter(context),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final probe = _probe;
    switch (_stage) {
      case _ProbeStage.searching:
        return _buildSearching(context);
      case _ProbeStage.empty:
        return _buildMessage(
          context,
          icon: Icons.search_off_rounded,
          text: '没有来源检索到这部番剧，先在「开始观看」里修改检索词再试。',
        );
      case _ProbeStage.probing:
      case _ProbeStage.done:
      case _ProbeStage.cancelled:
        if (probe == null) return const SizedBox.shrink();
        return ValueListenableBuilder<List<SourceQualityProbeState>>(
          valueListenable: probe.states,
          builder: (context, states, _) => _buildList(context, states),
        );
    }
  }

  Widget _buildSearching(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.infoController.pluginSearchStatus;
    final total = _pluginsController.pluginList.length;
    final finished = status.values
        .where((value) => value != PluginSearchStatus.pending)
        .length;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LoadingIndicator(size: 36, semanticsLabel: '正在检索来源'),
          const SizedBox(height: 12),
          Text('正在检索来源 $finished/$total', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context,
      {required IconData icon, required String text}) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildList(
      BuildContext context, List<SourceQualityProbeState> states) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final ordered = List<SourceQualityProbeState>.of(states);
    if (_stage != _ProbeStage.probing) {
      // 结束后按码率排，失败的沉底。
      ordered.sort((a, b) {
        final ka = a.entry?.kbps;
        final kb = b.entry?.kbps;
        if (ka != null && kb != null) return kb.compareTo(ka);
        if (ka != null) return -1;
        if (kb != null) return 1;
        return 0;
      });
    }
    var rank = 0;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      itemCount: ordered.length,
      separatorBuilder: (_, __) => const SizedBox(height: splitListRowGap),
      itemBuilder: (context, index) {
        final state = ordered[index];
        final entry = state.entry;
        final measured = entry?.isMeasured ?? false;
        if (measured) rank++;
        final Widget trailing;
        if (state.isFinished) {
          final label = Text(
            state.phaseLabel,
            style: theme.textTheme.labelLarge?.copyWith(
              color: measured ? colors.primary : colors.error,
              fontWeight: measured ? FontWeight.w600 : null,
            ),
          );
          final canRetry = !measured &&
              _stage == _ProbeStage.done &&
              !_retrying &&
              _targets.containsKey(state.pluginName);
          trailing = canRetry
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    label,
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '重试 ${state.pluginName}',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _retryOne(state.pluginName),
                      icon: const Icon(Icons.refresh_rounded, size: 20),
                    ),
                  ],
                )
              : label;
        } else if (state.phase == SourceQualityProbePhase.pending) {
          trailing = Text(state.phaseLabel,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: colors.onSurfaceVariant));
        } else {
          trailing = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LoadingIndicator(size: 16, semanticsLabel: '探测中'),
              const SizedBox(width: 8),
              Text(state.phaseLabel,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: colors.onSurfaceVariant)),
            ],
          );
        }
        final subtitle = <String>[
          if (entry != null && entry.searchItemName.isNotEmpty)
            entry.searchItemName,
          if (entry != null && entry.videoHost.isNotEmpty) entry.videoHost,
          if (entry?.downloadMbps != null) '下载 ${entry!.downloadMbps} Mbps',
        ].join(' · ');
        return SplitListRow(
          topRadius: index == 0 ? splitListOuterRadius : splitListInnerRadius,
          bottomRadius: index == ordered.length - 1
              ? splitListOuterRadius
              : splitListInnerRadius,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  if (measured && _stage != _ProbeStage.probing) ...[
                    Text('#$rank',
                        style: theme.textTheme.labelLarge
                            ?.copyWith(color: colors.primary)),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(state.pluginName,
                            style: theme.textTheme.bodyLarge),
                        if (subtitle.isNotEmpty)
                          Text(subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  trailing,
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFooter(BuildContext context) {
    final theme = Theme.of(context);
    final previous = _previous;
    final showPrevious = _stage == _ProbeStage.searching ||
        _stage == _ProbeStage.probing ||
        _stage == _ProbeStage.cancelled;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showPrevious && previous != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  '上次探测：${_formatTime(previous.probedAt)}，'
                  '${previous.measured.length} 个来源有结果',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            if (_stage == _ProbeStage.done ||
                _stage == _ProbeStage.cancelled ||
                _stage == _ProbeStage.empty)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _retrying ? null : _restart,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重新探测'),
                    ),
                  ),
                  if (_stage == _ProbeStage.done) ...[
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _retrying
                            ? null
                            : () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('开始观看'),
                      ),
                    ),
                  ],
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
  }
}
