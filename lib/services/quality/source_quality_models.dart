/// 按番剧存储的"播放来源码率排名"。
///
/// 一次探测针对一部番剧的一集，逐个来源（规则）嗅探视频地址并实测码率。
/// 结果只对这部番剧有效，不同番剧的上游不同，排名不能互相套用。
class SourceQualityEntry {
  const SourceQualityEntry({
    required this.pluginName,
    this.searchItemName = '',
    this.searchItemSrc = '',
    this.kbps,
    this.width,
    this.height,
    this.downloadMbps,
    this.container = '',
    this.videoHost = '',
    this.error,
  });

  final String pluginName;
  final String searchItemName;
  final String searchItemSrc;

  /// 实测视频码率（kbps）。为空表示未测出。
  final int? kbps;
  final int? width;
  final int? height;

  /// 采样期间的实际下载速率（Mbps），只作参考。
  final double? downloadMbps;

  /// `hls` 或 `mp4`。
  final String container;

  /// 视频地址主机名，用于识别共用上游的来源。
  final String videoHost;

  /// 失败原因；测出结果时为空。
  final String? error;

  bool get isMeasured => kbps != null && kbps! > 0;

  bool get hasResolution => width != null && height != null && height! > 0;

  String get resolutionLabel => hasResolution ? '${width}x$height' : '';

  /// 列表上显示的短标签，例如 `1140 kbps · 1920x804`。
  String get qualityLabel {
    if (!isMeasured) return error ?? '未探测';
    final parts = <String>['$kbps kbps'];
    if (hasResolution) parts.add(resolutionLabel);
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pluginName': pluginName,
        'searchItemName': searchItemName,
        'searchItemSrc': searchItemSrc,
        if (kbps != null) 'kbps': kbps,
        if (width != null) 'width': width,
        if (height != null) 'height': height,
        if (downloadMbps != null) 'downloadMbps': downloadMbps,
        'container': container,
        'videoHost': videoHost,
        if (error != null) 'error': error,
      };

  factory SourceQualityEntry.fromJson(Map<String, dynamic> json) {
    return SourceQualityEntry(
      pluginName: json['pluginName'] as String? ?? '',
      searchItemName: json['searchItemName'] as String? ?? '',
      searchItemSrc: json['searchItemSrc'] as String? ?? '',
      kbps: (json['kbps'] as num?)?.toInt(),
      width: (json['width'] as num?)?.toInt(),
      height: (json['height'] as num?)?.toInt(),
      downloadMbps: (json['downloadMbps'] as num?)?.toDouble(),
      container: json['container'] as String? ?? '',
      videoHost: json['videoHost'] as String? ?? '',
      error: json['error'] as String?,
    );
  }
}

class SourceQualityRank {
  SourceQualityRank({
    required this.bangumiId,
    required this.episodeNumber,
    required this.probedAt,
    required List<SourceQualityEntry> entries,
  }) : entries = List.unmodifiable(entries);

  final int bangumiId;
  final int episodeNumber;
  final DateTime probedAt;
  final List<SourceQualityEntry> entries;

  Map<String, SourceQualityEntry> get byPlugin =>
      {for (final entry in entries) entry.pluginName: entry};

  /// 测出码率的来源，按码率从高到低。
  List<SourceQualityEntry> get measured =>
      entries.where((entry) => entry.isMeasured).toList()
        ..sort((a, b) => b.kbps!.compareTo(a.kbps!));

  bool get hasMeasured => entries.any((entry) => entry.isMeasured);

  /// 1 起的名次；未测出返回 null。
  int? rankOf(String pluginName) {
    final index =
        measured.indexWhere((entry) => entry.pluginName == pluginName);
    return index < 0 ? null : index + 1;
  }

  /// 把来源名分三档排序：测出码率的按码率降序；探测过但失败的其次；
  /// 没参与探测的（通常是没搜到结果）最后。后两档各自保持传入顺序。
  List<String> sortPluginNames(Iterable<String> configuredOrder) {
    final order = configuredOrder.toList();
    final rank = <String, int>{
      for (final entry in measured) entry.pluginName: entry.kbps!,
    };
    final probed = <String>{for (final entry in entries) entry.pluginName};
    int tier(String name) {
      if (rank.containsKey(name)) return 0;
      if (probed.contains(name)) return 1;
      return 2;
    }

    final indexed = order.asMap().entries.toList()
      ..sort((a, b) {
        final ta = tier(a.value);
        final tb = tier(b.value);
        if (ta != tb) return ta.compareTo(tb);
        if (ta == 0) return rank[b.value]!.compareTo(rank[a.value]!);
        return a.key.compareTo(b.key);
      });
    return indexed.map((entry) => entry.value).toList();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bangumiId': bangumiId,
        'episodeNumber': episodeNumber,
        'probedAt': probedAt.toIso8601String(),
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };

  factory SourceQualityRank.fromJson(Map<String, dynamic> json) {
    return SourceQualityRank(
      bangumiId: (json['bangumiId'] as num?)?.toInt() ?? 0,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 1,
      probedAt: DateTime.tryParse(json['probedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      entries: ((json['entries'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) =>
              SourceQualityEntry.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
    );
  }
}
