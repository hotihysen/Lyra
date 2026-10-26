import 'package:flutter/material.dart';

import '../../api/librivox.dart';
import '../../data/downloads.dart';
import '../../data/models.dart';
import '../../data/store.dart';
import '../../main.dart';
import '../shell.dart';
import '../theme.dart';
import '../widgets.dart';

class BooksPage extends StatefulWidget {
  const BooksPage({super.key});
  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  final _ctrl = TextEditingController();
  late Future<List<Book>> _f = LibriVox.recent();
  String _q = '';

  static const _authors = ['Kafka', 'Goethe', 'Schiller', 'Grimm', 'Fontane', 'Austen', 'Doyle', 'Twain', 'Verne'];

  void _search(String q, {bool author = false}) {
    setState(() {
      _q = q.trim();
      if (_q.isEmpty) {
        _f = LibriVox.recent();
      } else {
        _f = author ? LibriVox.byAuthor(_q) : LibriVox.search(_q);
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        bottom: false,
        child: storeBuilder((context, s) {
          final cont = s.continueBooks();
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Text('Hörbücher', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 2, 16, 0),
                child: Text('Gemeinfreie Hörbücher von LibriVox, kostenlos und legal',
                    style: TextStyle(color: kMuted, fontSize: 13)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: TextField(
                  controller: _ctrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _search(v),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: kSurface2,
                    hintText: 'Titel suchen, z. B. «Verwandlung»',
                    hintStyle: const TextStyle(color: kMuted),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _q.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _ctrl.clear();
                              _search('');
                            },
                          ),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                  children: [
                    for (final a in _authors)
                      Pill(a, selected: _q == a, onTap: () {
                        _ctrl.text = '';
                        _search(a, author: true);
                      }),
                  ],
                ),
              ),
              if (cont.isNotEmpty && _q.isEmpty)
                Carousel(
                  title: 'Weiterhören',
                  size: 130,
                  items: [
                    for (final b in cont)
                      CardItem(
                        image: b.cover,
                        title: b.title,
                        subtitle: b.author,
                        fallback: Icons.menu_book_rounded,
                        onTap: () => openPage(BookPage(book: b)),
                      ),
                  ],
                ),
              SectionTitle(_q.isEmpty ? 'Neu bei LibriVox' : 'Ergebnisse für «$_q»'),
              FutureBuilder<List<Book>>(
                future: _f,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
                  }
                  final list = snap.data ?? const <Book>[];
                  if (snap.hasError || list.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Text(snap.hasError ? 'LibriVox ist gerade nicht erreichbar' : 'Nichts gefunden',
                            style: const TextStyle(color: kMuted)),
                      ),
                    );
                  }
                  return Column(children: [for (final b in list) _BookTile(book: b)]);
                },
              ),
            ],
          );
        }),
      ),
    );
  }
}

class _BookTile extends StatelessWidget {
  final Book book;
  const _BookTile({required this.book});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => openPage(BookPage(book: book)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Cover(book.cover, size: 72, radius: 6, fallback: Icons.menu_book_rounded),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(book.author, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted)),
                  const SizedBox(height: 3),
                  Text('${book.chapters.length} Kapitel · ${fmtLong(book.totalSeconds)}',
                      style: const TextStyle(color: kMuted, fontSize: 12.5)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BookPage extends StatefulWidget {
  final Book book;
  const BookPage({super.key, required this.book});
  @override
  State<BookPage> createState() => _BookPageState();
}

class _BookPageState extends State<BookPage> {
  bool _expanded = false;

  void _play(int start) {
    Store.instance.saveBook(widget.book);
    audio.playTracks(widget.book.chapters, start: start);
  }

  int _resumeIndex() {
    final last = Store.instance.lastChapter(widget.book.id);
    final i = widget.book.chapters.indexWhere((c) => c.id == last);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.book;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(),
      body: storeBuilder((context, s) {
        final hasProgress = s.lastChapter(b.id) != null;
        final resume = _resumeIndex();
        final saved = s.books.containsKey(b.id);
        return ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Center(
              child: Container(
                decoration: const BoxDecoration(boxShadow: [
                  BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
                ]),
                child: Cover(b.cover, size: 210, radius: 8, fallback: Icons.menu_book_rounded),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.title, style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                  const SizedBox(height: 4),
                  Text(b.author, style: const TextStyle(color: kMuted, fontSize: 15)),
                  const SizedBox(height: 4),
                  Text('${b.chapters.length} Kapitel · ${fmtLong(b.totalSeconds)}',
                      style: const TextStyle(color: kMuted, fontSize: 13)),
                  if (b.description.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    GestureDetector(
                      onTap: () => setState(() => _expanded = !_expanded),
                      child: Text(
                        b.description,
                        maxLines: _expanded ? null : 3,
                        overflow: _expanded ? null : TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, height: 1.4),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        icon: Icon(saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
                            color: saved ? accent : Colors.white),
                        onPressed: () => s.saveBook(b),
                      ),
                      _DownloadBook(book: b),
                      const Spacer(),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: accent,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                        ),
                        onPressed: () => _play(resume),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: Text(hasProgress ? 'Weiterhören' : 'Abspielen',
                            style: const TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SectionTitle('Kapitel'),
            for (var i = 0; i < b.chapters.length; i++)
              TrackTile(
                track: b.chapters[i],
                number: i + 1,
                showCover: false,
                trailing: DownloadButton(track: b.chapters[i], size: 22),
                onTap: () => _play(i),
              ),
          ],
        );
      }),
    );
  }
}

class _DownloadBook extends StatelessWidget {
  final Book book;
  const _DownloadBook({required this.book});
  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: Downloads.progress,
      builder: (context, prog, _) {
        final s = Store.instance;
        final all = book.chapters.every(s.isDownloaded);
        final running = book.chapters.any((c) => prog.containsKey(c.id));
        if (running) {
          return SizedBox(
            width: 48,
            height: 48,
            child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: accent))),
          );
        }
        return IconButton(
          icon: Icon(all ? Icons.download_done_rounded : Icons.download_for_offline_outlined, color: all ? accent : Colors.white),
          onPressed: all
              ? null
              : () async {
                  s.saveBook(book);
                  toast(context, 'Hörbuch wird heruntergeladen');
                  final n = await Downloads.downloadAll(book.chapters);
                  if (context.mounted) toast(context, '$n von ${book.chapters.length} Kapiteln heruntergeladen');
                },
        );
      },
    );
  }
}
