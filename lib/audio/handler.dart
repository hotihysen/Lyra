import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../api/ytmusic.dart';
import '../api/youtube.dart';
import '../data/mix.dart';
import '../data/models.dart';
import '../data/store.dart';
import '../data/updater.dart';
import 'control.dart';
import 'playlog.dart';
import 'queue.dart';
import 'session.dart';

enum RepeatSetting { off, all, one }

/// Auf dem zweiten Player vorbereiteter nächster Titel.
class _Prepared {
  final int id;
  final String uid;
  final Track track;
  bool ready = false;
  DateTime? readyAt;
  _Prepared(this.id, this.uid, this.track);
}

/// Wiedergabe mit zwei Playern: einer spielt, der andere bereitet den nächsten Titel vor
/// (für sofortigen Wechsel und für Crossfade).
///
/// Grundregeln:
/// * Jeder Auftrag (Titelwahl, Stop, neue Playlist, Überblendung) erhöht die Vorgangsnummer
///   [_gen]. Asynchrone Schritte prüfen danach, ob ihr Ergebnis noch gilt; sonst werden sie
///   verworfen. So startet kein verspäteter Abruf Musik nach einer Pause und überschreibt
///   keinen neu gewählten Titel.
/// * [_wantPlay] ist die Absicht des Nutzers. Pause setzt sie zurück; ein laufender
///   Ladevorgang lädt dann fertig, startet aber nicht.
/// * Während eines Titelwechsels meldet Lyra dem System weiter «spielt», damit der
///   Vordergrunddienst bestehen bleibt und Android den Abruf bei gesperrtem Bildschirm
///   nicht anhält.
/// * Die Sitzung (Warteschlange, Titel, Position) wird laufend gespeichert und beim Start
///   pausiert wiederhergestellt.
class LyraAudioHandler extends BaseAudioHandler with SeekHandler {
  LyraAudioHandler() {
    _init();
  }

  final _players = [AudioPlayer(), AudioPlayer()];
  int _active = 0;
  AudioPlayer get _p => _players[_active];
  AudioPlayer get _other => _players[1 - _active];

  final q = PlayQueue();
  List<Track> get tracks => q.tracks;
  int get index => q.index;

  final current = ValueNotifier<Track?>(null);
  final queueVersion = ValueNotifier<int>(0);
  final repeat = ValueNotifier<RepeatSetting>(RepeatSetting.off);
  final shuffle = ValueNotifier<bool>(false);
  final speed = ValueNotifier<double>(1.0);
  final loading = ValueNotifier<bool>(false);
  final sleepAt = ValueNotifier<DateTime?>(null);
  final sleepAfterTrack = ValueNotifier<bool>(false);
  final error = ValueNotifier<String?>(null);
  final phase = ValueNotifier<PlayPhase>(PlayPhase.idle);

  /// Verständlicher Zustand für die Anzeige (null, wenn nichts Besonderes los ist).
  final status = ValueNotifier<String?>(null);

  late final PlayLog log = PlayLog(initial: Store.instance.loadPlayLog(), persist: Store.instance.savePlayLog);

  final _gen = Generation();
  final _end = EndGuard();
  final _stall = StallDetector();
  final _retry = RetryPolicy();
  bool _wantPlay = false;
  String? _loadedUid;
  DateTime? _preparingSince;
  Duration? _pendingPosition;
  int? _failureGen;
  String _origin = '';

  _Prepared? _prep;
  int _prepSeq = 0;
  Future<void> _prepLock = Future.value();

  bool _fading = false;
  DateTime? _fadeStarted;
  AudioPlayer? _fadeFrom;
  Timer? _fadeTimer;

  Timer? _sleepTimer;
  Timer? _saveTimer;
  bool _saving = false;
  bool _saveAgain = false;
  bool _queueDirty = true;
  int _tick = 0;
  String _lastStateLog = '';

  late final Stream<Duration> position =
      Stream<Duration>.periodic(const Duration(milliseconds: 250), (_) => _displayPosition).asBroadcastStream();

  bool get _isLoaded => _loadedUid != null && _loadedUid == q.current?.uid;
  Duration get _displayPosition => _isLoaded ? _p.position : (_pendingPosition ?? Duration.zero);

  Duration get duration {
    final d = _isLoaded ? _p.duration : null;
    if (d != null && d > Duration.zero) return d;
    return Duration(seconds: current.value?.duration ?? 0);
  }

  List<Track> get upcoming => q.index < 0 || q.index + 1 > q.length ? [] : q.tracks.sublist(q.index + 1);

  // ---------- Hilfen ----------

  void _log(String s) {
    log.add(s);
    if (kDebugMode) debugPrint('Lyra: $s');
  }

  static String _short(Object? e) {
    var s = '$e'.replaceFirst('Exception: ', '').split('\n').first;
    if (s.length > 110) s = '${s.substring(0, 110)}…';
    return s;
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  static PState _pstate(ProcessingState s) => switch (s) {
        ProcessingState.idle => PState.idle,
        ProcessingState.loading => PState.loading,
        ProcessingState.buffering => PState.buffering,
        ProcessingState.ready => PState.ready,
        ProcessingState.completed => PState.completed,
      };

  void _updateInUse() {
    YT.inUse
      ..clear()
      ..addAll([q.current?.track.id, _prep?.track.id].whereType<String>());
  }

  // ---------- Start ----------

  Future<void> _init() async {
    _log('Lyra ${Updater.version} gestartet');
    _restoreSession();
    for (final pl in _players) {
      pl.playbackEventStream.listen(
        (_) {
          if (identical(pl, _p)) _broadcast();
        },
        onError: (Object e, StackTrace s) {
          if (identical(pl, _p)) {
            _onPlayerError(e);
          } else {
            _onPrepError(e);
          }
        },
      );
      pl.playerStateStream.listen((st) {
        if (identical(pl, _p)) _onPlayerState(st);
      });
    }
    Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    unawaited(YT.cleanTemp());
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      session.interruptionEventStream.listen((e) {
        _log('Audio-Unterbrechung ${e.begin ? 'Beginn' : 'Ende'} (${e.type.name})');
        // Dauerhafte Unterbrechung (anderer Player übernimmt): nicht von selbst weiterspielen
        if (e.begin && e.type == AudioInterruptionType.unknown) {
          _wantPlay = false;
          _setPhase(PlayPhase.paused);
          _scheduleSave(now: true);
        }
      });
      session.becomingNoisyEventStream.listen((_) {
        // Kopfhörer/Bluetooth getrennt: just_audio pausiert; Absicht entsprechend anpassen
        _log('Audioausgabe getrennt (Bluetooth oder Kopfhörer) – pausiert');
        _wantPlay = false;
        _setPhase(PlayPhase.paused);
        _scheduleSave(now: true);
      });
    } catch (e) {
      _log('Audiositzung nicht eingerichtet: ${_short(e)}');
    }
  }

  // ---------- Zustand an System/Benachrichtigung melden ----------

  static const _stateMap = {
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _setPhase(PlayPhase ph, [String? text]) {
    phase.value = ph;
    status.value = text ??
        (ph == PlayPhase.playing || ph == PlayPhase.paused || ph == PlayPhase.idle ? null : phaseLabel(ph));
    loading.value = ph == PlayPhase.resolving || ph == PlayPhase.buffering || ph == PlayPhase.retrying;
    _broadcast();
  }

  void _broadcast() {
    final p = _p;
    final isBook = current.value?.isBook ?? false;
    final transitioning = loading.value;
    // Während eines Wechsels «spielt» melden, damit der Vordergrunddienst erhalten bleibt
    final playing = p.playing || (_wantPlay && transitioning);
    final AudioProcessingState ps;
    switch (phase.value) {
      case PlayPhase.resolving:
      case PlayPhase.retrying:
        ps = AudioProcessingState.loading;
      case PlayPhase.buffering:
        ps = AudioProcessingState.buffering;
      case PlayPhase.failed:
        ps = AudioProcessingState.error;
      default:
        // Wiederhergestellte, noch nicht geladene Sitzung: als bereit (pausiert) zeigen
        ps = !_isLoaded && q.current != null
            ? AudioProcessingState.ready
            : (_stateMap[p.processingState] ?? AudioProcessingState.idle);
    }
    playbackState.add(playbackState.value.copyWith(
      controls: [
        isBook ? MediaControl.rewind : MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        isBook ? MediaControl.fastForward : MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: ps,
      playing: playing,
      updatePosition: _displayPosition,
      bufferedPosition: _isLoaded ? p.bufferedPosition : Duration.zero,
      speed: speed.value,
      queueIndex: q.index < 0 ? null : q.index,
      errorMessage: phase.value == PlayPhase.failed ? (status.value ?? 'Fehler') : null,
    ));
  }

  MediaItem _item(Track t, [Duration? d]) => MediaItem(
        id: t.id,
        title: t.title,
        artist: t.artist,
        album: t.album,
        artUri: t.cover.isEmpty ? null : Uri.parse(t.cover),
        duration: d ?? (t.duration > 0 ? Duration(seconds: t.duration) : null),
      );

  void _publishQueue() {
    queue.add([for (final e in q.items) _item(e.track)]);
    queueVersion.value++;
    _queueDirty = true;
    _checkPrep();
    _updateInUse();
    _scheduleSave();
  }

  void _onPlayerState(PlayerState st) {
    final ps = st.processingState;
    final key = '${ps.name}/${st.playing}';
    if (key != _lastStateLog) {
      _lastStateLog = key;
      _log('Player: ${ps.name}, ${st.playing ? 'spielt' : 'steht'} bei ${_fmt(_p.position)} (Puffer ${_fmt(_p.bufferedPosition)})');
    }
    if (ps == ProcessingState.completed) {
      _onTrackEnd('Player meldet Titelende');
      return;
    }
    if (_preparingSince == null && _isLoaded) {
      if (st.playing && ps == ProcessingState.ready) {
        if (phase.value != PlayPhase.playing) {
          _setPhase(PlayPhase.playing);
          _retry.onSuccess();
          error.value = null;
        }
      } else if (ps == ProcessingState.buffering || ps == ProcessingState.loading) {
        if (_wantPlay) _setPhase(PlayPhase.buffering);
      } else if (ps == ProcessingState.ready && !st.playing && !_wantPlay) {
        _setPhase(PlayPhase.paused);
      }
    }
    _broadcast();
  }

  // ---------- Warteschlange ----------

  Future<void> playTracks(List<Track> list, {int start = 0, bool shuffled = false, String origin = ''}) async {
    if (list.isEmpty) return;
    _log('Neue Warteschlange: ${list.length} Titel, Start bei ${start + 1}${shuffled ? ', Shuffle' : ''}');
    _radioCont = null;
    _radioList = null;
    _origin = origin;
    q.setTracks(list, start: start, shuffle: shuffled);
    shuffle.value = q.shuffled;
    _pendingPosition = null;
    _discardPrep();
    _publishQueue();
    _retry.onUserAction();
    _wantPlay = true;
    await _load(q.index, trigger: 'Neue Warteschlange');
  }

  Future<void> playShuffled(List<Track> list) async {
    if (list.isEmpty) return;
    final start = DateTime.now().microsecondsSinceEpoch % list.length;
    await playTracks(list, start: start, shuffled: true);
  }

  void addNext(Track t) {
    if (q.isEmpty) {
      playTracks([t]);
      return;
    }
    q.insertNext(t);
    _publishQueue();
  }

  void addToQueue(Track t) {
    if (q.isEmpty) {
      playTracks([t]);
      return;
    }
    q.append(t);
    _publishQueue();
  }

  void removeAt(int i) {
    if (q.removeAt(i)) _publishQueue();
  }

  void move(int from, int to) {
    q.move(from, to);
    _publishQueue();
  }

  void clearUpcoming() {
    q.clearUpcoming();
    _publishQueue();
  }

  void toggleShuffle() {
    if (q.current == null) return;
    q.setShuffle(!q.shuffled);
    shuffle.value = q.shuffled;
    _log('Shuffle ${q.shuffled ? 'an' : 'aus'}');
    _publishQueue();
    _broadcast();
  }

  void cycleRepeat() {
    repeat.value = RepeatSetting.values[(repeat.value.index + 1) % RepeatSetting.values.length];
    _log('Wiederholen: ${repeat.value.name}');
    if (repeat.value == RepeatSetting.one) _discardPrep();
    _scheduleSave();
  }

  // ---------- Laden & Abspielen ----------

  Future<AudioSource> _source(Track t, {Duration budget = const Duration(seconds: 60)}) async {
    final s = Store.instance;
    if (s.isDownloaded(t)) {
      final f = s.audioFile(t);
      if (f != null) {
        YT.lastWay = 'Download';
        return AudioSource.file(f.path);
      }
    }
    if (t.url != null) {
      YT.lastWay = 'Direkte Adresse';
      return AudioSource.uri(Uri.parse(t.url!));
    }
    return YT.audioSource(t, budget: budget);
  }

  void _startPlayback(int g) {
    final pl = _p;
    unawaited(pl.play().catchError((Object e) {
      if (_gen.isCurrent(g) && identical(pl, _p)) _onPlayerError(e);
    }));
  }

  /// Lädt den Titel an Platz [i] und spielt ihn, wenn der Nutzer spielen möchte.
  Future<void> _load(int i, {required String trigger, Duration? startAt}) async {
    _saveBookProgress();
    if (!q.jump(i)) return;
    final g = _gen.bump();
    _finishFade();
    final e = q.current!;
    final t = e.track;
    current.value = t;
    mediaItem.add(_item(t));
    error.value = null;
    _failureGen = null;
    _pendingPosition = startAt ?? (t.isBook ? Store.instance.bookPos(t) : null);
    _loadedUid = null;
    _stall.reset();
    _updateInUse();
    _log('[$g] Titel ${q.index + 1}/${q.length} «${t.title}» (${t.id}), Auslöser: $trigger'
        '${_pendingPosition != null ? ', ab ${_fmt(_pendingPosition!)}' : ''}');

    final prep = _prep;
    if (prep != null &&
        prep.uid == e.uid &&
        prep.ready &&
        prep.readyAt != null &&
        DateTime.now().difference(prep.readyAt!) < const Duration(minutes: 30) &&
        _pendingPosition == null) {
      _activatePrepared(g, e);
      return;
    }
    _discardPrep();
    _preparingSince = DateTime.now();
    _setPhase(PlayPhase.resolving);
    _scheduleSave();
    final sw = Stopwatch()..start();
    try {
      await _p.pause();
      final src = await _source(t).timeout(const Duration(seconds: 70));
      if (!_gen.isCurrent(g)) {
        _log('[$g] Quelle verworfen (inzwischen anderer Auftrag)');
        return;
      }
      _log('[$g] Quelle nach ${sw.elapsedMilliseconds} ms über ${YT.lastWay}');
      _setPhase(PlayPhase.buffering);
      final d = await _p.setAudioSource(src, initialPosition: _pendingPosition).timeout(const Duration(seconds: 30));
      if (!_gen.isCurrent(g)) {
        _log('[$g] Vorbereitung verworfen (inzwischen anderer Auftrag)');
        return;
      }
      _preparingSince = null;
      _loadedUid = e.uid;
      // Gespeicherte Position gegen die echte Länge prüfen
      if (_pendingPosition != null && d != null && _pendingPosition! >= d - const Duration(seconds: 2)) {
        await _p.seek(Duration.zero);
      }
      _pendingPosition = null;
      await _p.setVolume(1);
      await _p.setSpeed(speed.value);
      if (d != null) mediaItem.add(_item(t, d));
      _log('[$g] Player bereit nach ${sw.elapsedMilliseconds} ms (Länge ${d == null ? 'unbekannt' : _fmt(d)})');
      Store.instance.addRecent(t);
      if (_wantPlay) {
        _setPhase(PlayPhase.buffering);
        _startPlayback(g);
      } else {
        _setPhase(PlayPhase.paused);
      }
      _scheduleSave();
    } catch (err) {
      if (!_gen.isCurrent(g)) return;
      _preparingSince = null;
      _log('[$g] Laden fehlgeschlagen nach ${sw.elapsedMilliseconds} ms: ${_short(err)}');
      await _handleFailure(err, g, resumeAt: _pendingPosition);
    }
  }

  void _activatePrepared(int g, QueueEntry e) {
    _prep = null;
    final old = _p;
    _active = 1 - _active;
    _loadedUid = e.uid;
    _preparingSince = null;
    _pendingPosition = null;
    unawaited(old.pause().then((_) => old.stop()).catchError((_) {}));
    unawaited(_p.setVolume(1));
    unawaited(_p.setSpeed(speed.value));
    final d = _p.duration;
    if (d != null) mediaItem.add(_item(e.track, d));
    _log('[$g] Vorbereiteten Titel übernommen (ohne erneuten Abruf)');
    Store.instance.addRecent(e.track);
    _updateInUse();
    if (_wantPlay) {
      _setPhase(PlayPhase.buffering);
      _startPlayback(g);
    } else {
      _setPhase(PlayPhase.paused);
    }
    _scheduleSave();
  }

  Future<bool> _isOffline() async {
    try {
      final r = await InternetAddress.lookup('music.youtube.com').timeout(const Duration(seconds: 5));
      return r.isEmpty;
    } catch (_) {
      return true;
    }
  }

  /// Fehlerbehandlung: einmal mit frischer Quelle, dann nächster Titel; ohne Netz oder
  /// nach mehreren Fehlschlägen in Folge anhalten und die Sitzung erhalten.
  Future<void> _handleFailure(Object err, int g, {Duration? resumeAt}) async {
    if (_failureGen == g) return; // dieselbe Störung nur einmal behandeln
    _failureGen = g;
    final e = q.current;
    if (e == null) return;
    final offline = looksOffline(err) || await _isOffline();
    if (!_gen.isCurrent(g)) return;
    final action = _retry.onFailure(e.uid, offline: offline);
    final reason = _short(err);
    _log('[$g] Störung: $reason${offline ? ' (keine Verbindung)' : ''} → ${action.name}');
    switch (action) {
      case FailureAction.retry:
        YT.forget(e.track);
        _setPhase(PlayPhase.retrying);
        await Future.delayed(const Duration(seconds: 2));
        if (!_gen.isCurrent(g)) return;
        await _load(q.index, trigger: 'Erneuter Versuch', startAt: resumeAt);
      case FailureAction.skip:
        error.value = '«${e.track.title}» konnte nicht geladen werden ($reason)';
        if (!e.track.isYouTube) Store.instance.ytIds.remove(e.track.id);
        if (q.index + 1 < q.length) {
          _setPhase(PlayPhase.retrying, 'Titel konnte nicht geladen werden – nächster Titel');
          await Future.delayed(const Duration(milliseconds: 1500));
          if (!_gen.isCurrent(g)) return;
          await _load(q.index + 1, trigger: 'Vorheriger Titel nicht ladbar');
        } else {
          _stopWithFailure('«${e.track.title}» konnte nicht geladen werden ($reason)', resumeAt);
        }
      case FailureAction.stop:
        _stopWithFailure(
            offline
                ? 'Keine Internetverbindung. Die Sitzung bleibt erhalten; tippe auf «Erneut versuchen».'
                : 'Mehrere Titel konnten nacheinander nicht geladen werden ($reason).',
            resumeAt);
    }
  }

  void _stopWithFailure(String msg, Duration? resumeAt) {
    _gen.bump();
    _wantPlay = false;
    _preparingSince = null;
    if (resumeAt != null) _pendingPosition = resumeAt;
    _loadedUid = null;
    unawaited(_p.pause().catchError((_) {}));
    _discardPrep();
    _setPhase(PlayPhase.failed, 'Titel konnte nicht geladen werden');
    error.value = msg;
    _log('Angehalten: $msg');
    _scheduleSave(now: true);
  }

  /// Nach einem Fehler: derselbe Titel an derselben Stelle, mit frischer Quelle.
  Future<void> retry() async {
    final e = q.current;
    if (e == null) return;
    _retry.onUserAction();
    _wantPlay = true;
    YT.forget(e.track);
    await _load(q.index, trigger: 'Erneut versuchen (Nutzer)', startAt: _pendingPosition);
  }

  void _onPlayerError(Object e) {
    if (_preparingSince != null) return; // wird im Ladevorgang behandelt
    final g = _gen.value;
    final pos = _isLoaded ? _p.position : _pendingPosition;
    _log('[$g] Player-Fehler: ${_short(e)}');
    unawaited(_handleFailure(e, g, resumeAt: pos != null && pos > Duration.zero ? pos : null));
  }

  void _onPrepError(Object e) {
    _log('Vorbereiteter Titel: Fehler ${_short(e)} – wird beim Wechsel normal geladen');
    if (_prep != null) {
      _prep = null;
      _updateInUse();
    }
  }

  // ---------- Titelende ----------

  void _onTrackEnd(String trigger) {
    if (!_isLoaded || _preparingSince != null) return;
    final g = _gen.value;
    if (!_end.claim(g)) return; // Titelende pro Vorgang genau einmal
    _log('[$g] Titelende ($trigger)');
    if (sleepAfterTrack.value) {
      sleepAfterTrack.value = false;
      _wantPlay = false;
      unawaited(_p.pause());
      _setPhase(PlayPhase.paused);
      _scheduleSave(now: true);
      return;
    }
    if (repeat.value == RepeatSetting.one) {
      _end.release();
      unawaited(_p.seek(Duration.zero).then((_) => _startPlayback(g)));
      return;
    }
    unawaited(_advance('Titelende'));
  }

  Future<void> _advance(String trigger) async {
    final next = q.index + 1;
    if (next < q.length) {
      await _load(next, trigger: trigger);
    } else if (repeat.value == RepeatSetting.all && q.length > 0) {
      await _load(0, trigger: '$trigger, alle wiederholen');
    } else {
      await _autoplayMix();
    }
  }

  // Fortsetzung des YouTube-Music-Mix für «Als Nächstes»
  String? _radioCont;
  String? _radioList;

  /// Am Ende der Warteschlange: weiter mit dem Mix von YouTube Music zum aktuellen Titel.
  /// Höchstens zwei Versuche; ein Fehlschlag wird angezeigt, die Sitzung bleibt erhalten.
  Future<void> _autoplayMix() async {
    final t = current.value;
    if (t == null || t.isBook) {
      _wantPlay = false;
      _setPhase(PlayPhase.ended);
      _scheduleSave(now: true);
      return;
    }
    final g = _gen.bump();
    _setPhase(PlayPhase.resolving, 'Mix wird geladen');
    Object? lastErr;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        RadioResult r;
        if (_radioCont != null) {
          r = await YTMusic.radioMore(_radioCont!, _radioList).timeout(const Duration(seconds: 20));
        } else {
          final vid = (await YT.candidates(t).timeout(const Duration(seconds: 15))).first;
          r = await YTMusic.radio(vid).timeout(const Duration(seconds: 20));
        }
        if (!_gen.isCurrent(g)) return;
        final known = {for (final x in q.items) x.track.id};
        final more = r.tracks.where((e) => !known.contains(e.id)).toList();
        if (more.isEmpty) throw Exception('Mix enthält keine neuen Titel');
        _radioCont = r.continuation;
        _radioList = r.playlistId;
        q.appendAll(more);
        _publishQueue();
        _log('[$g] Mix: ${more.length} Titel angehängt');
        await _load(q.index + 1, trigger: 'Mix-Fortsetzung');
        return;
      } catch (e) {
        lastErr = e;
        _log('[$g] Mix-Abruf $attempt fehlgeschlagen: ${_short(e)}');
        if (!_gen.isCurrent(g)) return;
        if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
        if (!_gen.isCurrent(g)) return;
      }
    }
    _wantPlay = false;
    _setPhase(PlayPhase.ended, 'Warteschlange beendet – Mix konnte nicht geladen werden');
    error.value = 'Mix konnte nicht geladen werden (${_short(lastErr)})';
    _scheduleSave(now: true);
  }

  // ---------- Vorladen ----------

  void _withPrepLock(Future<void> Function() op) {
    _prepLock = _prepLock.then((_) => op()).catchError((_) {});
  }

  void _discardPrep() {
    final prep = _prep;
    if (prep == null) return;
    _log('Vorbereitung von «${prep.track.title}» verworfen');
    _prep = null;
    _updateInUse();
    final pl = _other;
    _withPrepLock(() async {
      if (!identical(pl, _p) && _prep == null) await pl.stop();
    });
  }

  /// Passt der vorbereitete Titel nicht mehr zum nächsten Platz, wird er verworfen.
  void _checkPrep() {
    final prep = _prep;
    if (prep != null && q.next?.uid != prep.uid) _discardPrep();
  }

  void _maybePrepare() {
    if (!_wantPlay || _prep != null || _fading || _preparingSince != null || !_isLoaded) return;
    if (repeat.value == RepeatSetting.one || sleepAfterTrack.value) return;
    final next = q.next;
    if (next == null) return;
    final d = _p.duration;
    if (d == null) return;
    final remaining = d - _p.position;
    if (remaining > Duration(seconds: 40 + Store.instance.crossfade)) return;
    _prepare(next);
  }

  void _prepare(QueueEntry e) {
    final id = ++_prepSeq;
    final prep = _Prepared(id, e.uid, e.track);
    _prep = prep;
    _updateInUse();
    final pl = _other;
    _log('Nächster Titel wird vorbereitet: «${e.track.title}»');
    (() async {
      try {
        final src = await _source(e.track, budget: const Duration(seconds: 50)).timeout(const Duration(seconds: 60));
        if (_prep?.id != id) return;
        final way = YT.lastWay;
        final c = Completer<void>();
        _withPrepLock(() async {
          try {
            if (_prep?.id != id || identical(pl, _p)) return;
            await pl.stop();
            await pl.setVolume(1);
            await pl.setAudioSource(src).timeout(const Duration(seconds: 30));
            if (_prep?.id != id || identical(pl, _p)) return;
            prep.ready = true;
            prep.readyAt = DateTime.now();
            _log('Nächster Titel bereit (über $way)');
            c.complete();
          } catch (err) {
            if (!c.isCompleted) c.completeError(err);
          } finally {
            if (!c.isCompleted) c.complete();
          }
        });
        await c.future;
      } catch (err) {
        if (_prep?.id == id) {
          _prep = null;
          _updateInUse();
        }
        _log('Vorbereitung fehlgeschlagen: ${_short(err)} – Wechsel erfolgt normal');
      }
    })();
  }

  // ---------- Crossfade ----------

  void _maybeCrossfade() {
    final cf = Store.instance.crossfade;
    if (cf <= 0 || _fading || !_wantPlay || !_p.playing || !_isLoaded) return;
    if (sleepAfterTrack.value || repeat.value == RepeatSetting.one) return;
    final cur = current.value;
    if (cur == null || cur.isBook) return;
    final prep = _prep;
    final next = q.next;
    if (prep == null || !prep.ready || next == null || next.uid != prep.uid || next.track.isBook) return;
    final d = _p.duration;
    if (d == null || d.inSeconds < cf * 3) return;
    if (d - _p.position > Duration(seconds: cf)) return;
    _startFade(next, cf);
  }

  void _startFade(QueueEntry next, int seconds) {
    final g = _gen.bump();
    final from = _p;
    _prep = null;
    _active = 1 - _active;
    final to = _p;
    q.jump(q.index + 1);
    current.value = next.track;
    mediaItem.add(_item(next.track, to.duration));
    _loadedUid = next.uid;
    _pendingPosition = null;
    _preparingSince = null;
    _fading = true;
    _fadeStarted = DateTime.now();
    _fadeFrom = from;
    _stall.reset();
    _log('[$g] Überblendung zu «${next.track.title}» ($seconds s)');
    Store.instance.addRecent(next.track);
    _updateInUse();
    _scheduleSave();
    unawaited(to.setVolume(0));
    unawaited(to.setSpeed(speed.value));
    _startPlayback(g);
    const stepMs = 100;
    final totalMs = seconds * 1000;
    var elapsed = 0;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (_) {
      if (!_gen.isCurrent(g)) {
        _finishFade();
        return;
      }
      elapsed += stepMs;
      final k = (elapsed / totalMs).clamp(0.0, 1.0).toDouble();
      to.setVolume(k);
      from.setVolume(1 - k);
      if (k >= 1) _finishFade();
    });
  }

  /// Überblendung sofort abschliessen (bei Pause, Spulen, neuem Titel, Hänger).
  /// Setzt die Lautstärken immer zurück.
  void _finishFade() {
    if (!_fading) return;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fading = false;
    final old = _fadeFrom;
    _fadeFrom = null;
    if (old != null && !identical(old, _p)) {
      unawaited(old.stop().then((_) => old.setVolume(1)).catchError((_) {}));
    }
    unawaited(_p.setVolume(1));
  }

  // ---------- Wächter (jede Sekunde) ----------

  void _onTick() {
    _tick++;
    final now = DateTime.now();
    final verdict = _stall.tick(
      wantPlay: _wantPlay && phase.value != PlayPhase.failed && phase.value != PlayPhase.ended && !_fading,
      preparing: _preparingSince != null,
      preparingSecs: _preparingSince == null ? 0 : now.difference(_preparingSince!).inSeconds,
      state: _pstate(_p.processingState),
      playing: _p.playing,
      position: _p.position,
      buffered: _p.bufferedPosition,
      duration: _isLoaded ? _p.duration : null,
    );
    switch (verdict) {
      case StallVerdict.loadTimeout:
        final g = _gen.bump();
        _preparingSince = null;
        _log('[$g] Wächter: Laden dauert zu lange');
        unawaited(_handleFailure(TimeoutException('Laden dauert zu lange'), g, resumeAt: _pendingPosition));
      case StallVerdict.bufferStall:
        final g = _gen.bump();
        final pos = _p.position;
        _log('[$g] Wächter: Puffern hängt bei ${_fmt(pos)}');
        unawaited(_handleFailure(TimeoutException('Puffern hängt'), g, resumeAt: pos));
      case StallVerdict.endReached:
        _onTrackEnd('Wächter: Titelende ohne Meldung');
      case StallVerdict.ok:
        break;
    }
    // Hängen gebliebene Überblendung abschliessen
    if (_fading && _fadeStarted != null && now.difference(_fadeStarted!) > Duration(seconds: Store.instance.crossfade + 5)) {
      _log('Wächter: Überblendung abgeschlossen (hing)');
      _finishFade();
    }
    _maybePrepare();
    _maybeCrossfade();
    if (_p.playing && _tick % 5 == 0) {
      _scheduleSave();
      _saveBookProgress();
    }
    if (_wantPlay && _tick % 30 == 0) {
      _log('Zustand: ${phase.value.name}, ${_p.processingState.name}, ${_p.playing ? 'spielt' : 'steht'}, '
          '${_fmt(_p.position)} / ${_p.duration == null ? '?' : _fmt(_p.duration!)}, Puffer ${_fmt(_p.bufferedPosition)}');
    }
    if (_tick % 30 == 0) log.flush();
  }

  // ---------- Sitzung speichern und wiederherstellen ----------

  void _scheduleSave({bool now = false}) {
    if (now) {
      unawaited(_saveNow());
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () => unawaited(_saveNow()));
  }

  /// Speichert sofort (zum Beispiel wenn die App in den Hintergrund geht).
  Future<void> saveSession() async {
    await _saveNow();
    log.flush();
    await Store.instance.flush();
  }

  PlaybackSession? _snapshot() {
    final e = q.current;
    if (e == null) return null;
    // Titel und Position immer zusammen: Position nur vom Player, wenn er genau diesen Platz geladen hat
    final pos = _isLoaded ? _p.position : (_pendingPosition ?? Duration.zero);
    return PlaybackSession(
      items: List.of(q.items),
      original: List.of(q.original),
      index: q.index,
      entryUid: e.uid,
      trackId: e.track.id,
      positionMs: pos.inMilliseconds,
      shuffle: q.shuffled,
      repeat: repeat.value.index,
      speed: speed.value,
      savedAt: DateTime.now().millisecondsSinceEpoch,
      wasPlaying: _wantPlay,
      origin: _origin,
    );
  }

  Future<void> _saveNow() async {
    _saveTimer?.cancel();
    if (_saving) {
      _saveAgain = true;
      return;
    }
    final s = _snapshot();
    if (s == null) return;
    _saving = true;
    try {
      final j = s.toJson();
      if (_queueDirty) {
        _queueDirty = false;
        await Store.instance.saveSessionQueue({
          for (final k in const ['items', 'original', 'shuffle', 'origin']) k: j[k],
        });
      }
      j.remove('items');
      j.remove('original');
      await Store.instance.saveSessionPointer(j);
    } catch (err) {
      _queueDirty = true;
      _log('Sitzung speichern fehlgeschlagen: ${_short(err)}');
    } finally {
      _saving = false;
      if (_saveAgain) {
        _saveAgain = false;
        unawaited(_saveNow());
      }
    }
  }

  void _restoreSession() {
    if (!q.isEmpty) return; // laufende Sitzung nie durch alten Stand ersetzen
    try {
      final raw = Store.instance.loadSessionRaw();
      if (raw == null) {
        _log('Start: keine gespeicherte Sitzung');
        return;
      }
      final s = PlaybackSession.fromJson(raw);
      if (s == null) {
        _log('Start: gespeicherte Sitzung unlesbar oder unvollständig – übersprungen');
        return;
      }
      final (idx, pos) = s.resumePoint();
      q.restore(s.items, s.original, idx, s.shuffle);
      shuffle.value = q.shuffled;
      repeat.value = RepeatSetting.values[s.repeat];
      speed.value = s.speed;
      _origin = s.origin;
      final t = q.current!.track;
      current.value = t;
      mediaItem.add(_item(t));
      _pendingPosition = Duration(milliseconds: pos);
      queue.add([for (final e in q.items) _item(e.track)]);
      queueVersion.value++;
      _queueDirty = false;
      _updateInUse();
      _setPhase(PlayPhase.paused);
      final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(s.savedAt));
      _log('Start: Sitzung wiederhergestellt – «${t.title}» bei ${_fmt(_pendingPosition!)}, '
          'Platz ${idx + 1}/${q.length}, gespeichert vor ${age.inMinutes} min');
    } catch (e) {
      _log('Start: Sitzung konnte nicht wiederhergestellt werden: ${_short(e)}');
    }
  }

  // ---------- Steuerung ----------

  @override
  Future<void> play() async {
    final e = q.current;
    if (e == null) return;
    _wantPlay = true;
    _retry.onUserAction();
    _log('Play');
    if (phase.value == PlayPhase.ended && !e.track.isBook && q.next == null) {
      await _autoplayMix();
      return;
    }
    if (_preparingSince != null) {
      // Ladevorgang läuft; er startet die Wiedergabe selbst
      _broadcast();
      return;
    }
    if (!_isLoaded || phase.value == PlayPhase.failed) {
      await _load(q.index, trigger: 'Play (Fortsetzen)', startAt: _pendingPosition);
      return;
    }
    if (_p.processingState == ProcessingState.completed) {
      await _p.seek(Duration.zero);
      _end.release();
    }
    _startPlayback(_gen.value);
  }

  @override
  Future<void> pause() async {
    _wantPlay = false;
    _finishFade();
    _log('Pause bei ${_fmt(_displayPosition)}');
    await _p.pause();
    if (_preparingSince == null) _setPhase(PlayPhase.paused);
    _broadcast();
    _saveBookProgress();
    await _saveNow();
  }

  Future<void> togglePlay() => (_p.playing || (_wantPlay && loading.value)) ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    _finishFade();
    if (_isLoaded) {
      await _p.seek(position);
    } else {
      _pendingPosition = position;
    }
    _end.release();
    _log('Spulen auf ${_fmt(position)}');
    _broadcast();
    _scheduleSave();
  }

  Future<void> seekRelative(Duration delta) async {
    var p = _displayPosition + delta;
    if (p < Duration.zero) p = Duration.zero;
    final d = _isLoaded ? _p.duration : null;
    if (d != null && p > d) p = d;
    await seek(p);
  }

  @override
  Future<void> fastForward() => seekRelative(const Duration(seconds: 30));

  @override
  Future<void> rewind() => seekRelative(const Duration(seconds: -15));

  @override
  Future<void> skipToNext() async {
    _retry.onUserAction();
    _log('Weiter (Nutzer)');
    await _advance('Weiter (Nutzer)');
  }

  @override
  Future<void> skipToPrevious() async {
    _retry.onUserAction();
    if ((_isLoaded && _p.position > const Duration(seconds: 3)) || q.index <= 0) {
      await seek(Duration.zero);
    } else {
      await _load(q.index - 1, trigger: 'Zurück (Nutzer)');
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _retry.onUserAction();
    _wantPlay = true;
    await _load(index, trigger: 'Titel in der Warteschlange gewählt');
  }

  @override
  Future<void> setSpeed(double speed) async {
    this.speed.value = speed;
    await _p.setSpeed(speed);
    _scheduleSave();
  }

  @override
  Future<void> stop() async {
    _log('Stop');
    _saveBookProgress();
    if (_isLoaded) _pendingPosition = _p.position;
    _gen.bump();
    _wantPlay = false;
    _preparingSince = null;
    _finishFade();
    _discardPrep();
    await _saveNow();
    _loadedUid = null;
    await _players[0].stop();
    await _players[1].stop();
    _setPhase(PlayPhase.paused);
    log.flush();
    await super.stop();
  }

  /// App aus der Übersicht gewischt: laufende Musik spielt weiter; nur wenn nichts läuft,
  /// wird der Dienst beendet.
  @override
  Future<void> onTaskRemoved() async {
    await _saveNow();
    if (_wantPlay) {
      _log('App aus der Übersicht entfernt – Wiedergabe läuft weiter');
      log.flush();
      return;
    }
    await stop();
  }

  // ---------- Sleep-Timer ----------

  void setSleep(Duration? d, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    sleepAt.value = null;
    sleepAfterTrack.value = endOfTrack;
    if (endOfTrack) _discardPrep();
    if (d == null) return;
    sleepAt.value = DateTime.now().add(d);
    _sleepTimer = Timer(d, () async {
      for (var i = 10; i >= 0; i--) {
        await _p.setVolume(i / 10);
        await Future.delayed(const Duration(milliseconds: 500));
      }
      await pause();
      await _p.setVolume(1);
      sleepAt.value = null;
    });
  }

  // ---------- Hörbuch-Fortschritt ----------

  void _saveBookProgress() {
    final t = current.value;
    if (t == null || !t.isBook || !_isLoaded || _preparingSince != null) return;
    final pos = _p.position;
    if (pos > const Duration(seconds: 2)) Store.instance.setProgress(t, pos);
  }

  // ---------- Android Auto: Menü zum Blättern, Abspielen und Sprachsuche ----------

  static const _autoRoot = AudioService.browsableRootId;
  final _autoSearch = <String, Track>{};

  MediaItem _folder(String id, String title, {String? subtitle}) =>
      MediaItem(id: id, title: title, displaySubtitle: subtitle, playable: false);

  MediaItem _autoItem(String prefix, Track t) => MediaItem(
        id: '$prefix|${t.id}',
        title: t.title,
        artist: t.isBook ? t.album : t.artist,
        album: t.album,
        artUri: t.cover.isEmpty ? null : Uri.parse(t.cover),
        duration: t.duration > 0 ? Duration(seconds: t.duration) : null,
        playable: true,
      );

  /// Liste und Präfix zu einem Ordner des Menüs.
  List<Track>? _autoList(String folder) {
    final s = Store.instance;
    if (folder == 'history') return s.recent.where((t) => !t.isBook).toList();
    if (folder == 'mymix') return List.of(s.mix);
    if (folder == 'liked') return List.of(s.liked);
    if (folder == 'downloads') return s.downloads.values.toList();
    if (folder.startsWith('pl:')) return s.playlist(folder.substring(3))?.tracks.toList();
    if (folder.startsWith('book:')) return s.books[folder]?.chapters.toList();
    if (folder == 'search') return _autoSearch.values.toList();
    return null;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    final s = Store.instance;
    switch (parentMediaId) {
      case _autoRoot:
        return [
          _folder('mymix', 'Mein Mix', subtitle: 'Aus deinen Lieblingssongs'),
          _folder('history', 'Zuletzt gehört', subtitle: '${s.recent.where((t) => !t.isBook).length} Titel'),
          _folder('liked', 'Favoriten', subtitle: '${s.liked.length} Titel'),
          _folder('playlists', 'Playlists', subtitle: '${s.playlists.length} Playlists'),
          _folder('downloads', 'Downloads', subtitle: '${s.downloads.length} Titel offline'),
          _folder('books', 'Hörbücher'),
        ];
      case AudioService.recentRootId:
        // Für «Weiterhören» im Auto: der zuletzt gespielte Titel
        final cur = current.value ?? (s.recent.isNotEmpty ? s.recent.first : null);
        return cur == null ? [] : [_autoItem('history', cur)];
      case 'mymix':
        try {
          await MyMix.get();
        } catch (_) {}
        return [for (final t in s.mix) _autoItem('mymix', t)];
      case 'playlists':
        return [
          for (final p in s.playlists) _folder('pl:${p.id}', p.name, subtitle: '${p.tracks.length} Titel'),
        ];
      case 'books':
        final books = [...s.continueBooks(), ...s.books.values.where((b) => !s.continueBooks().any((c) => c.id == b.id))];
        return [for (final b in books) _folder(b.id, b.title, subtitle: b.author)];
    }
    final list = _autoList(parentMediaId);
    if (list == null) return [];
    return [for (final t in list.take(200)) _autoItem(parentMediaId, t)];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final i = mediaId.indexOf('|');
    if (i < 0) return null;
    final list = _autoList(mediaId.substring(0, i)) ?? const <Track>[];
    final id = mediaId.substring(i + 1);
    for (final t in list) {
      if (t.id == id) return _autoItem(mediaId.substring(0, i), t);
    }
    return null;
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final i = mediaId.indexOf('|');
    if (i < 0) return;
    final folder = mediaId.substring(0, i);
    final id = mediaId.substring(i + 1);
    final list = _autoList(folder);
    if (list == null || list.isEmpty) return;
    final start = list.indexWhere((t) => t.id == id);
    if (folder.startsWith('book:')) Store.instance.saveBook(Store.instance.books[folder]!);
    await playTracks(list, start: start < 0 ? 0 : start);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    if (query.trim().isEmpty) return [];
    try {
      final r = await YTMusic.searchTracks(query.trim());
      _autoSearch
        ..clear()
        ..addEntries(r.take(30).map((t) => MapEntry(t.id, t)));
      return [for (final t in _autoSearch.values) _autoItem('search', t)];
    } catch (_) {
      return [];
    }
  }

  /// Sprachbefehl wie «Spiele … auf Lyra».
  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final q = query.trim();
    if (q.isEmpty) {
      // Ohne Suchbegriff («Spiele Musik auf Lyra»): Mein Mix, sonst Favoriten
      final s = Store.instance;
      try {
        final mix = await MyMix.get();
        if (mix.isNotEmpty) {
          await playTracks(mix);
          return;
        }
      } catch (_) {}
      final list = s.liked.isNotEmpty ? s.liked : s.recent.where((t) => !t.isBook).toList();
      if (list.isNotEmpty) await playShuffled(list);
      return;
    }
    try {
      // Wie YouTube Music: bester Treffer, danach dessen Mix
      final r = await YTMusic.searchTracks(q);
      if (r.isEmpty) return;
      final first = r.first;
      var queue = <Track>[first];
      try {
        final radio = await YTMusic.radio(first.id);
        queue = [first, ...radio.tracks.where((t) => t.id != first.id)];
        await playTracks(queue);
        _radioCont = radio.continuation;
        _radioList = radio.playlistId;
        return;
      } catch (_) {}
      await playTracks(queue);
    } catch (_) {}
  }
}
