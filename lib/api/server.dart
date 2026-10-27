import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/store.dart';

/// Eigener Lyra-Server (zum Beispiel auf Unraid hinter einem Cloudflare Tunnel).
/// Er holt das Audio bei YouTube und liefert es als M4A. Auf dem iPhone ist er der
/// Hauptweg, auf Android eine Reserve nach den eingebauten Extraktoren.
class LyraServer {
  /// Zerlegt den Server-Link, den man in der App einfügt:
  /// `https://lyra.beispiel.ch/?k=SCHLUESSEL` (auch ohne `https://`).
  static ({Uri base, String key})? parse(String? link) {
    if (link == null) return null;
    var s = link.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    final key = u.queryParameters['k'] ?? u.queryParameters['key'] ?? (u.fragment.isNotEmpty ? u.fragment : '');
    if (key.isEmpty) return null;
    return (base: Uri(scheme: u.scheme, host: u.host, port: u.hasPort ? u.port : null), key: key);
  }

  static ({Uri base, String key})? get current => parse(Store.instance.serverLink);
  static bool get configured => current != null;

  static Uri audioUrl(String vid) => current!.base.replace(path: '/audio/$vid.m4a');
  static Map<String, String> get headers => {'X-Lyra-Key': current!.key, 'User-Agent': 'Lyra'};

  /// Prüft Erreichbarkeit und Schlüssel. Liefert eine verständliche Meldung.
  static Future<String> test([String? link]) async {
    final c = parse(link ?? Store.instance.serverLink);
    if (c == null) return 'Kein gültiger Server-Link (Format: https://adresse/?k=SCHLÜSSEL)';
    try {
      final r = await http
          .get(c.base.replace(path: '/health'), headers: {'X-Lyra-Key': c.key})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 401) return 'Server erreicht, aber der Schlüssel ist falsch';
      if (r.statusCode != 200) return 'Server antwortet mit Fehler ${r.statusCode}';
      final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
      final err = '${j['lastError'] ?? ''}';
      return 'Verbunden (yt-dlp ${j['ytdlp']}, ${j['cacheFiles']} Songs im Zwischenspeicher)'
          '${err.isEmpty ? '' : '\nLetzter Fehler: ${err.split('\n').last}'}';
    } catch (e) {
      return 'Server nicht erreichbar: ${e.toString().split('\n').first}';
    }
  }
}
