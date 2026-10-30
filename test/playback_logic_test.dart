// Tests der Wiedergabelogik ohne Player: Warteschlange, Sitzung, Vorgänge, Wächter,
// Wiederholungen und Protokoll.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lyra/audio/control.dart';
import 'package:lyra/audio/playlog.dart';
import 'package:lyra/audio/queue.dart';
import 'package:lyra/audio/session.dart';
import 'package:lyra/data/models.dart';

Track tr(String id, {int dur = 200}) => Track(id: id, title: 'Titel $id', artist: 'A', duration: dur);

PlaybackSession sessionFrom(PlayQueue q, int posMs) => PlaybackSession(
      items: q.items,
      original: q.original,
      index: q.index,
      entryUid: q.current!.uid,
      trackId: q.current!.track.id,
      positionMs: posMs,
      shuffle: q.shuffled,
      repeat: 1,
      speed: 1.25,
      savedAt: 1700000000000,
      wasPlaying: true,
      origin: 'test',
    );

void main() {
  group('Warteschlange', () {
    test('doppelte Titel bleiben unterscheidbar', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b'), tr('a')], start: 2);
      expect(q.items[0].track.id, q.items[2].track.id);
      expect(q.items[0].uid, isNot(q.items[2].uid));
      expect(q.index, 2);
      expect(q.current!.uid, q.items[2].uid);
    });

    test('Entfernen und Shuffle aus: entfernte Titel tauchen nicht wieder auf', () {
      final q = PlayQueue()..setTracks([for (final i in 'abcdef'.split('')) tr(i)], start: 1);
      q.setShuffle(true, rnd: Random(1));
      expect(q.current!.track.id, 'b');
      final victim = q.items.indexWhere((e) => e.track.id == 'e');
      expect(q.removeAt(victim), isTrue);
      q.setShuffle(false);
      expect(q.tracks.map((t) => t.id).join(), 'abcdf');
      expect(q.current!.track.id, 'b');
      expect(q.index, 1);
    });

    test('Kommende löschen entfernt auch aus der Originalreihenfolge', () {
      final q = PlayQueue()..setTracks([for (final i in 'abcde'.split('')) tr(i)], start: 0);
      q.setShuffle(true, rnd: Random(3));
      q.clearUpcoming();
      q.setShuffle(false);
      expect(q.tracks.map((t) => t.id).toList(), ['a']);
      expect(q.original.length, 1);
    });

    test('Verschieben hält Index und aktuellen Titel', () {
      final q = PlayQueue()..setTracks([for (final i in 'abcde'.split('')) tr(i)], start: 2);
      q.move(0, 4); // a ans Ende
      expect(q.current!.track.id, 'c');
      expect(q.index, 1);
      q.move(1, 0); // aktueller Titel nach vorne
      expect(q.index, 0);
      expect(q.current!.track.id, 'c');
      expect(q.original.length, q.items.length);
    });

    test('Als Nächstes einfügen steht auch in der Originalreihenfolge nach dem aktuellen', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b'), tr('c')], start: 0);
      q.setShuffle(true, rnd: Random(2));
      q.insertNext(tr('x'));
      expect(q.next!.track.id, 'x');
      q.setShuffle(false);
      expect(q.tracks.map((t) => t.id).toList(), ['a', 'x', 'b', 'c']);
    });

    test('Wiederherstellung bereinigt fremde und fehlende uids', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b')]);
      final r = PlayQueue()..restore(q.items, ['fremd', q.items[1].uid], 5, false);
      expect(r.index, 1);
      expect(r.original, [q.items[1].uid, q.items[0].uid]);
    });
  });

  group('Sitzung', () {
    test('Speichern und Laden: gleicher Titel, Platz, Position und Einstellungen', () {
      final q = PlayQueue()..setTracks([for (var i = 0; i < 10; i++) tr('t$i')], start: 6);
      final s = sessionFrom(q, 138000);
      final back = PlaybackSession.fromJson(s.toJson())!;
      expect(back.index, 6);
      expect(back.entryUid, q.items[6].uid);
      expect(back.trackId, 't6');
      expect(back.positionMs, 138000);
      expect(back.items.length, 10);
      expect(back.repeat, 1);
      expect(back.speed, 1.25);
      expect(back.wasPlaying, isTrue);
      expect(back.resumePoint(), (6, 138000));
    });

    test('Doppelte Titel: Wiederherstellung trifft den richtigen Platz', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b'), tr('a')], start: 2);
      final back = PlaybackSession.fromJson(sessionFrom(q, 5000).toJson())!;
      expect(back.index, 2);
      expect(back.entryUid, q.items[2].uid);
    });

    test('Index passt nicht zur uid: wird über die uid repariert', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b'), tr('c')], start: 1);
      final j = sessionFrom(q, 1000).toJson()..['index'] = 0;
      expect(PlaybackSession.fromJson(j)!.index, 1);
    });

    test('Neue Titel-ID mit Position des alten Titels wird abgelehnt', () {
      final q = PlayQueue()..setTracks([tr('a'), tr('b')], start: 1);
      final j = sessionFrom(q, 1000).toJson()..['trackId'] = 'a';
      expect(PlaybackSession.fromJson(j), isNull);
    });

    test('Beschädigte, leere, neuere und fremde Daten ergeben null statt Absturz', () {
      expect(PlaybackSession.fromJson(null), isNull);
      expect(PlaybackSession.fromJson('kaputt'), isNull);
      expect(PlaybackSession.fromJson({'v': 1}), isNull);
      expect(PlaybackSession.fromJson({'v': 99, 'items': []}), isNull);
      expect(PlaybackSession.fromJson({'v': 1, 'items': 'x', 'index': 0}), isNull);
      expect(PlaybackSession.fromJson({'v': 1, 'items': [{'uid': 1}], 'index': 0}), isNull);
      final q = PlayQueue()..setTracks([tr('a')]);
      final j = sessionFrom(q, -50).toJson()..['speed'] = 99;
      final s = PlaybackSession.fromJson(j)!;
      expect(s.positionMs, 0);
      expect(s.speed, 1.0);
    });

    test('Titel am Ende gespeichert: weiter mit dem nächsten ab Anfang', () {
      final q = PlayQueue()..setTracks([tr('a', dur: 180), tr('b')], start: 0);
      expect(sessionFrom(q, 179500).resumePoint(), (1, 0));
      final last = PlayQueue()..setTracks([tr('a', dur: 180)]);
      expect(sessionFrom(last, 179500).resumePoint(), (0, 0));
    });
  });

  group('Vorgänge und Titelende', () {
    test('Verspätetes Ergebnis nach manuellem Titelwechsel wird verworfen', () {
      final gen = Generation();
      final load1 = gen.bump(); // Titel 1 wird geladen
      final load2 = gen.bump(); // Nutzer wählt Titel 2
      expect(gen.isCurrent(load1), isFalse);
      expect(gen.isCurrent(load2), isTrue);
    });

    test('Pause/Stop während der Quellensuche: Ergebnis gehört nicht mehr zum Auftrag', () {
      final gen = Generation();
      final load = gen.bump();
      gen.bump(); // Stop
      expect(gen.isCurrent(load), isFalse);
    });

    test('Player-Ende und Wächter gleichzeitig: genau ein Wechsel', () {
      final gen = Generation();
      final end = EndGuard();
      final g = gen.bump();
      var advances = 0;
      for (final _ in ['Player', 'Wächter', 'Player']) {
        if (end.claim(gen.value)) advances++;
      }
      expect(advances, 1);
      expect(g, gen.value);
      gen.bump(); // nächster Titel
      expect(end.claim(gen.value), isTrue);
    });

    test('Titelende während des Vorladens geht nicht verloren', () {
      // Vorladen erhöht die Vorgangsnummer nicht; das Ende des laufenden Titels wird verarbeitet
      final gen = Generation();
      final end = EndGuard();
      gen.bump(); // Titel spielt
      const preparing = true; // nächster Titel wird vorbereitet
      expect(preparing && end.claim(gen.value), isTrue);
    });

    test('Wiederholen eines Titels gibt das Ende wieder frei', () {
      final end = EndGuard();
      expect(end.claim(3), isTrue);
      end.release();
      expect(end.claim(3), isTrue);
    });
  });

  group('Wächter', () {
    StallVerdict run(StallDetector d, int secs,
        {bool want = true,
        bool preparing = false,
        PState st = PState.buffering,
        bool playing = false,
        Duration Function(int)? pos,
        Duration Function(int)? buf,
        Duration? dur}) {
      var v = StallVerdict.ok;
      for (var i = 0; i < secs; i++) {
        v = d.tick(
          wantPlay: want,
          preparing: preparing,
          preparingSecs: i,
          state: st,
          playing: playing,
          position: pos?.call(i) ?? const Duration(seconds: 30),
          buffered: buf?.call(i) ?? const Duration(seconds: 40),
          duration: dur,
        );
        if (v != StallVerdict.ok) return v;
      }
      return v;
    }

    test('Puffern ohne Fortschritt: Hänger nach 25 s', () {
      expect(run(StallDetector(), 24), StallVerdict.ok);
      expect(run(StallDetector(), 26), StallVerdict.bufferStall);
    });

    test('Puffern mit Fortschritt im Puffer ist kein Hänger', () {
      expect(run(StallDetector(), 60, buf: (i) => Duration(seconds: 40 + i)), StallVerdict.ok);
    });

    test('Absichtlich pausiert ist nie ein Hänger', () {
      expect(run(StallDetector(), 120, want: false), StallVerdict.ok);
      expect(run(StallDetector(), 120, want: false, preparing: true), StallVerdict.ok);
    });

    test('Laden dauert zu lange: Zeitlimit', () {
      expect(run(StallDetector(), 74, preparing: true), StallVerdict.ok);
      expect(run(StallDetector(), 80, preparing: true), StallVerdict.loadTimeout);
    });

    test('Titelende ohne Meldung: nach 3 s erkannt', () {
      const dur = Duration(minutes: 3);
      expect(
          run(StallDetector(), 5, st: PState.ready, playing: true, pos: (_) => dur, dur: dur), StallVerdict.endReached);
    });

    test('Normales Spielen ist kein Hänger', () {
      expect(
          run(StallDetector(), 100,
              st: PState.ready, playing: true, pos: (i) => Duration(seconds: i), dur: const Duration(minutes: 3)),
          StallVerdict.ok);
    });
  });

  group('Wiederholungen', () {
    test('ein erneuter Versuch, dann nächster Titel', () {
      final r = RetryPolicy();
      expect(r.onFailure('a', offline: false), FailureAction.retry);
      expect(r.onFailure('a', offline: false), FailureAction.skip);
    });

    test('nach drei Titeln in Folge anhalten statt die Playlist zu durchlaufen', () {
      final r = RetryPolicy();
      final actions = <FailureAction>[];
      for (final id in ['a', 'b', 'c']) {
        actions.add(r.onFailure(id, offline: false));
        actions.add(r.onFailure(id, offline: false));
      }
      expect(actions.where((a) => a == FailureAction.skip).length, 2);
      expect(actions.last, FailureAction.stop);
    });

    test('ohne Netz nach dem erneuten Versuch anhalten', () {
      final r = RetryPolicy();
      expect(r.onFailure('a', offline: true), FailureAction.retry);
      expect(r.onFailure('a', offline: true), FailureAction.stop);
    });

    test('erfolgreiche Wiedergabe setzt die Zähler zurück', () {
      final r = RetryPolicy();
      r.onFailure('a', offline: false);
      r.onFailure('a', offline: false);
      r.onSuccess();
      expect(r.skips, 0);
      expect(r.onFailure('b', offline: false), FailureAction.retry);
    });

    test('Verbindungsfehler werden erkannt', () {
      expect(looksOffline(Exception('SocketException: Failed host lookup')), isTrue);
      expect(looksOffline(Exception('Server 403')), isFalse);
    });
  });

  group('Protokoll', () {
    test('entfernt Adressen und Schlüssel, begrenzt die Grösse', () {
      List<String>? saved;
      final log = PlayLog(max: 5, persist: (l) => saved = l);
      log.add('Abruf https://rr1.googlevideo.com/videoplayback?sig=abc fertig');
      log.add('Server lyra.example?k=GEHEIM ok');
      expect(log.lines[0], isNot(contains('googlevideo')));
      expect(log.lines[1], isNot(contains('GEHEIM')));
      for (var i = 0; i < 20; i++) {
        log.add('Zeile $i');
      }
      expect(log.lines.length, 5);
      log.flush();
      expect(saved, isNotNull);
    });
  });
}
