import 'dart:convert';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/quality/source_quality_models.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 码率排名的本地存储，按番剧 ID 存一条 JSON。
class SourceQualityStore {
  const SourceQualityStore();

  static String _key(int bangumiId) => bangumiId.toString();

  SourceQualityRank? get(int bangumiId) {
    final raw = GStorage.sourceQualityRanks.get(_key(bangumiId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return SourceQualityRank.fromJson(Map<String, dynamic>.from(decoded));
    } catch (error) {
      KazumiLogger().w(
        'SourceQualityStore: corrupted rank for bangumi $bangumiId',
        error: error,
      );
      return null;
    }
  }

  Future<void> put(SourceQualityRank rank) async {
    await GStorage.sourceQualityRanks
        .put(_key(rank.bangumiId), jsonEncode(rank.toJson()));
    await GStorage.sourceQualityRanks.flush();
  }

  Future<void> delete(int bangumiId) async {
    await GStorage.sourceQualityRanks.delete(_key(bangumiId));
    await GStorage.sourceQualityRanks.flush();
  }
}
