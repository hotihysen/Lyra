// YouTube Music (InnerTube, Client WEB_REMIX) als Katalog: Suche, Startseite, Künstler,
// Alben, Playlists, Radio und Genres. Wie bei Lyra Music trägt jeder Titel direkt seine
// YouTube-Music-Video-ID; abgespielt wird genau diese, ohne erneute Suche.
//
// Reines Dart (nur package:http), damit der Parser ohne Flutter gegen echte Antworten
// getestet werden kann (test/ytmusic_parse_test.dart).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/models.dart';

// ---------------------------------------------------------------------------
// Ergebnis-Typen
// ---------------------------------------------------------------------------

enum YtKind { song, video, album, playlist, artist, other }

/// Ein Eintrag aus einer Liste oder einem Karussell.
class YtItem {
  final YtKind kind;
  final String id; // Video-ID oder browseId
  final String title;
  final String subtitle;
  final List<Ref> artists;
  final Ref? album;
  final int duration;
  final String thumb;
  final String year;
  final String typeLabel; // «Single», «EP», «Album», …
  const YtItem({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.artists = const [],
    this.album,
    this.duration = 0,
    this.thumb = '',
    this.year = '',
    this.typeLabel = '',
  });

  bool get playable => kind == YtKind.song || kind == YtKind.video;
  String get artistNames => artists.map((a) => a.name).join(', ');

  Track toTrack({String? fallbackArtist, String? fallbackArtistId, Ref? fallbackAlbum, String? fallbackCover}) {
    final ar = artists.isNotEmpty ? artistNames : (fallbackArtist ?? '');
    final arId = artists.isNotEmpty ? artists.firstWhere((a) => a.id.isNotEmpty, orElse: () => artists.first).id : (fallbackArtistId ?? '');
    final al = album ?? fallbackAlbum;
    return Track(
      id: id,
      title: title,
      artist: ar,
      artistId: arId,
      album: al?.name ?? '',
      albumId: al?.id ?? '',
      cover: thumb.isNotEmpty ? thumb : (fallbackCover ?? ''),
      duration: duration,
    );
  }

  Album toAlbum() => Album(
        id: id,
        title: title,
        artist: artistNames,
        artistId: artists.isEmpty ? '' : artists.first.id,
        cover: thumb,
        year: year,
        type: _albumType(typeLabel),
      );

  Artist toArtist() => Artist(id: id, name: title, picture: thumb, info: subtitle);

  PlaylistRef toPlaylist() => PlaylistRef(id: id, title: title, cover: thumb, subtitle: subtitle);
}

class Ref {
  final String name;
  final String id;
  const Ref(this.name, this.id);
}

/// Ein Regal/Karussell mit Überschrift.
class YtSection {
  final String title;
  final List<YtItem> items;
  final String? moreBrowseId;
  final String? moreParams;
  const YtSection(this.title, this.items, {this.moreBrowseId, this.moreParams});
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
  final List<Album> singles;
  final List<PlaylistRef> playlists;
  final List<Artist> related;
  final String? songsBrowseId; // «Alle Songs» des Künstlers
  final String? radioVideoId;
  final String? radioPlaylistId;
  const ArtistData(this.artist, this.top, this.albums, this.related,
      {this.singles = const [], this.playlists = const [], this.songsBrowseId, this.radioVideoId, this.radioPlaylistId});
}

class RadioResult {
  final List<Track> tracks;
  final String? continuation;
  final String? playlistId;
  const RadioResult(this.tracks, this.continuation, this.playlistId);
}

// ---------------------------------------------------------------------------
// Hilfsfunktionen für das JSON von InnerTube
// ---------------------------------------------------------------------------

dynamic _at(dynamic node, List<Object> path) {
  var cur = node;
  for (final p in path) {
    if (cur is Map && p is String) {
      cur = cur[p];
    } else if (cur is List && p is int) {
      if (p < 0 || p >= cur.length) return null;
      cur = cur[p];
    } else {
      return null;
    }
  }
  return cur;
}

Map? _map(dynamic v) => v is Map ? v : null;
List _list(dynamic v) => v is List ? v : const [];

List<Map> _runs(dynamic textObj) => _list(_at(textObj, ['runs'])).whereType<Map>().toList();

String _text(dynamic textObj) {
  final runs = _runs(textObj);
  if (runs.isNotEmpty) return runs.map((r) => '${r['text'] ?? ''}').join();
  final simple = _at(textObj, ['simpleText']);
  return simple is String ? simple : '';
}

String? _pageType(Map? browseEndpoint) =>
    _at(browseEndpoint, ['browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']) as String?;

/// Grösstes Vorschaubild; YouTube-Music-Bilder auf 544 px hochgesetzt.
String _thumb(dynamic thumbnailsList) {
  final list = _list(thumbnailsList).whereType<Map>().toList();
  if (list.isEmpty) return '';
  var url = '${list.last['url'] ?? ''}';
  if (url.startsWith('//')) url = 'https:$url';
  return upscaleThumb(url);
}

String upscaleThumb(String url) {
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    return url.replaceFirst(RegExp(r'=w\d+-h\d+'), '=w544-h544').replaceFirst(RegExp(r'=s\d+'), '=s544');
  }
  return url;
}

final _durationRe = RegExp(r'^(\d+):(\d{2})(?::(\d{2}))?$');
final _yearRe = RegExp(r'^\d{4}$');

int parseDuration(String s) {
  final m = _durationRe.firstMatch(s.trim());
  if (m == null) return 0;
  if (m.group(3) != null) {
    return int.parse(m.group(1)!) * 3600 + int.parse(m.group(2)!) * 60 + int.parse(m.group(3)!);
  }
  return int.parse(m.group(1)!) * 60 + int.parse(m.group(2)!);
}

/// Typbezeichnungen, die YouTube Music (deutsch und englisch) als erstes Segment zeigt.
const _typeLabels = {
  'titel', 'song', 'songs', 'video', 'videos', 'album', 'alben', 'albums', 'single', 'ep', 'playlist', 'künstler',
  'artist', 'podcast', 'folge', 'episode', 'profil', 'profile', 'hörbuch', 'audiobook',
};

bool _isViews(String s) {
  final l = s.toLowerCase();
  return l.contains('wiedergabe') || l.contains('aufruf') || l.contains('views') || l.contains('plays') ||
      l.contains('abonnent') || l.contains('subscriber') || l.contains('zuschauer') || l.contains('listener');
}

String _albumType(String label) {
  final l = label.toLowerCase();
  if (l == 'single') return 'single';
  if (l == 'ep') return 'ep';
  return 'album';
}

/// Wertet die Text-Runs einer Zeile aus: verlinkte Künstler, Album, Dauer, Jahr, Typ.
class _Meta {
  final artists = <Ref>[];
  Ref? album;
  int duration = 0;
  String year = '';
  String typeLabel = '';
  final plain = <String>[];

  void addRuns(List<Map> runs) {
    for (final r in runs) {
      final text = '${r['text'] ?? ''}';
      final be = _map(_at(r, ['navigationEndpoint', 'browseEndpoint']));
      final pt = _pageType(be);
      final id = '${be?['browseId'] ?? ''}';
      if (pt == 'MUSIC_PAGE_TYPE_ARTIST' || pt == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
        artists.add(Ref(text, id));
        continue;
      }
      if (pt == 'MUSIC_PAGE_TYPE_ALBUM') {
        album = Ref(text, id);
        continue;
      }
      for (final part in text.split('•')) {
        final p = part.trim();
        if (p.isEmpty || p == ',' || p == '&' || p == 'und' || p == 'and') continue;
        if (_durationRe.hasMatch(p)) {
          duration = parseDuration(p);
        } else if (_yearRe.hasMatch(p)) {
          year = p;
        } else if (_typeLabels.contains(p.toLowerCase()) && typeLabel.isEmpty) {
          typeLabel = p;
        } else if (!_isViews(p)) {
          plain.add(p);
        }
      }
    }
  }

  /// Künstler aus unverlinktem Text (z.B. «Kida, Noizy und Roman»), falls keine Links da sind.
  List<Ref> artistsOrText() {
    if (artists.isNotEmpty) return artists;
    if (plain.isEmpty) return const [];
    return [Ref(plain.first, '')];
  }
}

// ---------------------------------------------------------------------------
// Parser für die drei Eintragsarten
// ---------------------------------------------------------------------------

/// Listenzeile (musicResponsiveListItemRenderer): Songs, Videos, Alben, Künstler, Playlists.
YtItem? parseListItem(Map r) {
  final cols = _list(r['flexColumns'])
      .map((c) => _map(_at(c, ['musicResponsiveListItemFlexColumnRenderer', 'text'])))
      .toList();
  final title = cols.isEmpty ? '' : _text(cols.first);
  final firstRun = cols.isEmpty ? null : _runs(cols.first).firstOrNull;
  final videoId = (_at(r, ['playlistItemData', 'videoId']) ??
      _at(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'videoId']) ??
      _at(firstRun, ['navigationEndpoint', 'watchEndpoint', 'videoId'])) as String?;
  final mvt = (_at(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']) ??
      _at(firstRun, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType'])) as String?;
  final be = _map(_at(r, ['navigationEndpoint', 'browseEndpoint']));
  final thumb = _thumb(_at(r, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));

  final meta = _Meta();
  for (final c in cols.skip(1)) {
    meta.addRuns(_runs(c));
  }
  for (final f in _list(r['fixedColumns'])) {
    final t = _text(_at(f, ['musicResponsiveListItemFixedColumnRenderer', 'text']));
    if (_durationRe.hasMatch(t.trim())) meta.duration = parseDuration(t);
  }
  final subtitle = cols.length > 1 ? _text(cols[1]) : '';

  if (videoId != null && videoId.isNotEmpty) {
    final isVideo = mvt != null && mvt != 'MUSIC_VIDEO_TYPE_ATV';
    return YtItem(
      kind: isVideo ? YtKind.video : YtKind.song,
      id: videoId,
      title: title,
      subtitle: subtitle,
      artists: meta.artistsOrText(),
      album: meta.album,
      duration: meta.duration,
      thumb: thumb,
      year: meta.year,
      typeLabel: meta.typeLabel,
    );
  }
  if (be != null) {
    final id = '${be['browseId'] ?? ''}';
    final kind = switch (_pageType(be)) {
      'MUSIC_PAGE_TYPE_ALBUM' => YtKind.album,
      'MUSIC_PAGE_TYPE_ARTIST' || 'MUSIC_PAGE_TYPE_USER_CHANNEL' => YtKind.artist,
      'MUSIC_PAGE_TYPE_PLAYLIST' => YtKind.playlist,
      _ => YtKind.other,
    };
    return YtItem(
      kind: kind,
      id: id,
      title: title,
      subtitle: kind == YtKind.artist ? meta.plain.join(' • ') : subtitle,
      artists: meta.artists,
      thumb: thumb,
      year: meta.year,
      typeLabel: meta.typeLabel,
    );
  }
  return null;
}

/// Karte in einem Karussell (musicTwoRowItemRenderer).
YtItem? parseTwoRowItem(Map r) {
  final title = _text(r['title']);
  final subRuns = _runs(r['subtitle']);
  final meta = _Meta()..addRuns(subRuns);
  final thumb = _thumb(_at(r, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
  final ne = _map(r['navigationEndpoint']);
  final we = _map(ne?['watchEndpoint']);
  final be = _map(ne?['browseEndpoint']);
  if (we != null && we['videoId'] != null) {
    final mvt = _at(we, ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']);
    return YtItem(
      kind: mvt == 'MUSIC_VIDEO_TYPE_ATV' ? YtKind.song : YtKind.video,
      id: '${we['videoId']}',
      title: title,
      subtitle: _text(r['subtitle']),
      artists: meta.artistsOrText(),
      album: meta.album,
      thumb: thumb,
      year: meta.year,
    );
  }
  if (be != null) {
    final kind = switch (_pageType(be)) {
      'MUSIC_PAGE_TYPE_ALBUM' => YtKind.album,
      'MUSIC_PAGE_TYPE_ARTIST' || 'MUSIC_PAGE_TYPE_USER_CHANNEL' => YtKind.artist,
      'MUSIC_PAGE_TYPE_PLAYLIST' => YtKind.playlist,
      _ => YtKind.other,
    };
    return YtItem(
      kind: kind,
      id: '${be['browseId'] ?? ''}',
      title: title,
      subtitle: _text(r['subtitle']),
      artists: meta.artists,
      thumb: thumb,
      year: meta.year,
      typeLabel: meta.typeLabel,
    );
  }
  return null;
}

/// Eintrag der Warteschlange/des Radios (playlistPanelVideoRenderer).
YtItem? parsePanelVideo(Map v) {
  final id = v['videoId'];
  if (id is! String || id.isEmpty) return null;
  final meta = _Meta()..addRuns(_runs(v['longBylineText']));
  final len = _text(v['lengthText']);
  final mvt = _at(v, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']);
  return YtItem(
    kind: mvt == null || mvt == 'MUSIC_VIDEO_TYPE_ATV' ? YtKind.song : YtKind.video,
    id: id,
    title: _text(v['title']),
    artists: meta.artistsOrText(),
    album: meta.album,
    duration: len.isEmpty ? meta.duration : parseDuration(len),
    thumb: _thumb(_at(v, ['thumbnail', 'thumbnails'])),
    year: meta.year,
  );
}

YtItem? _parseAny(dynamic x) {
  if (x is! Map) return null;
  final row = _map(x['musicResponsiveListItemRenderer']);
  if (row != null) return parseListItem(row);
  final two = _map(x['musicTwoRowItemRenderer']);
  if (two != null) return parseTwoRowItem(two);
  final panel = _map(x['playlistPanelVideoRenderer']) ??
      _map(_at(x, ['playlistPanelVideoWrapperRenderer', 'primaryRenderer', 'playlistPanelVideoRenderer']));
  if (panel != null) return parsePanelVideo(panel);
  return null;
}

/// Alle Regale eines sectionListRenderer.contents.
List<YtSection> parseSections(dynamic contents) {
  final out = <YtSection>[];
  for (final s in _list(contents)) {
    if (s is! Map) continue;
    final shelf = _map(s['musicShelfRenderer']);
    if (shelf != null) {
      final items = _list(shelf['contents']).map(_parseAny).whereType<YtItem>().toList();
      final be = _map(_at(shelf, ['title', 'runs', 0, 'navigationEndpoint', 'browseEndpoint'])) ??
          _map(_at(shelf, ['bottomEndpoint', 'browseEndpoint']));
      if (items.isNotEmpty) {
        out.add(YtSection(_text(shelf['title']), items, moreBrowseId: be?['browseId'] as String?, moreParams: be?['params'] as String?));
      }
      continue;
    }
    final car = _map(s['musicCarouselShelfRenderer']);
    if (car != null) {
      final hd = _map(_at(car, ['header', 'musicCarouselShelfBasicHeaderRenderer']));
      final be = _map(_at(hd, ['title', 'runs', 0, 'navigationEndpoint', 'browseEndpoint'])) ??
          _map(_at(hd, ['moreContentButton', 'buttonRenderer', 'navigationEndpoint', 'browseEndpoint']));
      final items = _list(car['contents']).map(_parseAny).whereType<YtItem>().toList();
      if (items.isNotEmpty) {
        out.add(YtSection(_text(hd?['title']), items, moreBrowseId: be?['browseId'] as String?, moreParams: be?['params'] as String?));
      }
      continue;
    }
    final grid = _map(s['gridRenderer']);
    if (grid != null) {
      final items = _list(grid['items']).map(_parseAny).whereType<YtItem>().toList();
      if (items.isNotEmpty) out.add(YtSection(_text(_at(grid, ['header', 'gridHeaderRenderer', 'title'])), items));
      continue;
    }
    final pl = _map(s['musicPlaylistShelfRenderer']);
    if (pl != null) {
      final items = _list(pl['contents']).map(_parseAny).whereType<YtItem>().toList();
      if (items.isNotEmpty) out.add(YtSection('', items));
      continue;
    }
    final itemSection = _map(s['itemSectionRenderer']);
    if (itemSection != null) {
      final items = _list(itemSection['contents']).map(_parseAny).whereType<YtItem>().toList();
      if (items.isNotEmpty) out.add(YtSection('', items));
    }
  }
  return out;
}

/// Genre-/Stimmungs-Knöpfe (musicNavigationButtonRenderer) einer Seite.
List<Genre> parseGenreButtons(dynamic contents) {
  final out = <Genre>[];
  void visit(dynamic n) {
    if (n is Map) {
      final b = _map(n['musicNavigationButtonRenderer']);
      if (b != null) {
        final params = _at(b, ['clickCommand', 'browseEndpoint', 'params']);
        if (params is String) {
          final c = _at(b, ['solid', 'leftStripeColor']);
          out.add(Genre(params, _text(b['buttonText']), '', c is num ? c.toInt() : 0));
        }
        return;
      }
      n.values.forEach(visit);
    } else if (n is List) {
      n.forEach(visit);
    }
  }

  visit(contents);
  return out;
}

String? _continuationToken(List items) {
  for (final x in items.reversed) {
    final t = _at(x, ['continuationItemRenderer', 'continuationEndpoint', 'continuationCommand', 'token']);
    if (t is String) return t;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Seiten-Parser (öffentlich für Tests)
// ---------------------------------------------------------------------------

List<YtItem> parseSearch(Map j) {
  final contents = _at(j, ['contents', 'tabbedSearchResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']);
  return parseSections(contents).expand((s) => s.items).toList();
}

List<YtSection> parseBrowseSections(Map j) => parseSections(
    _at(j, ['contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']));

ArtistData parseArtist(Map j, String id) {
  final h = _map(_at(j, ['header', 'musicImmersiveHeaderRenderer'])) ?? _map(_at(j, ['header', 'musicVisualHeaderRenderer'])) ?? const {};
  final name = _text(h['title']);
  final picture = _thumb(_at(h, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
  final monthly = _text(h['monthlyListenerCount']);
  final subs = _text(_at(h, ['subscriptionButton', 'subscribeButtonRenderer', 'subscriberCountText']));
  final info = monthly.isNotEmpty ? monthly : (subs.isNotEmpty ? '$subs Abonnenten' : '');
  final radio = _map(_at(h, ['startRadioButton', 'buttonRenderer', 'navigationEndpoint', 'watchEndpoint'])) ??
      _map(_at(h, ['playButton', 'buttonRenderer', 'navigationEndpoint', 'watchEndpoint']));
  final artist = Artist(id: id, name: name, picture: picture, info: info);

  final sections = parseBrowseSections(j);
  final top = <Track>[];
  final albums = <Album>[];
  final singles = <Album>[];
  final playlists = <PlaylistRef>[];
  final related = <Artist>[];
  String? songsId;
  for (final s in sections) {
    final songs = s.items.where((i) => i.playable).toList();
    // Erstes Regal nur aus Titeln = «Top-Songs»
    if (top.isEmpty && songs.isNotEmpty && songs.length == s.items.length && songs.any((i) => i.kind == YtKind.song)) {
      top.addAll(songs.map((i) => i.toTrack(fallbackArtist: name, fallbackArtistId: id)));
      songsId ??= s.moreBrowseId;
      continue;
    }
    if (songs.length == s.items.length) continue; // Videos-Regal
    final albumItems = s.items.where((i) => i.kind == YtKind.album).toList();
    if (albumItems.isNotEmpty && albumItems.length == s.items.length) {
      final isSingles = albumItems.every((a) => a.typeLabel.isNotEmpty && a.typeLabel.toLowerCase() != 'album') ||
          s.title.toLowerCase().contains('single');
      (isSingles ? singles : albums).addAll(albumItems.map((a) {
        final al = a.toAlbum();
        return Album(id: al.id, title: al.title, artist: al.artist.isEmpty ? name : al.artist, artistId: al.artistId.isEmpty ? id : al.artistId,
            cover: al.cover, year: al.year, type: isSingles && al.type == 'album' ? 'single' : al.type);
      }));
      continue;
    }
    final artistItems = s.items.where((i) => i.kind == YtKind.artist).toList();
    if (artistItems.isNotEmpty && artistItems.length == s.items.length) {
      related.addAll(artistItems.map((a) => a.toArtist()));
      continue;
    }
    final plItems = s.items.where((i) => i.kind == YtKind.playlist).toList();
    if (plItems.isNotEmpty && plItems.length == s.items.length) {
      playlists.addAll(plItems.map((p) => p.toPlaylist()));
    }
  }
  return ArtistData(artist, top, albums, related,
      singles: singles,
      playlists: playlists,
      songsBrowseId: songsId,
      radioVideoId: radio?['videoId'] as String?,
      radioPlaylistId: radio?['playlistId'] as String?);
}

/// Kopf einer Album- oder Playlist-Seite (musicResponsiveHeaderRenderer).
Map? _responsiveHeader(Map j) {
  for (final s in _list(_at(j, ['contents', 'twoColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'contents']))) {
    final h = _map(_at(s, ['musicResponsiveHeaderRenderer'])) ?? _map(_at(s, ['musicEditablePlaylistDetailHeaderRenderer', 'header', 'musicResponsiveHeaderRenderer']));
    if (h != null) return h;
  }
  return null;
}

List _secondaryContents(Map j) =>
    _list(_at(j, ['contents', 'twoColumnBrowseResultsRenderer', 'secondaryContents', 'sectionListRenderer', 'contents']));

(Album, List<Track>) parseAlbum(Map j, String id) {
  final h = _responsiveHeader(j) ?? const {};
  final title = _text(h['title']);
  final meta = _Meta()..addRuns(_runs(h['subtitle']));
  final strap = _runs(h['straplineTextOne']);
  final artists = <Ref>[];
  for (final r in strap) {
    final be = _map(_at(r, ['navigationEndpoint', 'browseEndpoint']));
    if (be != null) artists.add(Ref('${r['text']}', '${be['browseId'] ?? ''}'));
  }
  final artistText = artists.isNotEmpty ? artists.map((a) => a.name).join(', ') : _text(h['straplineTextOne']);
  final cover = _thumb(_at(h, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
  final album = Album(
    id: id,
    title: title,
    artist: artistText,
    artistId: artists.isEmpty ? '' : artists.first.id,
    cover: cover,
    year: meta.year,
    type: _albumType(meta.typeLabel),
  );
  final tracks = <Track>[];
  for (final s in _secondaryContents(j)) {
    final shelf = _map(_at(s, ['musicShelfRenderer'])) ?? _map(_at(s, ['musicPlaylistShelfRenderer']));
    if (shelf == null) continue;
    for (final x in _list(shelf['contents'])) {
      final it = _parseAny(x);
      if (it == null || !it.playable) continue;
      tracks.add(it.toTrack(
        fallbackArtist: artistText,
        fallbackArtistId: album.artistId,
        fallbackAlbum: Ref(title, id),
        fallbackCover: cover,
      ));
    }
    if (tracks.isNotEmpty) break;
  }
  // Albumtitel immer vom Album, auch wenn eine Zeile keinen Link trägt
  return (album, [for (final t in tracks) t.album.isEmpty ? _withAlbum(t, title, id) : t]);
}

Track _withAlbum(Track t, String title, String id) => Track(
    id: t.id, title: t.title, artist: t.artist, artistId: t.artistId, album: title, albumId: id, cover: t.cover, duration: t.duration);

class PlaylistPage {
  final PlaylistRef ref;
  final List<Track> tracks;
  final String description;
  final String? continuation;
  const PlaylistPage(this.ref, this.tracks, this.description, this.continuation);
}

PlaylistPage parsePlaylist(Map j, String id) {
  final h = _responsiveHeader(j) ?? const {};
  final title = _text(h['title']);
  final cover = _thumb(_at(h, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail', 'thumbnails']));
  final second = _text(h['secondSubtitle']);
  final desc = _text(_at(h, ['description', 'musicDescriptionShelfRenderer', 'description']));
  final tracks = <Track>[];
  String? cont;
  for (final s in _secondaryContents(j)) {
    final shelf = _map(_at(s, ['musicPlaylistShelfRenderer'])) ?? _map(_at(s, ['musicShelfRenderer']));
    if (shelf == null) continue;
    final items = _list(shelf['contents']);
    for (final x in items) {
      final it = _parseAny(x);
      if (it != null && it.playable) tracks.add(it.toTrack());
    }
    cont = _continuationToken(items) ?? _at(shelf, ['continuations', 0, 'nextContinuationData', 'continuation']) as String?;
    if (tracks.isNotEmpty) break;
  }
  return PlaylistPage(PlaylistRef(id: id, title: title, cover: cover, subtitle: second), tracks, desc, cont);
}

(List<Track>, String?) parsePlaylistContinuation(Map j) {
  final items = _list(_at(j, ['onResponseReceivedActions', 0, 'appendContinuationItemsAction', 'continuationItems']));
  if (items.isNotEmpty) {
    return (items.map(_parseAny).whereType<YtItem>().where((i) => i.playable).map((i) => i.toTrack()).toList(), _continuationToken(items));
  }
  final c = _map(_at(j, ['continuationContents', 'musicPlaylistShelfContinuation'])) ?? const {};
  final list = _list(c['contents']);
  return (
    list.map(_parseAny).whereType<YtItem>().where((i) => i.playable).map((i) => i.toTrack()).toList(),
    _at(c, ['continuations', 0, 'nextContinuationData', 'continuation']) as String?,
  );
}

RadioResult parseRadio(Map j) {
  final panel = _map(_at(j, [
        'contents', 'singleColumnMusicWatchNextResultsRenderer', 'tabbedRenderer', 'watchNextTabbedResultsRenderer', 'tabs', 0,
        'tabRenderer', 'content', 'musicQueueRenderer', 'content', 'playlistPanelRenderer'
      ])) ??
      _map(_at(j, ['continuationContents', 'playlistPanelContinuation'])) ??
      const {};
  final tracks = _list(panel['contents']).map(_parseAny).whereType<YtItem>().where((i) => i.playable).map((i) => i.toTrack()).toList();
  final cont = _at(panel, ['continuations', 0, 'nextRadioContinuationData', 'continuation']) ??
      _at(panel, ['continuations', 0, 'nextContinuationData', 'continuation']);
  return RadioResult(tracks, cont as String?, panel['playlistId'] as String?);
}

// ---------------------------------------------------------------------------
// Netzwerk
// ---------------------------------------------------------------------------

class YTMusic {
  static const _base = 'https://music.youtube.com/youtubei/v1';
  static const _clientVersion = '1.20260114.01.00';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
  static String hl = 'de';
  static String gl = 'CH';
  static String? _visitor;
  static http.Client client = http.Client();

  static const filterSongs = 'EgWKAQIIAWoKEAkQBRAKEAMQBA==';
  static const filterVideos = 'EgWKAQIQAWoKEAkQChAFEAMQBA==';
  static const filterAlbums = 'EgWKAQIYAWoKEAkQChAFEAMQBA==';
  static const filterArtists = 'EgWKAQIgAWoKEAkQChAFEAMQBA==';
  static const filterPlaylists = 'EgeKAQQoADgBagwQDhAKEAMQBRAJEAQ=';

  static Future<Map> _post(String endpoint, Map<String, dynamic> body) async {
    final ctx = {
      'client': {
        'clientName': 'WEB_REMIX',
        'clientVersion': _clientVersion,
        'hl': hl,
        'gl': gl,
        if (_visitor != null) 'visitorData': _visitor,
      },
    };
    final r = await client
        .post(
          Uri.parse('$_base/$endpoint?prettyPrint=false'),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': _ua,
            'Origin': 'https://music.youtube.com',
            'Referer': 'https://music.youtube.com/',
            'X-Goog-Api-Format-Version': '1',
            'X-YouTube-Client-Name': '67',
            'X-YouTube-Client-Version': _clientVersion,
            if (_visitor != null) 'X-Goog-Visitor-Id': _visitor!,
          },
          body: jsonEncode({'context': ctx, ...body}),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('YouTube Music antwortet mit ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map) throw Exception('Ungültige Antwort von YouTube Music');
    _visitor ??= _at(j, ['responseContext', 'visitorData']) as String?;
    return j;
  }

  static Future<Map> browse(String browseId, {String? params}) =>
      _post('browse', {'browseId': browseId, if (params != null) 'params': params});

  // ----- Suche -----

  static Future<List<YtItem>> search(String q, String filter) async =>
      parseSearch(await _post('search', {'query': q, 'params': filter}));

  static Future<List<Track>> searchTracks(String q) async =>
      (await search(q, filterSongs)).where((i) => i.playable).map((i) => i.toTrack()).toList();

  static Future<List<T>> _safe<T>(Future<List<T>> f) async {
    try {
      return await f;
    } catch (_) {
      return <T>[];
    }
  }

  static Future<SearchResult> searchAll(String q) async {
    final r = await Future.wait<List<YtItem>>([
      _safe(search(q, filterSongs)),
      _safe(search(q, filterArtists)),
      _safe(search(q, filterAlbums)),
      _safe(search(q, filterPlaylists)),
    ]);
    return SearchResult(
      r[0].where((i) => i.playable).map((i) => i.toTrack()).toList(),
      r[1].where((i) => i.kind == YtKind.artist).map((i) => i.toArtist()).toList(),
      r[2].where((i) => i.kind == YtKind.album).map((i) => i.toAlbum()).toList(),
      r[3].where((i) => i.kind == YtKind.playlist).map((i) => i.toPlaylist()).toList(),
    );
  }

  static Future<List<String>> suggestions(String q) async {
    final j = await _post('music/get_search_suggestions', {'input': q});
    final out = <String>[];
    for (final sec in _list(j['contents'])) {
      for (final c in _list(_at(sec, ['searchSuggestionsSectionRenderer', 'contents']))) {
        final t = _text(_at(c, ['searchSuggestionRenderer', 'suggestion']));
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out;
  }

  /// Bester Treffer für einen Titel aus alten Daten (ohne Video-ID): nach Länge und Name.
  static Future<String?> findVideoId(Track t) async {
    final results = await search('${t.artist} ${t.title}', filterSongs);
    final songs = results.where((i) => i.playable).toList();
    if (songs.isEmpty) return null;
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
    final wantTitle = norm(t.title);
    int score(YtItem i) {
      var s = 0;
      if (t.duration > 0 && i.duration > 0) s += (i.duration - t.duration).abs();
      final title = norm(i.title);
      if (title != wantTitle) s += title.contains(wantTitle) || wantTitle.contains(title) ? 15 : 60;
      final ar = norm(i.artistNames);
      if (t.artist.isNotEmpty && !ar.contains(norm(t.artist.split(',').first))) s += 40;
      if (i.kind == YtKind.video) s += 10;
      return s;
    }

    songs.sort((a, b) => score(a).compareTo(score(b)));
    return songs.first.id;
  }

  // ----- Seiten -----

  static Future<List<YtSection>> home() async {
    final j = await browse('FEmusic_home');
    final sections = parseBrowseSections(j);
    // eine Fortsetzung für mehr Regale
    final cont = _at(j, [
      'contents', 'singleColumnBrowseResultsRenderer', 'tabs', 0, 'tabRenderer', 'content', 'sectionListRenderer', 'continuations', 0,
      'nextContinuationData', 'continuation'
    ]);
    if (cont is String) {
      try {
        final more = await _post('browse', {'continuation': cont});
        sections.addAll(parseSections(_at(more, ['continuationContents', 'sectionListContinuation', 'contents'])));
      } catch (_) {}
    }
    return sections;
  }

  static Future<List<YtSection>> charts() async => parseBrowseSections(await browse('FEmusic_charts'));

  static Future<ArtistData> artist(String id) async => parseArtist(await browse(id), id);

  static Future<(Album, List<Track>)> album(String id) async => parseAlbum(await browse(id), id);

  static Future<(PlaylistRef, List<Track>, String)> playlist(String id, {int maxPages = 5}) async {
    final browseId = id.startsWith('VL') ? id : 'VL$id';
    final page = parsePlaylist(await browse(browseId), browseId);
    final tracks = [...page.tracks];
    var cont = page.continuation;
    for (var i = 0; i < maxPages && cont != null; i++) {
      try {
        final (more, next) = parsePlaylistContinuation(await _post('browse', {'continuation': cont}));
        tracks.addAll(more);
        cont = next;
      } catch (_) {
        break;
      }
    }
    return (page.ref, tracks, page.description);
  }

  static Future<List<Genre>> genres() async => parseGenreButtons(await browse('FEmusic_moods_and_genres'));

  static Future<List<YtSection>> genre(String params) async =>
      parseBrowseSections(await browse('FEmusic_moods_and_genres_category', params: params));

  // ----- Radio -----

  /// Radio (Mix) ab einem Titel, wie «Als Nächstes» in YouTube Music.
  static Future<RadioResult> radio(String videoId, {String? playlistId, String? params}) async => parseRadio(await _post('next', {
        'videoId': videoId,
        'playlistId': playlistId ?? 'RDAMVM$videoId',
        if (params != null) 'params': params,
        'isAudioOnly': true,
        'enablePersistentPlaylistPanel': true,
        'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
      }));

  static Future<RadioResult> radioMore(String continuation, String? playlistId) async => parseRadio(await _post('next', {
        'continuation': continuation,
        if (playlistId != null) 'playlistId': playlistId,
        'isAudioOnly': true,
        'enablePersistentPlaylistPanel': true,
      }));

  /// Radio eines Künstlers (Mix-Knopf auf der Künstlerseite).
  static Future<List<Track>> artistRadio(String artistId) async {
    final a = await artist(artistId);
    if (a.radioVideoId != null) {
      return (await radio(a.radioVideoId!, playlistId: a.radioPlaylistId)).tracks;
    }
    if (a.top.isNotEmpty) return (await radio(a.top.first.id)).tracks;
    return const [];
  }
}
