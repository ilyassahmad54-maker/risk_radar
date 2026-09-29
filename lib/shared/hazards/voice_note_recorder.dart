// lib/shared/hazards/voice_note_recorder.dart

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:riskradar/utils/responsive.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:riskradar/shared/theme/app_colors.dart';
import 'package:uuid/uuid.dart';

// Callback definitions
typedef RecordingStateChanged = void Function(bool isRecording);
typedef PlaybackStateChanged = void Function(bool isPlaying);

class VoiceNote {
  final String id;
  final File file;
  final Duration duration;
  final List<double> waveformData;
  final DateTime createdAt;

  VoiceNote({
    required this.id,
    required this.file,
    required this.duration,
    required this.waveformData,
    required this.createdAt,
  });
}

class VoiceNoteRecorder extends StatefulWidget {
  final RecordingStateChanged onRecordingStateChanged;
  final PlaybackStateChanged? onPlaybackStateChanged;

  const VoiceNoteRecorder({
    super.key,
    required this.onRecordingStateChanged,
    this.onPlaybackStateChanged,
  });

  @override
  State<VoiceNoteRecorder> createState() => VoiceNoteRecorderState();
}

class VoiceNoteRecorderState extends State<VoiceNoteRecorder> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isRecorderReady = false;
  bool _isRecording = false;
  bool _isRecordingPaused = false;
  bool _playerReady = false;

  StreamSubscription? _recorderSubscription;
  StreamSubscription? _playerSubscription;
  Timer? _recordingDurationTimer;
  final Stopwatch _recordingStopwatch = Stopwatch();

  final List<VoiceNote> _voiceNotes = [];
  String? _currentPlayingId;
  Duration _currentPlayPosition = Duration.zero;

  final List<double> _currentWaveformData = [];
  Duration _currentRecordingDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _initRecorder();
    _initPlayer();
  }

  Future<void> _initRecorder() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) return;
    await Permission.storage.request();
    await _recorder.openRecorder();
    _isRecorderReady = true;

    _recorderSubscription = _recorder.onProgress?.listen((event) {
      if (event.decibels != null &&
          mounted &&
          _isRecording &&
          !_isRecordingPaused) {
        final double amplitude = (event.decibels!.abs() / 80).clamp(0.0, 1.0);
        setState(() {
          _currentWaveformData.add(amplitude);
          if (_currentWaveformData.length > 100) {
            _currentWaveformData.removeAt(0);
          }
        });
      }
    });
    _recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
  }

  Future<void> _initPlayer() async {
    await _player.openPlayer();
    setState(() => _playerReady = true);
    _playerSubscription = _player.onProgress?.listen((event) {
      if (mounted && _currentPlayingId != null) {
        setState(() => _currentPlayPosition = event.position);
      }
    });
    _player.setSubscriptionDuration(const Duration(milliseconds: 100));
  }

  @override
  void dispose() {
    _recordingDurationTimer?.cancel();
    _recorderSubscription?.cancel();
    _playerSubscription?.cancel();
    unawaited(_disposeAudioResources());
    super.dispose();
  }

  Future<void> _disposeAudioResources() async {
    if (_isRecording) {
      await _recorder.stopRecorder();
    }
    if (_currentPlayingId != null) {
      await _player.stopPlayer();
    }
    await _recorder.closeRecorder();
    await _player.closePlayer();
  }

  Future<void> discardActiveSession() async {
    _recordingDurationTimer?.cancel();
    _recordingDurationTimer = null;
    _recordingStopwatch.stop();

    if (_isRecordingPaused) {
      await _recorder.resumeRecorder();
    }
    if (_isRecording) {
      await _recorder.stopRecorder();
    }
    if (_currentPlayingId != null) {
      await _player.stopPlayer();
    }

    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingPaused = false;
      _currentPlayingId = null;
      _currentPlayPosition = Duration.zero;
      _currentWaveformData.clear();
      _currentRecordingDuration = Duration.zero;
    });
    widget.onRecordingStateChanged(false);
    widget.onPlaybackStateChanged?.call(false);
  }

  Future<void> startRecording() async {
    if (!_isRecorderReady || _currentPlayingId != null) return;

    final dir = await getTemporaryDirectory();
    final path = "${dir.path}/${const Uuid().v4()}.m4a";
    if (!mounted) return;
    setState(() {
      _currentWaveformData.clear();
      _currentRecordingDuration = Duration.zero;
      _isRecordingPaused = false;
    });
    await _recorder.startRecorder(
      toFile: path,
      codec: Codec.aacMP4,
      sampleRate: 44100,
      bitRate: 128000,
      numChannels: 1,
    );
    _startRecordingClock();
    if (!mounted) return;
    setState(() => _isRecording = true);
    widget.onRecordingStateChanged(true);
  }

  Future<void> toggleRecordingPause() async {
    if (!_isRecording) return;

    if (_isRecordingPaused) {
      await _recorder.resumeRecorder();
      if (!mounted) return;
      _resumeRecordingClock();
      setState(() => _isRecordingPaused = false);
      return;
    }

    await _recorder.pauseRecorder();
    if (!mounted) return;
    _pauseRecordingClock();
    setState(() => _isRecordingPaused = true);
  }

  Future<void> stopRecording() async {
    if (!_isRecording) return;
    final Duration recordedDuration = _recordingStopwatch.elapsed;
    final List<double> recordedWaveformData = List<double>.from(
      _currentWaveformData,
    );
    _stopRecordingClock();
    if (_isRecordingPaused) {
      await _recorder.resumeRecorder();
    }
    final recordedPath = await _recorder.stopRecorder();
    if (recordedPath != null &&
        recordedDuration > const Duration(milliseconds: 500)) {
      final voiceNote = VoiceNote(
        id: const Uuid().v4(),
        file: File(recordedPath),
        duration: recordedDuration,
        waveformData: recordedWaveformData,
        createdAt: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _voiceNotes.add(voiceNote);
      });
    }
    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isRecordingPaused = false;
      _currentWaveformData.clear();
      _currentRecordingDuration = Duration.zero;
    });
    widget.onRecordingStateChanged(false);
  }

  void _startRecordingClock() {
    _recordingDurationTimer?.cancel();
    _recordingStopwatch
      ..reset()
      ..start();
    _recordingDurationTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) {
        if (!mounted || !_isRecording || _isRecordingPaused) return;
        setState(() {
          _currentRecordingDuration = _recordingStopwatch.elapsed;
        });
      },
    );
  }

  void _pauseRecordingClock() {
    _recordingStopwatch.stop();
    _currentRecordingDuration = _recordingStopwatch.elapsed;
  }

  void _resumeRecordingClock() {
    _recordingStopwatch.start();
  }

  void _stopRecordingClock() {
    _recordingDurationTimer?.cancel();
    _recordingDurationTimer = null;
    _recordingStopwatch.stop();
  }

  Future<void> _playVoiceNote(String voiceNoteId) async {
    if (!_playerReady || _isRecording) return;

    final voiceNote = _voiceNotes.firstWhere((note) => note.id == voiceNoteId);
    if (_currentPlayingId != null && _currentPlayingId != voiceNoteId) {
      await _player.stopPlayer();
    }
    if (_currentPlayingId == voiceNoteId) {
      await _player.stopPlayer();
      setState(() {
        _currentPlayingId = null;
        _currentPlayPosition = Duration.zero;
      });
      widget.onPlaybackStateChanged?.call(false);
    } else {
      await _player.startPlayer(
        fromURI: voiceNote.file.path,
        codec: Codec.aacMP4,
        whenFinished: () {
          if (mounted) {
            setState(() {
              _currentPlayingId = null;
              _currentPlayPosition = Duration.zero;
            });
            widget.onPlaybackStateChanged?.call(false);
          }
        },
      );
      setState(() {
        _currentPlayingId = voiceNoteId;
        _currentPlayPosition = Duration.zero;
      });
      widget.onPlaybackStateChanged?.call(true);
    }
  }

  Future<void> _seekInVoiceNote(
    String voiceNoteId,
    double positionFraction,
  ) async {
    if (!_playerReady || _currentPlayingId != voiceNoteId) return;

    final voiceNote = _voiceNotes.firstWhere((note) => note.id == voiceNoteId);
    final seekPosition = Duration(
      milliseconds: (voiceNote.duration.inMilliseconds * positionFraction)
          .round(),
    );

    await _player.seekToPlayer(seekPosition);

    setState(() {
      _currentPlayPosition = seekPosition;
    });
  }

  void _deleteVoiceNote(String voiceNoteId) {
    setState(() {
      if (_currentPlayingId == voiceNoteId) {
        _player.stopPlayer();
        _currentPlayingId = null;
        _currentPlayPosition = Duration.zero;
        widget.onPlaybackStateChanged?.call(false);
      }
      _voiceNotes.removeWhere((note) => note.id == voiceNoteId);
    });
  }

  List<File> getAllRecordedFiles() {
    return _voiceNotes.map((note) => note.file).toList();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    R.init(context);
    if (!_isRecording && _voiceNotes.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_voiceNotes.isNotEmpty)
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _voiceNotes.length,
            separatorBuilder: (_, _) => SizedBox(height: R.blockV * 1.5),
            itemBuilder: (context, index) {
              return _buildVoiceNoteItem(_voiceNotes[index]);
            },
          ),

        if (_voiceNotes.isNotEmpty && _isRecording)
          SizedBox(height: R.blockV * 2),

        if (_isRecording) _buildCurrentRecording(),
      ],
    );
  }

  Widget _buildVoiceNoteItem(VoiceNote voiceNote) {
    final isPlaying = _currentPlayingId == voiceNote.id;
    final progress = isPlaying && voiceNote.duration.inMilliseconds > 0
        ? (_currentPlayPosition.inMilliseconds /
                  voiceNote.duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;

    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    final Color surfaceColor = isLightTheme
        ? AppColors.brandTeal
        : AppColors.surfaceTeal.withValues(alpha: 0.70);
    final Color borderColor = isLightTheme
        ? AppColors.accentGold.withValues(alpha: 0.34)
        : AppColors.accentGold.withValues(alpha: 0.30);
    final Color primaryTextColor = Colors.white;
    final Color secondaryTextColor = isLightTheme
        ? Colors.white.withValues(alpha: 0.78)
        : Colors.white.withValues(alpha: 0.74);
    final Color playButtonColor = isPlaying
        ? AppColors.brandTeal
        : AppColors.accentGold;
    final Color inactiveControlColor = isLightTheme
        ? Colors.white.withValues(alpha: 0.16)
        : Colors.white.withValues(alpha: 0.22);
    final Color playbackIconColor = _isRecording
        ? Colors.white
        : (isPlaying ? Colors.white : AppColors.brandTeal);

    return ClipRRect(
      borderRadius: BorderRadius.circular(20.0),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: R.blockH * 3,
            vertical: R.blockV * 1,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20.0),
            color: surfaceColor,
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: AppColors.brandTeal.withValues(
                  alpha: isLightTheme ? 0.22 : 0.24,
                ),
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: _isRecording ? null : () => _playVoiceNote(voiceNote.id),
                child: Container(
                  width: R.blockH * 9.6,
                  height: R.blockV * 4.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isRecording
                        ? inactiveControlColor
                        : playButtonColor,
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: playbackIconColor,
                    size: 18,
                  ),
                ),
              ),
              SizedBox(width: R.blockH * 3.2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      child: Builder(
                        builder: (context) {
                          return CustomPaint(
                            painter: VoiceNoteWaveformPainter(
                              waveformData: voiceNote.waveformData,
                              progress: progress,
                              isLightTheme: isLightTheme,
                              playedColor: AppColors.accentGold,
                              unplayedColor: secondaryTextColor.withValues(
                                alpha: 0.48,
                              ),
                              handleColor: primaryTextColor,
                            ),
                            size: const Size(double.infinity, 30),
                          );
                        },
                      ),
                      onTapDown: (details) {
                        final RenderBox box =
                            context.findRenderObject() as RenderBox;
                        final positionFraction =
                            (details.localPosition.dx / box.size.width).clamp(
                              0.0,
                              1.0,
                            );
                        _seekInVoiceNote(voiceNote.id, positionFraction);
                      },
                      onHorizontalDragUpdate: (details) {
                        final RenderBox box =
                            context.findRenderObject() as RenderBox;
                        final positionFraction =
                            (details.localPosition.dx / box.size.width).clamp(
                              0.0,
                              1.0,
                            );
                        _seekInVoiceNote(voiceNote.id, positionFraction);
                      },
                    ),
                    SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(
                            isPlaying ? _currentPlayPosition : Duration.zero,
                          ),
                          style: TextStyle(
                            fontSize: R.blockH * 2.5,
                            color: secondaryTextColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          _formatDuration(voiceNote.duration),
                          style: TextStyle(
                            fontSize: R.blockH * 2.5,
                            color: secondaryTextColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: R.blockH * 3.2),
              GestureDetector(
                onTap: () => _deleteVoiceNote(voiceNote.id),
                child: Container(
                  width: R.blockH * 7.467,
                  height: R.blockV * 3.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isLightTheme
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.10),
                  ),
                  child: Icon(
                    Icons.delete_outline,
                    color: isLightTheme ? Colors.white : AppColors.accentGold,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentRecording() {
    final isLightTheme = Theme.of(context).brightness == Brightness.light;
    final Color recordingSurfaceColor = isLightTheme
        ? AppColors.accentGold.withValues(alpha: 0.14)
        : AppColors.brandTeal.withValues(alpha: 0.82);
    final Color recordingBorderColor = AppColors.accentGold.withValues(
      alpha: 0.42,
    );
    final Color recordingTextColor = isLightTheme
        ? AppColors.brandTeal
        : Colors.white;
    final Color recordingWaveColor = isLightTheme
        ? AppColors.brandTeal
        : AppColors.accentGold;
    final IconData pauseResumeIcon = _isRecordingPaused
        ? Icons.play_arrow_rounded
        : Icons.pause_rounded;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: R.blockH * 3,
        vertical: R.blockV * 1,
      ),
      decoration: BoxDecoration(
        color: recordingSurfaceColor,
        borderRadius: BorderRadius.circular(20.0),
        border: Border.all(color: recordingBorderColor),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandTeal.withValues(
              alpha: isLightTheme ? 0.08 : 0.28,
            ),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: stopRecording,
            child: Container(
              width: R.blockH * 9.6,
              height: R.blockV * 4.5,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accentGold,
              ),
              child: Icon(Icons.stop, color: AppColors.brandTeal, size: 20),
            ),
          ),
          SizedBox(width: R.blockH * 2.667),
          GestureDetector(
            onTap: toggleRecordingPause,
            child: Container(
              width: R.blockH * 9.6,
              height: R.blockV * 4.5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isLightTheme
                    ? AppColors.brandTeal.withValues(alpha: 0.12)
                    : Colors.white.withValues(alpha: 0.12),
                border: Border.all(
                  color: isLightTheme
                      ? AppColors.brandTeal.withValues(alpha: 0.22)
                      : Colors.white.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(pauseResumeIcon, color: recordingTextColor, size: 22),
            ),
          ),
          SizedBox(width: R.blockH * 3.2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: R.blockV * 3.75,
                  child: CustomPaint(
                    painter: VoiceNoteWaveformPainter(
                      waveformData: _currentWaveformData,
                      progress: 0.0,
                      isRecording: true,
                      isLightTheme: isLightTheme,
                      playedColor: recordingWaveColor,
                      unplayedColor: recordingWaveColor.withValues(alpha: 0.36),
                      handleColor: recordingWaveColor,
                    ),
                    size: const Size(double.infinity, 30),
                  ),
                ),
                SizedBox(height: 2),
                Row(
                  children: [
                    Container(
                      width: R.blockH * 2.133,
                      height: R.blockV * 1,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.accentGold,
                      ),
                    ),
                    SizedBox(width: R.blockH * 1.6),
                    Text(
                      _formatDuration(_currentRecordingDuration),
                      style: TextStyle(
                        fontSize: R.blockH * 3,
                        color: recordingTextColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class VoiceNoteWaveformPainter extends CustomPainter {
  final List<double> waveformData;
  final double progress;
  final bool isRecording;
  final bool isLightTheme;
  final Color playedColor;
  final Color unplayedColor;
  final Color handleColor;

  VoiceNoteWaveformPainter({
    required this.waveformData,
    required this.progress,
    this.isRecording = false,
    this.isLightTheme = false,
    this.playedColor = AppColors.accentGold,
    this.unplayedColor = AppColors.surfaceTeal,
    this.handleColor = AppColors.brandTeal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (waveformData.isEmpty) {
      final paint = Paint()
        ..color = unplayedColor
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      return;
    }

    final paint = Paint()..strokeWidth = 2.5;
    final barWidth = size.width / max(waveformData.length, 1);
    final progressPosition = size.width * progress.clamp(0.0, 1.0);

    for (int i = 0; i < waveformData.length; i++) {
      final x = i * barWidth + barWidth / 2;
      final barHeight = (waveformData[i] * size.height * 0.8).clamp(
        2.0,
        size.height * 0.8,
      );
      final y1 = (size.height - barHeight) / 2;
      final y2 = y1 + barHeight;
      paint.color = x <= progressPosition || isRecording
          ? playedColor
          : unplayedColor;
      canvas.drawLine(Offset(x, y1), Offset(x, y2), paint);
    }

    if (!isRecording && progress > 0) {
      final progressHandlePaint = Paint()..color = handleColor;
      canvas.drawCircle(
        Offset(progressPosition, size.height / 2),
        4,
        progressHandlePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! VoiceNoteWaveformPainter ||
        oldDelegate.waveformData.length != waveformData.length ||
        oldDelegate.progress != progress ||
        oldDelegate.isRecording != isRecording ||
        oldDelegate.isLightTheme != isLightTheme ||
        oldDelegate.playedColor != playedColor ||
        oldDelegate.unplayedColor != unplayedColor ||
        oldDelegate.handleColor != handleColor;
  }
}
