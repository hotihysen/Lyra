// Plattformunabhängiger Kern der Update-Funktion: Versionsvergleich, Sperre,
// Download mit Prüfungen und Aufräumen. Ohne Flutter- oder Android-Abhängigkeit,
// damit er mit `flutter test` geprüft werden kann.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Build-Nummer aus einem Release-Tag der Form `v1.0.<Build>` (auch ohne `v`).
/// Andere Formen liefern null, damit nie aus einem unbekannten Tag ein Update abgeleitet wird.
int? buildFromTag(String tag) {
  final m = RegExp(r'^v?\d+\.\d+\.(\d+)$').firstMatch(tag.trim());
  return m == null ? null : int.parse(m.group(1)!);
}

/// Nur eine echte, höhere Build-Nummer ist ein Update. Eine Entwicklerversion (Build 0)
/// bietet nie ein Update an, sonst würde sie sich selbst überschreiben.
bool isNewer({required int remote, required int installed}) => installed > 0 && remote > installed;

/// Höchstens ein Update-Vorgang gleichzeitig. Die Sperre wird nicht automatisch
/// freigegeben, sondern erst, wenn der Vorgang wirklich beendet ist (auch nach
/// dem Öffnen des Android-Installers bleibt sie gehalten).
class UpdateLock {
  bool _held = false;
  String? _owner;

  bool get isHeld => _held;
  String? get owner => _owner;

  /// true, wenn der Aufrufer die Sperre erhalten hat.
  bool tryAcquire(String owner) {
    if (_held) return false;
    _held = true;
    _owner = owner;
    return true;
  }

  void release() {
    _held = false;
    _owner = null;
  }
}

class DownloadException implements Exception {
  final String message;
  const DownloadException(this.message);
  @override
  String toString() => message;
}

class DownloadedApk {
  final File file;
  final int bytes;
  const DownloadedApk(this.file, this.bytes);
}

/// Lädt die APK in eine temporäre `.part`-Datei und benennt sie erst nach allen
/// Prüfungen in `.apk` um. Eine unvollständige Datei wird nie als APK bereitgestellt.
Future<DownloadedApk> downloadApk({
  required http.Client client,
  required Uri url,
  required Directory dir,
  required String baseName,
  required int expectedSize,
  void Function(int received, int total)? onProgress,
  Duration connectTimeout = const Duration(seconds: 20),
  Duration stallTimeout = const Duration(seconds: 30),
  DateTime Function() now = DateTime.now,
}) async {
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final stamp = now().millisecondsSinceEpoch;
  final part = File('${dir.path}/$baseName-$stamp.apk.part');
  final done = File('${dir.path}/$baseName-$stamp.apk');

  http.StreamedResponse res;
  try {
    res = await client.send(http.Request('GET', url)).timeout(connectTimeout);
  } on TimeoutException {
    throw const DownloadException('Keine Antwort vom Server (Zeitüberschreitung beim Verbinden)');
  } on SocketException catch (e) {
    throw DownloadException('Keine Netzwerkverbindung (${e.message})');
  } on http.ClientException catch (e) {
    throw DownloadException('Verbindungsfehler (${e.message})');
  }

  if (res.statusCode != 200) {
    // Antwort verwerfen, damit die Verbindung frei wird
    unawaited(res.stream.drain<void>().catchError((_) {}));
    throw DownloadException('Server antwortet mit HTTP ${res.statusCode}');
  }
  final announced = res.contentLength;
  if (expectedSize > 0 && announced != null && announced != expectedSize) {
    unawaited(res.stream.drain<void>().catchError((_) {}));
    throw DownloadException('Grösse passt nicht: Server meldet $announced Bytes, Release nennt $expectedSize Bytes');
  }
  final total = expectedSize > 0 ? expectedSize : (announced ?? 0);

  final sink = part.openWrite();
  var got = 0;
  Object? failure;
  try {
    await for (final chunk in res.stream.timeout(stallTimeout)) {
      got += chunk.length;
      if (total > 0 && got > total) {
        throw DownloadException('Mehr Daten als erwartet ($got > $total Bytes)');
      }
      sink.add(chunk);
      onProgress?.call(got, total);
    }
    await sink.flush();
  } catch (e) {
    failure = e;
  } finally {
    try {
      await sink.close();
    } catch (_) {}
  }

  if (failure != null) {
    _deleteQuietly(part);
    if (failure is DownloadException) throw failure;
    if (failure is TimeoutException) {
      throw DownloadException('Download steht seit ${stallTimeout.inSeconds} s still und wurde abgebrochen ($got Bytes erhalten)');
    }
    throw DownloadException('Download abgebrochen nach $got Bytes ($failure)');
  }
  if (got == 0) {
    _deleteQuietly(part);
    throw const DownloadException('Leere Antwort vom Server');
  }
  if (total > 0 && got != total) {
    _deleteQuietly(part);
    throw DownloadException('Download unvollständig: $got von $total Bytes');
  }
  final apk = await part.rename(done.path);
  return DownloadedApk(apk, got);
}

/// Löscht alte Update-Dateien, ausser den ausdrücklich behaltenen.
/// Nur aufrufen, wenn kein Vorgang läuft (sonst `.part`-Dateien eines laufenden Downloads).
int cleanupUpdateDir(Directory dir, {Set<String> keep = const {}}) {
  if (!dir.existsSync()) return 0;
  var n = 0;
  for (final e in dir.listSync()) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    if (keep.contains(e.path)) continue;
    if (name.endsWith('.apk') || name.endsWith('.apk.part')) {
      _deleteQuietly(e);
      n++;
    }
  }
  return n;
}

void _deleteQuietly(File f) {
  try {
    if (f.existsSync()) f.deleteSync();
  } catch (_) {}
}
