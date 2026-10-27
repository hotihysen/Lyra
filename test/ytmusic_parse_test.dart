// Prüft den YouTube-Music-Parser gegen echte, gespeicherte Antworten (Branch ytm-fixtures).
// Ordner über die Umgebungsvariable YTM_FIXTURES; ohne sie werden die Tests übersprungen.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyra/api/ytmusic.dart';
import 'package:lyra/data/models.dart';

void main() {
  final dir = Platform.environment['YTM_FIXTURES'];
  final skip = dir == null || !Directory(dir).existsSync() ? 'YTM_FIXTURES nicht gesetzt' : null;
  Map load(String name) => jsonDecode(File('$dir/$name.json').readAsStringSync()) as Map;
  final report = <String>[];
  void note(String s) => report.add(s);
  tearDownAll(() {
    if (dir != null) File('$dir/_parse_report.txt').writeAsStringSync(report.join('\n'));
  });

  group('Suche (deine Beispiele)', () {
    for (final (file, title) in [
      ('search_songs_kida_mama', 'MAMA'),
      ('search_songs_kida_tdu', 'TDU'),
      ('search_songs_kida_ma_lujte', 'Ma lujte'),
    ]) {
      test('$title: erster Treffer ist der Song von Kida mit Video-ID', () {
        final items = parseSearch(load(file));
        expect(items, isNotEmpty);
        final t = items.first.toTrack();
        note('$file -> ${t.id} | ${t.title} | ${t.artist} | ${t.album} | ${t.duration}s | ${items.first.kind}');
        expect(isVideoId(t.id), isTrue);
        expect(t.title.toLowerCase(), contains(title.toLowerCase()));
        expect(t.artist.toLowerCase(), contains('kida'));
        expect(t.duration, greaterThan(60));
        expect(t.cover, startsWith('https://'));
        expect(t.artistId, startsWith('UC'));
      }, skip: skip);
    }

    test('Künstler, Alben, Playlists', () {
      final ar = parseSearch(load('search_artists_kida')).where((i) => i.kind == YtKind.artist).toList();
      final al = parseSearch(load('search_albums_kida')).where((i) => i.kind == YtKind.album).toList();
      final pl = parseSearch(load('search_playlists_hits')).where((i) => i.kind == YtKind.playlist).toList();
      note('Künstler: ${ar.take(3).map((a) => '${a.title} ${a.id} «${a.subtitle}»').join('; ')}');
      note('Alben: ${al.take(3).map((a) => '${a.title} ${a.id} ${a.typeLabel} ${a.year} ${a.artistNames}').join('; ')}');
      note('Playlists: ${pl.take(3).map((p) => '${p.title} ${p.id}').join('; ')}');
      expect(ar.first.title, 'Kida');
      expect(ar.first.id, startsWith('UC'));
      expect(al, isNotEmpty);
      expect(al.every((a) => a.id.startsWith('MPRE')), isTrue);
      expect(pl.first.id, startsWith('VL'));
    }, skip: skip);
  });

  test('Künstlerseite', () {
    final a = parseArtist(load('artist'), 'UCeFq5TLDSjP04KMjtXiu8fw');
    note('Künstler: ${a.artist.name} «${a.artist.info}» Bild:${a.artist.picture.isNotEmpty} Top:${a.top.length} '
        'Alben:${a.albums.length} Singles:${a.singles.length} Playlists:${a.playlists.length} Ähnlich:${a.related.length} '
        'Songs:${a.songsBrowseId} Radio:${a.radioVideoId}/${a.radioPlaylistId}');
    note('  Top: ${a.top.take(3).map((t) => '${t.title} (${t.artist}, ${t.album})').join('; ')}');
    expect(a.artist.name, 'Kida');
    expect(a.artist.picture, startsWith('https://'));
    expect(a.top, isNotEmpty);
    expect(a.top.every((t) => isVideoId(t.id)), isTrue);
    expect(a.albums.length + a.singles.length, greaterThan(0));
    expect(a.related, isNotEmpty);
    expect(a.radioVideoId, isNotNull);
  }, skip: skip);

  test('Album', () {
    final (album, tracks) = parseAlbum(load('album'), 'MPREb_ob5cslgCNc0');
    note('Album: ${album.title} | ${album.artist} ${album.artistId} | ${album.year} | ${album.type} | ${tracks.length} Titel');
    note('  ${tracks.take(3).map((t) => '${t.title} ${t.duration}s ${t.artist} ${t.cover.isNotEmpty}').join('; ')}');
    expect(album.title, isNotEmpty);
    expect(album.artist, isNotEmpty);
    expect(tracks.length, greaterThan(3));
    expect(tracks.every((t) => isVideoId(t.id) && t.duration > 0 && t.artist.isNotEmpty && t.cover.isNotEmpty && t.album == album.title), isTrue);
  }, skip: skip);

  test('Playlist und «Alle Songs» eines Künstlers', () {
    final p = parsePlaylist(load('playlist'), 'VLtest');
    final s = parsePlaylist(load('artist_songs'), 'VLtest2');
    note('Playlist: ${p.ref.title} «${p.ref.subtitle}» ${p.tracks.length} Titel, Fortsetzung: ${p.continuation != null}');
    note('Künstler-Songs: ${s.tracks.length} Titel; ${s.tracks.take(2).map((t) => '${t.title}/${t.artist}/${t.album}').join('; ')}');
    expect(p.tracks.length, greaterThan(20));
    expect(p.tracks.every((t) => isVideoId(t.id) && t.artist.isNotEmpty), isTrue);
    expect(s.tracks.length, greaterThan(10));
  }, skip: skip);

  test('Radio (Mix ab MAMA)', () {
    final r = parseRadio(load('next_radio'));
    note('Radio: ${r.tracks.length} Titel, weiter: ${r.continuation != null}, Liste ${r.playlistId}; '
        '${r.tracks.take(3).map((t) => '${t.title} – ${t.artist}').join('; ')}');
    expect(r.tracks.length, greaterThan(10));
    expect(r.tracks.first.title, 'MAMA');
    expect(r.tracks.first.artist, contains('Kida'));
    expect(r.continuation, isNotNull);
  }, skip: skip);

  test('Startseite, Charts, Genres', () {
    final home = parseBrowseSections(load('home'));
    final charts = parseBrowseSections(load('charts'));
    final genres = parseGenreButtons(load('moods_genres'));
    final genrePage = parseBrowseSections(load('genre_page'));
    note('Startseite: ${home.map((s) => '${s.title}(${s.items.length})').join(', ')}');
    note('Charts: ${charts.map((s) => '${s.title}(${s.items.length})').join(', ')}');
    note('Genres: ${genres.length}, z.B. ${genres.take(4).map((g) => '${g.name}#${g.color.toRadixString(16)}').join(', ')}');
    note('Genreseite: ${genrePage.map((s) => '${s.title}(${s.items.length})').take(4).join(', ')}');
    expect(home.length, greaterThan(2));
    expect(home.expand((s) => s.items).length, greaterThan(20));
    expect(genres.length, greaterThan(10));
    expect(genrePage, isNotEmpty);
  }, skip: skip);
}
