import 'dart:io';

import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../data/models.dart';
import '../data/store.dart';

/// Findet zu einem Deezer-Titel das passende YouTube-Video und liefert dessen Audiostream.
class YT {
  static final _yt = YoutubeExplode();

  static Future<String> videoId(Track t) async {
    final cached = Store.instance.ytIds[t.id];
    if (cached != null) return cached;

    final results = await _yt.search.search('${t.artist} ${t.title} audio');
    final title = t.title.toLowerCase();
    Video? best;
    var bestScore = 1 << 30;
    for (final v in results.take(10)) {
      final d = v.duration?.inSeconds ?? 0;
      if (d == 0) continue;
      var score = t.duration > 0 ? (d - t.duration).abs() : 0;
      final vt = v.title.toLowerCase();
      for (final bad in ['live', 'cover', 'remix', 'karaoke', 'instrumental', 'sped up', 'slowed', 'reaction']) {
        if (vt.contains(bad) && !title.contains(bad)) score += 45;
      }
      if (v.author.toLowerCase().endsWith('- topic')) score -= 12;
      if (vt.contains('official audio')) score -= 6;
      if (score < bestScore) {
        best = v;
        bestScore = score;
      }
    }
    if (best == null) throw Exception('Kein passendes Audio gefunden');
    Store.instance.setYt(t.id, best.id.value);
    return best.id.value;
  }

  static Future<AudioOnlyStreamInfo> _stream(String vid) async {
    StreamManifest manifest;
    try {
      manifest = await _yt.videos.streamsClient
          .getManifest(vid, ytClients: [YoutubeApiClient.androidVr, YoutubeApiClient.ios]);
    } catch (_) {
      manifest = await _yt.videos.streamsClient.getManifest(vid);
    }
    final audio = manifest.audioOnly.toList();
    if (audio.isEmpty) throw Exception('Kein Audiostream');
    final mp4 = audio.where((s) => s.container == StreamContainer.mp4).toList();
    final pool = mp4.isNotEmpty ? mp4 : audio;
    pool.sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    return pool.first;
  }

  static Future<Uri> streamUrl(Track t) async => (await _stream(await videoId(t))).url;

  static Future<void> download(Track t, File f, void Function(double) onProgress) async {
    final info = await _stream(await videoId(t));
    final total = info.size.totalBytes;
    final tmp = File('${f.path}.part');
    final sink = tmp.openWrite();
    var got = 0;
    try {
      await for (final chunk in _yt.videos.streamsClient.get(info)) {
        got += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress(got / total);
      }
    } finally {
      await sink.close();
    }
    await tmp.rename(f.path);
  }
}
