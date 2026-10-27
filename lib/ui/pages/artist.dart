import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../api/ytmusic.dart';
import '../../data/store.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'collection.dart';

class ArtistPage extends StatefulWidget {
  final String artistId;
  final String? name; // für gefolgte Künstler aus der Deezer-Zeit
  const ArtistPage({super.key, required this.artistId, this.name});
  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  late Future<ArtistData> _f = _load();
  bool _more = false;

  Future<ArtistData> _load() async {
    final id = widget.artistId;
    if (id.startsWith('UC')) return YTMusic.artist(id);
    final found = await YTMusic.findArtistId(widget.name ?? '');
    if (found == null) throw Exception('Künstler in YouTube Music nicht gefunden');
    final d = await YTMusic.artist(found);
    Store.instance.migrateArtist(id, d.artist);
    return d;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: FutureBuilder<ArtistData>(
        future: _f,
        builder: (context, s) {
          if (s.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Künstler konnte nicht geladen werden', style: TextStyle(color: kMuted)),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => setState(() => _f = _load()),
                  child: const Text('Erneut versuchen'),
                ),
              ]),
            );
          }
          if (!s.hasData) return const Center(child: CircularProgressIndicator());
          final d = s.data!;
          final a = d.artist;
          final top = _more ? d.top : d.top.take(5).toList();
          final accent = Theme.of(context).colorScheme.primary;
          return CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight: 320,
                backgroundColor: kBg,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsetsDirectional.only(start: 56, bottom: 14, end: 16),
                  title: Text(a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 24)),
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (a.picture.isNotEmpty) CachedNetworkImage(imageUrl: a.picture, fit: BoxFit.cover),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x33000000), Color(0x000E0E10), kBg],
                            stops: [0, 0.5, 1],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (a.info.isNotEmpty)
                        Text(a.info, style: const TextStyle(color: kMuted, fontSize: 13.5)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          storeBuilder((context, st) {
                            final f = st.isFollowing(a.id);
                            return OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: f ? accent : Colors.white,
                                side: BorderSide(color: f ? accent : Colors.white54),
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(horizontal: 18),
                              ),
                              onPressed: () => st.toggleFollow(a),
                              child: Text(f ? 'Folge ich' : 'Folgen'),
                            );
                          }),
                          IconButton(
                            tooltip: 'Mix des Künstlers',
                            icon: const Icon(Icons.radio_rounded),
                            onPressed: () async {
                              toast(context, 'Mix wird geladen …');
                              try {
                                final vid = d.radioVideoId ?? (d.top.isEmpty ? null : d.top.first.id);
                                if (vid == null) throw Exception('kein Mix');
                                final r = await YTMusic.radio(vid, playlistId: d.radioPlaylistId);
                                await audio.playTracks(r.tracks);
                              } catch (_) {
                                if (context.mounted) toast(context, 'Mix konnte nicht geladen werden');
                              }
                            },
                          ),
                          const Spacer(),
                          IconButton(
                            iconSize: 28,
                            color: kMuted,
                            icon: const Icon(Icons.shuffle_rounded),
                            onPressed: d.top.isEmpty ? null : () => audio.playShuffled(d.top),
                          ),
                          ListPlayButton(tracks: d.top),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: SectionTitle(
                  'Beliebt',
                  trailing: d.songsBrowseId == null
                      ? null
                      : TextButton(
                          onPressed: () => openPage(PlaylistPage(playlistId: d.songsBrowseId!)),
                          child: const Text('Alle Songs', style: TextStyle(color: kMuted, fontWeight: FontWeight.w700)),
                        ),
                ),
              ),
              SliverList.builder(
                itemCount: top.length,
                itemBuilder: (context, i) => TrackTile(
                  track: top[i],
                  number: i + 1,
                  onTap: () => audio.playTracks(d.top, start: i),
                ),
              ),
              if (d.top.length > 5)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _more = !_more),
                        child: Text(_more ? 'Weniger anzeigen' : 'Mehr anzeigen',
                            style: const TextStyle(color: kMuted, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Carousel(
                  title: 'Alben',
                  items: [
                    for (final al in d.albums)
                      CardItem(
                        image: al.cover,
                        title: al.title,
                        subtitle: [al.year, al.typeLabel].where((x) => x.isNotEmpty).join(' · '),
                        onTap: () => openPage(AlbumPage(albumId: al.id)),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Carousel(
                  title: 'Singles & EPs',
                  items: [
                    for (final al in d.singles)
                      CardItem(
                        image: al.cover,
                        title: al.title,
                        subtitle: [al.year, al.typeLabel].where((x) => x.isNotEmpty).join(' · '),
                        onTap: () => openPage(AlbumPage(albumId: al.id)),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Carousel(
                  title: 'Playlists',
                  items: [
                    for (final p in d.playlists)
                      CardItem(
                        image: p.cover,
                        title: p.title,
                        subtitle: p.subtitle,
                        onTap: () => openPage(PlaylistPage(playlistId: p.id)),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Carousel(
                  title: 'Fans mögen auch',
                  size: 130,
                  items: [
                    for (final r in d.related)
                      CardItem(
                        image: r.picture,
                        title: r.name,
                        circle: true,
                        fallback: Icons.person_rounded,
                        onTap: () => openPage(ArtistPage(artistId: r.id)),
                      ),
                  ],
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          );
        },
      ),
    );
  }
}
