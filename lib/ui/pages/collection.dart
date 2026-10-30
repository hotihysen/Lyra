import 'package:flutter/material.dart';

import '../../api/ytmusic.dart';
import '../../data/downloads.dart';
import '../../data/mix.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist.dart';

/// Gemeinsames Layout für Alben, Playlists, Lieblingssongs und Downloads.
class CollectionView extends StatefulWidget {
  final String title;
  final String subtitle;
  final String coverUrl;
  final Widget? art;
  final List<Track> tracks;
  final List<Widget> actions;
  final bool numbered;
  final bool showCovers;
  final String? playlistId;
  final VoidCallback? onSubtitleTap;
  final String emptyText;
  final Widget? Function(Track)? trailing;

  const CollectionView({
    super.key,
    required this.title,
    this.subtitle = '',
    this.coverUrl = '',
    this.art,
    required this.tracks,
    this.actions = const [],
    this.numbered = false,
    this.showCovers = true,
    this.playlistId,
    this.onSubtitleTap,
    this.emptyText = 'Noch keine Titel',
    this.trailing,
  });

  @override
  State<CollectionView> createState() => _CollectionViewState();
}

class _CollectionViewState extends State<CollectionView> {
  late Color _bg = cachedCoverColor(widget.coverUrl) ?? kSurface2;
  final _scroll = ScrollController();
  bool _showTitle = false;

  @override
  void initState() {
    super.initState();
    if (widget.coverUrl.isNotEmpty) {
      coverColor(widget.coverUrl).then((c) {
        if (mounted) setState(() => _bg = c);
      });
    }
    _scroll.addListener(() {
      final show = _scroll.offset > 260;
      if (show != _showTitle) setState(() => _showTitle = show);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final tracks = w.tracks;
    return Scaffold(
      backgroundColor: kBg,
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverAppBar(
            pinned: true,
            backgroundColor: _showTitle ? Color.lerp(_bg, kBg, 0.4) : Colors.transparent,
            title: AnimatedOpacity(
              opacity: _showTitle ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Text(w.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          SliverToBoxAdapter(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_bg, kBg],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      decoration: const BoxDecoration(boxShadow: [
                        BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
                      ]),
                      child: w.art ?? Cover(w.coverUrl, size: 230, radius: 6),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(w.title,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.4)),
                  if (w.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: w.onSubtitleTap,
                      child: Text(w.subtitle, style: const TextStyle(color: kMuted, fontSize: 13.5)),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      ...w.actions,
                      const Spacer(),
                      ValueListenableBuilder<bool>(
                        valueListenable: audio.shuffle,
                        builder: (context, sh, _) => IconButton(
                          iconSize: 28,
                          icon: const Icon(Icons.shuffle_rounded),
                          color: kMuted,
                          onPressed: tracks.isEmpty ? null : () => audio.playShuffled(tracks),
                        ),
                      ),
                      const SizedBox(width: 4),
                      ListPlayButton(tracks: tracks),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (tracks.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Center(child: Text(w.emptyText, style: const TextStyle(color: kMuted))),
              ),
            ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) => TrackTile(
              track: tracks[i],
              number: w.numbered ? i + 1 : null,
              showCover: w.showCovers,
              playlistId: w.playlistId,
              trailing: w.trailing?.call(tracks[i]),
              onTap: () => audio.playTracks(tracks, start: i),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

class _DownloadAllButton extends StatelessWidget {
  final List<Track> tracks;
  const _DownloadAllButton(this.tracks);
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: Downloads.progress,
      builder: (context, prog, _) => storeBuilder((context, s) {
        final all = tracks.isNotEmpty && tracks.every(s.isDownloaded);
        final running = tracks.any((t) => prog.containsKey(t.id));
        if (running) {
          return SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: accent)),
            ),
          );
        }
        return IconButton(
          icon: Icon(all ? Icons.download_done_rounded : Icons.download_for_offline_outlined,
              color: all ? accent : Colors.white),
          onPressed: all
              ? null
              : () async {
                  toast(context, '${tracks.length} Titel werden heruntergeladen');
                  final n = await Downloads.downloadAll(tracks);
                  if (context.mounted) toast(context, '$n von ${tracks.length} heruntergeladen');
                },
        );
      }),
    );
  }
}

Widget _loading() => const Scaffold(
      backgroundColor: kBg,
      body: Center(child: CircularProgressIndicator()),
    );

Widget _failed(String msg, VoidCallback retry) => Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(msg, style: const TextStyle(color: kMuted)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: retry, child: const Text('Erneut versuchen')),
          ],
        ),
      ),
    );

// ---------- Album ----------

class AlbumPage extends StatefulWidget {
  final String albumId;
  // Für gespeicherte Alben aus der Deezer-Zeit: damit wird das Album in YouTube Music gesucht
  final String? title;
  final String? artist;
  const AlbumPage({super.key, required this.albumId, this.title, this.artist});
  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  late Future<(Album, List<Track>)> _f = _load();

  Future<(Album, List<Track>)> _load() async {
    final id = widget.albumId;
    if (id.startsWith('MPRE')) return YTMusic.album(id);
    final found = await YTMusic.findAlbumId(widget.title ?? '', widget.artist ?? '');
    if (found == null) throw Exception('Album in YouTube Music nicht gefunden');
    final r = await YTMusic.album(found);
    Store.instance.migrateAlbum(id, r.$1);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(Album, List<Track>)>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) {
          return _failed('Album konnte nicht geladen werden',
              () => setState(() => _f = _load()));
        }
        if (!s.hasData) return _loading();
        final (album, tracks) = s.data!;
        final accent = Theme.of(context).colorScheme.primary;
        return CollectionView(
          title: album.title,
          subtitle: '${album.artist} · ${album.typeLabel}${album.year.isEmpty ? '' : ' · ${album.year}'}',
          onSubtitleTap: album.artistId.startsWith('UC') ? () => openPage(ArtistPage(artistId: album.artistId)) : null,
          coverUrl: album.cover,
          tracks: tracks,
          numbered: true,
          showCovers: false,
          actions: [
            storeBuilder((context, st) {
              final liked = st.isAlbumLiked(album.id);
              return IconButton(
                icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    color: liked ? accent : Colors.white),
                onPressed: () {
                  st.toggleAlbum(album);
                  toast(context, liked ? 'Aus der Bibliothek entfernt' : 'In der Bibliothek gespeichert');
                },
              );
            }),
            _DownloadAllButton(tracks),
          ],
        );
      },
    );
  }
}

// ---------- YouTube-Music-Playlist ----------

class PlaylistPage extends StatefulWidget {
  final String playlistId;
  const PlaylistPage({super.key, required this.playlistId});
  @override
  State<PlaylistPage> createState() => _PlaylistPageState();
}

class _PlaylistPageState extends State<PlaylistPage> {
  late Future<(PlaylistRef, List<Track>, String)> _f = YTMusic.playlist(widget.playlistId);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<(PlaylistRef, List<Track>, String)>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) {
          return _failed('Playlist konnte nicht geladen werden',
              () => setState(() => _f = YTMusic.playlist(widget.playlistId)));
        }
        if (!s.hasData) return _loading();
        final (p, tracks, desc) = s.data!;
        return CollectionView(
          title: p.title,
          subtitle: desc.isNotEmpty ? desc : '${tracks.length} Titel',
          coverUrl: p.cover,
          tracks: tracks,
          actions: [
            IconButton(
              tooltip: 'Als eigene Playlist speichern',
              icon: const Icon(Icons.library_add_outlined),
              onPressed: () {
                Store.instance.createPlaylist(p.title, tracks);
                toast(context, 'In deiner Bibliothek gespeichert');
              },
            ),
            _DownloadAllButton(tracks),
          ],
        );
      },
    );
  }
}

// ---------- Lieblingssongs ----------

class LikedPage extends StatelessWidget {
  const LikedPage({super.key});
  @override
  Widget build(BuildContext context) {
    return storeBuilder((context, s) => CollectionView(
          title: 'Lieblingssongs',
          subtitle: '${s.liked.length} Titel',
          art: const GradientArt(icon: Icons.favorite_rounded, size: 230, radius: 6),
          tracks: List.of(s.liked),
          emptyText: 'Tippe bei einem Song auf das Herz,\num ihn hier zu speichern.',
          actions: [_DownloadAllButton(List.of(s.liked))],
        ));
  }
}

// ---------- Mein Mix ----------

class MixPage extends StatefulWidget {
  const MixPage({super.key});
  @override
  State<MixPage> createState() => _MixPageState();
}

class _MixPageState extends State<MixPage> {
  late Future<List<Track>> _f = MyMix.get();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Track>>(
      future: _f,
      builder: (context, s) {
        if (s.hasError) return _failed('Mix konnte nicht erstellt werden', () => setState(() => _f = MyMix.get(force: true)));
        if (!s.hasData) return _loading();
        final tracks = s.data!;
        return CollectionView(
          title: 'Mein Mix',
          subtitle: 'Aus deinen Lieblingssongs und meistgehörten Titeln · ${tracks.length} Titel · täglich neu',
          art: const GradientArt(icon: Icons.auto_awesome_rounded, size: 230, radius: 6),
          tracks: tracks,
          emptyText: 'Like ein paar Songs oder hör etwas Musik,\ndann entsteht hier dein Mix.',
          actions: [
            IconButton(
              tooltip: 'Neu mischen',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => setState(() => _f = MyMix.get(force: true)),
            ),
            _DownloadAllButton(tracks),
          ],
        );
      },
    );
  }
}

/// Mix sofort abspielen (für Knöpfe auf der Startseite).
Future<void> playMyMix(BuildContext context) async {
  final tracks = await MyMix.get();
  if (tracks.isEmpty) {
    if (context.mounted) toast(context, 'Like ein paar Songs, dann entsteht dein Mix');
    return;
  }
  await audio.playTracks(tracks);
}

// ---------- Downloads ----------

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});
  @override
  Widget build(BuildContext context) {
    return storeBuilder((context, s) {
      final tracks = s.downloads.values.toList();
      final mb = (s.downloadsBytes() / (1024 * 1024)).toStringAsFixed(0);
      return CollectionView(
        title: 'Downloads',
        subtitle: '${tracks.length} Titel · $mb MB · offline verfügbar',
        art: const GradientArt(icon: Icons.download_rounded, size: 230, radius: 6),
        tracks: tracks,
        emptyText: 'Noch nichts heruntergeladen.',
        trailing: (t) => IconButton(
          icon: const Icon(Icons.delete_outline_rounded, color: kMuted),
          onPressed: () => s.removeDownload(t),
        ),
      );
    });
  }
}

// ---------- Eigene Playlist ----------

class UserPlaylistPage extends StatelessWidget {
  final String playlistId;
  const UserPlaylistPage({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    return storeBuilder((context, s) {
      final p = s.playlist(playlistId);
      if (p == null) {
        return Scaffold(appBar: AppBar(), body: const Center(child: Text('Playlist gelöscht')));
      }
      return CollectionView(
        title: p.name,
        subtitle: '${p.tracks.length} Titel · Deine Playlist',
        coverUrl: p.cover,
        art: p.tracks.isEmpty ? const GradientArt(icon: Icons.queue_music_rounded, size: 230, radius: 6) : _Mosaic(p.tracks),
        tracks: List.of(p.tracks),
        playlistId: p.id,
        emptyText: 'Füge über das Menü ⋮ eines Songs\nTitel zu dieser Playlist hinzu.',
        actions: [
          _DownloadAllButton(List.of(p.tracks)),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            color: kSurface2,
            onSelected: (v) async {
              if (v == 'rename') {
                final name = await askName(context, title: 'Umbenennen', initial: p.name);
                if (name != null && name.isNotEmpty) s.renamePlaylist(p.id, name);
              } else if (v == 'delete') {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: const Text('Playlist löschen?'),
                    content: Text('«${p.name}» wird endgültig entfernt.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Löschen')),
                    ],
                  ),
                );
                if (ok == true && context.mounted) {
                  Navigator.of(context).pop();
                  s.deletePlaylist(p.id);
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Umbenennen')),
              PopupMenuItem(value: 'delete', child: Text('Löschen')),
            ],
          ),
        ],
      );
    });
  }
}

/// 2×2-Collage aus den ersten Covern einer Playlist.
class _Mosaic extends StatelessWidget {
  final List<Track> tracks;
  const _Mosaic(this.tracks);
  @override
  Widget build(BuildContext context) {
    final covers = <String>[];
    for (final t in tracks) {
      if (!covers.contains(t.cover) && t.cover.isNotEmpty) covers.add(t.cover);
      if (covers.length == 4) break;
    }
    if (covers.length < 4) return Cover(covers.isEmpty ? '' : covers.first, size: 230, radius: 6);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 230,
        height: 230,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [for (final c in covers) Cover(c, size: 115, radius: 0)],
        ),
      ),
    );
  }
}
