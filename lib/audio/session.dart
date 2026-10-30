import 'queue.dart';

/// Gespeicherte Wiedergabesitzung (Warteschlange, Titel, Position, Einstellungen).
/// Enthält keine Streaming-Adressen; die Quelle wird beim Fortsetzen neu ermittelt.
class PlaybackSession {
  static const version = 1;

  final List<QueueEntry> items;
  final List<String> original;
  final int index;
  final String entryUid;
  final String trackId;
  final int positionMs;
  final bool shuffle;
  final int repeat; // Index von RepeatSetting
  final double speed;
  final int savedAt; // ms seit 1970
  final bool wasPlaying;
  final String origin;

  const PlaybackSession({
    required this.items,
    required this.original,
    required this.index,
    required this.entryUid,
    required this.trackId,
    required this.positionMs,
    this.shuffle = false,
    this.repeat = 0,
    this.speed = 1.0,
    required this.savedAt,
    this.wasPlaying = false,
    this.origin = '',
  });

  Map<String, dynamic> toJson() => {
        'v': version,
        'items': [for (final e in items) e.toJson()],
        'original': original,
        'index': index,
        'entryUid': entryUid,
        'trackId': trackId,
        'positionMs': positionMs,
        'shuffle': shuffle,
        'repeat': repeat,
        'speed': speed,
        'savedAt': savedAt,
        'wasPlaying': wasPlaying,
        'origin': origin,
      };

  /// Liest einen gespeicherten Stand. Beschädigte, fremde oder neuere Daten ergeben null,
  /// damit der App-Start nie daran scheitert. Kleine Unstimmigkeiten werden repariert.
  static PlaybackSession? fromJson(dynamic j) {
    try {
      if (j is! Map) return null;
      final v = j['v'];
      if (v is! num || v.toInt() < 1 || v.toInt() > version) return null;
      final items = <QueueEntry>[];
      final seen = <String>{};
      for (final x in (j['items'] as List?) ?? const []) {
        final e = QueueEntry.fromJson(x);
        if (e != null && seen.add(e.uid)) items.add(e);
      }
      if (items.isEmpty) return null;
      final uid = j['entryUid'] is String ? j['entryUid'] as String : '';
      final tid = j['trackId'] is String ? j['trackId'] as String : '';
      var idx = j['index'] is num ? (j['index'] as num).toInt() : -1;
      // Titel und Platz müssen zusammenpassen; sonst über die uid suchen
      if (idx < 0 || idx >= items.length || items[idx].uid != uid) {
        idx = items.indexWhere((e) => e.uid == uid);
      }
      if (idx < 0) return null;
      if (tid.isNotEmpty && items[idx].track.id != tid) return null;
      var pos = j['positionMs'] is num ? (j['positionMs'] as num).toInt() : 0;
      if (pos < 0) pos = 0;
      final sp = j['speed'] is num ? (j['speed'] as num).toDouble() : 1.0;
      final rep = j['repeat'] is num ? (j['repeat'] as num).toInt() : 0;
      return PlaybackSession(
        items: items,
        original: [for (final u in (j['original'] as List?) ?? const []) if (u is String) u],
        index: idx,
        entryUid: items[idx].uid,
        trackId: items[idx].track.id,
        positionMs: pos,
        shuffle: j['shuffle'] == true,
        repeat: rep < 0 || rep > 2 ? 0 : rep,
        speed: sp < 0.5 || sp > 3 ? 1.0 : sp,
        savedAt: j['savedAt'] is num ? (j['savedAt'] as num).toInt() : 0,
        wasPlaying: j['wasPlaying'] == true,
        origin: j['origin'] is String ? j['origin'] as String : '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Wo die Wiedergabe fortgesetzt wird. Stand die Position praktisch am Titelende,
  /// geht es mit dem nächsten Titel ab Anfang weiter, statt einen beendeten Titel
  /// immer wieder herzustellen. Ohne nächsten Titel: derselbe Titel ab Anfang.
  (int index, int positionMs) resumePoint() {
    final d = items[index].track.duration * 1000;
    if (d > 0 && positionMs >= d - 2000) {
      if (index + 1 < items.length) return (index + 1, 0);
      return (index, 0);
    }
    return (index, positionMs);
  }
}
