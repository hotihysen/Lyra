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

  Future<void> run(Stream<List<int>> source) async {
    final raf = await file.open(mode: FileMode.write);
    try {
      await for (final chunk in source) {
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
        final client = http.Client();
        try {
          final req = http.Request('GET', url)..headers.addAll({...headers, 'Range': 'bytes=$written-'});
          final res = await client.send(req).timeout(sendTimeout);
          if (res.statusCode != 200 && res.statusCode != 206) throw Exception('Server ${res.statusCode}');
          if (res.statusCode == 200 && written > 0) {
            // Server kann nicht fortsetzen: von vorne
            written = 0;
            await raf.setPosition(0);
          }
          if (total <= 0) {
            final cr = res.headers['content-range'];
            final m = cr == null ? null : RegExp(r'/(\d+)').firstMatch(cr);
            total = m != null ? int.parse(m.group(1)!) : (res.contentLength ?? 0) + written;
          }
          await for (final chunk in res.stream.timeout(const Duration(seconds: 20))) {
            await raf.writeFrom(chunk);
            written += chunk.length;
            failures = 0;
            _changes.add(null);
          }
          if (total > 0 && written < total) throw Exception('Verbindung abgebrochen');
          done = true;
          return;
        } catch (e) {
          failures++;
          if (failures > 6) {
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
          final dir = await getTemporaryDirectory();
          final f = File('${dir.path}/stream_${t.id}_${r.client}.${r.ext}');
          final p = _Progressive(f, total);
          unawaited(p.run(_yt.videos.streamsClient.get(r.info)));
          await p.waitForStart();
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

  /// Lädt [url] in eine Datei, während der Player schon daraus liest.
  static Future<AudioSource> _stream(Track t, String prefix, Uri url, Map<String, String> headers, String mime,
      {int size = 0, Duration wait = const Duration(seconds: 20)}) async {
    final dir = await getTemporaryDirectory();
    final ext = mime == 'audio/webm' ? 'webm' : 'm4a';
    final p = _Progressive(File('${dir.path}/${prefix}_${t.id}.$ext'), size);
    unawaited(p.runHttp(url, headers, sendTimeout: wait));
    await p.waitForStart(wait);
    _cache[t.id] = p;
    _trimCache();
    if (p.total <= 0) {
      // Grösse unbekannt: warten, bis die Datei vollständig ist.
      while (!p.done && p.error == null) {
        await p.waitForChange();
      }
      if (p.error != null) throw p.error!;
      return AudioSource.file(p.file.path);
    }
    return _ProgressiveSource(p, mime);
  }

  /// Der eigene Server lädt beim ersten Abruf den ganzen Song, deshalb länger warten.
  static const _serverWait = Duration(seconds: 90);

  /// Audioquelle für den Player: wird gestreamt und gleichzeitig zwischengespeichert.
  /// Reihenfolge auf Android: Extraktoren, eigener Server, Invidious, direkt.
  /// Auf dem iPhone: eigener Server, Invidious (nur AAC), direkt.
  static Future<AudioSource> audioSource(Track t) async {
    final old = _cache[t.id];
    if (old != null && old.done && old.file.existsSync()) {
      return AudioSource.file(old.file.path);
    }
    final errors = <String>[];
    final ids = await candidates(t);
    if (ids.isEmpty) throw Exception('Kein passendes Video gefunden');
    final vid = ids.first;

    Future<AudioSource?> viaServer() async {
      if (!LyraServer.configured) return null;
      try {
        final a = await _stream(t, 'srv', LyraServer.audioUrl(vid), LyraServer.headers, 'audio/mp4', wait: _serverWait);
        Store.instance.setYt(t.id, vid);
        return a;
      } catch (e) {
        errors.add('Eigener Server: ${_short(e)}');
        return null;
      }
    }

    if (Platform.isAndroid) {
      // 1. Wie SimpMusic: native Extraktoren (PipePipe, BravePipe)
      try {
        final n = await native(vid);
        Store.instance.setYt(t.id, vid);
        return await _stream(t, 'yt', n.url, {'User-Agent': n.ua}, n.mime);
      } catch (e) {
        errors.add('Extraktor: ${_short(e)}');
      }
    }
    final srv = await viaServer();
    if (srv != null) return srv;
    // Invidious-Server
    try {
      final a = await Invidious.audio(vid, errors: errors);
      if (!Platform.isAndroid && a.mime == 'audio/webm') throw Exception('nur WebM, auf dem iPhone nicht abspielbar');
      Store.instance.setYt(t.id, vid);
      return await _stream(t, 'inv', a.url, const {'User-Agent': 'Mozilla/5.0 (Linux; Android 14) Lyra/1.0'}, a.mime,
          size: a.size);
    } catch (e) {
      errors.add('Invidious: ${_short(e)}');
    }
    // Reserve: direkt bei YouTube
    final (r, p) = await _open(t, ids: [vid], earlier: errors);
    _cache[t.id] = p;
    _trimCache();
    if (p.total <= 0) {
      while (!p.done && p.error == null) {
        await p.waitForChange();
      }
      if (p.error != null) throw p.error!;
      return AudioSource.file(p.file.path);
    }
    return _ProgressiveSource(p, r.mime);
  }

  static void _trimCache() {
    if (_cache.length <= 6) return;
    final keys = _cache.keys.toList();
    for (final k in keys.take(_cache.length - 6)) {
      final p = _cache.remove(k);
      if (p != null && (p.done || p.error != null)) {
        try {
          p.file.deleteSync();
        } catch (_) {}
      }
    }
  }

  static Future<void> download(Track t, File f, void Function(double) onProgress) async {
    final cached = _cache[t.id];
    if (cached != null && cached.done && cached.file.existsSync() && !cached.file.path.endsWith('.webm')) {
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
      if (p.error == null && p.written > 0) {
        await p.file.rename(f.path);
        return true;
      }
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
        await for (final c in res.stream) {
          got += c.length;
          sink.add(c);
          if (total > 0) onP(got / total);
        }
      } finally {
        await sink.close();
      }
      if (got == 0) throw Exception('leere Datei');
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
