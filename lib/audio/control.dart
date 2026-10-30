/// Zustände und Regeln der Wiedergabesteuerung. Reine Logik ohne Player, testbar.
library;

enum PlayPhase { idle, paused, resolving, buffering, playing, retrying, failed, ended }

String phaseLabel(PlayPhase p) => switch (p) {
      PlayPhase.idle => 'Bereit',
      PlayPhase.paused => 'Pausiert',
      PlayPhase.resolving => 'Audioquelle wird gesucht',
      PlayPhase.buffering => 'Titel wird geladen',
      PlayPhase.playing => 'Spielt',
      PlayPhase.retrying => 'Verbindung unterbrochen – erneuter Versuch',
      PlayPhase.failed => 'Titel konnte nicht geladen werden',
      PlayPhase.ended => 'Warteschlange beendet',
    };

/// Vorgangsnummer. Jeder Auftrag (Titelwahl, Stop, neue Playlist) erhöht sie; ein
/// asynchroner Schritt prüft danach, ob sein Ergebnis noch zum aktuellen Auftrag gehört.
class Generation {
  int _v = 0;
  int get value => _v;
  int bump() => ++_v;
  bool isCurrent(int g) => g == _v;
}

/// Sorgt dafür, dass ein Titelende pro Vorgang genau einmal verarbeitet wird, egal ob
/// es vom Player, vom Wächter oder von der Fehlerbehandlung gemeldet wird.
class EndGuard {
  int? _handled;
  bool claim(int gen) {
    if (_handled == gen) return false;
    _handled = gen;
    return true;
  }

  void release() => _handled = null;
}

/// Vereinfachter Player-Zustand (unabhängig von just_audio).
enum PState { idle, loading, buffering, ready, completed }

enum StallVerdict { ok, endReached, bufferStall, loadTimeout }

/// Erkennt festhängendes Laden, Puffern und Titelende. Wird jede Sekunde aufgerufen.
/// Ein absichtlich pausierter Player gilt nie als Hänger.
class StallDetector {
  StallDetector({this.loadLimit = 75, this.bufferLimit = 25, this.endLimit = 3});

  final int loadLimit; // Sekunden für Quellensuche und Vorbereitung zusammen
  final int bufferLimit; // Sekunden ohne Positions- und Pufferfortschritt
  final int endLimit; // Sekunden am Titelende ohne Abschlussmeldung

  Duration? _lastPos;
  Duration? _lastBuf;
  int _bufferSecs = 0;
  int _endSecs = 0;

  void reset() {
    _lastPos = null;
    _lastBuf = null;
    _bufferSecs = 0;
    _endSecs = 0;
  }

  StallVerdict tick({
    required bool wantPlay,
    required bool preparing,
    required int preparingSecs,
    required PState state,
    required bool playing,
    required Duration position,
    required Duration buffered,
    Duration? duration,
  }) {
    if (!wantPlay) {
      reset();
      return StallVerdict.ok;
    }
    if (preparing) {
      _bufferSecs = 0;
      _endSecs = 0;
      return preparingSecs >= loadLimit ? StallVerdict.loadTimeout : StallVerdict.ok;
    }
    final posMoved = _lastPos == null || (position - _lastPos!).abs() >= const Duration(milliseconds: 300);
    final bufMoved = _lastBuf == null || buffered - _lastBuf! >= const Duration(milliseconds: 300);
    _lastPos = position;
    _lastBuf = buffered;

    if (state == PState.buffering || state == PState.loading) {
      _endSecs = 0;
      _bufferSecs = (posMoved || bufMoved) ? 0 : _bufferSecs + 1;
      return _bufferSecs >= bufferLimit ? StallVerdict.bufferStall : StallVerdict.ok;
    }
    _bufferSecs = 0;
    if (state == PState.ready && playing && duration != null && duration >= const Duration(seconds: 10)) {
      final atEnd = position >= duration - const Duration(milliseconds: 1500);
      final pastEnd = position > duration + const Duration(seconds: 3);
      if (pastEnd || (atEnd && !posMoved)) {
        _endSecs++;
        if (_endSecs >= endLimit) {
          _endSecs = 0;
          return StallVerdict.endReached;
        }
        return StallVerdict.ok;
      }
    }
    _endSecs = 0;
    return StallVerdict.ok;
  }
}

enum FailureAction { retry, skip, stop }

/// Begrenzte Wiederholung: pro Titel ein erneuter Versuch mit frischer Quelle, danach
/// zum nächsten Titel. Nach mehreren Fehlschlägen in Folge oder ohne Netz anhalten,
/// statt die ganze Playlist zu durchlaufen.
class RetryPolicy {
  RetryPolicy({this.retriesPerTrack = 1, this.maxSkips = 3});

  final int retriesPerTrack;
  final int maxSkips;
  String? _uid;
  int _attempts = 0;
  int _skips = 0;

  int get skips => _skips;

  FailureAction onFailure(String uid, {required bool offline}) {
    if (uid != _uid) {
      _uid = uid;
      _attempts = 0;
    }
    _attempts++;
    if (_attempts <= retriesPerTrack) return FailureAction.retry;
    if (offline) return FailureAction.stop;
    _skips++;
    if (_skips >= maxSkips) return FailureAction.stop;
    return FailureAction.skip;
  }

  /// Titel spielt: Zähler zurücksetzen.
  void onSuccess() {
    _attempts = 0;
    _skips = 0;
    _uid = null;
  }

  /// Ausdrückliche Wahl des Nutzers (Play, Titel antippen, Wiederholen).
  void onUserAction() {
    _attempts = 0;
    _skips = 0;
    _uid = null;
  }
}

/// Erkennt Fehler, die auf fehlende Verbindung hindeuten.
bool looksOffline(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('socketexception') ||
      s.contains('failed host lookup') ||
      s.contains('network is unreachable') ||
      s.contains('keine internetverbindung') ||
      s.contains('connection refused') ||
      s.contains('no address associated');
}
