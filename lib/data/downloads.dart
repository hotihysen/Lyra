import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api/youtube.dart';
import 'models.dart';
import 'store.dart';

/// Offline-Downloads mit Fortschrittsanzeige.
class Downloads {
  static final progress = ValueNotifier<Map<String, double>>({});

  static void _set(String id, double? v) {
    final old = progress.value[id];
    if (v != null && old != null && (v - old).abs() < 0.02 && v < 1) return;
    final m = Map<String, double>.from(progress.value);
    if (v == null) {
      m.remove(id);
    } else {
      m[id] = v;
    }
    progress.value = m;
  }

  static bool isRunning(Track t) => progress.value.containsKey(t.id);

  static Future<bool> download(Track t) async {
    final s = Store.instance;
    if (s.isDownloaded(t)) return true;
    if (isRunning(t)) return false;
    final f = s.fileFor(t);
    _set(t.id, 0);
    try {
      if (t.url != null) {
        await _http(Uri.parse(t.url!), f, (p) => _set(t.id, p));
      } else {
        await YT.download(t, f, (p) => _set(t.id, p));
      }
      // Erst nach vollständigem, geprüftem Abschluss als verfügbar markieren
      if (!s.fixDownloadFormat(t)) {
        try {
          f.deleteSync();
        } catch (_) {}
        throw Exception('Datei ist keine gültige Audiodatei');
      }
      s.addDownload(t);
      return true;
    } catch (_) {
      try {
        File('${f.path}.part').deleteSync();
      } catch (_) {}
      return false;
    } finally {
      _set(t.id, null);
    }
  }

  static Future<int> downloadAll(List<Track> tracks) async {
    var ok = 0;
    for (final t in tracks) {
      if (await download(t)) ok++;
    }
    return ok;
  }

  static Future<void> _http(Uri u, File f, void Function(double) onP) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', u));
      if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final tmp = File('${f.path}.part');
      final sink = tmp.openWrite();
      var got = 0;
      try {
        await for (final c in res.stream) {
          got += c.length;
          sink.add(c);
          if (total > 0) onP(got / total);
        }
      } finally {
        await sink.close();
      }
      if (total > 0 && got < total) throw Exception('Download unvollständig');
      await tmp.rename(f.path);
    } finally {
      client.close();
    }
  }
}
