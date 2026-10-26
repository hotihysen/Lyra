import 'package:flutter/material.dart';

import '../../data/store.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist.dart';
import 'books.dart';
import 'collection.dart';
import 'settings.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _filter = -1; // -1 alles, 0 Playlists, 1 Alben, 2 Künstler, 3 Hörbücher, 4 Downloads

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    const filters = ['Playlists', 'Alben', 'Künstler', 'Hörbücher', 'Downloads'];
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        bottom: false,
        child: storeBuilder((context, s) {
          bool show(int f) => _filter == -1 || _filter == f;
          final entries = <Widget>[
            if (show(0))
              _LibTile(
                art: const GradientArt(icon: Icons.favorite_rounded),
                title: 'Lieblingssongs',
                subtitle: 'Playlist · ${s.liked.length} Titel',
                pinned: true,
                onTap: () => openPage(const LikedPage()),
              ),
            if (show(4))
              _LibTile(
                art: const GradientArt(icon: Icons.download_rounded),
                title: 'Downloads',
                subtitle: '${s.downloads.length} Titel offline',
                pinned: true,
                onTap: () => openPage(const DownloadsPage()),
              ),
            if (show(0))
              for (final p in s.playlists)
                _LibTile(
                  art: Cover(p.cover, size: 56, fallback: Icons.queue_music_rounded),
                  title: p.name,
                  subtitle: 'Playlist · ${p.tracks.length} Titel',
                  onTap: () => openPage(UserPlaylistPage(playlistId: p.id)),
                ),
            if (show(1))
              for (final a in s.likedAlbums)
                _LibTile(
                  art: Cover(a.cover, size: 56),
                  title: a.title,
                  subtitle: '${a.typeLabel} · ${a.artist}',
                  onTap: () => openPage(AlbumPage(albumId: a.id)),
                ),
            if (show(2))
              for (final a in s.followed)
                _LibTile(
                  art: Cover(a.picture, size: 56, circle: true, fallback: Icons.person_rounded),
                  title: a.name,
                  subtitle: 'Künstler',
                  onTap: () => openPage(ArtistPage(artistId: a.id)),
                ),
            if (show(3))
              for (final b in s.books.values)
                _LibTile(
                  art: Cover(b.cover, size: 56, fallback: Icons.menu_book_rounded),
                  title: b.title,
                  subtitle: 'Hörbuch · ${b.author}',
                  onTap: () => openPage(BookPage(book: b)),
                ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        gradient: accents[s.accentIndex.value.clamp(0, accents.length - 1)].gradient,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Text('L', style: TextStyle(fontWeight: FontWeight.w900, color: Colors.white)),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Bibliothek', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded, size: 28),
                      onPressed: () async {
                        final name = await askName(context);
                        if (name == null || name.isEmpty) return;
                        final p = s.createPlaylist(name);
                        openPage(UserPlaylistPage(playlistId: p.id));
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => openPage(const SettingsPage()),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  children: [
                    if (_filter != -1)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _filter = -1),
                          child: Container(
                            width: 36,
                            decoration: const BoxDecoration(color: kSurface2, shape: BoxShape.circle),
                            child: const Icon(Icons.close_rounded, size: 18),
                          ),
                        ),
                      ),
                    for (var i = 0; i < filters.length; i++)
                      Pill(filters[i], selected: _filter == i, onTap: () => setState(() => _filter = _filter == i ? -1 : i)),
                  ],
                ),
              ),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            'Hier erscheint, was du speicherst:\nPlaylists, Alben, Künstler und Hörbücher.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: kMuted, height: 1.4, decorationColor: accent),
                          ),
                        ),
                      )
                    : ListView(padding: const EdgeInsets.only(top: 6, bottom: 24), children: entries),
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _LibTile extends StatelessWidget {
  final Widget art;
  final String title;
  final String subtitle;
  final bool pinned;
  final VoidCallback onTap;
  const _LibTile({required this.art, required this.title, required this.subtitle, required this.onTap, this.pinned = false});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            art,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (pinned) ...[
                        Icon(Icons.push_pin_rounded, size: 13, color: accent),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: kMuted, fontSize: 13)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
