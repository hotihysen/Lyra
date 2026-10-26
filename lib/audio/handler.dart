import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../api/deezer.dart';
import '../api/youtube.dart';
import '../data/models.dart';
import '../data/store.dart';

enum RepeatSetting { off, all, one }

/// Wiedergabe mit zwei Playern, damit Titel weich ineinander überblenden (Crossfade).
class LyraAudioHandler extends BaseAudioHandler with SeekHandler {
  LyraAudioHandler() {
    _init();
  }

  final _players = [AudioPlayer(), AudioPlayer()];
  int _active = 0;
  AudioPlayer get _p => _players[_active];
  AudioPlayer get _other => _players[1 - _active];

  List<Track> tracks = [];
  List<Track> _original = [];
  int index = -1;

  final current = ValueNotifier<Track?>(null);
  final queueVersion = ValueNotifier<int>(0);
  final repeat = ValueNotifier<RepeatSetting>(RepeatSetting.off);
  final shuffle = ValueNotifier<bool>(false);
  final speed = ValueNotifier<double>(1.0);
  final loading = ValueNotifier<bool>(false);
  final sleepAt = ValueNotifier<DateTime?>(null);
  final sleepAfterTrack = ValueNotifier<bool>(false);
  final error = ValueNotifier<String?>(null);

  bool _fading = false;
  Timer? _fadeTimer;
  Timer? _sleepTimer;
  int _loadToken = 0;

  late final Stream<Duration> position =
      Stream<Duration>.periodic(const Duration(milliseconds: 250), (_) => _p.position).asBroadcastStream();

  Duration get duration {
    final d = _p.duration;
    if (d != null && d > Duration.zero) return d;
    return Duration(seconds: current.value?.duration ?? 0);
  }

  List<Track> get upcoming => index < 0 || index + 1 > tracks.length ? [] : tracks.sublist(index + 1);

  Future<void> _init() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (_) {}
    for (final pl in _players) {
      pl.playbackEventStream.listen(
        (_) {
          if (identical(pl, _p)) _broadcast();
        },
        onError: (Object e, StackTrace s) {
          if (identical(pl, _p)) _onError(e);
        },
      );
      pl.playingStream.listen((_) {
        if (identical(pl, _p)) _broadcast();
      });
      pl.processingStateStream.listen((st) {
        if (identical(pl, _p) && st == ProcessingState.completed && !_fading) _onCompleted();
      });
      pl.positionStream.listen((pos) {
        if (identical(pl, _p)) _checkCrossfade(pos);
      });
    }
    Timer.periodic(const Duration(seconds: 5), (_) => _saveBookProgress());
  }

  // ---------- Status an System/Benachrichtigung melden ----------

  static const _stateMap = {
    ProcessingState.idle: AudioProcessingState.idle,
    ProcessingState.loading: AudioProcessingState.loading,
    ProcessingState.buffering: AudioProcessingState.buffering,
    ProcessingState.ready: AudioProcessingState.ready,
    ProcessingState.completed: AudioProcessingState.completed,
  };

  void _broadcast() {
    final p = _p;
    final isBook = current.value?.isBook ?? false;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        isBook ? MediaControl.rewind : MediaControl.skipToPrevious,
        p.playing ? MediaControl.pause : MediaControl.play,
        isBook ? MediaControl.fastForward : MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: loading.value
          ? AudioProcessingState.loading
          : (_stateMap[p.processingState] ?? AudioProcessingState.idle),
      playing: p.playing,
      updatePosition: p.position,
      bufferedPosition: p.bufferedPosition,
      speed: p.speed,
      queueIndex: index < 0 ? null : index,
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
    queue.add(tracks.map((t) => _item(t)).toList());
    queueVersion.value++;
  }

  // ---------- Warteschlange ----------

  Future<void> playTracks(List<Track> list, {int start = 0, bool shuffled = false}) async {
    if (list.isEmpty) return;
    _original = List.of(list);
    tracks = List.of(list);
    if (shuffled) {
      final first = tracks.removeAt(start.clamp(0, tracks.length - 1));
      tracks.shuffle();
      tracks.insert(0, first);
      start = 0;
    }
    shuffle.value = shuffled;
    _publishQueue();
    await _load(start);
  }

  Future<void> playShuffled(List<Track> list) async {
    if (list.isEmpty) return;
    final start = DateTime.now().microsecondsSinceEpoch % list.length;
    await playTracks(list, start: start, shuffled: true);
  }

  void addNext(Track t) {
    if (index < 0) {
      playTracks([t]);
      return;
    }
    tracks.insert(index + 1, t);
    _original.add(t);
    _publishQueue();
  }

  void addToQueue(Track t) {
    if (index < 0) {
      playTracks([t]);
      return;
    }
    tracks.add(t);
    _original.add(t);
    _publishQueue();
  }

  void removeAt(int i) {
    if (i == index || i < 0 || i >= tracks.length) return;
    tracks.removeAt(i);
    if (i < index) index--;
    _publishQueue();
  }

  void move(int from, int to) {
    if (from == to || from < 0 || from >= tracks.length) return;
    final t = tracks.removeAt(from);
    tracks.insert(to.clamp(0, tracks.length), t);
    if (from == index) {
      index = to;
    } else if (from < index && to >= index) {
      index--;
    } else if (from > index && to <= index) {
      index++;
    }
    _publishQueue();
  }

  void clearUpcoming() {
    if (index < 0) return;
    tracks = tracks.sublist(0, index + 1);
    _publishQueue();
  }

  void toggleShuffle() {
    if (tracks.isEmpty || index < 0) return;
    final cur = tracks[index];
    if (!shuffle.value) {
      _original = List.of(tracks);
      final rest = List.of(tracks)..removeAt(index);
      rest.shuffle();
      tracks = [cur, ...rest];
      index = 0;
    } else {
      tracks = List.of(_original);
      index = tracks.indexWhere((t) => t.id == cur.id);
      if (index < 0) {
        tracks.insert(0, cur);
        index = 0;
      }
    }
    shuffle.value = !shuffle.value;
    _publishQueue();
    _broadcast();
  }

  void cycleRepeat() {
    repeat.value = RepeatSetting.values[(repeat.value.index + 1) % RepeatSetting.values.length];
  }

  // ---------- Laden & Abspielen ----------

  Future<AudioSource> _source(Track t) async {
    final f = Store.instance.fileFor(t);
    if (Store.instance.isDownloaded(t) && f.existsSync()) return AudioSource.file(f.path);
    if (t.url != null) return AudioSource.uri(Uri.parse(t.url!));
    return AudioSource.uri(await YT.streamUrl(t));
  }

  Future<void> _load(int i, {bool autoplay = true}) async {
    if (i < 0 || i >= tracks.length) return;
    _saveBookProgress();
    final token = ++_loadToken;
    _cancelFade();
    index = i;
    final t = tracks[i];
    current.value = t;
    mediaItem.add(_item(t));
    loading.value = true;
    error.value = null;
    _broadcast();
    try {
      await _other.stop();
      await _p.stop();
      final src = await _source(t);
      if (token != _loadToken) return;
      final at = t.isBook ? Store.instance.bookPos(t) : null;
      final d = await _p.setAudioSource(src, initialPosition: at);
      if (token != _loadToken) return;
      await _p.setVolume(1);
      await _p.setSpeed(speed.value);
      loading.value = false;
      if (d != null) mediaItem.add(_item(t, d));
      if (autoplay) _p.play();
      Store.instance.addRecent(t);
    } catch (e) {
      if (token != _loadToken) return;
      loading.value = false;
      _onError(e);
    }
    _broadcast();
  }

  void _onError(Object e) {
    final t = current.value;
    error.value = t == null ? 'Wiedergabe fehlgeschlagen' : '«${t.title}» konnte nicht geladen werden';
    if (t != null && !t.isBook) {
      // Falsche oder veraltete Zuordnung vergessen, damit der nächste Versuch neu sucht.
      Store.instance.ytIds.remove(t.id);
    }
    final token = _loadToken;
    if (index + 1 < tracks.length) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (token == _loadToken) _load(index + 1);
      });
    }
  }

  void _onCompleted() {
    if (sleepAfterTrack.value) {
      sleepAfterTrack.value = false;
      _p.pause();
      _p.seek(Duration.zero);
      return;
    }
    if (repeat.value == RepeatSetting.one) {
      _p.seek(Duration.zero);
      _p.play();
      return;
    }
    skipToNext();
  }

  Future<void> _autoplay() async {
    final t = current.value;
    if (t == null || t.isBook || t.artistId.isEmpty) {
      await _p.pause();
      await _p.seek(Duration.zero);
      return;
    }
    try {
      final known = tracks.map((e) => e.id).toSet();
      final more = (await Deezer.artistRadio(t.artistId)).where((e) => !known.contains(e.id)).toList();
      if (more.isEmpty) throw Exception('leer');
      tracks.addAll(more);
      _original.addAll(more);
      _publishQueue();
      await _load(index + 1);
    } catch (_) {
      await _p.pause();
      await _p.seek(Duration.zero);
    }
  }

  // ---------- Crossfade ----------

  void _checkCrossfade(Duration pos) {
    final cf = Store.instance.crossfade;
    if (cf <= 0 || _fading || loading.value || sleepAfterTrack.value) return;
    if (repeat.value == RepeatSetting.one) return;
    final t = current.value;
    if (t == null || t.isBook) return;
    final dur = _p.duration;
    if (dur == null || dur.inSeconds < cf * 3) return;
    if (dur - pos > Duration(seconds: cf)) return;
    var next = index + 1;
    if (next >= tracks.length) {
      if (repeat.value != RepeatSetting.all) return;
      next = 0;
    }
    if (tracks[next].isBook) return;
    _startFade(next, cf);
  }

  Future<void> _startFade(int next, int seconds) async {
    _fading = true;
    final token = ++_loadToken;
    final from = _p;
    final to = _other;
    final t = tracks[next];
    try {
      final src = await _source(t);
      if (token != _loadToken) {
        _fading = false;
        return;
      }
      await to.setAudioSource(src);
      await to.setVolume(0);
      await to.setSpeed(speed.value);
      if (token != _loadToken) {
        _fading = false;
        return;
      }
      to.play();
    } catch (_) {
      // Überblenden nicht möglich: normaler Wechsel am Titelende.
      _fading = false;
      return;
    }
    _active = 1 - _active;
    index = next;
    current.value = t;
    mediaItem.add(_item(t, to.duration));
    Store.instance.addRecent(t);
    _broadcast();
    const stepMs = 100;
    final totalMs = seconds * 1000;
    var elapsed = 0;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      elapsed += stepMs;
      final k = (elapsed / totalMs).clamp(0.0, 1.0).toDouble();
      to.setVolume(k);
      from.setVolume(1 - k);
      if (k >= 1) _finishFade();
    });
  }

  /// Überblendung sofort abschliessen (bei Pause, Spulen usw.).
  void _finishFade() {
    if (!_fading) return;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final old = _other;
    old.stop();
    old.setVolume(1);
    _p.setVolume(1);
    _fading = false;
  }

  void _cancelFade() => _finishFade();

  // ---------- Steuerung ----------

  @override
  Future<void> play() async {
    if (index >= 0 && _p.audioSource == null) {
      await _load(index);
      return;
    }
    _p.play();
  }

  @override
  Future<void> pause() async {
    _finishFade();
    await _p.pause();
    _saveBookProgress();
  }

  Future<void> togglePlay() => _p.playing ? pause() : play();

  @override
  Future<void> seek(Duration position) async {
    _finishFade();
    await _p.seek(position);
  }

  Future<void> seekRelative(Duration delta) async {
    var p = _p.position + delta;
    if (p < Duration.zero) p = Duration.zero;
    final d = _p.duration;
    if (d != null && p > d) p = d;
    await seek(p);
  }

  @override
  Future<void> fastForward() => seekRelative(const Duration(seconds: 30));

  @override
  Future<void> rewind() => seekRelative(const Duration(seconds: -15));

  @override
  Future<void> skipToNext() async {
    if (index + 1 < tracks.length) {
      await _load(index + 1);
    } else if (repeat.value == RepeatSetting.all && tracks.isNotEmpty) {
      await _load(0);
    } else {
      await _autoplay();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_p.position > const Duration(seconds: 3) || index <= 0) {
      await seek(Duration.zero);
    } else {
      await _load(index - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _load(index);

  @override
  Future<void> setSpeed(double speed) async {
    this.speed.value = speed;
    await _p.setSpeed(speed);
  }

  @override
  Future<void> stop() async {
    _saveBookProgress();
    _finishFade();
    await _players[0].stop();
    await _players[1].stop();
    await super.stop();
  }

  @override
  Future<void> onTaskRemoved() => stop();

  // ---------- Sleep-Timer ----------

  void setSleep(Duration? d, {bool endOfTrack = false}) {
    _sleepTimer?.cancel();
    sleepAt.value = null;
    sleepAfterTrack.value = endOfTrack;
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
    if (t == null || !t.isBook || loading.value) return;
    final pos = _p.position;
    if (pos > const Duration(seconds: 2)) Store.instance.setProgress(t, pos);
  }
}
