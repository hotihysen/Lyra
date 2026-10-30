import 'dart:math';

import '../data/models.dart';

/// Ein Platz in der Warteschlange. [uid] unterscheidet denselben Titel, wenn er
/// mehrmals in der Warteschlange steht.
class QueueEntry {
  final String uid;
  final Track track;
  const QueueEntry(this.uid, this.track);

  Map<String, dynamic> toJson() => {'uid': uid, 'track': track.toJson()};

  static QueueEntry? fromJson(dynamic j) {
    if (j is! Map) return null;
    final uid = j['uid'];
    final t = j['track'];
    if (uid is! String || uid.isEmpty || t is! Map) return null;
    final track = Track.fromJson(t);
    if (track.id.isEmpty) return null;
    return QueueEntry(uid, track);
  }
}

/// Warteschlange mit tatsächlicher Reihenfolge, Originalreihenfolge (für Shuffle)
/// und aktuellem Platz. Reine Logik ohne Player, deshalb direkt testbar.
class PlayQueue {
  List<QueueEntry> items = [];
  /// Originalreihenfolge als uids; enthält immer genau die uids aus [items].
  List<String> original = [];
  int index = -1;
  bool shuffled = false;

  static int _seq = 0;
  static String newUid() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_seq++).toRadixString(36)}';

  bool get isEmpty => items.isEmpty;
  int get length => items.length;
  QueueEntry? get current => index >= 0 && index < items.length ? items[index] : null;
  QueueEntry? get next => index + 1 >= 0 && index + 1 < items.length ? items[index + 1] : null;
  List<Track> get tracks => [for (final e in items) e.track];
  int indexOfUid(String uid) => items.indexWhere((e) => e.uid == uid);

  void setTracks(List<Track> list, {int start = 0, bool shuffle = false, Random? rnd}) {
    items = [for (final t in list) QueueEntry(newUid(), t)];
    original = [for (final e in items) e.uid];
    index = items.isEmpty ? -1 : start.clamp(0, items.length - 1);
    shuffled = false;
    if (shuffle && items.isNotEmpty) setShuffle(true, rnd: rnd);
  }

  /// Übernimmt einen gespeicherten Stand. Fehlende oder fremde uids in [orig] werden
  /// bereinigt, damit [original] immer zu [items] passt.
  void restore(List<QueueEntry> list, List<String> orig, int idx, bool shuf) {
    items = List.of(list);
    final ids = {for (final e in items) e.uid};
    final seen = <String>{};
    original = [for (final u in orig) if (ids.contains(u) && seen.add(u)) u];
    for (final e in items) {
      if (!seen.contains(e.uid)) original.add(e.uid);
    }
    index = items.isEmpty ? -1 : idx.clamp(0, items.length - 1);
    shuffled = shuf;
  }

  bool jump(int i) {
    if (i < 0 || i >= items.length) return false;
    index = i;
    return true;
  }

  void insertNext(Track t) {
    final e = QueueEntry(newUid(), t);
    if (index < 0) {
      setTracks([t]);
      return;
    }
    items.insert(index + 1, e);
    // In der Originalreihenfolge direkt nach dem aktuellen Titel
    final cur = current!.uid;
    final oi = original.indexOf(cur);
    original.insert(oi < 0 ? original.length : oi + 1, e.uid);
  }

  void append(Track t) => appendAll([t]);

  void appendAll(List<Track> list) {
    if (list.isEmpty) return;
    if (index < 0) {
      setTracks(list);
      return;
    }
    for (final t in list) {
      final e = QueueEntry(newUid(), t);
      items.add(e);
      original.add(e.uid);
    }
  }

  /// Entfernt einen Platz (nicht den aktuellen). Auch aus der Originalreihenfolge.
  bool removeAt(int i) {
    if (i == index || i < 0 || i >= items.length) return false;
    final e = items.removeAt(i);
    original.remove(e.uid);
    if (i < index) index--;
    return true;
  }

  void move(int from, int to) {
    if (from == to || from < 0 || from >= items.length) return;
    final cur = current?.uid;
    final e = items.removeAt(from);
    items.insert(to.clamp(0, items.length), e);
    if (cur != null) index = indexOfUid(cur);
    // Ohne Shuffle ist die sichtbare Reihenfolge die Originalreihenfolge
    if (!shuffled) original = [for (final x in items) x.uid];
  }

  /// Entfernt alle kommenden Titel, auch aus der Originalreihenfolge.
  void clearUpcoming() {
    if (index < 0) return;
    final removed = {for (final e in items.sublist(index + 1)) e.uid};
    items = items.sublist(0, index + 1);
    original.removeWhere(removed.contains);
  }

  void setShuffle(bool on, {Random? rnd}) {
    final cur = current;
    if (cur == null) {
      shuffled = on;
      return;
    }
    if (on) {
      final rest = List.of(items)..removeAt(index);
      rest.shuffle(rnd ?? Random());
      items = [cur, ...rest];
      index = 0;
    } else {
      final byUid = {for (final e in items) e.uid: e};
      items = [for (final u in original) if (byUid[u] != null) byUid[u]!];
      index = indexOfUid(cur.uid);
      if (index < 0) {
        items.insert(0, cur);
        original.insert(0, cur.uid);
        index = 0;
      }
    }
    shuffled = on;
  }
}
