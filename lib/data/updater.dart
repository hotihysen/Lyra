import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Neue Versionen aus den GitHub-Releases von hotihysen/Lyra holen und installieren.
class Updater {
  static const repo = 'hotihysen/Lyra';
  static const build = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
  static String get version => build == 0 ? 'Entwicklerversion' : '1.0.$build';
  static const _ch = MethodChannel('ch.hysen.lyra/update');

  static final available = ValueNotifier<UpdateInfo?>(null);
  static final progress = ValueNotifier<double?>(null);

  /// Protokoll für die Update-Test-Seite.
  static final log = ValueNotifier<List<String>>(const []);

  static void _log(String msg) {
    final t = DateTime.now();
    final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    log.value = [...log.value, '$ts  $msg'];
  }

  static void clearLog() => log.value = const [];

  /// Gibt null zurück, wenn die App aktuell ist. Wirft bei Fehlern eine verständliche Meldung.
  static Future<UpdateInfo?> check() async {
    final info = await fetchLatest();
    final newer = info.build > build;
    available.value = newer ? info : null;
    return newer ? info : null;
  }

  /// Neuestes Release, unabhängig davon, ob es neuer ist.
  static Future<UpdateInfo> fetchLatest() async {
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Lyra'},
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode == 404) {
      throw Exception('Keine Releases gefunden. Ist das Repo auf GitHub öffentlich?');
    }
    if (r.statusCode != 200) throw Exception('GitHub antwortet mit ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    final tag = '${j['tag_name'] ?? ''}';
    final n = int.tryParse(tag.split('.').last) ?? 0;
    final assets = (j['assets'] as List?) ?? const [];
    Map? apk;
    for (final a in assets) {
      if ('${(a as Map)['name']}'.endsWith('.apk')) {
        apk = a;
        break;
      }
    }
    if (apk == null) throw Exception('Im neuesten Release liegt keine APK');
    final info = UpdateInfo(
      build: n,
      tag: tag,
      url: '${apk['browser_download_url']}',
      size: (apk['size'] as num?)?.toInt() ?? 0,
      notes: '${j['body'] ?? ''}'.trim(),
    );
    return info;
  }

  static Future<void> checkSilently() async {
    try {
      await check();
    } catch (_) {}
  }

  /// Beobachtet die Installationssitzung. Zeigt Android innert weniger Sekunden nichts an
  /// (z.B. weil der Bestätigungsdialog blockiert wurde), öffnet Lyra den klassischen Installer.
  static String statusName(int s) => switch (s) {
        -99 => 'keine Rückmeldung',
        -1 => 'wartet auf Bestätigung',
        0 => 'erfolgreich',
        1 => 'fehlgeschlagen',
        2 => 'blockiert',
        3 => 'abgebrochen',
        4 => 'ungültige APK',
        5 => 'Konflikt (andere Signatur?)',
        6 => 'zu wenig Speicher',
        7 => 'inkompatibel',
        _ => 'Status $s',
      };

  static Future<void> _watchSession(File apk, {required bool fallback}) async {
    final until = DateTime.now().add(const Duration(seconds: 10));
    var last = -100;
    while (DateTime.now().isBefore(until)) {
      await Future.delayed(const Duration(milliseconds: 500));
      final st = await _ch.invokeMapMethod<String, dynamic>('installStatus');
      final status = (st?['status'] as num?)?.toInt() ?? -99;
      if (status != last) {
        last = status;
        final msg = st?['message'];
        _log('Installer: ${statusName(status)}${msg != null ? ' ($msg)' : ''}');
      }
      // Der Installer liegt jetzt über Lyra: es läuft
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _log('Android-Dialog ist offen, bitte dort bestätigen');
        return;
      }
      if (status == 0) return; // Erfolg: Android ersetzt die App gleich
      if (status > 0) break; // Fehler der Sitzung: klassischer Weg
    }
    if (!fallback) {
      _log('Kein Dialog erschienen (Modus «nur Sitzung», kein Rückfall)');
      throw Exception('Die Installationssitzung hat keinen Dialog geöffnet');
    }
    _log('Rückfall: klassischer Installer wird geöffnet');
    await _ch.invokeMethod('openApk', {'path': apk.path});
  }

  /// Lädt die APK und öffnet den Android-Installer (bestätigen musst du dort selbst).
  static Future<void> install(UpdateInfo info, {InstallMode mode = InstallMode.auto}) async {
    _log('Start: ${Updater.version} → ${info.version}, Modus ${mode.label}');
    if (!await _ch.invokeMethod<bool>('canInstall').then((v) => v ?? false)) {
      _log('Berechtigung «Unbekannte Apps installieren» fehlt, Einstellungen geöffnet');
      await _ch.invokeMethod('openInstallSettings');
      throw Exception('Bitte erlaube Lyra «Unbekannte Apps installieren» und tippe danach nochmals auf Aktualisieren.');
    }
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    final file = File('${dir.path}/Lyra-${info.tag}.apk');
    final client = http.Client();
    progress.value = 0;
    _log('Lade ${info.url.split('/').last} …');
    try {
      final res = await client.send(http.Request('GET', Uri.parse(info.url)));
      if (res.statusCode != 200) throw Exception('Download fehlgeschlagen (${res.statusCode})');
      final total = res.contentLength ?? info.size;
      final sink = file.openWrite();
      var got = 0;
      try {
        await for (final c in res.stream) {
          got += c.length;
          sink.add(c);
          if (total > 0) progress.value = got / total;
        }
      } finally {
        await sink.close();
      }
      _log('Download: ${(got / 1048576).toStringAsFixed(1)} MB');
      if (got < 1000000) throw Exception('Download unvollständig (${got ~/ 1024} KB)');
      if (mode == InstallMode.classic) {
        _log('Klassischer Installer wird geöffnet');
        await _ch.invokeMethod('openApk', {'path': file.path});
        return;
      }
      final used = await _ch.invokeMethod<String>('install', {'path': file.path});
      _log(used == 'session' ? 'Installationssitzung übergeben' : 'Sitzung nicht möglich, klassischer Installer geöffnet');
      if (used == 'session') await _watchSession(file, fallback: mode == InstallMode.auto);
    } finally {
      client.close();
      progress.value = null;
    }
  }
}

class UpdateInfo {
  final int build;
  final String tag;
  final String url;
  final int size;
  final String notes;
  const UpdateInfo({required this.build, required this.tag, required this.url, required this.size, required this.notes});
  String get version => tag.startsWith('v') ? tag.substring(1) : tag;
}

enum InstallMode {
  auto('Automatisch'),
  session('Nur Sitzung (wie Flimmer)'),
  classic('Nur klassisch');

  final String label;
  const InstallMode(this.label);
}
