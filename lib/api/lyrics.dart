import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class Lyrics {
  final List<LyricLine> synced;
  final String plain;
  const Lyrics(this.synced, this.plain);
  bool get hasSynced => synced.isNotEmpty;
  bool get isEmpty => synced.isEmpty && plain.trim().isEmpty;

  int indexAt(Duration pos) {
    var idx = -1;
    final p = pos + const Duration(milliseconds: 300);
    for (var i = 0; i < synced.length; i++) {
      if (synced[i].time <= p) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// Synchronisierte Songtexte von LRCLIB (offen, ohne Schlüssel).
class LyricsApi {
  static final _futures = <String, Future<Lyrics?>>{};

  static Future<Lyrics?> fetch(Track t) => _futures.putIfAbsent(t.id, () => _fetch(t));

  static Future<Lyrics?> _fetch(Track t) async {
    const headers = {'User-Agent': 'Lyra/1.0 (private)'};
    try {
      Map? j;
      if (t.album.isNotEmpty && t.duration > 0) {
        final r = await http.get(
          Uri.https('lrclib.net', '/api/get', {
            'track_name': t.title,
            'artist_name': t.artist,
            'album_name': t.album,
            'duration': '${t.duration}',
          }),
          headers: headers,
        );
        if (r.statusCode == 200) j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      }
      if (j == null) {
        final s = await http.get(
          Uri.https('lrclib.net', '/api/search', {'track_name': t.title, 'artist_name': t.artist}),
          headers: headers,
        );
        if (s.statusCode == 200) {
          final list = jsonDecode(utf8.decode(s.bodyBytes)) as List;
          Map? withSync;
          for (final e in list) {
            if ((e as Map)['syncedLyrics'] != null) {
              withSync = e;
              break;
            }
          }
          j = withSync ?? (list.isNotEmpty ? list.first as Map : null);
        }
      }
      if (j == null) return null;
      final l = Lyrics(parse(j['syncedLyrics'] as String?), (j['plainLyrics'] as String?) ?? '');
      return l.isEmpty ? null : l;
    } catch (_) {
      _futures.remove(t.id);
      return null;
    }
  }

  static final _re = RegExp(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$');

  static List<LyricLine> parse(String? s) {
    if (s == null) return const [];
    final out = <LyricLine>[];
    for (final raw in const LineSplitter().convert(s)) {
      final m = _re.firstMatch(raw.trim());
      if (m == null) continue;
      final min = int.parse(m.group(1)!);
      final sec = double.parse(m.group(2)!);
      final text = m.group(3)!.trim();
      out.add(LyricLine(Duration(milliseconds: (min * 60000 + sec * 1000).round()), text.isEmpty ? '♪' : text));
    }
    return out;
  }
}
