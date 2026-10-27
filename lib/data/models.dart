String _s(dynamic v) => v == null ? '' : '$v';
int _i(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

final _videoIdRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
final _digitsRe = RegExp(r'^\d+$');

/// true für eine YouTube-Video-ID (11 Zeichen, nicht nur Ziffern wie alte Deezer-IDs).
bool isVideoId(String id) => _videoIdRe.hasMatch(id) && !_digitsRe.hasMatch(id);

class Track {
  final String id;
  final String title;
  final String artist;
  final String artistId;
  final String album;
  final String albumId;
  final String cover;
  final int duration; // Sekunden
  final String? url; // direkte Audio-URL (Hörbücher)
  final String kind; // 'music' oder 'book'

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.artistId = '',
    this.album = '',
    this.albumId = '',
    this.cover = '',
    this.duration = 0,
    this.url,
    this.kind = 'music',
  });

  bool get isBook => kind == 'book';

  /// Titel aus dem YouTube-Music-Katalog (ID ist die Video-ID).
  bool get isYouTube => !isBook && isVideoId(id);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'artistId': artistId,
        'album': album,
        'albumId': albumId,
        'cover': cover,
        'duration': duration,
        'url': url,
        'kind': kind,
      };

  factory Track.fromJson(Map j) => Track(
        id: _s(j['id']),
        title: _s(j['title']),
        artist: _s(j['artist']),
        artistId: _s(j['artistId']),
        album: _s(j['album']),
        albumId: _s(j['albumId']),
        cover: _s(j['cover']),
        duration: _i(j['duration']),
        url: j['url'] == null ? null : _s(j['url']),
        kind: j['kind'] == null ? 'music' : _s(j['kind']),
      );
}

class Artist {
  final String id;
  final String name;
  final String picture;
  final int fans;
  final String info; // z.B. «1,26 Mio. Zuschauer/Monat»
  const Artist({required this.id, required this.name, this.picture = '', this.fans = 0, this.info = ''});


  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'picture': picture, 'fans': fans, 'info': info};
  factory Artist.fromJson(Map j) => Artist(
      id: _s(j['id']), name: _s(j['name']), picture: _s(j['picture']), fans: _i(j['fans']), info: _s(j['info']));
}

class Album {
  final String id;
  final String title;
  final String artist;
  final String artistId;
  final String cover;
  final String year;
  final String type;
  const Album({
    required this.id,
    required this.title,
    this.artist = '',
    this.artistId = '',
    this.cover = '',
    this.year = '',
    this.type = 'album',
  });


  String get typeLabel {
    switch (type) {
      case 'single':
        return 'Single';
      case 'ep':
        return 'EP';
      case 'compile':
        return 'Compilation';
      default:
        return 'Album';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'artistId': artistId,
        'cover': cover,
        'year': year,
        'type': type,
      };
  factory Album.fromJson(Map j) => Album(
        id: _s(j['id']),
        title: _s(j['title']),
        artist: _s(j['artist']),
        artistId: _s(j['artistId']),
        cover: _s(j['cover']),
        year: _s(j['year']),
        type: _s(j['type']),
      );
}

class PlaylistRef {
  final String id;
  final String title;
  final String cover;
  final String subtitle;
  const PlaylistRef({required this.id, required this.title, this.cover = '', this.subtitle = ''});

}

class Genre {
  final String id; // bei YouTube Music die «params» der Kategorie
  final String name;
  final String picture;
  final int color; // ARGB, 0 = keine Angabe
  const Genre(this.id, this.name, this.picture, [this.color = 0]);
}

class UserPlaylist {
  final String id;
  String name;
  final List<Track> tracks;
  UserPlaylist({required this.id, required this.name, required this.tracks});

  String get cover => tracks.isEmpty ? '' : tracks.first.cover;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'tracks': tracks.map((t) => t.toJson()).toList()};
  factory UserPlaylist.fromJson(Map j) => UserPlaylist(
        id: _s(j['id']),
        name: _s(j['name']),
        tracks: ((j['tracks'] as List?) ?? const []).map((e) => Track.fromJson(e as Map)).toList(),
      );
}

class Book {
  final String id; // 'book:<librivox id>'
  final String title;
  final String author;
  final String cover;
  final String description;
  final List<Track> chapters;
  const Book({
    required this.id,
    required this.title,
    required this.author,
    this.cover = '',
    this.description = '',
    this.chapters = const [],
  });

  int get totalSeconds => chapters.fold(0, (a, c) => a + c.duration);

  factory Book.fromLibriVox(Map b) {
    final id = 'book:${_s(b['id'])}';
    final title = _s(b['title']).trim();
    final authors = ((b['authors'] as List?) ?? const [])
        .map((a) => '${_s((a as Map)['first_name'])} ${_s(a['last_name'])}'.trim())
        .where((a) => a.isNotEmpty)
        .join(', ');
    final ia = Uri.tryParse(_s(b['url_iarchive']));
    final ident = (ia != null && ia.pathSegments.isNotEmpty) ? ia.pathSegments.last : '';
    final cover = ident.isEmpty ? '' : 'https://archive.org/services/img/$ident';
    final sections = (b['sections'] as List?) ?? const [];
    final chapters = <Track>[];
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i] as Map;
      var url = _s(s['listen_url']);
      if (url.isEmpty) continue;
      if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
      final t = _s(s['title']).trim();
      chapters.add(Track(
        id: '$id:${i + 1}',
        title: t.isEmpty ? 'Kapitel ${i + 1}' : t,
        artist: authors,
        album: title,
        albumId: id,
        cover: cover,
        duration: _i(s['playtime']),
        url: url,
        kind: 'book',
      ));
    }
    final desc = _s(b['description'])
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .trim();
    return Book(id: id, title: title, author: authors, cover: cover, description: desc, chapters: chapters);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'cover': cover,
        'description': description,
        'chapters': chapters.map((c) => c.toJson()).toList(),
      };
  factory Book.fromJson(Map j) => Book(
        id: _s(j['id']),
        title: _s(j['title']),
        author: _s(j['author']),
        cover: _s(j['cover']),
        description: _s(j['description']),
        chapters: ((j['chapters'] as List?) ?? const []).map((e) => Track.fromJson(e as Map)).toList(),
      );
}
