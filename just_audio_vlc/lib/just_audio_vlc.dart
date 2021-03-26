import 'dart:async';
import 'dart:math';

import 'package:dart_vlc/dart_vlc.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// The vlc implementation of [JustAudioPlatform].
class JustAudioPlugin extends JustAudioPlatform {
  final Map<String, JustAudioPlayer> players = {};

  /// The entrypoint called by the generated plugin registrant.
  static void registerWith() {
    JustAudioPlatform.instance = JustAudioPlugin();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (players.containsKey(request.id)) {
      throw PlatformException(
          code: "error",
          message: "Platform player ${request.id} already exists");
    }
    final player = VlcAudioPlayer(id: request.id);
    players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    await players[request.id]?.release();
    players.remove(request.id);
    return DisposePlayerResponse();
  }
}

/// The vlc impluementation of [AudioPlayerPlatform].
abstract class JustAudioPlayer extends AudioPlayerPlatform {
  final _eventController = StreamController<PlaybackEventMessage>();
  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  bool _playing = false;
  int? _index;

  /// Creates a platform player with the given [id].
  JustAudioPlayer({required String id}) : super(id);

  @mustCallSuper
  Future<void> release() async {
    _eventController.close();
  }

  /// Returns the current position of the player.
  Duration getCurrentPosition();

  /// Returns the current buffered position of the player.
  Duration getBufferedPosition();

  /// Returns the duration of the current player item or `null` if unknown.
  Duration? getDuration();

  /// Broadcasts a playback event from the platform side to the plugin side.
  void broadcastPlaybackEvent() {
    var updateTime = DateTime.now();
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updatePosition: getCurrentPosition(),
      updateTime: updateTime,
      bufferedPosition: getBufferedPosition(),
      // TODO: Icy Metadata
      icyMetadata: null,
      duration: getDuration(),
      currentIndex: _index,
      androidAudioSessionId: null,
    ));
  }

  /// Transitions to [processingState] and broadcasts a playback event.
  void transition(ProcessingStateMessage processingState) {
    _processingState = processingState;
    broadcastPlaybackEvent();
  }
}

/// An VLC-specific implementation of [JustAudioPlayer].
class VlcAudioPlayer extends JustAudioPlayer {
  late Player _audioElement;
  Completer? _durationCompleter;
  AudioSourcePlayer? _audioSourcePlayer;
  LoopModeMessage _loopMode = LoopModeMessage.off;
  bool _shuffleModeEnabled = false;
  final Map<String, AudioSourcePlayer> _audioSourcePlayers = {};

  /// Creates an [VlcAudioPlayer] with the given [id].
  VlcAudioPlayer({required String id}) : super(id: id) {
    Player.create(id: 0).then((value) {
      _audioElement = value;
      _audioElement.playbackStream.listen((event) {
        if (event.isCompleted) {
          _durationCompleter?.complete();
          broadcastPlaybackEvent();
        }
      });
    });
  }

  /// The current playback order, depending on whether shuffle mode is enabled.
  List<int> get order {
    final sequence = _audioSourcePlayer!.sequence;
    return _shuffleModeEnabled
        ? _audioSourcePlayer!.shuffleIndices
        : List.generate(sequence.length, (i) => i);
  }

  /// gets the inverted order for the given order.
  List<int> getInv(List<int> order) {
    final orderInv = List<int>.filled(order.length, 0);
    for (var i = 0; i < order.length; i++) {
      orderInv[order[i]] = i;
    }
    return orderInv;
  }

  /// Called when playback reaches the end of an item.
  Future<void> onEnded() async {
    if (_loopMode == LoopModeMessage.one) {
      await _seek(0, null);
      _play();
    } else {
      final order = this.order;
      final orderInv = getInv(order);
      if (orderInv[_index!] + 1 < order.length) {
        // move to next item
        _index = order[orderInv[_index!] + 1];
        await _currentAudioSourcePlayer!.load();
        // Should always be true...
        if (_playing) {
          _play();
        }
      } else {
        // reached end of playlist
        if (_loopMode == LoopModeMessage.all) {
          // Loop back to the beginning
          if (order.length == 1) {
            await _seek(0, null);
            _play();
          } else {
            _index = order[0];
            await _currentAudioSourcePlayer!.load();
            // Should always be true...
            if (_playing) {
              _play();
            }
          }
        } else {
          transition(ProcessingStateMessage.completed);
        }
      }
    }
  }

  // TODO: Improve efficiency.
  IndexedAudioSourcePlayer? get _currentAudioSourcePlayer =>
      _audioSourcePlayer != null &&
              _index != null &&
              _audioSourcePlayer!.sequence.isNotEmpty &&
              _index! < _audioSourcePlayer!.sequence.length
          ? _audioSourcePlayer!.sequence[_index!]
          : null;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _currentAudioSourcePlayer?.pause();
    _audioSourcePlayer = getAudioSource(request.audioSourceMessage);
    _index = request.initialIndex ?? 0;
    final duration = await _currentAudioSourcePlayer!.load();
    if (request.initialPosition != null) {
      await _currentAudioSourcePlayer!
          .seek(request.initialPosition!.inMilliseconds);
    }
    if (_playing) {
      _currentAudioSourcePlayer!.play();
    }
    return LoadResponse(duration: duration);
  }

  /// Loads audio from [uri] and returns the duration of the loaded audio if
  /// known.
  Future<Duration?> loadUri(final Uri uri) async {
    transition(ProcessingStateMessage.loading);
    final src = uri.toString();
    if (src != _audioElement.current.media.resource) {
      _durationCompleter = Completer<dynamic>();
      _audioElement.add(await Media.network(uri.toString()));
      try {
        await _durationCompleter!.future;
      } on Exception catch (e) {
        throw PlatformException(code: "${e}", message: "Failed to load URL");
      } finally {
        _durationCompleter = null;
      }
    }
    transition(ProcessingStateMessage.ready);
    final seconds = _audioElement.position.duration.inSeconds;
    return seconds.isFinite
        ? Duration(milliseconds: (seconds * 1000).toInt())
        : null;
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_playing) return PlayResponse();
    _playing = true;
    await _play();
    return PlayResponse();
  }

  Future<void> _play() async {
    await _currentAudioSourcePlayer?.play();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_playing) return PauseResponse();
    _playing = false;
    _currentAudioSourcePlayer?.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _audioElement.setVolume(request.volume);
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _audioElement.setRate(request.speed);
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loopMode = request.loopMode;
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    _shuffleModeEnabled = request.shuffleMode == ShuffleModeMessage.all;
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(
      SetShuffleOrderRequest request) async {
    void internalSetShuffleOrder(AudioSourceMessage sourceMessage) {
      final audioSourcePlayer = _audioSourcePlayers[sourceMessage.id];
      if (audioSourcePlayer == null) return;
      if (sourceMessage is ConcatenatingAudioSourceMessage &&
          audioSourcePlayer is ConcatenatingAudioSourcePlayer) {
        audioSourcePlayer.setShuffleOrder(sourceMessage.shuffleOrder);
        for (var childMessage in sourceMessage.children) {
          internalSetShuffleOrder(childMessage);
        }
      } else if (sourceMessage is LoopingAudioSourceMessage) {
        internalSetShuffleOrder(sourceMessage.child);
      }
    }

    internalSetShuffleOrder(request.audioSourceMessage);
    return SetShuffleOrderResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    await _seek(request.position?.inMilliseconds ?? 0, request.index);
    return SeekResponse();
  }

  Future<void> _seek(int position, int? newIndex) async {
    var index = newIndex ?? _index;
    if (index != _index) {
      _currentAudioSourcePlayer!.pause();
      _index = index;
      await _currentAudioSourcePlayer!.load();
      await _currentAudioSourcePlayer!.seek(position);
      if (_playing) {
        _currentAudioSourcePlayer!.play();
      }
    } else {
      await _currentAudioSourcePlayer!.seek(position);
    }
  }

  ConcatenatingAudioSourcePlayer? _concatenating(String playerId) =>
      _audioSourcePlayers[playerId] as ConcatenatingAudioSourcePlayer?;

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .insertAll(request.index, getAudioSources(request.children));
    if (_index != null && request.index <= _index!) {
      _index = _index! + request.children.length;
    }
    broadcastPlaybackEvent();
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    if (_index != null &&
        _index! >= request.startIndex &&
        _index! < request.endIndex &&
        _playing) {
      // Pause if removing current item
      _currentAudioSourcePlayer!.pause();
    }
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!
        .removeRange(request.startIndex, request.endIndex);
    if (_index != null) {
      if (_index! >= request.startIndex && _index! < request.endIndex) {
        // Skip backward if there's nothing after this
        if (request.startIndex >= _audioSourcePlayer!.sequence.length) {
          _index = request.startIndex - 1;
          if (_index! < 0) _index = 0;
        } else {
          _index = request.startIndex;
        }
        // Resume playback at the new item (if it exists)
        if (_playing && _currentAudioSourcePlayer != null) {
          await _currentAudioSourcePlayer!.load();
          _currentAudioSourcePlayer!.play();
        }
      } else if (request.endIndex <= _index!) {
        // Reflect that the current item has shifted its position
        _index = _index! - (request.endIndex - request.startIndex);
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) async {
    _concatenating(request.id)!.setShuffleOrder(request.shuffleOrder);
    _concatenating(request.id)!.move(request.currentIndex, request.newIndex);
    if (_index != null) {
      if (request.currentIndex == _index) {
        _index = request.newIndex;
      } else if (request.currentIndex < _index! &&
          request.newIndex >= _index!) {
        _index = _index! - 1;
      } else if (request.currentIndex > _index! &&
          request.newIndex <= _index!) {
        _index = _index! + 1;
      }
    }
    broadcastPlaybackEvent();
    return ConcatenatingMoveResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(
      SetAndroidAudioAttributesRequest request) async {
    return SetAndroidAudioAttributesResponse();
  }

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse>
      setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async {
    return SetAutomaticallyWaitsToMinimizeStallingResponse();
  }

  @override
  Duration getCurrentPosition() =>
      _currentAudioSourcePlayer?.position ?? Duration.zero;

  @override
  Duration getBufferedPosition() =>
      _currentAudioSourcePlayer?.bufferedPosition ?? Duration.zero;

  @override
  Duration? getDuration() => _currentAudioSourcePlayer?.duration;

  @override
  Future<void> release() async {
    _currentAudioSourcePlayer?.pause();
    transition(ProcessingStateMessage.idle);
    return await super.release();
  }

  /// Converts a list of audio source messages to players.
  List<AudioSourcePlayer> getAudioSources(List<AudioSourceMessage> messages) =>
      messages.map((message) => getAudioSource(message)).toList();

  /// Converts an audio source message to a player, using the cache if it is
  /// already cached.
  AudioSourcePlayer getAudioSource(AudioSourceMessage audioSourceMessage) {
    final id = audioSourceMessage.id;
    var audioSourcePlayer = _audioSourcePlayers[id];
    if (audioSourcePlayer == null) {
      audioSourcePlayer = decodeAudioSource(audioSourceMessage);
      _audioSourcePlayers[id] = audioSourcePlayer;
    }
    return audioSourcePlayer;
  }

  /// Converts an audio source message to a player.
  AudioSourcePlayer decodeAudioSource(AudioSourceMessage audioSourceMessage) {
    if (audioSourceMessage is ProgressiveAudioSourceMessage) {
      return ProgressiveAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is DashAudioSourceMessage) {
      return DashAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is HlsAudioSourceMessage) {
      return HlsAudioSourcePlayer(this, audioSourceMessage.id,
          Uri.parse(audioSourceMessage.uri), audioSourceMessage.headers);
    } else if (audioSourceMessage is ConcatenatingAudioSourceMessage) {
      return ConcatenatingAudioSourcePlayer(
          this,
          audioSourceMessage.id,
          getAudioSources(audioSourceMessage.children),
          audioSourceMessage.useLazyPreparation,
          audioSourceMessage.shuffleOrder);
    } else if (audioSourceMessage is ClippingAudioSourceMessage) {
      return ClippingAudioSourcePlayer(
          this,
          audioSourceMessage.id,
          getAudioSource(audioSourceMessage.child) as UriAudioSourcePlayer,
          audioSourceMessage.start,
          audioSourceMessage.end);
    } else if (audioSourceMessage is LoopingAudioSourceMessage) {
      return LoopingAudioSourcePlayer(this, audioSourceMessage.id,
          getAudioSource(audioSourceMessage.child), audioSourceMessage.count);
    } else {
      throw Exception("Unknown AudioSource type: $audioSourceMessage");
    }
  }
}

/// A player for a single audio source.
abstract class AudioSourcePlayer {
  /// The [VlcAudioPlayer] responsible for audio I/O.
  VlcAudioPlayer vlcAudioPlayer;

  /// The ID of the underlying audio source.
  final String id;

  AudioSourcePlayer(this.vlcAudioPlayer, this.id);

  /// The sequence of players for the indexed items nested in this player.
  List<IndexedAudioSourcePlayer> get sequence;

  /// The order to use over [sequence] when in shuffle mode.
  List<int> get shuffleIndices;
}

/// A player for an [IndexedAudioSourceMessage].
abstract class IndexedAudioSourcePlayer extends AudioSourcePlayer {
  IndexedAudioSourcePlayer(VlcAudioPlayer vlcAudioPlayer, String id)
      : super(vlcAudioPlayer, id);

  /// Loads the audio for the underlying audio source.
  Future<Duration?> load();

  /// Plays the underlying audio source.
  Future<void> play();

  /// Pauses playback of the underlying audio source.
  Future<void> pause();

  /// Seeks to [position] milliseconds.
  Future<void> seek(int position);

  /// Called when playback reaches the end of the underlying audio source.
  Future<void> complete();

  /// Called when the playback position of the underlying VLC player changes.
  Future<void> timeUpdated(double seconds) async {}

  /// The duration of the underlying audio source.
  Duration? get duration;

  /// The current playback position.
  Duration get position;

  /// The current buffered position.
  Duration get bufferedPosition;

  /// The audio element that renders the audio.
  Player get _audioElement => vlcAudioPlayer._audioElement;

  @override
  String toString() => "$runtimeType";
}

/// A player for an [UriAudioSourceMessage].
abstract class UriAudioSourcePlayer extends IndexedAudioSourcePlayer {
  /// The URL to play.
  final Uri uri;

  /// The headers to include in the request (unsupported).
  final Map? headers;
  Duration? _resumePos;
  Duration? _duration;
  Completer? _completer;

  UriAudioSourcePlayer(
      VlcAudioPlayer vlcAudioPlayer, String id, this.uri, this.headers)
      : super(vlcAudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];

  @override
  Future<Duration?> load() async {
    _resumePos = Duration(milliseconds: 0);
    return _duration = await vlcAudioPlayer.loadUri(uri);
  }

  @override
  Future<void> play() async {
    _audioElement..seek(_resumePos!);
    await _audioElement.play();
    _completer = Completer<dynamic>();
    await _completer!.future;
    _completer = null;
  }

  @override
  Future<void> pause() async {
    _resumePos = _audioElement.position.position;
    _audioElement.pause();
    _interruptPlay();
  }

  @override
  Future<void> seek(int position) async {
    _audioElement.seek(_resumePos);
  }

  @override
  Future<void> complete() async {
    _interruptPlay();
    vlcAudioPlayer.onEnded();
  }

  void _interruptPlay() {
    if (_completer?.isCompleted == false) {
      _completer!.complete();
    }
  }

  @override
  Duration? get duration {
    return _duration;
  }

  @override
  Duration get position {
    final milliseconds = _audioElement.position.position.inMilliseconds;
    return Duration(milliseconds: milliseconds);
  }

  @override
  Duration get bufferedPosition {
    return Duration.zero;
  }
}

/// A player for a [ProgressiveAudioSourceMessage].
class ProgressiveAudioSourcePlayer extends UriAudioSourcePlayer {
  ProgressiveAudioSourcePlayer(
      VlcAudioPlayer vlcAudioPlayer, String id, Uri uri, Map? headers)
      : super(vlcAudioPlayer, id, uri, headers);
}

/// A player for a [DashAudioSourceMessage].
class DashAudioSourcePlayer extends UriAudioSourcePlayer {
  DashAudioSourcePlayer(
      VlcAudioPlayer vlcAudioPlayer, String id, Uri uri, Map? headers)
      : super(vlcAudioPlayer, id, uri, headers);
}

/// A player for a [HlsAudioSourceMessage].
class HlsAudioSourcePlayer extends UriAudioSourcePlayer {
  HlsAudioSourcePlayer(
      VlcAudioPlayer vlcAudioPlayer, String id, Uri uri, Map? headers)
      : super(vlcAudioPlayer, id, uri, headers);
}

/// A player for a [ConcatenatingAudioSourceMessage].
class ConcatenatingAudioSourcePlayer extends AudioSourcePlayer {
  /// The players for each child audio source.
  final List<AudioSourcePlayer> audioSourcePlayers;

  /// Whether audio should be loaded as late as possible. (Currently ignored.)
  final bool useLazyPreparation;
  List<int> _shuffleOrder;

  ConcatenatingAudioSourcePlayer(VlcAudioPlayer vlcAudioPlayer, String id,
      this.audioSourcePlayers, this.useLazyPreparation, List<int> shuffleOrder)
      : _shuffleOrder = shuffleOrder,
        super(vlcAudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence =>
      audioSourcePlayers.expand((p) => p.sequence).toList();

  @override
  List<int> get shuffleIndices {
    final order = <int>[];
    var offset = order.length;
    final childOrders = <List<int>>[];
    for (var audioSourcePlayer in audioSourcePlayers) {
      final childShuffleIndices = audioSourcePlayer.shuffleIndices;
      childOrders.add(childShuffleIndices.map((i) => i + offset).toList());
      offset += childShuffleIndices.length;
    }
    for (var i = 0; i < childOrders.length; i++) {
      order.addAll(childOrders[_shuffleOrder[i]]);
    }
    return order;
  }

  /// Sets the current shuffle order.
  void setShuffleOrder(List<int> shuffleOrder) {
    _shuffleOrder = shuffleOrder;
  }

  /// Inserts [players] into this player at position [index].
  void insertAll(int index, List<AudioSourcePlayer> players) {
    audioSourcePlayers.insertAll(index, players);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= index) {
        _shuffleOrder[i] += players.length;
      }
    }
  }

  /// Removes the child players in the specified range.
  void removeRange(int start, int end) {
    audioSourcePlayers.removeRange(start, end);
    for (var i = 0; i < audioSourcePlayers.length; i++) {
      if (_shuffleOrder[i] >= end) {
        _shuffleOrder[i] -= (end - start);
      }
    }
  }

  /// Moves a child player from [currentIndex] to [newIndex].
  void move(int currentIndex, int newIndex) {
    audioSourcePlayers.insert(
        newIndex, audioSourcePlayers.removeAt(currentIndex));
  }
}

/// A player for a [ClippingAudioSourceMessage].
class ClippingAudioSourcePlayer extends IndexedAudioSourcePlayer {
  final UriAudioSourcePlayer audioSourcePlayer;
  final Duration? start;
  final Duration? end;
  Completer<ClipInterruptReason>? _completer;
  Duration? _resumePos;
  Duration? _duration;

  ClippingAudioSourcePlayer(VlcAudioPlayer vlcAudioPlayer, String id,
      this.audioSourcePlayer, this.start, this.end)
      : super(vlcAudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence => [this];

  @override
  List<int> get shuffleIndices => [0];

  @override
  Future<Duration?> load() async {
    _resumePos = start ?? Duration.zero;
    final fullDuration =
        (await vlcAudioPlayer.loadUri(audioSourcePlayer.uri))!;
    _audioElement.seek(_resumePos!);
    _duration = Duration(
        milliseconds: min((end ?? fullDuration).inMilliseconds,
                fullDuration.inMilliseconds) -
            (start ?? Duration.zero).inMilliseconds);
    return _duration;
  }

  double get remaining =>
      end!.inMilliseconds / 1000 -
      _audioElement.position.position.inMilliseconds;

  @override
  Future<void> play() async {
    _interruptPlay(ClipInterruptReason.simultaneous);
    _audioElement.seek(_resumePos!);
    await _audioElement.play();
    _completer = Completer<ClipInterruptReason>();
    ClipInterruptReason reason;
    while ((reason = await _completer!.future) == ClipInterruptReason.seek) {
      _completer = Completer<ClipInterruptReason>();
    }
    if (reason == ClipInterruptReason.end) {
      vlcAudioPlayer.onEnded();
    }
    _completer = null;
  }

  @override
  Future<void> pause() async {
    _interruptPlay(ClipInterruptReason.pause);
    _resumePos = _audioElement.position.position;
    _audioElement.pause();
  }

  @override
  Future<void> seek(int position) async {
    _interruptPlay(ClipInterruptReason.seek);
    _resumePos = Duration(milliseconds: start!.inMilliseconds + position);
    _audioElement.seek(_resumePos!);
  }

  @override
  Future<void> complete() async {
    _interruptPlay(ClipInterruptReason.end);
  }

  @override
  Future<void> timeUpdated(double seconds) async {
    if (end != null) {
      if (seconds >= end!.inMilliseconds / 1000) {
        _interruptPlay(ClipInterruptReason.end);
      }
    }
  }

  @override
  Duration? get duration {
    return _duration;
  }

  @override
  Duration get position {
    final seconds = _audioElement.position.position.inSeconds;
    var position = Duration(milliseconds: (seconds * 1000).toInt());
    if (start != null) {
      position -= start!;
    }
    if (position < Duration.zero) {
      position = Duration.zero;
    }
    return position;
  }

  @override
  Duration get bufferedPosition {
    return Duration.zero;
  }

  void _interruptPlay(ClipInterruptReason reason) {
    if (_completer?.isCompleted == false) {
      _completer!.complete(reason);
    }
  }
}

/// Reasons why playback of a clipping audio source may be interrupted.
enum ClipInterruptReason { end, pause, seek, simultaneous }

/// A player for a [LoopingAudioSourceMessage].
class LoopingAudioSourcePlayer extends AudioSourcePlayer {
  /// The child audio source player to loop.
  final AudioSourcePlayer audioSourcePlayer;

  /// The number of times to loop.
  final int count;

  LoopingAudioSourcePlayer(VlcAudioPlayer vlcAudioPlayer, String id,
      this.audioSourcePlayer, this.count)
      : super(vlcAudioPlayer, id);

  @override
  List<IndexedAudioSourcePlayer> get sequence =>
      List.generate(count, (i) => audioSourcePlayer)
          .expand((p) => p.sequence)
          .toList();

  @override
  List<int> get shuffleIndices {
    final order = <int>[];
    var offset = order.length;
    for (var i = 0; i < count; i++) {
      final childShuffleOrder = audioSourcePlayer.shuffleIndices;
      order.addAll(childShuffleOrder.map((i) => i + offset).toList());
      offset += childShuffleOrder.length;
    }
    return order;
  }
}
