// Diagnose: welche YouTube-Abrufmethode liefert heute spielbares Audio?
// Läuft nur in GitHub Actions (dart run tool/diag.dart), nicht in der App.
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void report(String line) {
  stdout.writeln(line);
  File('diag.txt').writeAsStringSync('$line\n', mode: FileMode.append);
}

Future<void> main() async {
  final yt = YoutubeExplode();
  String vid;
  try {
    final r = await yt.search.search('Daft Punk Get Lucky audio');
    vid = r.first.id.value;
    report('SUCHE ok: ${r.length} Treffer, erstes Video $vid «${r.first.title}» ${r.first.duration}');
  } catch (e) {
    report('SUCHE FEHLER: $e');
    vid = 'h5EofwRzit0';
  }

  final clients = <String, List<YoutubeApiClient>?>{
    'standard': null,
    'androidVr': [YoutubeApiClient.androidVr],
    'ios': [YoutubeApiClient.ios],
    'tv': [YoutubeApiClient.tv],
    'android': [YoutubeApiClient.android],
    'mweb': [YoutubeApiClient.mweb],
    'safari': [YoutubeApiClient.safari],
  };

  const uas = {
    'ohneUA': <String, String>{},
    'vrUA': {
      'User-Agent':
          'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip'
    },
    'exoUA': {'User-Agent': 'ExoPlayerLib/2.19.1'},
    'browserUA': {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
    },
  };

  for (final c in clients.entries) {
    try {
      final m = c.value == null
          ? await yt.videos.streamsClient.getManifest(vid)
          : await yt.videos.streamsClient.getManifest(vid, ytClients: c.value!);
      final audio = m.audioOnly.toList()
        ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      if (audio.isEmpty) {
        report('[${c.key}] Manifest ohne Audio');
        continue;
      }
      final mp4 = audio.where((s) => s.container == StreamContainer.mp4).toList();
      final s = mp4.isNotEmpty ? mp4.first : audio.first;
      final res = <String>[];
      for (final u in uas.entries) {
        try {
          final r = await http.get(s.url, headers: {...u.value, 'Range': 'bytes=0-65535'});
          res.add('${u.key}=${r.statusCode}/${r.bodyBytes.length}B');
        } catch (e) {
          res.add('${u.key}=ERR');
        }
        // Mittendrin lesen (Spulen)
      }
      try {
        final r = await http.get(s.url, headers: {'Range': 'bytes=1000000-1065535'});
        res.add('mitte=${r.statusCode}');
      } catch (_) {
        res.add('mitte=ERR');
      }
      var got = 0;
      try {
        await for (final chunk in yt.videos.streamsClient.get(s).timeout(const Duration(seconds: 25))) {
          got += chunk.length;
          if (got > 300000) break;
        }
        res.add('ytGet=${got}B');
      } catch (e) {
        res.add('ytGet=FEHLER($got B) ${e.toString().split('\n').first}');
      }
      report('[${c.key}] ${audio.length} Audio, gewählt ${s.container.name} ${s.bitrate.kiloBitsPerSecond.round()}kbps '
          'n=${s.url.queryParameters['c']} -> ${res.join(' ')}');
    } catch (e) {
      report('[${c.key}] MANIFEST FEHLER: ${e.toString().split('\n').first}');
    }
  }
  yt.close();
}
