import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/store.dart';

class InvAudio {
  final Uri url;
  final String mime;
  final int size;
  final String host;
  const InvAudio(this.url, this.mime, this.size, this.host);
}

/// Invidious-Server holen das Audio selbst bei YouTube und reichen es durch.
/// So greift YouTubes Sperre gegen Apps auf dem Handy nicht.
class Invidious {
  /// Bekannte Server als Reserve, falls die Liste nicht geladen werden kann.
  static const _fallback = [
    'https://yt.chocolatemoo53.com',
    'https://inv.nadeko.net',
    'https://invidious.nerdvpn.de',
    'https://yewtu.be',
    'https://invidious.f5.si',
    'https://iv.melmac.space',
  ];

  static List<String>? _list;
  static DateTime? _listAt;
  static final _bad = <String, DateTime>{};
  static const _ua = {'User-Agent': 'Mozilla/5.0 (Linux; Android 14) Lyra/1.0'};

  static Future<List<String>> instances() async {
    if (_list != null && _listAt != null && DateTime.now().difference(_listAt!).inHours < 6) return _list!;
    final hosts = <String>[];
    try {
      final r = await http
          .get(Uri.parse('https://api.invidious.io/instances.json?sort_by=health'), headers: _ua)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        for (final e in jsonDecode(utf8.decode(r.bodyBytes)) as List) {
          final m = (e as List)[1] as Map;
          if (m['type'] == 'https' && m['uri'] != null) {
            // Server mit offener API zuerst, die anderen trotzdem versuchen
            if (m['api'] == true) {
              hosts.insert(0, '${m['uri']}');
            } else {
              hosts.add('${m['uri']}');
            }
          }
        }
      }
    } catch (_) {}
    for (final f in _fallback) {
      if (!hosts.contains(f)) hosts.add(f);
    }
    final pref = Store.instance.invHost;
    if (pref != null && hosts.remove(pref)) hosts.insert(0, pref);
    _list = hosts;
    _listAt = DateTime.now();
    return hosts;
  }

  static bool _isBad(String h) {
    final t = _bad[h];
    return t != null && DateTime.now().difference(t).inMinutes < 30;
  }

  /// Sucht einen Server, der für dieses Video wirklich Audio liefert.
  static Future<InvAudio> audio(String vid, {List<String>? errors}) async {
    final hosts = (await instances()).where((h) => !_isBad(h)).take(8).toList();
    for (final h in hosts) {
      try {
        final a = await _tryHost(h, vid);
        if (Store.instance.invHost != h) Store.instance.setInvHost(h);
        return a;
      } catch (e) {
        errors?.add('${Uri.parse(h).host}: ${e.toString().split('\n').first}');
        _bad[h] = DateTime.now();
      }
    }
    throw Exception('Kein Invidious-Server erreichbar');
  }

  static Future<InvAudio> _tryHost(String host, String vid) async {
    final r = await http
        .get(Uri.parse('$host/api/v1/videos/$vid?local=true&fields=adaptiveFormats'), headers: _ua)
        .timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) throw Exception('API ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) throw Exception('ungültige Antwort');
    final formats = ((j['adaptiveFormats'] as List?) ?? const [])
        .cast<Map>()
        .where((f) => '${f['type']}'.startsWith('audio/'))
        .toList();
    if (formats.isEmpty) throw Exception('kein Audio');
    int br(Map f) => int.tryParse('${f['bitrate'] ?? 0}') ?? 0;
    // AAC (mp4) bevorzugen, läuft überall; sonst Opus (webm)
    final mp4 = formats.where((f) => '${f['type']}'.contains('mp4')).toList()..sort((a, b) => br(b) - br(a));
    final f = mp4.isNotEmpty ? mp4.first : (formats..sort((a, b) => br(b) - br(a))).first;
    var url = '${f['url']}';
    if (url.startsWith('/')) url = '$host$url';
    final uri = Uri.parse(url);
    // Prüfen, ob der Stream wirklich Daten liefert
    final client = http.Client();
    try {
      final req = http.Request('GET', uri)
        ..headers.addAll({..._ua, 'Range': 'bytes=0-4095'});
      final res = await client.send(req).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200 && res.statusCode != 206) throw Exception('Stream ${res.statusCode}');
      await res.stream.first.timeout(const Duration(seconds: 10));
    } finally {
      client.close();
    }
    final mime = '${f['type']}'.contains('webm') ? 'audio/webm' : 'audio/mp4';
    return InvAudio(uri, mime, int.tryParse('${f['clen'] ?? 0}') ?? 0, host);
  }
}
