String _s(dynamic v) => v == null ? '' : '$v';
int _i(dynamic v) => v is num ? v.toInt() : (int.tryParse('${v ?? ''}') ?? 0);

String _cover(Map? m) =>
    _s(m?['cover_xl'] ?? m?['cover_big'] ?? m?['cover_medium'] ?? m?['cover']);

String _picture(Map? m) =>
    _s(m?['picture_xl'] ?? m?['picture_big'] ?? m?['picture_medium'] ?? m?['picture']);

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

  factory Track.fromDeezer(Map j, {Map? album}) {
    final al = j['album'] as Map?;
    final ar = (j['artist'] as Map?) ?? (album?['artist'] as Map?);
    final c = _cover(al);
    return Track(
      id: _s(j['id']),
      title: _s(j['title']),
      artist: _s(ar?['name']),
      artistId: _s(ar?['id']),
      album: _s(al?['title'] ?? album?['title']),
      albumId: _s(al?['id'] ?? album?['id']),
      cover: c.isNotEmpty ? c : _cover(album),
      duration: _i(j['duration']),
    );
  }

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
  const Artist({required this.id, required this.name, this.picture = '', this.fans = 0});

  factory Artist.fromDeezer(Map j) =>
      Artist(id: _s(j['id']), name: _s(j['name']), picture: _picture(j), fans: _i(j['nb_fan']));

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'picture': picture, 'fans': fans};
  factory Artist.fromJson(Map j) =>
      Artist(id: _s(j['id']), name: _s(j['name']), picture: _s(j['picture']), fans: _i(j['fans']));
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

  factory Album.fromDeezer(Map j, {Artist? artist}) {
    final ar = j['artist'] as Map?;
    final date = _s(j['release_date']);
    return Album(
      id: _s(j['id']),
      title: _s(j['title']),
      artist: ar != null ? _s(ar['name']) : (artist?.name ?? ''),
      artistId: ar != null ? _s(ar['id']) : (artist?.id ?? ''),
      cover: _cover(j),
      year: date.length >= 4 ? date.substring(0, 4) : '',
      type: _s(j['record_type']).isEmpty ? 'album' : _s(j['record_type']),
    );
  }

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

  factory PlaylistRef.fromDeezer(Map j) {
    final n = _i(j['nb_tracks']);
    final user = (j['user'] as Map?) ?? (j['creator'] as Map?);
    return PlaylistRef(
      id: _s(j['id']),
      title: _s(j['title']),
      cover: _picture(j),
      subtitle: n > 0 ? '$n Titel' : _s(user?['name']),
    );
  }
}

class Genre {
  final String id;
  final String name;
  final String picture;
  const Genre(this.id, this.name, this.picture);
  factory Genre.fromDeezer(Map j) => Genre(_s(j['id']), _s(j['name']), _picture(j));
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
