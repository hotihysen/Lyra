import 'dart:math';

import '../api/youtube.dart';
import '../api/ytmusic.dart';
import 'models.dart';
import 'store.dart';

/// «Mein Mix» wie der Supermix von YouTube Music: Mixe zu deinen Lieblingssongs und
/// meistgehörten Titeln, gemischt mit einigen dieser Titel selbst. Wird einmal pro Tag
/// neu zusammengestellt und dazwischen gespeichert (auch für Android Auto).
class MyMix {
  static const maxTracks = 80;
  static Future<List<Track>>? _running;

  static String _today() {
    final d = DateTime.now();
    return '${d.year}-${d.month}-${d.day}';
  }

  /// Titel, aus denen der Mix entsteht, nach Beliebtheit sortiert.
  static List<Track> favourites() {
    final s = Store.instance;
    final pool = <String, Track>{};
    for (final t in [...s.liked, ...s.recent]) {
      if (!t.isBook && t.url == null) pool.putIfAbsent(t.id, () => t);
    }
    double score(Track t) => (s.plays[t.id] ?? 0) + (s.isLiked(t) ? 3 : 0);
    return pool.values.toList()..sort((a, b) => score(b).compareTo(score(a)));
  }

  static bool get possible => favourites().isNotEmpty;

  /// Gespeicherter Mix von heute, sonst neu zusammenstellen.
  static Future<List<Track>> get({bool force = false}) {
    final s = Store.instance;
    if (!force && s.mixDay == _today() && s.mix.isNotEmpty) return Future.value(s.mix);
    return _running ??= _build().whenComplete(() => _running = null);
  }

  static Future<List<Track>> _build() async {
    final fav = favourites();
    if (fav.isEmpty) return const [];
    final rnd = Random();
    // Startpunkte: aus den beliebtesten zwölf zufällig fünf, damit der Mix jeden Tag anders ist
    final top = fav.take(12).toList()..shuffle(rnd);
    final seeds = top.take(5).toList();
    final radios = await Future.wait(seeds.map((t) async {
      try {
        final vid = (await YT.candidates(t)).first;
        return (await YTMusic.radio(vid)).tracks.where((e) => e.id != vid).toList();
      } catch (_) {
        return <Track>[];
      }
    }));
    final known = (fav.take(30).toList()..shuffle(rnd));
    final seen = <String>{};
    final out = <Track>[];
    var k = 0;
    // Abwechselnd aus den Mixen; jeder vierte Titel ist ein bekannter Lieblingstitel
    for (var round = 0; out.length < maxTracks; round++) {
      var added = false;
      for (final r in radios) {
        if (round < r.length && seen.add(r[round].id)) {
          out.add(r[round]);
          added = true;
          if (out.length % 4 == 3 && k < known.length) {
            while (k < known.length && !seen.add(known[k].id)) {
              k++;
            }
            if (k < known.length) out.add(known[k++]);
          }
        }
        if (out.length >= maxTracks) break;
      }
      if (!added) break;
    }
    if (out.isEmpty) {
      // Ohne Netz: wenigstens die eigenen Lieblingstitel
      return fav.take(maxTracks).toList()..shuffle(rnd);
    }
    Store.instance.saveMix(out, _today());
    return out;
  }
}
