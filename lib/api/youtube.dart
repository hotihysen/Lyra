import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../data/models.dart';
import 'invidious.dart';
import 'server.dart';
import 'ytmusic.dart';
import '../data/store.dart';

/// Ein Abrufweg zu YouTube (verschiedene App-Kennungen werden unterschiedlich behandelt).
class YtClientOption {
  final String name;
  final List<YoutubeApiClient>? clients;
  const YtClientOption(this.name, this.clients);
}

final ytClientOptions = <YtClientOption>[
  YtClientOption('androidVr', [YoutubeApiClient.androidVr]),
  YtClientOption('ios', [YoutubeApiClient.ios]),
  YtClientOption('tv', [YoutubeApiClient.tv]),
  YtClientOption('mweb', [YoutubeApiClient.mweb]),
  YtClientOption('safari', [YoutubeApiClient.safari]),
  YtClientOption('android', [YoutubeApiClient.android]),
  const YtClientOption('standard', null),
];

class YtResolved {
  final String videoId;
  final AudioOnlyStreamInfo info;
  final String client;
  const YtResolved(this.videoId, this.info, this.client);
  String get mime => info.container.name.toLowerCase() == 'webm' ? 'audio/webm' : 'audio/mp4';
  String get ext => info.container.name.toLowerCase() == 'webm' ? 'webm' : 'm4a';
}

/// Datei, die im Hintergrund geladen wird, während der Player schon daraus liest.
class _Progressive {
  final File file;
  int total;
  int written = 0;
  bool done = false;
  Object? error;
  final _changes = StreamController<void>.broadcast();

  _Progressive(this.file, this.total);

  bool cancelled = false;
  http.Client? _client;
  DateTime lastUse = DateTime.now();

  /// Bricht den Abruf ab (nicht mehr benötigt). Liest der Player noch, bekommt er einen Fehler.
  void cancel() {
    if (done || cancelled) return;
    cancelled = true;
    error ??= Exception('Abruf abgebrochen');
    try {
      _client?.close();
    } catch (_) {}
    _changes.add(null);
  }

  Future<void> run(Stream<List<int>> source) async {
    final raf = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in source.timeout(const Duration(seconds: 20))) {
        if (cancelled) throw Exception('Abruf abgebrochen');
        await raf.writeFrom(chunk);
        written += chunk.length;
        _changes.add(null);
      }
      done = true;
    } catch (e) {
      error = e;
    } finally {
      await raf.close();
      _changes.add(null);
    }
  }

  /// Lädt per HTTP und setzt nach Verbindungsabbrüchen an derselben Stelle fort.
  Future<void> runHttp(Uri url, Map<String, String> headers, {Duration sendTimeout = const Duration(seconds: 20)}) async {
    final raf = await file.open(mode: FileMode.write);
    var failures = 0;
    try {
      while (true) {
        if (cancelled) return;
        final client = http.Client();
        _client = client;
        try {
          final req = http.Request('GET', url)..headers.addAll({...headers, 'Range': 'bytes=$written-'});
          final res = await client.send(req).timeout(sendTimeout);
          if (res.statusCode != 200 && res.statusCode != 206) throw Exception('Server ${res.statusCode}');
          if (res.statusCode == 200 && written > 0) {
            // Server kann nicht fortsetzen: von vorne
            written = 0;
            await raf.setPosition(0);
          }
          if (res.statusCode == 206) {
            // Teilantwort muss genau an der gewünschten Stelle beginnen
            final cr = res.headers['content-range'] ?? '';
            final m = RegExp(r'bytes\s+(\d+)-').firstMatch(cr);
            final start = m == null ? -1 : int.parse(m.group(1)!);
            if (start != written) {
              written = 0;
              await raf.setPosition(0);
              if (start != 0) throw Exception('Teilantwort ab falscher Stelle');
            }
          }
          if (total <= 0) {
            final cr = res.headers['content-range'];
            final m = cr == null ? null : RegExp(r'/(\d+)').firstMatch(cr);
            total = m != null ? int.parse(m.group(1)!) : (res.contentLength ?? 0) + written;
          }
          await for (final chunk in res.stream.timeout(const Duration(seconds: 20))) {
            if (cancelled) return;
            await raf.writeFrom(chunk);
            written += chunk.length;
            failures = 0;
            _changes.add(null);
          }
          if (total > 0 && written < total) throw Exception('Verbindung abgebrochen');
          done = true;
          return;
        } catch (e) {
          if (cancelled) return;
          failures++;
          if (failures > 4) {
            error = e;
            return;
          }
          await Future.delayed(Duration(milliseconds: 600 * failures));
        } finally {
          client.close();
        }
      }
    } finally {
      await raf.close();
      _changes.add(null);
    }
  }

  Future<void> waitForChange() =>
      _changes.stream.first.timeout(const Duration(seconds: 15), onTimeout: () {});

  /// Wartet, bis die ersten Bytes da sind (oder ein Fehler).
  Future<void> waitForStart([Duration max = const Duration(seconds: 20)]) async {
    final until = DateTime.now().add(max);
    while (written == 0 && error == null && !done) {
      if (DateTime.now().isAfter(until)) throw TimeoutException('Keine Daten vom Server');
      await waitForChange();
    }
    if (written == 0 && error != null) throw error!;
  }
}

class _ProgressiveSource extends StreamAudioSource {
  final _Progressive p;
  final String mime;
  _ProgressiveSource(this.p, this.mime) : super(tag: null);

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0;
    var e = end ?? p.total;
    if (e > p.total) e = p.total;
    return StreamAudioResponse(
      sourceLength: p.total,
      contentLength: e - s,
      offset: s,
      stream: _read(s, e),
      contentType: mime,
    );
  }

  Stream<List<int>> _read(int start, int end) async* {
    final raf = await p.file.open();
    try {
      var pos = start;
      while (pos < end) {
        final avail = math.min(p.written, end);
        if (pos < avail) {
          await raf.setPosition(pos);
          final bytes = await raf.read(math.min(64 * 1024, avail - pos));
          if (bytes.isEmpty) {
            await Future.delayed(const Duration(milliseconds: 30));
            continue;
          }
          pos += bytes.length;
          yield bytes;
        } else if (p.done) {
          break;
        } else if (p.error != null) {
          throw p.error!;
        } else {
          await p.waitForChange();
        }
      }
    } finally {
      await raf.close();
    }
  }
}

class _Resolved {
  final _Progressive p;
  final String mime;
  final String way;
  const _Resolved(this.p, this.mime, this.way);
}

/// Liefert das Audio zur YouTube-Music-Video-ID eines Titels.
class YT {
  static final _yt = YoutubeExplode();
  static final _manifests = <String, (DateTime, YtResolved)>{};
  static final _cache = <String, _Progressive>{};
  static String? preferredClient;
  static String lastError = '';

  static const _ch = MethodChannel('ch.hysen.lyra/extract');

  /// Native Extraktion (PipePipe / BravePipe) im Android-Teil der App.
  static Future<({Uri url, String mime, String ext, String ua, String source})> native(String vid) async {
    if (!Platform.isAndroid) throw Exception('nur auf Android');
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('audio', {'id': vid}).timeout(const Duration(seconds: 40));
      if (r == null) throw Exception('keine Antwort');
      final itag = (r['itag'] as num?)?.toInt() ?? 140;
      final webm = itag == 251 || itag == 250 || itag == 249;
      return (
        url: Uri.parse('${r['url']}'),
        mime: webm ? 'audio/webm' : 'audio/mp4',
        ext: webm ? 'webm' : 'm4a',
        ua: '${r['ua'] ?? 'Mozilla/5.0'}',
        source: '${r['source'] ?? ''}',
      );
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    }
  }

  /// Die Video-ID, die abgespielt wird. Wie bei Lyra Music: Titel aus YouTube Music tragen ihre
  /// ID selbst und werden genau so abgespielt, ohne Suche. Nur alte Titel ohne ID (aus der früheren
  /// Deezer-Zeit) werden einmal in YouTube Music gesucht und die Zuordnung gespeichert.
  static Future<List<String>> candidates(Track t) async {
    if (t.isYouTube) return [t.id];
    final cached = Store.instance.ytIds[t.id];
    if (cached != null) return [cached];
    final vid = await YTMusic.findVideoId(t);
    if (vid == null) throw Exception('In YouTube Music nicht gefunden');
    Store.instance.setYt(t.id, vid);
    return [vid];
  }

  static Future<YtResolved> _manifest(String vid, YtClientOption o) async {
    final m = o.clients == null
        ? await _yt.videos.streamsClient.getManifest(vid)
        : await _yt.videos.streamsClient.getManifest(vid, ytClients: o.clients!);
    final audio = m.audioOnly.toList();
    if (audio.isEmpty) throw Exception('kein Audio im Manifest');
    final mp4 = audio.where((s) => s.container == StreamContainer.mp4).toList();
    final pool = mp4.isNotEmpty ? mp4 : audio;
    pool.sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    return YtResolved(vid, pool.first, o.name);
  }

  static List<YtClientOption> _orderedClients() {
    final list = List.of(ytClientOptions);
    final pref = preferredClient ?? Store.instance.ytClient;
    final i = list.indexWhere((o) => o.name == pref);
    if (i > 0) list.insert(0, list.removeAt(i));
    return list;
  }

  static String _short(Object e) {
    final s = e.toString().split('\n').first;
    return s.length > 90 ? '${s.substring(0, 90)}…' : s;
  }

  /// Probiert Videos und Abrufwege der Reihe nach durch, bis ein Stream wirklich Daten liefert.
  static Future<(YtResolved, _Progressive)> _open(Track t, {List<String>? ids, List<String>? earlier}) async {
    final errors = <String>[...?earlier];
    ids ??= await candidates(t);
    if (ids.isEmpty) throw Exception('Kein passendes Video gefunden');
    for (final vid in ids.take(3)) {
      for (final o in _orderedClients()) {
        try {
          final key = '$vid|${o.name}';
          final hit = _manifests[key];
          final r = (hit != null && DateTime.now().difference(hit.$1).inHours < 3) ? hit.$2 : await _manifest(vid, o);
          _manifests[key] = (DateTime.now(), r);
          final total = r.info.size.totalBytes;
          final p = _Progressive(await _tempFile('stream', t, r.ext), total);
          unawaited(p.run(_yt.videos.streamsClient.get(r.info)));
          try {
            await p.waitForStart();
          } catch (_) {
            p.cancel();
            rethrow;
          }
          Store.instance.setYt(t.id, vid);
          if (Store.instance.ytClient != o.name) Store.instance.setYtClient(o.name);
          return (r, p);
        } catch (e) {
          errors.add('${o.name}: ${_short(e)}');
          _manifests.remove('$vid|${o.name}');
        }
      }
    }
    lastError = errors.join('\n');
    throw Exception('Kein Abrufweg hat Audio geliefert');
  }

  /// Zuletzt gewählter Abrufweg (für das Wiedergabeprotokoll, ohne Adressen).
  static String lastWay = '';

  /// Titel, deren Dateien gerade gespielt oder vorbereitet werden; werden nicht gelöscht.
  static final inUse = <String>{};

  /// Laufende Abrufe je Titel: gleichzeitige Anfragen (Vorladen und Laden) teilen sich einen.
  static final _inflight = <String, Future<_Resolved>>{};
  static int _fileSeq = 0;

  /// Vergisst alles Zwischengespeicherte zu einem Titel (für einen Versuch mit frischer Quelle).
  static void forget(Track t) {
    final p = _cache.remove(t.id);
    p?.cancel();
    _inflight.remove(t.id);
    _manifests.removeWhere((k, _) => k.startsWith('${Store.instance.ytIds[t.id] ?? t.id}|'));
  }

  static Future<File> _tempFile(String prefix, Track t, String ext) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/${prefix}_${t.id}_${DateTime.now().millisecondsSinceEpoch}_${_fileSeq++}.$ext');
  }

  /// Startet einen Abruf über HTTP in eine eigene Datei und wartet auf die ersten Bytes.
  static Future<_Resolved> _http(Track t, String prefix, String way, Uri url, Map<String, String> headers, String mime,
      {int size = 0, Duration wait = const Duration(seconds: 20)}) async {
    final ext = mime == 'audio/webm' ? 'webm' : 'm4a';
    final p = _Progressive(await _tempFile(prefix, t, ext), size);
    unawaited(p.runHttp(url, headers, sendTimeout: wait));
    try {
      await p.waitForStart(wait);
    } catch (e) {
      p.cancel();
      rethrow;
    }
    if (p.total <= 0) {
      // Grösse unbekannt: vollständig laden, dann als Datei abspielen
      while (!p.done && p.error == null) {
        await p.waitForChange();
      }
      if (p.error != null) throw p.error!;
    }
    return _Resolved(p, mime, way);
  }

  /// Der eigene Server lädt beim ersten Abruf den ganzen Song, deshalb länger warten.
  static const _serverWait = Duration(seconds: 60);

  /// Audioquelle für den Player: wird gestreamt und gleichzeitig zwischengespeichert.
  /// Reihenfolge auf Android: Extraktoren, eigener Server, Invidious, direkt.
  /// Auf dem iPhone: eigener Server, Invidious (nur AAC), direkt.
  /// [budget] begrenzt die gesamte Suche; danach wird kein weiterer Weg mehr begonnen.
  static Future<AudioSource> audioSource(Track t, {Duration budget = const Duration(seconds: 60)}) async {
    final old = _cache[t.id];
    if (old != null && old.done && old.error == null && old.file.existsSync()) {
      old.lastUse = DateTime.now();
      lastWay = 'Zwischenspeicher';
      return AudioSource.file(old.file.path);
    }
    final running = _inflight[t.id];
    final f = running ?? _resolve(t, DateTime.now().add(budget));
    if (running == null) {
      _inflight[t.id] = f;
      unawaited(f.then((_) {}, onError: (_) {}).whenComplete(() {
        if (identical(_inflight[t.id], f)) _inflight.remove(t.id);
      }));
    }
    final r = await f;
    lastWay = r.way;
    final p = r.p;
    p.lastUse = DateTime.now();
    if (p.total <= 0 || p.done) return AudioSource.file(p.file.path);
    // Jeder Player bekommt seine eigene Quelle, auch wenn die Datei geteilt wird
    return _ProgressiveSource(p, r.mime);
  }

  static Future<_Resolved> _resolve(Track t, DateTime deadline) async {
    Duration left() => deadline.difference(DateTime.now());
    bool timeUp() => left() <= const Duration(seconds: 2);
    Duration cap(Duration d) => left() < d ? left() : d;

    final errors = <String>[];
    final ids = await candidates(t).timeout(cap(const Duration(seconds: 15)));
    if (ids.isEmpty) throw Exception('Kein passendes Video gefunden');
    final vid = ids.first;

    Future<_Resolved> done(_Resolved r) async {
      Store.instance.setYt(t.id, vid);
      final prev = _cache[t.id];
      if (prev != null && !identical(prev, r.p) && !inUse.contains(t.id)) prev.cancel();
      _cache[t.id] = r.p;
      _trimCache();
      return r;
    }

    if (Platform.isAndroid && !timeUp()) {
      // 1. Wie SimpMusic: native Extraktoren (PipePipe, BravePipe)
      try {
        final n = await native(vid).timeout(cap(const Duration(seconds: 30)));
        return await done(await _http(t, 'yt', 'Extraktor (${n.source})', n.url, {'User-Agent': n.ua}, n.mime,
            wait: cap(const Duration(seconds: 20))));
      } catch (e) {
        errors.add('Extraktor: ${_short(e)}');
      }
    }
    if (LyraServer.configured && !timeUp()) {
      try {
        return await done(await _http(t, 'srv', 'Eigener Server', LyraServer.audioUrl(vid), LyraServer.headers, 'audio/mp4',
            wait: cap(_serverWait)));
      } catch (e) {
        errors.add('Eigener Server: ${_short(e)}');
      }
    }
    if (!timeUp()) {
      try {
        final a = await Invidious.audio(vid, errors: errors).timeout(cap(const Duration(seconds: 25)));
        if (!Platform.isAndroid && a.mime == 'audio/webm') throw Exception('nur WebM, auf dem iPhone nicht abspielbar');
        return await done(await _http(t, 'inv', 'Invidious', a.url, const {'User-Agent': 'Mozilla/5.0 (Linux; Android 14) Lyra/1.0'},
            a.mime, size: a.size, wait: cap(const Duration(seconds: 20))));
      } catch (e) {
        errors.add('Invidious: ${_short(e)}');
      }
    }
    if (!timeUp()) {
      try {
        final (r, p) = await _open(t, ids: [vid], earlier: errors).timeout(cap(const Duration(seconds: 40)));
        if (p.total <= 0) {
          while (!p.done && p.error == null) {
            await p.waitForChange();
          }
          if (p.error != null) throw p.error!;
        }
        return await done(_Resolved(p, r.mime, 'Direkt (${r.client})'));
      } catch (e) {
        errors.add('Direkt: ${_short(e)}');
      }
    }
    lastError = errors.join('\n');
    throw Exception(timeUp() ? 'Zeitlimit für die Quellensuche erreicht' : 'Kein Abrufweg hat Audio geliefert');
  }

  /// Hält höchstens 6 Dateien; nie gelöscht wird, was gerade gespielt oder vorbereitet wird
  /// oder noch geladen wird. Ältere temporäre Dateien werden beim Start aufgeräumt.
  static void _trimCache() {
    if (_cache.length <= 6) return;
    final entries = _cache.entries.where((e) => !inUse.contains(e.key)).toList()
      ..sort((a, b) => a.value.lastUse.compareTo(b.value.lastUse));
    for (final e in entries.take(_cache.length - 6)) {
      final p = e.value;
      if (!(p.done || p.error != null)) continue;
      _cache.remove(e.key);
      try {
        p.file.deleteSync();
      } catch (_) {}
    }
  }

  /// Entfernt temporäre Audiodateien, die älter als ein Tag sind oder zusammen 400 MB übersteigen.
  static Future<void> cleanTemp() async {
    try {
      final dir = await getTemporaryDirectory();
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'^(yt|srv|inv|stream)_.*\.(m4a|webm)$').hasMatch(f.uri.pathSegments.last))
          .toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      var total = 0;
      final now = DateTime.now();
      for (final f in files) {
        final st = f.statSync();
        total += st.size;
        if (now.difference(st.modified) > const Duration(days: 1) || total > 400 * 1024 * 1024) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Future<void> download(Track t, File f, void Function(double) onProgress) async {
    final cached = _cache[t.id];
    if (cached != null && cached.done && cached.error == null && cached.file.existsSync()) {
      await cached.file.copy(f.path);
      onProgress(1);
      return;
    }
    final ids = await candidates(t);
    final vid = ids.first;

    Future<bool> viaHttp(Uri url, Map<String, String> headers, {Duration wait = const Duration(seconds: 20)}) async {
      final p = _Progressive(File('${f.path}.part'), 0);
      final run = p.runHttp(url, headers, sendTimeout: wait);
      while (!p.done && p.error == null) {
        if (p.total > 0) onProgress(p.written / p.total);
        await Future.any([run, p.waitForChange()]);
      }
      // Nur eine vollständig geladene Datei gilt als Download
      if (p.done && p.error == null && p.written > 0) {
        await p.file.rename(f.path);
        return true;
      }
      try {
        p.file.deleteSync();
      } catch (_) {}
      return false;
    }

    if (Platform.isAndroid) {
      try {
        final n = await native(vid);
        if (await viaHttp(n.url, {'User-Agent': n.ua})) return;
      } catch (_) {}
    }
    if (LyraServer.configured) {
      try {
        onProgress(0.01);
        if (await viaHttp(LyraServer.audioUrl(vid), LyraServer.headers, wait: _serverWait)) return;
      } catch (_) {}
    }
    try {
      final a = await Invidious.audio(vid);
      if (Platform.isAndroid || a.mime != 'audio/webm') {
        await _httpDownload(a.url, f, onProgress);
        return;
      }
    } catch (_) {}
    final (_, p) = await _open(t);
    _cache[t.id] = p;
    while (!p.done && p.error == null) {
      if (p.total > 0) onProgress(p.written / p.total);
      await p.waitForChange();
    }
    if (p.error != null) throw p.error!;
    await p.file.copy(f.path);
  }

  static Future<void> _httpDownload(Uri u, File f, void Function(double) onP) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', u)..headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) Lyra/1.0');
      if (res.statusCode >= 400) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength ?? 0;
      final tmp = File('${f.path}.part');
      final sink = tmp.openWrite();
      var got = 0;
      try {
        await for (final c in res.stream.timeout(const Duration(seconds: 20))) {
          got += c.length;
          sink.add(c);
          if (total > 0) onP(got / total);
        }
      } finally {
        await sink.close();
      }
      if (got == 0) throw Exception('leere Datei');
      if (total > 0 && got < total) throw Exception('Download unvollständig');
      await tmp.rename(f.path);
    } finally {
      client.close();
    }
  }

  // ---------- Diagnose (in den Einstellungen) ----------

  static Future<List<String>> diagnose(void Function(String) log) async {
    final out = <String>[];
    void add(String s) {
      out.add(s);
      log(s);
    }

    String vid;
    try {
      final r = await _yt.search.search('Daft Punk Get Lucky audio');
      vid = r.first.id.value;
      add('Suche: ok (${r.length} Treffer), Video $vid');
    } catch (e) {
      add('Suche: FEHLER ${_short(e)}');
      return out;
    }
    if (LyraServer.configured) {
      add('Eigener Server: ${await LyraServer.test()}');
      try {
        final sw = Stopwatch()..start();
        final r = await http
            .get(LyraServer.audioUrl(vid), headers: {...LyraServer.headers, 'Range': 'bytes=0-1023'})
            .timeout(_serverWait);
        add(r.statusCode == 206 || r.statusCode == 200
            ? 'Eigener Server: Audio ok in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s'
            : 'Eigener Server: Audio FEHLER ${r.statusCode} ${utf8.decode(r.bodyBytes, allowMalformed: true)}');
      } catch (e) {
        add('Eigener Server: Audio FEHLER ${_short(e)}');
      }
    } else {
      add('Eigener Server: nicht eingerichtet');
    }
    if (Platform.isAndroid) try {
      final sw = Stopwatch()..start();
      final n = await native(vid);
      add('Extraktor (wie SimpMusic): ok über ${n.source} in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    } catch (e) {
      for (final l in e.toString().replaceFirst('Exception: ', '').split('\n')) {
        add('Extraktor FEHLER $l');
      }
    }
    final invErr = <String>[];
    try {
      final a = await Invidious.audio(vid, errors: invErr);
      for (final e in invErr) {
        add('Invidious ${e.replaceAll('Exception: ', '')} (FEHLER)');
      }
      add('Invidious: ok über ${Uri.parse(a.host).host} (${a.mime})');
    } catch (e) {
      for (final e in invErr) {
        add('Invidious ${e.replaceAll('Exception: ', '')} (FEHLER)');
      }
      add('Invidious: FEHLER ${_short(e)}');
    }
    add('Direkt bei YouTube (Reserve):');
    for (final o in ytClientOptions.take(3)) {
      try {
        final r = await _manifest(vid, o);
        var got = 0;
        try {
          await for (final c in _yt.videos.streamsClient.get(r.info).timeout(const Duration(seconds: 15))) {
            got += c.length;
            if (got > 200000) break;
          }
          add('${o.name}: Manifest ok, Stream ${got > 0 ? 'ok' : 'leer'} (${(got / 1024).round()} KB, ${r.info.container.name})');
        } catch (e) {
          add('${o.name}: Manifest ok, Stream FEHLER ${_short(e)}');
        }
      } catch (e) {
        add('${o.name}: Manifest FEHLER ${_short(e)}');
      }
    }
    return out;
  }
}
