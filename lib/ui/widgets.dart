import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../api/youtube.dart';
import '../api/ytmusic.dart';
import '../data/downloads.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../main.dart';
import 'pages/artist.dart';
import 'pages/collection.dart';
import 'shell.dart';
import 'theme.dart';

// ---------- Cover & Farben ----------

class Cover extends StatelessWidget {
  final String url;
  final double? size;
  final double radius;
  final bool circle;
  final IconData fallback;
  const Cover(this.url,
      {super.key, this.size = 48, this.radius = 4, this.circle = false, this.fallback = Icons.music_note_rounded});

  @override
  Widget build(BuildContext context) {
    final ph = Container(
      width: size,
      height: size,
      color: kSurface2,
      alignment: Alignment.center,
      child: Icon(fallback, color: kMuted, size: size == null ? 64 : size! * 0.45),
    );
    final img = url.isEmpty
        ? ph
        : CachedNetworkImage(
            imageUrl: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 150),
            placeholder: (_, __) => ph,
            errorWidget: (_, __, ___) => ph,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(circle ? 9999 : radius),
      child: SizedBox(width: size, height: size, child: img),
    );
  }
}

final _colorCache = <String, Color>{};

Color? cachedCoverColor(String url) => _colorCache[url];

/// Dominante Farbe eines Covers (für Verläufe wie im Player).
Future<Color> coverColor(String url) async {
  if (url.isEmpty) return kSurface2;
  final c = _colorCache[url];
  if (c != null) return c;
  try {
    final s = await ColorScheme.fromImageProvider(
      provider: CachedNetworkImageProvider(url),
      brightness: Brightness.dark,
    );
    final col = Color.lerp(s.primaryContainer, Colors.black, 0.28)!;
    _colorCache[url] = col;
    return col;
  } catch (_) {
    return kSurface2;
  }
}

// ---------- Kleine Bausteine ----------

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

class Pill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const Pill(this.label, {super.key, this.selected = false, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: selected ? accent : kSurface2,
        borderRadius: BorderRadius.circular(32),
        child: InkWell(
          borderRadius: BorderRadius.circular(32),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Text(label,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.black : Colors.white,
                )),
          ),
        ),
      ),
    );
  }
}

class PlayButton extends StatelessWidget {
  final double size;
  final VoidCallback onPressed;
  final bool showPause;
  const PlayButton({super.key, this.size = 56, required this.onPressed, this.showPause = false});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: accent,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(showPause ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: size * 0.56),
        ),
      ),
    );
  }
}

/// Play-Knopf für eine Liste: zeigt Pause, wenn gerade ein Titel dieser Liste läuft.
class ListPlayButton extends StatelessWidget {
  final List<Track> tracks;
  final double size;
  final VoidCallback? onStart;
  const ListPlayButton({super.key, required this.tracks, this.size = 56, this.onStart});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Track?>(
      valueListenable: audio.current,
      builder: (context, cur, _) => StreamBuilder<PlaybackState>(
        stream: audio.playbackState,
        builder: (context, s) {
          final mine = cur != null && tracks.any((t) => t.id == cur.id);
          final playing = mine && (s.data?.playing ?? false);
          return PlayButton(
            size: size,
            showPause: playing,
            onPressed: () {
              if (mine) {
                audio.togglePlay();
              } else if (tracks.isNotEmpty) {
                onStart?.call();
                audio.playTracks(tracks);
              }
            },
          );
        },
      ),
    );
  }
}

class LikeButton extends StatelessWidget {
  final Track track;
  final double size;
  const LikeButton({super.key, required this.track, this.size = 26});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return storeBuilder((context, s) {
      final liked = s.isLiked(track);
      return IconButton(
        iconSize: size,
        icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            color: liked ? accent : Colors.white),
        onPressed: () {
          s.toggleLike(track);
          toast(context, liked ? 'Aus Lieblingssongs entfernt' : 'Zu Lieblingssongs hinzugefügt');
        },
      );
    });
  }
}

class DownloadButton extends StatelessWidget {
  final Track track;
  final double size;
  const DownloadButton({super.key, required this.track, this.size = 24});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: Downloads.progress,
      builder: (context, prog, _) => storeBuilder((context, s) {
        final p = prog[track.id];
        if (p != null) {
          return SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: SizedBox(
                width: size - 4,
                height: size - 4,
                child: CircularProgressIndicator(value: p > 0 ? p : null, strokeWidth: 2.5, color: accent),
              ),
            ),
          );
        }
        if (s.isDownloaded(track)) {
          return IconButton(
            iconSize: size,
            icon: Icon(Icons.download_done_rounded, color: accent),
            onPressed: () => _confirmRemove(context, track),
          );
        }
        return IconButton(
          iconSize: size,
          icon: const Icon(Icons.download_rounded),
          onPressed: () async {
            final ok = await Downloads.download(track);
            if (context.mounted) toast(context, ok ? 'Heruntergeladen' : 'Download fehlgeschlagen');
          },
        );
      }),
    );
  }
}

Future<void> _confirmRemove(BuildContext context, Track t) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Download entfernen?'),
      content: Text('«${t.title}» ist danach nicht mehr offline verfügbar.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Abbrechen')),
        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Entfernen')),
      ],
    ),
  );
  if (ok == true) Store.instance.removeDownload(t);
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1600)));
}

// ---------- Titelzeile ----------

class TrackTile extends StatelessWidget {
  final Track track;
  final VoidCallback onTap;
  final bool showCover;
  final int? number;
  final Widget? trailing;
  final String? playlistId;
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.showCover = true,
    this.number,
    this.trailing,
    this.playlistId,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<Track?>(
      valueListenable: audio.current,
      builder: (context, cur, _) {
        final active = cur?.id == track.id;
        return InkWell(
          onTap: onTap,
          onLongPress: () => showTrackMenu(context, track, playlistId: playlistId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
            child: Row(
              children: [
                if (number != null)
                  SizedBox(
                    width: 30,
                    child: active
                        ? Icon(Icons.graphic_eq_rounded, color: accent, size: 18)
                        : Text('$number', style: const TextStyle(color: kMuted, fontSize: 15)),
                  ),
                if (showCover) ...[
                  Cover(track.cover,
                      size: 48, fallback: track.isBook ? Icons.menu_book_rounded : Icons.music_note_rounded),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: active ? accent : Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          storeBuilder((c, s) => s.isDownloaded(track)
                              ? Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Icon(Icons.arrow_circle_down_rounded, size: 14, color: accent),
                                )
                              : const SizedBox.shrink()),
                          Expanded(
                            child: Text(
                              track.isBook ? fmtSeconds(track.duration) : track.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: kMuted, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                trailing ??
                    IconButton(
                      icon: const Icon(Icons.more_vert_rounded, color: kMuted),
                      onPressed: () => showTrackMenu(context, track, playlistId: playlistId),
                    ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------- Kontextmenü ----------

void showTrackMenu(BuildContext context, Track t, {String? playlistId}) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kSurface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (c) {
      final s = Store.instance;
      final liked = s.isLiked(t);
      final downloaded = s.isDownloaded(t);
      Widget item(IconData icon, String label, VoidCallback onTap) => ListTile(
            leading: Icon(icon),
            title: Text(label),
            onTap: () {
              Navigator.pop(c);
              onTap();
            },
          );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(width: 36, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              ListTile(
                leading: Cover(t.cover, size: 48),
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(t.isBook ? t.album : t.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Divider(height: 1, color: Colors.white10),
              if (!t.isBook)
                item(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    liked ? 'Aus Lieblingssongs entfernen' : 'Zu Lieblingssongs hinzufügen', () => s.toggleLike(t)),
              if (!t.isBook) item(Icons.playlist_add_rounded, 'Zur Playlist hinzufügen', () => showAddToPlaylist(context, t)),
              if (playlistId != null)
                item(Icons.remove_circle_outline_rounded, 'Aus dieser Playlist entfernen',
                    () => s.removeFromPlaylist(playlistId, t)),
              item(Icons.queue_play_next_rounded, 'Als Nächstes spielen', () {
                audio.addNext(t);
                toast(context, 'Wird als Nächstes gespielt');
              }),
              item(Icons.add_to_queue_rounded, 'Zur Warteschlange hinzufügen', () {
                audio.addToQueue(t);
                toast(context, 'Zur Warteschlange hinzugefügt');
              }),
              item(downloaded ? Icons.delete_outline_rounded : Icons.download_rounded,
                  downloaded ? 'Download entfernen' : 'Herunterladen', () async {
                if (downloaded) {
                  s.removeDownload(t);
                } else {
                  toast(context, 'Download gestartet');
                  final ok = await Downloads.download(t);
                  if (context.mounted) toast(context, ok ? 'Heruntergeladen' : 'Download fehlgeschlagen');
                }
              }),
              if (!t.isBook)
                item(Icons.radio_rounded, 'Mix zu diesem Song', () => startArtistRadio(context, t.artistId, seed: t)),
              if (!t.isBook && t.artistId.startsWith('UC'))
                item(Icons.person_outline_rounded, 'Zum Künstler', () => openPage(ArtistPage(artistId: t.artistId))),
              if (!t.isBook && t.albumId.startsWith('MPRE'))
                item(Icons.album_outlined, 'Zum Album', () => openPage(AlbumPage(albumId: t.albumId))),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

Future<String?> askName(BuildContext context, {String title = 'Neue Playlist', String initial = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Name der Playlist'),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Abbrechen')),
        TextButton(onPressed: () => Navigator.pop(c, ctrl.text.trim()), child: const Text('Speichern')),
      ],
    ),
  );
}

void showAddToPlaylist(BuildContext context, Track t) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: kSurface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (c) {
      final s = Store.instance;
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Zur Playlist hinzufügen', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: kSurface2, borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.add_rounded),
              ),
              title: const Text('Neue Playlist'),
              onTap: () async {
                Navigator.pop(c);
                final name = await askName(context);
                if (name == null || name.isEmpty) return;
                s.createPlaylist(name, [t]);
                if (context.mounted) toast(context, 'Zu «$name» hinzugefügt');
              },
            ),
            for (final p in s.playlists)
              ListTile(
                leading: Cover(p.cover, size: 48, fallback: Icons.queue_music_rounded),
                title: Text(p.name),
                subtitle: Text('${p.tracks.length} Titel'),
                onTap: () {
                  Navigator.pop(c);
                  final added = s.addToPlaylist(p.id, t);
                  toast(context, added ? 'Zu «${p.name}» hinzugefügt' : 'Schon in «${p.name}»');
                },
              ),
          ],
        ),
      );
    },
  );
}

Future<void> startArtistRadio(BuildContext context, String artistId, {Track? seed}) async {
  toast(context, 'Radio wird erstellt …');
  try {
    // Mit Ausgangstitel: Mix zu diesem Song; sonst der Mix des Künstlers (wie in YouTube Music)
    final list = seed != null
        ? (await YTMusic.radio((await YT.candidates(seed)).first)).tracks
        : await YTMusic.artistRadio(artistId);
    final tracks = [if (seed != null) seed, ...list.where((e) => e.id != seed?.id)];
    if (tracks.isEmpty) throw Exception('leer');
    await audio.playTracks(tracks);
  } catch (_) {
    if (context.mounted) toast(context, 'Radio konnte nicht geladen werden');
  }
}

// ---------- Karussell ----------

class CardItem {
  final String image;
  final String title;
  final String subtitle;
  final bool circle;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final IconData fallback;
  const CardItem({
    required this.image,
    required this.title,
    this.subtitle = '',
    this.circle = false,
    required this.onTap,
    this.onLongPress,
    this.fallback = Icons.music_note_rounded,
  });
}

class Carousel extends StatelessWidget {
  final String title;
  final List<CardItem> items;
  final double size;
  final Widget? trailing;
  const Carousel({super.key, required this.title, required this.items, this.size = 148, this.trailing});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title, trailing: trailing),
        SizedBox(
          height: size + 54,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final it = items[i];
              return GestureDetector(
                onTap: it.onTap,
                onLongPress: it.onLongPress,
                child: SizedBox(
                  width: size,
                  child: Column(
                    crossAxisAlignment: it.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      Cover(it.image, size: size, radius: 6, circle: it.circle, fallback: it.fallback),
                      const SizedBox(height: 8),
                      Text(it.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: it.circle ? TextAlign.center : TextAlign.start,
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                      if (it.subtitle.isNotEmpty)
                        Text(it.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: it.circle ? TextAlign.center : TextAlign.start,
                            style: const TextStyle(color: kMuted, fontSize: 12.5)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Ein Regal von YouTube Music als Karussell: Titel spielen, Alben/Playlists/Künstler öffnen.
class YtSectionCarousel extends StatelessWidget {
  final YtSection section;
  const YtSectionCarousel(this.section, {super.key});

  @override
  Widget build(BuildContext context) {
    final items = section.items.where((i) => i.kind != YtKind.other).toList();
    if (items.isEmpty) return const SizedBox.shrink();
    final playable = items.where((i) => i.playable).map((i) => i.toTrack()).toList();
    final allArtists = items.every((i) => i.kind == YtKind.artist);
    return Carousel(
      title: section.title.isEmpty ? 'Für dich' : section.title,
      size: allArtists ? 130 : 148,
      items: [
        for (final it in items)
          CardItem(
            image: it.thumb,
            title: it.title,
            subtitle: it.playable ? it.artistNames : it.subtitle,
            circle: it.kind == YtKind.artist,
            fallback: it.kind == YtKind.artist ? Icons.person_rounded : Icons.music_note_rounded,
            onTap: () {
              switch (it.kind) {
                case YtKind.song:
                case YtKind.video:
                  final i = playable.indexWhere((t) => t.id == it.id);
                  audio.playTracks(playable, start: i < 0 ? 0 : i);
                case YtKind.album:
                  openPage(AlbumPage(albumId: it.id));
                case YtKind.playlist:
                  openPage(PlaylistPage(playlistId: it.id));
                case YtKind.artist:
                  openPage(ArtistPage(artistId: it.id));
                case YtKind.other:
                  break;
              }
            },
            onLongPress: it.playable ? () => showTrackMenu(context, it.toTrack()) : null,
          ),
      ],
    );
  }
}

/// Grosses Verlaufs-Quadrat (Lieblingssongs, Downloads).
class GradientArt extends StatelessWidget {
  final IconData icon;
  final double size;
  final double radius;
  const GradientArt({super.key, required this.icon, this.size = 56, this.radius = 4});
  @override
  Widget build(BuildContext context) {
    final a = accents[Store.instance.accentIndex.value.clamp(0, accents.length - 1)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: a.gradient, borderRadius: BorderRadius.circular(radius)),
      child: Icon(icon, color: Colors.white, size: size * 0.42),
    );
  }
}
