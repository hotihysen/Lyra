import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Lokaler Speicher für Bibliothek, Einstellungen, Downloads und Hörbuch-Fortschritt.
class Store extends ChangeNotifier {
  Store._();
  static final Store instance = Store._();

  late Box _box;
  late Directory downloadsDir;

  final accentIndex = ValueNotifier<int>(0);
  List<Track> liked = [];
  List<Album> likedAlbums = [];
  List<Artist> followed = [];
  List<UserPlaylist> playlists = [];
  List<Track> recent = [];
  Map<String, Track> downloads = {};
  Map<String, String> ytIds = {};
  Map<String, Book> books = {};
  Map<String, Map> progress = {};
  /// Wie oft ein Titel gestartet wurde (für «Mein Mix»).
  Map<String, int> plays = {};
  /// Zwischengespeicherter Tagesmix.
  List<Track> mix = [];
  String mixDay = '';
  int crossfade = 4;
  String? ytClient;
  String? invHost;
  String? serverLink;
  bool autoUpdate = true;

  Future<void> init() async {
    _box = await Hive.openBox('lyra');
    accentIndex.value = (_box.get('accent') as int?) ?? 0;
    crossfade = (_box.get('crossfade') as int?) ?? 4;
    ytClient = _box.get('ytClient') as String?;
    invHost = _box.get('invHost') as String?;
    serverLink = _box.get('server') as String?;
    autoUpdate = (_box.get('autoUpdate') as bool?) ?? true;
    liked = _list('liked', Track.fromJson);
    likedAlbums = _list('likedAlbums', Album.fromJson);
    followed = _list('followed', Artist.fromJson);
    playlists = _list('playlists', UserPlaylist.fromJson);
    recent = _list('recent', Track.fromJson);
    downloads = {for (final t in _list('downloads', Track.fromJson)) t.id: t};
    books = {for (final b in _list('books', Book.fromJson)) b.id: b};
    // Zuordnungen alter Titel (ohne Video-ID) zu YouTube Music. Die frühere Zuordnung über die
    // allgemeine YouTube-Suche ('yt') war die Ursache falscher Titel und wird verworfen.
    ytIds = Map<String, String>.from((_box.get('ytm') as Map?) ?? const {});
    if (_box.containsKey('yt')) _box.delete('yt');
    plays = {for (final e in ((_box.get('plays') as Map?) ?? const {}).entries) '${e.key}': (e.value as num).toInt()};
    mix = _list('mix', Track.fromJson);
    mixDay = (_box.get('mixDay') as String?) ?? '';
    final p = (_box.get('progress') as Map?) ?? const {};
    progress = {for (final e in p.entries) '${e.key}': Map.from(e.value as Map)};
    final dir = await getApplicationDocumentsDirectory();
    downloadsDir = Directory('${dir.path}/downloads');
    if (!downloadsDir.existsSync()) downloadsDir.createSync(recursive: true);
  }

  List<T> _list<T>(String key, T Function(Map) f) =>
      ((_box.get(key) as List?) ?? const []).map((e) => f(e as Map)).toList();

  void _put(String key, Iterable items) {
    _box.put(key, items.map((e) => e.toJson()).toList());
    notifyListeners();
  }

  // Lieblingssongs
  bool isLiked(Track t) => liked.any((e) => e.id == t.id);
  void toggleLike(Track t) {
    if (isLiked(t)) {
      liked.removeWhere((e) => e.id == t.id);
    } else {
      liked.insert(0, t);
    }
    _put('liked', liked);
  }

  // Alben
  bool isAlbumLiked(String id) => likedAlbums.any((e) => e.id == id);
  void toggleAlbum(Album a) {
    if (isAlbumLiked(a.id)) {
      likedAlbums.removeWhere((e) => e.id == a.id);
    } else {
      likedAlbums.insert(0, a);
    }
    _put('likedAlbums', likedAlbums);
  }

  /// Ersetzt einen Eintrag aus der Deezer-Zeit durch den gefundenen YouTube-Music-Eintrag.
  void migrateAlbum(String oldId, Album a) {
    final i = likedAlbums.indexWhere((e) => e.id == oldId);
    if (i < 0) return;
    likedAlbums[i] = a;
    likedAlbums = [for (var j = 0; j < likedAlbums.length; j++) if (j == i || likedAlbums[j].id != a.id) likedAlbums[j]];
    _put('likedAlbums', likedAlbums);
  }

  void migrateArtist(String oldId, Artist a) {
    final i = followed.indexWhere((e) => e.id == oldId);
    if (i < 0) return;
    followed[i] = a;
    followed = [for (var j = 0; j < followed.length; j++) if (j == i || followed[j].id != a.id) followed[j]];
    _put('followed', followed);
  }

  // Künstler
  bool isFollowing(String id) => followed.any((e) => e.id == id);
  void toggleFollow(Artist a) {
    if (isFollowing(a.id)) {
      followed.removeWhere((e) => e.id == a.id);
    } else {
      followed.insert(0, a);
    }
    _put('followed', followed);
  }

  // Eigene Playlists
  UserPlaylist createPlaylist(String name, [List<Track> tracks = const []]) {
    final p = UserPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name,
      tracks: List.of(tracks),
    );
    playlists.insert(0, p);
    _put('playlists', playlists);
    return p;
  }

  UserPlaylist? playlist(String id) {
    for (final p in playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool addToPlaylist(String id, Track t) {
    final p = playlist(id);
    if (p == null || p.tracks.any((e) => e.id == t.id)) return false;
    p.tracks.add(t);
    _put('playlists', playlists);
    return true;
  }

  void removeFromPlaylist(String id, Track t) {
    playlist(id)?.tracks.removeWhere((e) => e.id == t.id);
    _put('playlists', playlists);
  }

  void reorderPlaylist(String id, int from, int to) {
    final p = playlist(id);
    if (p == null) return;
    final t = p.tracks.removeAt(from);
    p.tracks.insert(to, t);
    _put('playlists', playlists);
  }

  void renamePlaylist(String id, String name) {
    playlist(id)?.name = name;
    _put('playlists', playlists);
  }

  void deletePlaylist(String id) {
    playlists.removeWhere((p) => p.id == id);
    _put('playlists', playlists);
  }

  // Zuletzt gehört
  void removeRecent(Track t) {
    recent.removeWhere((e) => e.id == t.id);
    _put('recent', recent);
  }

  void clearRecent() {
    recent.clear();
    _put('recent', recent);
  }

  void addRecent(Track t) {
    if (!t.isBook) {
      plays[t.id] = (plays[t.id] ?? 0) + 1;
      if (plays.length > 3000) {
        // Seltenste Einträge vergessen
        final keep = (plays.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(2000);
        plays = {for (final e in keep) e.key: e.value};
      }
      _box.put('plays', plays);
    }
    recent.removeWhere((e) => e.id == t.id);
    recent.insert(0, t);
    if (recent.length > 40) recent = recent.sublist(0, 40);
    _put('recent', recent);
  }

  void saveMix(List<Track> tracks, String day) {
    mix = tracks;
    mixDay = day;
    _box.put('mixDay', day);
    _put('mix', mix);
  }

  // Zuordnung alter Titel (Deezer-ID) zur YouTube-Music-Video-ID
  void setYt(String id, String vid) {
    if (id == vid) return;
    ytIds[id] = vid;
    _box.put('ytm', ytIds);
  }

  void clearYt() {
    ytIds.clear();
    _box.put('ytm', ytIds);
    notifyListeners();
  }

  void setYtClient(String c) {
    ytClient = c;
    _box.put('ytClient', c);
  }

  void setInvHost(String h) {
    invHost = h;
    _box.put('invHost', h);
  }

  void setServerLink(String? v) {
    serverLink = (v == null || v.trim().isEmpty) ? null : v.trim();
    if (serverLink == null) {
      _box.delete('server');
    } else {
      _box.put('server', serverLink);
    }
    notifyListeners();
  }

  void setAutoUpdate(bool v) {
    autoUpdate = v;
    _box.put('autoUpdate', v);
    notifyListeners();
  }

  // Einstellungen
  void setAccent(int i) {
    accentIndex.value = i;
    _box.put('accent', i);
  }

  void setCrossfade(int s) {
    crossfade = s;
    _box.put('crossfade', s);
    notifyListeners();
  }

  // Downloads
  String _safe(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  File fileFor(Track t) => File('${downloadsDir.path}/${_safe(t.id)}.${t.isBook ? 'mp3' : 'm4a'}');
  bool isDownloaded(Track t) => downloads.containsKey(t.id);

  void addDownload(Track t) {
    downloads[t.id] = t;
    _put('downloads', downloads.values);
  }

  void removeDownload(Track t) {
    downloads.remove(t.id);
    try {
      fileFor(t).deleteSync();
    } catch (_) {}
    _put('downloads', downloads.values);
  }

  void clearDownloads() {
    for (final t in downloads.values.toList()) {
      try {
        fileFor(t).deleteSync();
      } catch (_) {}
    }
    downloads.clear();
    _put('downloads', downloads.values);
  }

  int downloadsBytes() {
    var sum = 0;
    for (final t in downloads.values) {
      try {
        sum += fileFor(t).lengthSync();
      } catch (_) {}
    }
    return sum;
  }

  // Hörbücher
  void saveBook(Book b) {
    books[b.id] = b;
    _put('books', books.values);
  }

  void setProgress(Track t, Duration pos) {
    progress[t.albumId] = {
      'track': t.id,
      'pos': pos.inMilliseconds,
      'at': DateTime.now().millisecondsSinceEpoch,
    };
    _box.put('progress', progress);
  }

  Duration? bookPos(Track t) {
    final p = progress[t.albumId];
    if (p == null || p['track'] != t.id) return null;
    return Duration(milliseconds: (p['pos'] as num).toInt());
  }

  String? lastChapter(String bookId) => progress[bookId]?['track'] as String?;

  List<Book> continueBooks() {
    final entries = progress.entries.toList()
      ..sort((a, b) => ((b.value['at'] as num?) ?? 0).compareTo((a.value['at'] as num?) ?? 0));
    return [
      for (final e in entries)
        if (books[e.key] != null) books[e.key]!
    ];
  }
}
