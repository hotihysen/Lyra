import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_logic.dart';

/// Installationsweg. Standard ist der klassische Android-Installer (wie Flimmer).
enum InstallMode {
  classic('Klassischer Installer (Standard)'),
  session('PackageInstaller-Sitzung (Diagnose)');

  final String label;
  const InstallMode(this.label);
}

/// Klar getrennte Zustände: «Installer geöffnet» ist nicht «installiert».
enum UpdatePhase {
  idle('Bereit'),
  checking('Suche nach Updates'),
  waitingPermission('Wartet auf Berechtigung «Unbekannte Apps installieren»'),
  downloading('Lädt herunter'),
  verifying('Prüft die APK'),
  installerOpen('Android-Installer offen, Bestätigung erforderlich'),
  failed('Fehlgeschlagen'),
  cancelled('Abgebrochen');

  final String label;
  const UpdatePhase(this.label);

  bool get busy =>
      this == checking || this == waitingPermission || this == downloading || this == verifying || this == installerOpen;
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

/// Neue Versionen aus den GitHub-Releases von hotihysen/Lyra holen und installieren.
class Updater {
  static const repo = 'hotihysen/Lyra';
  static const packageName = 'ch.hysen.lyra';
  static const build = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
  static String get version => build == 0 ? 'Entwicklerversion' : '1.0.$build';
  static const _ch = MethodChannel('ch.hysen.lyra/update');

  static final available = ValueNotifier<UpdateInfo?>(null);
  static final phase = ValueNotifier<UpdatePhase>(UpdatePhase.idle);
  static final progress = ValueNotifier<double?>(null);

  /// Letzte verständliche Meldung (Fehler, Ergebnis), für Dialoge.
  static final message = ValueNotifier<String?>(null);

  /// Ergebnis der Kontrolle nach einem Neustart (einmalig anzuzeigen).
  static final restartResult = ValueNotifier<String?>(null);
  static final log = ValueNotifier<List<String>>(const []);

  static final _lock = UpdateLock();
  static bool get busy => _lock.isHeld;

  static _Pending? _waitingForPermission;
  static Timer? _sessionTimeout;
  static bool _initialized = false;

  static Box get _box => Hive.box('lyra');

  // ---------- Start der App ----------

  /// Einmal beim Start: Protokoll laden, offenes Update kontrollieren, alte Dateien aufräumen.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final saved = _box.get('updateLog');
    if (saved is List) log.value = saved.map((e) => '$e').toList();
    _ch.setMethodCallHandler(_onPlatformEvent);
    WidgetsBinding.instance.addObserver(_LifecycleWatcher());

    final pending = _box.get('pendingUpdate');
    if (pending is Map) {
      final expected = (pending['build'] as num?)?.toInt() ?? 0;
      final tag = '${pending['tag'] ?? ''}'.replaceFirst('v', '');
      if (expected > 0 && build >= expected) {
        _log('Kontrolle nach Neustart: installiert ist $version (Build $build), erwartet Build $expected. Update erfolgreich.');
        restartResult.value = 'Update auf $tag wurde installiert.';
      } else {
        _log('Kontrolle nach Neustart: installiert ist $version (Build $build), erwartet Build $expected. Update wurde NICHT installiert.');
        restartResult.value = 'Das Update auf $tag wurde nicht abgeschlossen. Du kannst es erneut versuchen.';
      }
      await _box.delete('pendingUpdate');
    }
    // Sicherer Zeitpunkt zum Aufräumen: beim Start läuft noch kein Vorgang.
    try {
      final n = cleanupUpdateDir(await _updateDir());
      if (n > 0) _log('Aufgeräumt: $n alte Update-Datei(en) gelöscht');
    } catch (_) {}
  }

  static Future<Directory> _updateDir() async => Directory('${(await getTemporaryDirectory()).path}/updates');

  // ---------- Protokoll ----------

  static void _log(String msg) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    final lines = [...log.value, '$ts  $msg'];
    log.value = lines.length > 300 ? lines.sublist(lines.length - 300) : lines;
    try {
      _box.put('updateLog', log.value);
    } catch (_) {}
  }

  static void clearLog() {
    log.value = const [];
    try {
      _box.delete('updateLog');
    } catch (_) {}
  }

  // ---------- Release abfragen ----------

  static Future<UpdateInfo?> check() async {
    final info = await fetchLatest();
    final newer = isNewer(remote: info.build, installed: build);
    available.value = newer ? info : null;
    return newer ? info : null;
  }

  static Future<UpdateInfo> fetchLatest() async {
    final http.Response r;
    try {
      r = await http.get(
        Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
        headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Lyra'},
      ).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw Exception('GitHub antwortet nicht (Zeitüberschreitung)');
    } on SocketException {
      throw Exception('Keine Internetverbindung');
    }
    if (r.statusCode == 404) throw Exception('Keine Releases gefunden. Ist das Repo auf GitHub öffentlich?');
    if (r.statusCode == 403) throw Exception('GitHub hat die Abfrage vorübergehend begrenzt (403). Später erneut versuchen.');
    if (r.statusCode != 200) throw Exception('GitHub antwortet mit HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    final tag = '${j['tag_name'] ?? ''}';
    final n = buildFromTag(tag);
    if (n == null) throw Exception('Unbekanntes Release-Format «$tag»');
    // Android lädt die APK; das iPhone braucht die IPA (Installation über SideStore).
    // Erst wenn die passende Datei im Release liegt, gilt die Version als verfügbar.
    final ext = Platform.isIOS ? '.ipa' : '.apk';
    Map? apk;
    for (final a in (j['assets'] as List?) ?? const []) {
      if ('${(a as Map)['name']}'.endsWith(ext)) {
        apk = a;
        break;
      }
    }
    if (apk == null) {
      if (Platform.isIOS) throw Exception('Die iPhone-Version von $tag ist noch nicht fertig');
      throw Exception('Im Release $tag liegt keine APK');
    }
    return UpdateInfo(
      build: n,
      tag: tag,
      url: '${apk['browser_download_url']}',
      size: (apk['size'] as num?)?.toInt() ?? 0,
      notes: '${j['body'] ?? ''}'.trim(),
    );
  }

  // ---------- Ablauf ----------

  /// Startet Download und Installation. Läuft bereits ein Vorgang, passiert nichts
  /// (Rückgabe false). [allowSameVersion] erlaubt das erneute Installieren der
  /// gleichen Version (nur auf der Test-Seite).
  static Future<bool> start(UpdateInfo info,
      {InstallMode mode = InstallMode.classic, bool allowSameVersion = false}) async {
    if (!_lock.tryAcquire(info.tag)) {
      _log('Abgelehnt: es läuft bereits ein Vorgang (${phase.value.label}). Kein zweiter Download.');
      return false;
    }
    message.value = null;
    _log('Start: installiert $version (Build $build), angeboten ${info.version} (Build ${info.build}), Weg: ${mode.label}');
    if (!allowSameVersion && !isNewer(remote: info.build, installed: build)) {
      _log('Keine neuere Version, nichts zu tun');
      _finish(UpdatePhase.idle, 'Keine neuere Version verfügbar.');
      return true;
    }
    final p = _Pending(info, mode, allowSameVersion);
    final canInstall = await _canInstall();
    _log('Berechtigung «Unbekannte Apps installieren»: ${canInstall ? 'erteilt' : 'fehlt'}');
    if (!canInstall) {
      _waitingForPermission = p;
      phase.value = UpdatePhase.waitingPermission;
      message.value = 'Bitte erlaube Lyra in den Android-Einstellungen «Unbekannte Apps installieren» und kehre dann zurück.';
      _log('Android-Einstellungen geöffnet, warte auf Rückkehr');
      try {
        await _ch.invokeMethod('openInstallSettings');
      } catch (e) {
        _waitingForPermission = null;
        _fail('Einstellungen konnten nicht geöffnet werden: ${_err(e)}');
      }
      return true;
    }
    unawaited(_downloadAndInstall(p));
    return true;
  }

  /// Wird bei Rückkehr in die App aufgerufen.
  static Future<void> _onResumed() async {
    final p = _waitingForPermission;
    if (p == null || phase.value != UpdatePhase.waitingPermission) return;
    final ok = await _canInstall();
    _log('Rückkehr in die App, Berechtigung jetzt: ${ok ? 'erteilt' : 'fehlt'}');
    _waitingForPermission = null;
    if (ok) {
      _log('Vorgang wird fortgesetzt');
      unawaited(_downloadAndInstall(p));
    } else {
      _fail('Ohne die Berechtigung «Unbekannte Apps installieren» kann Lyra keine Updates installieren. '
          'Du kannst es jederzeit erneut versuchen.');
    }
  }

  static Future<void> _downloadAndInstall(_Pending p) async {
    final info = p.info;
    final client = http.Client();
    try {
      phase.value = UpdatePhase.downloading;
      progress.value = 0;
      _log('Download startet: ${info.url.split('/').last}, erwartet ${info.size} Bytes');
      final dl = await downloadApk(
        client: client,
        url: Uri.parse(info.url),
        dir: await _updateDir(),
        baseName: 'Lyra-${info.tag}',
        expectedSize: info.size,
        onProgress: (got, total) {
          if (total > 0) progress.value = got / total;
        },
      );
      progress.value = null;
      _log('Download vollständig: ${dl.bytes} von ${info.size} Bytes');

      phase.value = UpdatePhase.verifying;
      final apk = await _ch.invokeMapMethod<String, dynamic>('inspectApk', {'path': dl.file.path});
      if (apk == null) throw Exception('APK konnte nicht gelesen werden');
      final pkg = '${apk['packageName']}';
      final vc = (apk['versionCode'] as num?)?.toInt() ?? -1;
      final installedVc = (apk['installedVersionCode'] as num?)?.toInt() ?? -1;
      final sameSig = apk['sameSignature'];
      _log('APK: Paket $pkg, Version ${apk['versionName']} (Code $vc); installiert Code $installedVc; '
          'Signatur ${sameSig == true ? 'gleich' : sameSig == false ? 'VERSCHIEDEN' : 'nicht prüfbar'}');
      if (pkg != packageName) throw Exception('Falsches Paket in der APK ($pkg statt $packageName)');
      if (sameSig == false) {
        throw Exception('Signaturkonflikt: Die neue APK ist mit einem anderen Schlüssel signiert als die installierte Lyra, '
            'deshalb lässt Android dieses Update nicht zu. Bekannte Ursache: Versionen bis 1.0.14 wurden bei jedem Build '
            'mit einem neuen Schlüssel signiert. Ab der korrigierten Version ist der Schlüssel fest; der Wechsel dorthin '
            'braucht einmalig eine Neuinstallation. Bitte das Protokoll schicken.');
      }
      if (vc < installedVc) throw Exception('Die APK ist älter (Code $vc) als die installierte Version (Code $installedVc)');
      if (vc == installedVc && !p.allowSameVersion) throw Exception('Die APK hat dieselbe Version wie die installierte');
      if (vc != info.build) _log('Hinweis: Versionscode $vc weicht vom Release-Tag (Build ${info.build}) ab');

      await _box.put('pendingUpdate', {'build': vc, 'tag': info.tag, 'at': DateTime.now().millisecondsSinceEpoch});

      if (p.mode == InstallMode.classic) {
        await _ch.invokeMethod('openInstaller', {'path': dl.file.path});
        phase.value = UpdatePhase.installerOpen;
        message.value = 'Bitte im Android-Dialog «Installieren» bzw. «Aktualisieren» bestätigen.';
        _log('Klassischer Installer an Android übergeben, Bestätigung erforderlich (noch keine Installation)');
      } else {
        final id = await _ch.invokeMethod<int>('installSession', {'path': dl.file.path});
        phase.value = UpdatePhase.installerOpen;
        _log('PackageInstaller-Sitzung $id übergeben, warte auf Rückmeldung von Android');
        _sessionTimeout?.cancel();
        _sessionTimeout = Timer(const Duration(seconds: 30), () async {
          if (phase.value != UpdatePhase.installerOpen) return;
          _log('Keine Rückmeldung der Sitzung nach 30 s, Sitzung wird beendet');
          try {
            await _ch.invokeMethod('abandonSession');
          } catch (_) {}
          await _box.delete('pendingUpdate');
          _fail('Die Installationssitzung hat nicht reagiert. Bitte den klassischen Installer verwenden.');
        });
      }
      // Die Sperre bleibt gehalten, bis Android ein Ergebnis meldet oder der Vorgang zurückgesetzt wird.
    } catch (e) {
      progress.value = null;
      await _box.delete('pendingUpdate');
      _fail(_err(e));
    } finally {
      client.close();
    }
  }

  /// Ereignisse aus dem Android-Teil (Ergebnis des Installers, Sitzungsstatus).
  static Future<dynamic> _onPlatformEvent(MethodCall call) async {
    final a = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'installerResult':
        final code = (a['resultCode'] as num?)?.toInt();
        final install = (a['installResult'] as num?)?.toInt();
        _log('Android-Installer beendet: resultCode $code'
            '${install != null ? ', INSTALL_RESULT $install (${installResultName(install)})' : ''}');
        if (phase.value != UpdatePhase.installerOpen) return null;
        if (code == -1) {
          _log('Android meldet Erfolg, Kontrolle folgt beim nächsten Start');
          _finish(UpdatePhase.idle, 'Android meldet die Installation als erfolgreich.');
        } else if (code == 0 && (install == null || install == -115)) {
          await _box.delete('pendingUpdate');
          _log('Im Android-Installer abgebrochen');
          _finish(UpdatePhase.cancelled, 'Installation abgebrochen. Du kannst es erneut versuchen.');
        } else {
          await _box.delete('pendingUpdate');
          _fail('Android hat die Installation abgelehnt: ${installResultName(install)}');
        }
        return null;
      case 'sessionStatus':
        final status = (a['status'] as num?)?.toInt() ?? -99;
        final msg = a['message'];
        _log('Sitzung: Status $status (${sessionStatusName(status)})${msg != null ? ', Android: $msg' : ''}');
        if (phase.value != UpdatePhase.installerOpen) return null;
        if (status == -1) {
          message.value = 'Bitte im Android-Dialog bestätigen.';
        } else if (status == 0) {
          _sessionTimeout?.cancel();
          _finish(UpdatePhase.idle, 'Android meldet die Installation als erfolgreich.');
        } else {
          _sessionTimeout?.cancel();
          await _box.delete('pendingUpdate');
          _fail('Sitzung fehlgeschlagen: ${sessionStatusName(status)}${msg != null ? ' ($msg)' : ''}');
        }
        return null;
    }
    return null;
  }

  /// Löst einen hängenden Vorgang (z.B. Installer im Hintergrund vergessen).
  static Future<void> reset() async {
    _sessionTimeout?.cancel();
    _waitingForPermission = null;
    try {
      await _ch.invokeMethod('abandonSession');
    } catch (_) {}
    await _box.delete('pendingUpdate');
    _log('Vorgang von Hand zurückgesetzt');
    _finish(UpdatePhase.idle, null);
  }

  static void _finish(UpdatePhase ph, String? msg) {
    phase.value = ph;
    message.value = msg;
    progress.value = null;
    _lock.release();
  }

  static void _fail(String msg) {
    _log('FEHLER: $msg');
    _finish(UpdatePhase.failed, msg);
  }

  static Future<bool> _canInstall() async {
    try {
      return await _ch.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  static String _err(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString().replaceFirst('Exception: ', '');
  }

  static String installResultName(int? c) => switch (c) {
        null => 'keine Angabe',
        1 => 'erfolgreich',
        -1 => 'bereits vorhanden',
        -4 => 'zu wenig Speicher',
        -7 => 'Signaturkonflikt (INSTALL_FAILED_UPDATE_INCOMPATIBLE)',
        -25 => 'Version älter als installiert (INSTALL_FAILED_VERSION_DOWNGRADE)',
        -2 || -103 => 'ungültige APK',
        -115 => 'vom Nutzer abgebrochen',
        _ => 'Code $c',
      };

  static String sessionStatusName(int s) => switch (s) {
        -1 => 'Bestätigung erforderlich',
        0 => 'erfolgreich',
        1 => 'fehlgeschlagen',
        2 => 'blockiert',
        3 => 'abgebrochen',
        4 => 'ungültige APK',
        5 => 'Konflikt (z.B. andere Signatur)',
        6 => 'zu wenig Speicher',
        7 => 'inkompatibel',
        _ => 'unbekannt',
      };
}

class _Pending {
  final UpdateInfo info;
  final InstallMode mode;
  final bool allowSameVersion;
  const _Pending(this.info, this.mode, this.allowSameVersion);
}

class _LifecycleWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Updater._onResumed();
  }
}
