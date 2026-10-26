import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../api/lyrics.dart';
import '../../audio/handler.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';
import 'artist.dart';
import 'books.dart';
import 'collection.dart';

void openPlayer(BuildContext context) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, __, ___) => const PlayerPage(),
    transitionsBuilder: (_, a, __, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Track?>(
      valueListenable: audio.current,
      builder: (context, t, _) {
        if (t == null) return const Scaffold(backgroundColor: kBg);
        return _PlayerBody(key: ValueKey(t.id), track: t);
      },
    );
  }
}

class _PlayerBody extends StatefulWidget {
  final Track track;
  const _PlayerBody({super.key, required this.track});
  @override
  State<_PlayerBody> createState() => _PlayerBodyState();
}

class _PlayerBodyState extends State<_PlayerBody> {
  late Color _bg = cachedCoverColor(widget.track.cover) ?? kSurface2;

  @override
  void initState() {
    super.initState();
    coverColor(widget.track.cover).then((c) {
      if (mounted) setState(() => _bg = c);
    });
  }

  void _openSource() {
    final t = widget.track;
    if (t.isBook) {
      final b = Store.instance.books[t.albumId];
      if (b != null) openPage(BookPage(book: b));
    } else if (t.albumId.isNotEmpty) {
      openPage(AlbumPage(albumId: t.albumId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final mq = MediaQuery.of(context);
    final h = mq.size.height - mq.padding.top - mq.padding.bottom;
    return Scaffold(
      backgroundColor: kBg,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_bg, Color.lerp(_bg, kBg, 0.65)!, kBg],
            stops: const [0, 0.6, 1],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                SizedBox(
                  height: h,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 22),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              iconSize: 32,
                              icon: const Icon(Icons.keyboard_arrow_down_rounded),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                            Expanded(
                              child: GestureDetector(
                                onTap: _openSource,
                                child: Column(
                                  children: [
                                    Text(t.isBook ? 'HÖRBUCH' : 'WIRD GESPIELT AUS',
                                        style: const TextStyle(fontSize: 10.5, letterSpacing: 1.2, color: Colors.white70)),
                                    const SizedBox(height: 2),
                                    Text(t.album,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                                  ],
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.more_vert_rounded),
                              onPressed: () => showTrackMenu(context, t),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Flexible(
                          flex: 12,
                          child: Center(
                            child: AspectRatio(
                              aspectRatio: 1,
                              child: GestureDetector(
                                onHorizontalDragEnd: (d) {
                                  final v = d.primaryVelocity ?? 0;
                                  if (v < -300) audio.skipToNext();
                                  if (v > 300) audio.skipToPrevious();
                                },
                                child: Container(
                                  decoration: const BoxDecoration(boxShadow: [
                                    BoxShadow(color: Colors.black54, blurRadius: 32, offset: Offset(0, 14)),
                                  ]),
                                  child: Cover(t.cover,
                                      size: null,
                                      radius: 8,
                                      fallback: t.isBook ? Icons.menu_book_rounded : Icons.music_note_rounded),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                                  const SizedBox(height: 2),
                                  GestureDetector(
                                    onTap: t.artistId.isEmpty ? null : () => openPage(ArtistPage(artistId: t.artistId)),
                                    child: Text(t.isBook ? t.album : t.artist,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 15.5, color: Colors.white70)),
                                  ),
                                ],
                              ),
                            ),
                            if (!t.isBook) LikeButton(track: t, size: 28),
                          ],
                        ),
                        const SizedBox(height: 10),
                        const _ProgressBar(),
                        _Controls(track: t),
                        const SizedBox(height: 4),
                        _BottomRow(track: t),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
                if (!t.isBook) _LyricsCard(track: t, color: _bg),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar();
  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: audio.position,
      builder: (context, s) {
        final pos = s.data ?? Duration.zero;
        final dur = audio.duration;
        final max = math.max(1.0, dur.inMilliseconds.toDouble());
        final v = (_drag ?? pos.inMilliseconds.toDouble()).clamp(0.0, max).toDouble();
        return Column(
          children: [
            SizedBox(
              height: 28,
              child: Slider(
                value: v,
                max: max,
                onChanged: (x) => setState(() => _drag = x),
                onChangeEnd: (x) {
                  audio.seek(Duration(milliseconds: x.round()));
                  setState(() => _drag = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmtDuration(Duration(milliseconds: v.round())),
                      style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  Text(dur > Duration.zero ? '-${fmtDuration(dur - Duration(milliseconds: v.round()))}' : '--:--',
                      style: const TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class BigPlayButton extends StatelessWidget {
  final double size;
  const BigPlayButton({super.key, this.size = 68});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: audio.loading,
      builder: (context, loading, _) => StreamBuilder<PlaybackState>(
        stream: audio.playbackState,
        builder: (context, s) {
          final st = s.data;
          final playing = st?.playing ?? false;
          final busy = loading || st?.processingState == AudioProcessingState.buffering;
          return GestureDetector(
            onTap: audio.togglePlay,
            child: Container(
              width: size,
              height: size,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: busy
                  ? Padding(
                      padding: EdgeInsets.all(size * 0.3),
                      child: const CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                    )
                  : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.black, size: size * 0.56),
            ),
          );
        },
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  final Track track;
  const _Controls({required this.track});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (track.isBook)
          IconButton(
            iconSize: 30,
            icon: const Icon(Icons.replay_30_rounded),
            onPressed: () => audio.seekRelative(const Duration(seconds: -30)),
          )
        else
          ValueListenableBuilder<bool>(
            valueListenable: audio.shuffle,
            builder: (context, on, _) => IconButton(
              iconSize: 26,
              icon: Icon(Icons.shuffle_rounded, color: on ? accent : Colors.white),
              onPressed: audio.toggleShuffle,
            ),
          ),
        IconButton(iconSize: 42, icon: const Icon(Icons.skip_previous_rounded), onPressed: audio.skipToPrevious),
        const BigPlayButton(),
        IconButton(iconSize: 42, icon: const Icon(Icons.skip_next_rounded), onPressed: audio.skipToNext),
        if (track.isBook)
          IconButton(
            iconSize: 30,
            icon: const Icon(Icons.forward_30_rounded),
            onPressed: () => audio.seekRelative(const Duration(seconds: 30)),
          )
        else
          ValueListenableBuilder<RepeatSetting>(
            valueListenable: audio.repeat,
            builder: (context, m, _) => IconButton(
              iconSize: 26,
              icon: Icon(m == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  color: m == RepeatSetting.off ? Colors.white : accent),
              onPressed: audio.cycleRepeat,
            ),
          ),
      ],
    );
  }
}

class _BottomRow extends StatelessWidget {
  final Track track;
  const _BottomRow({required this.track});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        ValueListenableBuilder<double>(
          valueListenable: audio.speed,
          builder: (context, sp, _) => TextButton(
            onPressed: () => showSpeedSheet(context),
            style: TextButton.styleFrom(foregroundColor: sp == 1.0 ? Colors.white : accent),
            child: Text('${_speedLabel(sp)}×', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
        ),
        ValueListenableBuilder<DateTime?>(
          valueListenable: audio.sleepAt,
          builder: (context, at, _) => ValueListenableBuilder<bool>(
            valueListenable: audio.sleepAfterTrack,
            builder: (context, eot, _) => IconButton(
              icon: Icon(at != null || eot ? Icons.bedtime_rounded : Icons.bedtime_outlined,
                  color: at != null || eot ? accent : Colors.white),
              onPressed: () => showSleepSheet(context),
            ),
          ),
        ),
        const Spacer(),
        DownloadButton(track: track),
        IconButton(
          icon: const Icon(Icons.queue_music_rounded),
          onPressed: () => showQueue(context),
        ),
      ],
    );
  }
}

String _speedLabel(double s) {
  final txt = s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toString();
  return txt.replaceAll('.', ',');
}

// ---------- Sheets ----------

void showSpeedSheet(BuildContext context) {
  const speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: kSurface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (c) {
      final accent = Theme.of(c).colorScheme.primary;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Geschwindigkeit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              ValueListenableBuilder<double>(
                valueListenable: audio.speed,
                builder: (context, cur, _) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in speeds)
                      ChoiceChip(
                        label: Text('${_speedLabel(s)}×'),
                        selected: cur == s,
                        selectedColor: accent,
                        labelStyle: TextStyle(color: cur == s ? Colors.black : Colors.white, fontWeight: FontWeight.w700),
                        showCheckmark: false,
                        onSelected: (_) => audio.setSpeed(s),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

void showSleepSheet(BuildContext context) {
  const options = [5, 10, 15, 30, 45, 60, 90];
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (c) {
      Widget opt(String label, VoidCallback f) => ListTile(
            title: Text(label),
            onTap: () {
              Navigator.pop(c);
              f();
            },
          );
      final at = audio.sleepAt.value;
      final eot = audio.sleepAfterTrack.value;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  at != null
                      ? 'Sleep-Timer: endet um ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'
                      : eot
                          ? 'Sleep-Timer: nach diesem Titel'
                          : 'Sleep-Timer',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Die Musik wird am Ende sanft ausgeblendet.', style: TextStyle(color: kMuted)),
              ),
              for (final m in options) opt('$m Minuten', () => audio.setSleep(Duration(minutes: m))),
              opt('Ende des Titels', () => audio.setSleep(null, endOfTrack: true)),
              if (at != null || eot) opt('Timer ausschalten', () => audio.setSleep(null)),
            ],
          ),
        ),
      );
    },
  );
}

void showQueue(BuildContext context) {
  showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: kSurface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (c, ctrl) => _QueueView(controller: ctrl),
    ),
  );
}

class _QueueView extends StatelessWidget {
  final ScrollController controller;
  const _QueueView({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: audio.queueVersion,
      builder: (context, _, __) => ValueListenableBuilder<Track?>(
        valueListenable: audio.current,
        builder: (context, cur, __) {
          final up = audio.upcoming;
          final base = audio.index + 1;
          return CustomScrollView(
            controller: controller,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        margin: const EdgeInsets.only(top: 8),
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                      child: Text('Jetzt läuft', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                    ),
                    if (cur != null) TrackTile(track: cur, onTap: () {}, trailing: const SizedBox(width: 12)),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Als Nächstes', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          ),
                          if (up.isNotEmpty)
                            TextButton(onPressed: audio.clearUpcoming, child: const Text('Leeren')),
                        ],
                      ),
                    ),
                    if (up.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Text('Nach dem aktuellen Titel geht es automatisch mit ähnlicher Musik weiter.',
                            style: TextStyle(color: kMuted)),
                      ),
                  ],
                ),
              ),
              SliverReorderableList(
                itemCount: up.length,
                onReorder: (o, n) {
                  if (n > o) n -= 1;
                  audio.move(base + o, base + n);
                },
                proxyDecorator: (child, i, anim) => Material(color: kSurface2, elevation: 6, child: child),
                itemBuilder: (context, i) => Dismissible(
                  key: ValueKey('q_${up[i].id}_${base + i}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: Colors.red.shade700,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 20),
                    child: const Icon(Icons.delete_outline_rounded),
                  ),
                  onDismissed: (_) => audio.removeAt(base + i),
                  child: Material(
                    color: Colors.transparent,
                    child: TrackTile(
                      track: up[i],
                      onTap: () => audio.skipToQueueItem(base + i),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.drag_handle_rounded, color: kMuted),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    );
  }
}

// ---------- Songtexte ----------

class _LyricsCard extends StatelessWidget {
  final Track track;
  final Color color;
  const _LyricsCard({required this.track, required this.color});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Lyrics?>(
      future: LyricsApi.fetch(track),
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return const SizedBox(height: 40);
        }
        final l = s.data;
        if (l == null) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Kein Songtext gefunden', style: TextStyle(color: kMuted)),
          );
        }
        final card = Color.lerp(color, Colors.white, 0.08)!;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => LyricsPage(track: track, lyrics: l, color: card),
            )),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: card, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Expanded(
                        child: Text('Songtext', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                      ),
                      Icon(Icons.open_in_full_rounded, size: 20),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (l.hasSynced)
                    StreamBuilder<Duration>(
                      stream: audio.position,
                      builder: (context, p) {
                        final idx = l.indexAt(p.data ?? Duration.zero);
                        final start = math.max(0, idx - 1);
                        final lines = l.synced.skip(start).take(6).toList();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < lines.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  lines[i].text,
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    height: 1.25,
                                    color: start + i == idx
                                        ? Colors.white
                                        : start + i < idx
                                            ? Colors.white70
                                            : Colors.black.withValues(alpha: 0.55),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    )
                  else
                    Text(
                      l.plain.split('\n').take(8).join('\n'),
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, height: 1.35),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class LyricsPage extends StatefulWidget {
  final Track track;
  final Lyrics lyrics;
  final Color color;
  const LyricsPage({super.key, required this.track, required this.lyrics, required this.color});
  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  late final List<GlobalKey> _keys = List.generate(widget.lyrics.synced.length, (_) => GlobalKey());
  int _last = -2;

  void _follow(int idx) {
    if (idx == _last || idx < 0 || idx >= _keys.length) return;
    _last = idx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[idx].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            alignment: 0.35, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = widget.lyrics;
    return Scaffold(
      backgroundColor: widget.color,
      appBar: AppBar(
        backgroundColor: widget.color,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.track.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            Text(widget.track.artist, style: const TextStyle(fontSize: 13, color: Colors.white70)),
          ],
        ),
      ),
      body: l.hasSynced
          ? StreamBuilder<Duration>(
              stream: audio.position,
              builder: (context, p) {
                final idx = l.indexAt(p.data ?? Duration.zero);
                _follow(idx);
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 240),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < l.synced.length; i++)
                        GestureDetector(
                          key: _keys[i],
                          onTap: () => audio.seek(l.synced[i].time),
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 250),
                              style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                height: 1.25,
                                fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
                                color: i == idx
                                    ? Colors.white
                                    : i < idx
                                        ? Colors.white60
                                        : Colors.black.withValues(alpha: 0.55),
                              ),
                              child: Text(l.synced[i].text),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Text(l.plain, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, height: 1.4)),
            ),
    );
  }
}
