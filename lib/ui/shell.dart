import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../main.dart';
import 'pages/books.dart';
import 'pages/home.dart';
import 'pages/library.dart';
import 'pages/player.dart';
import 'pages/search.dart';
import 'theme.dart';
import 'widgets.dart';

final shellKey = GlobalKey<ShellState>();

/// Öffnet eine Seite im aktuellen Tab (schliesst vorher Player/Sheets).
void openPage(Widget page) => shellKey.currentState?.push(page);

void switchTab(int i) => shellKey.currentState?.setTab(i);

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => ShellState();
}

class ShellState extends State<Shell> {
  int tab = 0;
  final _keys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  @override
  void initState() {
    super.initState();
    audio.error.addListener(_showError);
  }

  @override
  void dispose() {
    audio.error.removeListener(_showError);
    super.dispose();
  }

  void _showError() {
    final msg = audio.error.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
  }

  void push(Widget page) {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    _keys[tab].currentState?.push(MaterialPageRoute(builder: (_) => page));
  }

  void setTab(int i) {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    if (i == tab) {
      _keys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => tab = i);
    }
  }

  Widget _tabNav(int i, Widget root) => Navigator(
        key: _keys[i],
        onGenerateRoute: (s) => MaterialPageRoute(builder: (_) => root, settings: s),
      );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final nav = _keys[tab].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (tab != 0) {
          setState(() => tab = 0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: IndexedStack(
          index: tab,
          children: [
            _tabNav(0, const HomePage()),
            _tabNav(1, const SearchPage()),
            _tabNav(2, const LibraryPage()),
            _tabNav(3, const BooksPage()),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(),
            _NavBar(tab: tab, onTap: setTab),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTap;
  const _NavBar({required this.tab, required this.onTap});

  static const _items = [
    (Icons.home_outlined, Icons.home_rounded, 'Start'),
    (Icons.search_rounded, Icons.manage_search_rounded, 'Suchen'),
    (Icons.library_music_outlined, Icons.library_music_rounded, 'Bibliothek'),
    (Icons.headphones_outlined, Icons.headphones_rounded, 'Hörbücher'),
  ];

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    return Container(
      padding: EdgeInsets.only(top: 6, bottom: bottom + 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xF00E0E10), Color(0xFF000000)],
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < _items.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => onTap(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(i == tab ? _items[i].$2 : _items[i].$1,
                          color: i == tab ? Colors.white : kMuted, size: 26),
                      const SizedBox(height: 3),
                      Text(
                        _items[i].$3,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: i == tab ? FontWeight.w700 : FontWeight.w500,
                          color: i == tab ? Colors.white : kMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Track?>(
      valueListenable: audio.current,
      builder: (context, t, _) {
        if (t == null) return const SizedBox.shrink();
        return _MiniBody(key: ValueKey(t.id), track: t);
      },
    );
  }
}

class _MiniBody extends StatefulWidget {
  final Track track;
  const _MiniBody({super.key, required this.track});
  @override
  State<_MiniBody> createState() => _MiniBodyState();
}

class _MiniBodyState extends State<_MiniBody> {
  late Color _bg = cachedCoverColor(widget.track.cover) ?? kSurface2;

  @override
  void initState() {
    super.initState();
    coverColor(widget.track.cover).then((c) {
      if (mounted) setState(() => _bg = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return GestureDetector(
      onTap: () => openPlayer(context),
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -200) openPlayer(context);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 2),
        decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(8)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
              child: Row(
                children: [
                  Cover(t.cover, size: 40, radius: 4, fallback: t.isBook ? Icons.menu_book_rounded : Icons.music_note_rounded),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                        Text(t.isBook ? t.album : t.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ],
                    ),
                  ),
                  if (t.isBook)
                    IconButton(
                      icon: const Icon(Icons.replay_10_rounded),
                      onPressed: () => audio.seekRelative(const Duration(seconds: -10)),
                    )
                  else
                    LikeButton(track: t, size: 24),
                  StreamBuilder<PlaybackState>(
                    stream: audio.playbackState,
                    builder: (context, s) {
                      final playing = s.data?.playing ?? false;
                      return ValueListenableBuilder<bool>(
                        valueListenable: audio.loading,
                        builder: (context, loading, _) => IconButton(
                          iconSize: 32,
                          icon: loading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                          onPressed: audio.togglePlay,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            StreamBuilder<Duration>(
              stream: audio.position,
              builder: (context, s) {
                final d = audio.duration.inMilliseconds;
                final p = s.data?.inMilliseconds ?? 0;
                return LinearProgressIndicator(
                  value: d > 0 ? (p / d).clamp(0.0, 1.0).toDouble() : 0,
                  minHeight: 2,
                  backgroundColor: Colors.white24,
                  color: Colors.white,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Wird von Seiten genutzt, die Store-Änderungen anzeigen sollen.
Widget storeBuilder(Widget Function(BuildContext, Store) b) =>
    ListenableBuilder(listenable: Store.instance, builder: (c, _) => b(c, Store.instance));
