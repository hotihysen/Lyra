// Holt echte Antworten von YouTube Music (InnerTube, Client WEB_REMIX) und speichert sie
// als JSON in einen Ordner. Läuft nur in GitHub Actions, dient als Testmaterial für den Parser.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

const _base = 'https://music.youtube.com/youtubei/v1';
const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
String? _visitor;

Map<String, dynamic> _context() => {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': '1.20260114.01.00',
        'hl': 'de',
        'gl': 'CH',
        if (_visitor != null) 'visitorData': _visitor,
      },
    };

Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
  final r = await http.post(
    Uri.parse('$_base/$endpoint?prettyPrint=false'),
    headers: {
      'Content-Type': 'application/json',
      'User-Agent': _ua,
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'X-Goog-Api-Format-Version': '1',
      'X-YouTube-Client-Name': '67',
      'X-YouTube-Client-Version': '1.20260114.01.00',
      if (_visitor != null) 'X-Goog-Visitor-Id': _visitor!,
    },
    body: jsonEncode({'context': _context(), ...body}),
  );
  if (r.statusCode != 200) throw Exception('$endpoint ${r.statusCode}: ${r.body.substring(0, r.body.length.clamp(0, 300))}');
  final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  _visitor ??= (j['responseContext'] as Map?)?['visitorData'] as String?;
  return j;
}

/// Erste Fundstelle eines Schlüssels mit passendem Wert (Tiefensuche).
String? _find(dynamic node, String key, bool Function(String) test) {
  if (node is Map) {
    final v = node[key];
    if (v is String && test(v)) return v;
    for (final c in node.values) {
      final r = _find(c, key, test);
      if (r != null) return r;
    }
  } else if (node is List) {
    for (final c in node) {
      final r = _find(c, key, test);
      if (r != null) return r;
    }
  }
  return null;
}

Future<void> main(List<String> args) async {
  final out = Directory(args.isEmpty ? 'fixtures' : args.first)..createSync(recursive: true);
  final log = StringBuffer();
  Future<Map<String, dynamic>?> save(String name, Future<Map<String, dynamic>> f) async {
    try {
      final j = await f;
      File('${out.path}/$name.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(j));
      log.writeln('OK   $name (${File('${out.path}/$name.json').lengthSync()} B)');
      return j;
    } catch (e) {
      log.writeln('FAIL $name: $e');
      return null;
    }
  }

  const songs = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';
  const albums = 'EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D';
  const artists = 'EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D';
  const playlists = 'EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ%3D';

  await save('home', _post('browse', {'browseId': 'FEmusic_home'}));
  await save('search_all_kida', _post('search', {'query': 'Kida'}));
  final mama = await save('search_songs_kida_mama', _post('search', {'query': 'Kida MAMA', 'params': Uri.decodeComponent(songs)}));
  await save('search_songs_kida_tdu', _post('search', {'query': 'Kida TDU', 'params': Uri.decodeComponent(songs)}));
  await save('search_songs_kida_ma_lujte', _post('search', {'query': 'Kida Ma lujte', 'params': Uri.decodeComponent(songs)}));
  final al = await save('search_albums_kida', _post('search', {'query': 'Kida', 'params': Uri.decodeComponent(albums)}));
  final ar = await save('search_artists_kida', _post('search', {'query': 'Kida', 'params': Uri.decodeComponent(artists)}));
  final pl = await save('search_playlists_hits', _post('search', {'query': 'Hits 2026', 'params': Uri.decodeComponent(playlists)}));
  await save('suggestions', _post('music/get_search_suggestions', {'input': 'kida'}));

  final artistId = _find(ar, 'browseId', (v) => v.startsWith('UC'));
  if (artistId != null) {
    final a = await save('artist', _post('browse', {'browseId': artistId}));
    // «Alle Songs» des Künstlers (Playlist VL…)
    final more = _find(a, 'browseId', (v) => v.startsWith('VLOLAK') || v.startsWith('VLPL') || v.startsWith('VLOL'));
    if (more != null) await save('artist_songs', _post('browse', {'browseId': more}));
  }
  final albumId = _find(al, 'browseId', (v) => v.startsWith('MPREb'));
  if (albumId != null) await save('album', _post('browse', {'browseId': albumId}));
  final plId = _find(pl, 'browseId', (v) => v.startsWith('VL'));
  if (plId != null) await save('playlist', _post('browse', {'browseId': plId}));

  final vid = _find(mama, 'videoId', (v) => v.length == 11);
  if (vid != null) {
    await save('next_radio', _post('next', {
      'videoId': vid,
      'playlistId': 'RDAMVM$vid',
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
    }));
  }
  final g = await save('moods_genres', _post('browse', {'browseId': 'FEmusic_moods_and_genres'}));
  final gp = _find(g, 'params', (v) => v.length > 10);
  if (gp != null) await save('genre_page', _post('browse', {'browseId': 'FEmusic_moods_and_genres_category', 'params': gp}));
  await save('explore', _post('browse', {'browseId': 'FEmusic_explore'}));
  await save('charts', _post('browse', {'browseId': 'FEmusic_charts', 'formData': {'selectedValues': ['CH']}}));

  File('${out.path}/_log.txt').writeAsStringSync(log.toString());
  stdout.write(log);
}
