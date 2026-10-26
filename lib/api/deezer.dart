import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

class Chart {
  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;
  final List<PlaylistRef> playlists;
  const Chart(this.tracks, this.albums, this.artists, this.playlists);
}

class SearchResult {
  final List<Track> tracks;
  final List<Artist> artists;
  final List<Album> albums;
  final List<PlaylistRef> playlists;
  const SearchResult(this.tracks, this.artists, this.albums, this.playlists);
  bool get isEmpty => tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;
}

class ArtistData {
  final Artist artist;
  final List<Track> top;
  final List<Album> albums;
  final List<Artist> related;
  const ArtistData(this.artist, this.top, this.albums, this.related);
}

/// Öffentliche Deezer-API (ohne Anmeldung): Katalog, Cover, Charts, Empfehlungen.
class Deezer {
  static const _base = 'https://api.deezer.com';

  static Future<Map> _get(String path) async {
    final r = await http.get(Uri.parse('$_base$path'));
    if (r.statusCode != 200) throw Exception('Deezer ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is Map && j['error'] != null) throw Exception('Deezer: ${j['error']}');
    return j as Map;
  }

  static List<Map> _data(Map? j) => ((j?['data'] as List?) ?? const []).cast<Map>();
  static String _q(String q) => Uri.encodeQueryComponent(q);

  static Future<Chart> chart() async {
    final j = await _get('/chart/0?limit=20');
    return Chart(
      _data(j['tracks'] as Map?).map((e) => Track.fromDeezer(e)).toList(),
      _data(j['albums'] as Map?).map((e) => Album.fromDeezer(e)).toList(),
      _data(j['artists'] as Map?).map((e) => Artist.fromDeezer(e)).toList(),
      _data(j['playlists'] as Map?).map((e) => PlaylistRef.fromDeezer(e)).toList(),
    );
  }

  static Future<List<Track>> searchTracks(String q) async =>
      _data(await _get('/search/track?q=${_q(q)}&limit=40')).map((e) => Track.fromDeezer(e)).toList();
  static Future<List<Artist>> searchArtists(String q) async =>
      _data(await _get('/search/artist?q=${_q(q)}&limit=20')).map((e) => Artist.fromDeezer(e)).toList();
  static Future<List<Album>> searchAlbums(String q) async =>
      _data(await _get('/search/album?q=${_q(q)}&limit=20')).map((e) => Album.fromDeezer(e)).toList();
  static Future<List<PlaylistRef>> searchPlaylists(String q) async =>
      _data(await _get('/search/playlist?q=${_q(q)}&limit=20')).map((e) => PlaylistRef.fromDeezer(e)).toList();

  static Future<List<T>> _safe<T>(Future<List<T>> f) async {
    try {
      return await f;
    } catch (_) {
      return <T>[];
    }
  }

  static Future<SearchResult> searchAll(String q) async {
    final r = await Future.wait<List<Object>>([
      _safe<Track>(searchTracks(q)),
      _safe<Artist>(searchArtists(q)),
      _safe<Album>(searchAlbums(q)),
      _safe<PlaylistRef>(searchPlaylists(q)),
    ]);
    return SearchResult(
      r[0] as List<Track>,
      r[1] as List<Artist>,
      r[2] as List<Album>,
      r[3] as List<PlaylistRef>,
    );
  }

  static Future<Artist> artist(String id) async => Artist.fromDeezer(await _get('/artist/$id'));

  static Future<List<Track>> artistTop(String id) async =>
      _data(await _get('/artist/$id/top?limit=10')).map((e) => Track.fromDeezer(e)).toList();

  static Future<List<Album>> artistAlbums(String id, Artist a) async {
    final list = _data(await _get('/artist/$id/albums?limit=60'))
        .map((e) => Album.fromDeezer(e, artist: a))
        .toList();
    list.sort((x, y) => y.year.compareTo(x.year));
    return list;
  }

  static Future<List<Artist>> related(String id) async =>
      _data(await _get('/artist/$id/related?limit=15')).map((e) => Artist.fromDeezer(e)).toList();

  static Future<List<Track>> artistRadio(String id) async =>
      _data(await _get('/artist/$id/radio?limit=30')).map((e) => Track.fromDeezer(e)).toList();

  static Future<ArtistData> artistFull(String id) async {
    final a = await artist(id);
    final r = await Future.wait<List<Object>>([
      _safe<Track>(artistTop(id)),
      _safe<Album>(artistAlbums(id, a)),
      _safe<Artist>(related(id)),
    ]);
    return ArtistData(a, r[0] as List<Track>, r[1] as List<Album>, r[2] as List<Artist>);
  }

  static Future<(Album, List<Track>)> album(String id) async {
    final j = await _get('/album/$id');
    final al = Album.fromDeezer(j);
    final tracks = _data(j['tracks'] as Map?).map((e) => Track.fromDeezer(e, album: j)).toList();
    return (al, tracks);
  }

  static Future<(PlaylistRef, List<Track>, String)> playlist(String id) async {
    final j = await _get('/playlist/$id');
    final p = PlaylistRef.fromDeezer(j);
    final tracks = _data(j['tracks'] as Map?).map((e) => Track.fromDeezer(e)).toList();
    final desc = '${j['description'] ?? ''}';
    return (p, tracks, desc);
  }

  static Future<List<Genre>> genres() async =>
      _data(await _get('/genre')).map((e) => Genre.fromDeezer(e)).where((g) => g.id != '0').toList();

  static Future<List<Artist>> genreArtists(String id) async =>
      _data(await _get('/genre/$id/artists')).map((e) => Artist.fromDeezer(e)).toList();
}
