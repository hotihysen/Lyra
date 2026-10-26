import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/deezer.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist.dart';
import 'collection.dart';

const _genreColors = [
  Color(0xFFE13300), Color(0xFF1E3264), Color(0xFF8400E7), Color(0xFF148A08),
  Color(0xFFBA5D07), Color(0xFF503750), Color(0xFF0D73EC), Color(0xFFE8115B),
  Color(0xFF27856A), Color(0xFF477D95), Color(0xFFAF2896), Color(0xFF8D67AB),
];

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  Timer? _deb;
  String _q = '';
  Future<SearchResult>? _f;
  int _filter = 0;
  late Future<List<Genre>> _genres = Deezer.genres();

  void _onChanged(String v) {
    _deb?.cancel();
    _deb = Timer(const Duration(milliseconds: 380), () {
      final q = v.trim();
      if (q == _q) return;
      setState(() {
        _q = q;
        _f = q.isEmpty ? null : Deezer.searchAll(q);
      });
    });
  }

  @override
  void dispose() {
    _deb?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Text('Suchen', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _ctrl,
                onChanged: _onChanged,
                textInputAction: TextInputAction.search,
                cursorColor: Colors.black,
                style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.white,
                  hintText: 'Was möchtest du hören?',
                  hintStyle: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w500),
                  prefixIcon: const Icon(Icons.search_rounded, color: Colors.black87),
                  suffixIcon: _ctrl.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.black87),
                          onPressed: () {
                            _ctrl.clear();
                            _onChanged('');
                            setState(() {});
                          },
                        ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            Expanded(child: _q.isEmpty ? _genreGrid() : _results()),
          ],
        ),
      ),
    );
  }

  Widget _genreGrid() {
    return FutureBuilder<List<Genre>>(
      future: _genres,
      builder: (context, s) {
        if (s.hasError) {
          return Center(
            child: TextButton(
              onPressed: () => setState(() => _genres = Deezer.genres()),
              child: const Text('Genres neu laden'),
            ),
          );
        }
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final g = s.data!;
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Text('Alle durchsuchen', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.75,
              ),
              itemCount: g.length,
              itemBuilder: (context, i) => _GenreTile(genre: g[i], color: _genreColors[i % _genreColors.length]),
            ),
          ],
        );
      },
    );
  }

  Widget _results() {
    const filters = ['Alle', 'Songs', 'Künstler', 'Alben', 'Playlists'];
    return Column(
      children: [
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            children: [
              for (var i = 0; i < filters.length; i++)
                Pill(filters[i], selected: _filter == i, onTap: () => setState(() => _filter = i)),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<SearchResult>(
            future: _f,
            builder: (context, s) {
              if (!s.hasData) return const Center(child: CircularProgressIndicator());
              final r = s.data!;
              if (r.isEmpty) {
                return Center(
                  child: Text('Keine Ergebnisse für «$_q»', style: const TextStyle(color: kMuted)),
                );
              }
              switch (_filter) {
                case 1:
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: r.tracks.length,
                    itemBuilder: (c, i) =>
                        TrackTile(track: r.tracks[i], onTap: () => audio.playTracks(r.tracks, start: i)),
                  );
                case 2:
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [for (final a in r.artists) _artistTile(a)],
                  );
                case 3:
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [for (final a in r.albums) _albumTile(a)],
                  );
                case 4:
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [for (final p in r.playlists) _playlistTile(p)],
                  );
                default:
                  final songs = r.tracks.take(5).toList();
                  return ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      if (r.artists.isNotEmpty) ...[
                        const SectionTitle('Top-Ergebnis'),
                        _TopResult(artist: r.artists.first),
                      ],
                      if (songs.isNotEmpty) ...[
                        const SectionTitle('Songs'),
                        for (var i = 0; i < songs.length; i++)
                          TrackTile(track: songs[i], onTap: () => audio.playTracks(r.tracks, start: i)),
                      ],
                      Carousel(
                        title: 'Künstler',
                        size: 120,
                        items: [
                          for (final a in r.artists)
                            CardItem(
                              image: a.picture,
                              title: a.name,
                              circle: true,
                              fallback: Icons.person_rounded,
                              onTap: () => openPage(ArtistPage(artistId: a.id)),
                            ),
                        ],
                      ),
                      Carousel(
                        title: 'Alben',
                        size: 140,
                        items: [
                          for (final a in r.albums)
                            CardItem(
                              image: a.cover,
                              title: a.title,
                              subtitle: a.artist,
                              onTap: () => openPage(AlbumPage(albumId: a.id)),
                            ),
                        ],
                      ),
                      Carousel(
                        title: 'Playlists',
                        size: 140,
                        items: [
                          for (final p in r.playlists)
                            CardItem(
                              image: p.cover,
                              title: p.title,
                              subtitle: p.subtitle,
                              onTap: () => openPage(PlaylistPage(playlistId: p.id)),
                            ),
                        ],
                      ),
                    ],
                  );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _artistTile(Artist a) => ListTile(
        leading: Cover(a.picture, size: 52, circle: true, fallback: Icons.person_rounded),
        title: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: const Text('Künstler', style: TextStyle(color: kMuted)),
        onTap: () => openPage(ArtistPage(artistId: a.id)),
      );

  Widget _albumTile(Album a) => ListTile(
        leading: Cover(a.cover, size: 52),
        title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${a.typeLabel} · ${a.artist}', style: const TextStyle(color: kMuted)),
        onTap: () => openPage(AlbumPage(albumId: a.id)),
      );

  Widget _playlistTile(PlaylistRef p) => ListTile(
        leading: Cover(p.cover, size: 52),
        title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('Playlist · ${p.subtitle}', style: const TextStyle(color: kMuted)),
        onTap: () => openPage(PlaylistPage(playlistId: p.id)),
      );
}

class _TopResult extends StatelessWidget {
  final Artist artist;
  const _TopResult({required this.artist});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: kSurface2,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => openPage(ArtistPage(artistId: artist.id)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Cover(artist.picture, size: 86, circle: true, fallback: Icons.person_rounded),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(artist.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('Künstler', style: TextStyle(color: kMuted)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.radio_rounded),
                  onPressed: () => startArtistRadio(context, artist.id),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GenreTile extends StatelessWidget {
  final Genre genre;
  final Color color;
  const _GenreTile({required this.genre, required this.color});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openPage(GenrePage(genre: genre)),
        child: Stack(
          children: [
            Positioned(
              right: -14,
              bottom: -6,
              child: Transform.rotate(
                angle: 0.42,
                child: Container(
                  decoration: const BoxDecoration(boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 8)]),
                  child: Cover(genre.picture, size: 66),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(genre.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
  }
}

class GenrePage extends StatefulWidget {
  final Genre genre;
  const GenrePage({super.key, required this.genre});
  @override
  State<GenrePage> createState() => _GenrePageState();
}

class _GenrePageState extends State<GenrePage> {
  late final Future<List<Artist>> _f = Deezer.genreArtists(widget.genre.id);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: Text(widget.genre.name, style: const TextStyle(fontWeight: FontWeight.w800))),
      body: FutureBuilder<List<Artist>>(
        future: _f,
        builder: (context, s) {
          if (s.hasError) return const Center(child: Text('Konnte nicht geladen werden', style: TextStyle(color: kMuted)));
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final a = s.data!;
          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 16,
              crossAxisSpacing: 12,
              childAspectRatio: 0.78,
            ),
            itemCount: a.length,
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => openPage(ArtistPage(artistId: a[i].id)),
              child: Column(
                children: [
                  LayoutBuilder(
                    builder: (c, box) =>
                        Cover(a[i].picture, size: box.maxWidth, circle: true, fallback: Icons.person_rounded),
                  ),
                  const SizedBox(height: 6),
                  Text(a[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
