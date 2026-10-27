import 'package:flutter/material.dart';

import '../../api/youtube.dart';
import '../../api/ytmusic.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist.dart';
import 'books.dart';
import 'collection.dart';
import 'settings.dart';

class HomeData {
  final List<YtSection>? sections; // Startseite von YouTube Music
  final List<Track> forYou;
  final String forYouLabel;
  final List<Artist> similar;
  final String similarLabel;
  const HomeData(this.sections, this.forYou, this.forYouLabel, this.similar, this.similarLabel);
}

Future<HomeData> loadHome() async {
  final s = Store.instance;
  final homeF = YTMusic.home().then<List<YtSection>?>((v) => v).catchError((_) => null);

  // «Dein Mix»: Mix von YouTube Music zu einem kürzlich gehörten oder gelikten Titel
  final seeds = [...s.recent.take(5), ...s.liked.take(5)].where((t) => !t.isBook).toList()..shuffle();
  var forYou = <Track>[];
  var label = '';
  if (seeds.isNotEmpty) {
    final seed = seeds.first;
    try {
      final vid = (await YT.candidates(seed)).first;
      forYou = (await YTMusic.radio(vid)).tracks.where((t) => t.id != vid).toList();
      label = seed.title;
    } catch (_) {}
  }

  // «Ähnlich wie …»: verwandte Künstler eines gefolgten oder gehörten Künstlers
  var similar = <Artist>[];
  var similarLabel = '';
  final artistSeeds = <String, String>{
    for (final a in s.followed.where((a) => a.id.startsWith('UC'))) a.id: a.name,
    for (final t in s.recent.where((t) => t.artistId.startsWith('UC'))) t.artistId: t.artist.split(',').first,
  }.entries.toList()
    ..shuffle();
  if (artistSeeds.isNotEmpty) {
    try {
      final a = await YTMusic.artist(artistSeeds.first.key);
      similar = a.related.where((r) => !s.isFollowing(r.id)).toList();
      similarLabel = a.artist.name;
    } catch (_) {}
  }
  return HomeData(await homeF, forYou, label, similar, similarLabel);
}

String greeting() {
  final h = DateTime.now().hour;
  if (h < 5) return 'Gute Nacht';
  if (h < 11) return 'Guten Morgen';
  if (h < 18) return 'Guten Tag';
  return 'Guten Abend';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<HomeData> _f = loadHome();

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: kBg,
      body: FutureBuilder<HomeData>(
        future: _f,
        builder: (context, snap) => RefreshIndicator(
          onRefresh: () async {
            final f = loadHome();
            setState(() => _f = f);
            await f;
          },
          child: storeBuilder((context, s) {
            final d = snap.data;
            final sections = d?.sections;
            return ListView(
              padding: EdgeInsets.only(top: top + 10, bottom: 24),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(greeting(),
                            style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                      ),
                      IconButton(
                        icon: const Icon(Icons.download_for_offline_outlined),
                        onPressed: () => openPage(const DownloadsPage()),
                      ),
                      IconButton(
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: () => openPage(const SettingsPage()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 36,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      Pill('Musik', selected: true, onTap: () {}),
                      Pill('Hörbücher', onTap: () => switchTab(3)),
                      Pill('Lieblingssongs', onTap: () => openPage(const LikedPage())),
                      Pill('Downloads', onTap: () => openPage(const DownloadsPage())),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _QuickGrid(store: s),
                if (snap.connectionState != ConnectionState.done)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (snap.connectionState == ConnectionState.done && sections == null)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(children: [
                      const Text('Keine Verbindung zum Katalog', style: TextStyle(color: kMuted)),
                      TextButton(onPressed: () => setState(() => _f = loadHome()), child: const Text('Erneut laden')),
                    ]),
                  ),
                Carousel(
                  title: 'Zuletzt gehört',
                  size: 130,
                  trailing: TextButton(
                    onPressed: () => _confirmClearRecent(context),
                    child: const Text('Leeren', style: TextStyle(color: kMuted, fontWeight: FontWeight.w700)),
                  ),
                  items: [
                    for (var i = 0; i < s.recent.length && i < 15; i++)
                      CardItem(
                        image: s.recent[i].cover,
                        title: s.recent[i].title,
                        subtitle: s.recent[i].isBook ? s.recent[i].album : s.recent[i].artist,
                        fallback: s.recent[i].isBook ? Icons.menu_book_rounded : Icons.music_note_rounded,
                        onTap: () => audio.playTracks([s.recent[i]]),
                        onLongPress: () => _recentMenu(context, s.recent[i]),
                      ),
                  ],
                ),
                if (d != null && d.forYou.isNotEmpty)
                  Carousel(
                    title: 'Mix: ${d.forYouLabel}',
                    items: [
                      for (var i = 0; i < d.forYou.length; i++)
                        CardItem(
                          image: d.forYou[i].cover,
                          title: d.forYou[i].title,
                          subtitle: d.forYou[i].artist,
                          onTap: () => audio.playTracks(d.forYou, start: i),
                        ),
                    ],
                  ),
                if (sections != null)
                  for (final sec in sections) YtSectionCarousel(sec),
                if (d != null && d.similar.isNotEmpty)
                  Carousel(
                    title: 'Ähnlich wie ${d.similarLabel}',
                    size: 130,
                    items: [
                      for (final a in d.similar)
                        CardItem(
                          image: a.picture,
                          title: a.name,
                          circle: true,
                          fallback: Icons.person_rounded,
                          onTap: () => openPage(ArtistPage(artistId: a.id)),
                        ),
                    ],
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }
}

void _recentMenu(BuildContext context, Track t) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: kSurface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Cover(t.cover, size: 48),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(t.isBook ? t.album : t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(height: 1, color: Colors.white10),
          ListTile(
            leading: const Icon(Icons.history_toggle_off_rounded),
            title: const Text('Aus «Zuletzt gehört» entfernen'),
            onTap: () {
              Navigator.pop(c);
              Store.instance.removeRecent(t);
            },
          ),
          ListTile(
            leading: const Icon(Icons.more_horiz_rounded),
            title: const Text('Weitere Optionen'),
            onTap: () {
              Navigator.pop(c);
              showTrackMenu(context, t);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

Future<void> _confirmClearRecent(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Verlauf leeren?'),
      content: const Text('Alle Titel unter «Zuletzt gehört» werden entfernt. Bibliothek und Downloads bleiben erhalten.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leeren')),
      ],
    ),
  );
  if (ok == true) Store.instance.clearRecent();
}

class _QuickGrid extends StatelessWidget {
  final Store store;
  const _QuickGrid({required this.store});

  @override
  Widget build(BuildContext context) {
    final s = store;
    final tiles = <Widget>[
      _QuickTile(
        art: const GradientArt(icon: Icons.favorite_rounded, size: 56, radius: 0),
        title: 'Lieblingssongs',
        onTap: () => openPage(const LikedPage()),
      ),
      for (final p in s.playlists.take(3))
        _QuickTile(
          art: Cover(p.cover, size: 56, radius: 0, fallback: Icons.queue_music_rounded),
          title: p.name,
          onTap: () => openPage(UserPlaylistPage(playlistId: p.id)),
        ),
      for (final a in s.likedAlbums.take(2))
        _QuickTile(
          art: Cover(a.cover, size: 56, radius: 0),
          title: a.title,
          onTap: () => openPage(AlbumPage(albumId: a.id, title: a.title, artist: a.artist)),
        ),
      for (final b in s.continueBooks().take(1))
        _QuickTile(
          art: Cover(b.cover, size: 56, radius: 0, fallback: Icons.menu_book_rounded),
          title: b.title,
          onTap: () => openPage(BookPage(book: b)),
        ),
      for (final a in s.followed.take(2))
        _QuickTile(
          art: Cover(a.picture, size: 56, radius: 0, fallback: Icons.person_rounded),
          title: a.name,
          onTap: () => openPage(ArtistPage(artistId: a.id, name: a.name)),
        ),
    ];
    final list = tiles.take(6).toList();
    if (list.length.isOdd && list.length > 1) list.removeLast();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          for (var i = 0; i < list.length; i += 2)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(child: list[i]),
                  const SizedBox(width: 8),
                  Expanded(child: i + 1 < list.length ? list[i + 1] : const SizedBox.shrink()),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final Widget art;
  final String title;
  final VoidCallback onTap;
  const _QuickTile({required this.art, required this.title, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface2,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              art,
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}
