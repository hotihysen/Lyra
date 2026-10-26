import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lyra/data/update_logic.dart';

/// Antwort, deren Daten in Stücken kommen; optional mit Pause oder Abbruch.
MockClient _server({
  int status = 200,
  required List<List<int>> chunks,
  int? contentLength,
  Duration? stallAfterFirst,
  Object? errorAfterFirst,
}) {
  return MockClient.streaming((req, body) async {
    final ctrl = StreamController<List<int>>();
    () async {
      for (var i = 0; i < chunks.length; i++) {
        ctrl.add(chunks[i]);
        if (i == 0 && errorAfterFirst != null) {
          ctrl.addError(errorAfterFirst);
          await ctrl.close();
          return;
        }
        if (i == 0 && stallAfterFirst != null) await Future.delayed(stallAfterFirst);
      }
      await ctrl.close();
    }();
    return http.StreamedResponse(ctrl.stream, status, contentLength: contentLength);
  });
}

List<int> _bytes(int n) => List<int>.filled(n, 7);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('lyra_update_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  List<String> filesIn(Directory d) => d.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  group('Versionsvergleich', () {
    test('Tag wird gelesen', () {
      expect(buildFromTag('v1.0.14'), 14);
      expect(buildFromTag('1.0.7'), 7);
      expect(buildFromTag(' v1.0.120 '), 120);
    });
    test('unbekannte Tags ergeben kein Update', () {
      expect(buildFromTag('build-5'), isNull);
      expect(buildFromTag('v1.0'), isNull);
      expect(buildFromTag('v1.0.x'), isNull);
      expect(buildFromTag(''), isNull);
    });
    test('nur höhere Build-Nummern sind Updates', () {
      expect(isNewer(remote: 15, installed: 14), isTrue);
      expect(isNewer(remote: 14, installed: 14), isFalse, reason: 'gleiche Version, z.B. erneuter Build');
      expect(isNewer(remote: 13, installed: 14), isFalse);
      expect(isNewer(remote: 99, installed: 0), isFalse, reason: 'Entwicklerversion bietet kein Update an');
    });
  });

  group('Sperre', () {
    test('nur ein Vorgang gleichzeitig', () {
      final lock = UpdateLock();
      expect(lock.tryAcquire('auto'), isTrue);
      expect(lock.tryAcquire('manuell'), isFalse);
      expect(lock.owner, 'auto');
      lock.release();
      expect(lock.isHeld, isFalse);
      expect(lock.tryAcquire('manuell'), isTrue, reason: 'nach Abschluss oder Fehler ist ein neuer Versuch möglich');
    });
    test('gleichzeitige Aufrufe: genau einer kommt durch', () async {
      final lock = UpdateLock();
      final results = await Future.wait(List.generate(5, (i) async {
        await Future.delayed(Duration(milliseconds: i));
        return lock.tryAcquire('Aufruf $i');
      }));
      expect(results.where((r) => r).length, 1);
    });
  });

  group('Download', () {
    test('vollständiger Download wird als .apk bereitgestellt', () async {
      final client = _server(chunks: [_bytes(600), _bytes(400)], contentLength: 1000);
      final r = await downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'Lyra-v1.0.15', expectedSize: 1000);
      expect(r.bytes, 1000);
      expect(r.file.lengthSync(), 1000);
      expect(r.file.path.endsWith('.apk'), isTrue);
      expect(filesIn(dir).where((f) => f.endsWith('.part')), isEmpty);
    });

    test('Fortschritt wird gemeldet', () async {
      final seen = <int>[];
      final client = _server(chunks: [_bytes(500), _bytes(500)], contentLength: 1000);
      await downloadApk(
          client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000, onProgress: (g, t) => seen.add(g));
      expect(seen, [500, 1000]);
    });

    test('unvollständiger Download wird verworfen', () async {
      final client = _server(chunks: [_bytes(700)], contentLength: null);
      await expectLater(
        downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('unvollständig'))),
      );
      expect(filesIn(dir), isEmpty, reason: 'keine .apk und keine .part-Datei');
    });

    test('Abbruch mitten im Download wird verworfen', () async {
      final client = _server(chunks: [_bytes(300), _bytes(700)], contentLength: 1000, errorAfterFirst: const SocketException('Verbindung weg'));
      await expectLater(
        downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('abgebrochen'))),
      );
      expect(filesIn(dir), isEmpty);
    });

    test('Stillstand löst Zeitüberschreitung aus', () async {
      final client = _server(chunks: [_bytes(100), _bytes(900)], contentLength: 1000, stallAfterFirst: const Duration(milliseconds: 400));
      await expectLater(
        downloadApk(
            client: client,
            url: Uri.parse('https://x/a.apk'),
            dir: dir,
            baseName: 'L',
            expectedSize: 1000,
            stallTimeout: const Duration(milliseconds: 100)),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('still'))),
      );
      expect(filesIn(dir), isEmpty);
    });

    test('HTTP-Fehler wird gemeldet', () async {
      final client = _server(status: 404, chunks: [_bytes(10)], contentLength: 10);
      await expectLater(
        downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('404'))),
      );
      expect(filesIn(dir), isEmpty);
    });

    test('falsche angekündigte Grösse wird abgelehnt', () async {
      final client = _server(chunks: [_bytes(900)], contentLength: 900);
      await expectLater(
        downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000),
        throwsA(isA<DownloadException>().having((e) => e.message, 'message', contains('Grösse'))),
      );
    });

    test('zu viele Daten werden abgelehnt', () async {
      final client = _server(chunks: [_bytes(800), _bytes(800)], contentLength: null);
      await expectLater(
        downloadApk(client: client, url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 1000),
        throwsA(isA<DownloadException>()),
      );
      expect(filesIn(dir), isEmpty);
    });

    test('jeder Download bekommt einen eigenen Dateinamen', () async {
      var t = 1000;
      DateTime clock() => DateTime.fromMillisecondsSinceEpoch(t++);
      final a = await downloadApk(
          client: _server(chunks: [_bytes(10)], contentLength: 10), url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 10, now: clock);
      final b = await downloadApk(
          client: _server(chunks: [_bytes(10)], contentLength: 10), url: Uri.parse('https://x/a.apk'), dir: dir, baseName: 'L', expectedSize: 10, now: clock);
      expect(a.file.path, isNot(b.file.path));
      expect(a.file.existsSync() && b.file.existsSync(), isTrue);
    });
  });

  group('Aufräumen', () {
    test('löscht alte Dateien, behält die angegebene', () {
      final keep = File('${dir.path}/neu.apk')..writeAsStringSync('x');
      File('${dir.path}/alt.apk').writeAsStringSync('x');
      File('${dir.path}/abgebrochen.apk.part').writeAsStringSync('x');
      File('${dir.path}/andere.txt').writeAsStringSync('x');
      final n = cleanupUpdateDir(dir, keep: {keep.path});
      expect(n, 2);
      expect(filesIn(dir), ['andere.txt', 'neu.apk']);
    });
    test('fehlender Ordner ist kein Fehler', () {
      expect(cleanupUpdateDir(Directory('${dir.path}/gibts-nicht')), 0);
    });
  });
}
