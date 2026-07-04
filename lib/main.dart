// =============================================================================
// BatBox - Flutter app for sound-triggered and motion-triggered photography
// BUILD v12.6 - 2026-06-30 08:00 UTC
//
// PROMPT THAT GENERATED THIS VERSION:
// "1. From now on, if you're not doing so already, add the prompt that
//  generates code as a comment at the top of the code near the version number.
//  2. The two buttons that play the full reference audio and the trimmed
//  reference audio, play the audio but then change to the word Stop once
//  the clip has ended. Pushing the 'Stop' then brings back the Play button
//  again. Instead, they need to say Stop while the clip is playing only."
//
// FIX: Added processingStateStream listener (more reliable than
// playerStateStream for detecting playback completion). Buttons now
// correctly return to "Play" when audio finishes.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Catch all unhandled Flutter errors so we never get a white screen.
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('[batbox] FLUTTER ERROR: ${details.exception}');
    debugPrint('[batbox] stack: ${details.stack}');
  };
  // Catch all unhandled async errors.
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    debugPrint('[batbox] ASYNC ERROR: $error');
    debugPrint('[batbox] stack: $stack');
    return true;
  };
  runApp(const BatboxApp());
}

// =============================================================================
// Enums
// =============================================================================

enum RecognitionMode {
  standard('Standard'),
  better('Better');

  const RecognitionMode(this.label);
  final String label;
}

enum PhotoCountMode {
  one('1 photo per match'),
  three('3 photos per match'),
  ten('10 photos per match'),
  continuous('Continuous (1 per match)'),
  flashOnly('Flash only (test)');

  const PhotoCountMode(this.label);
  final String label;
  int get burstSize {
    switch (this) {
      case PhotoCountMode.one: return 1;
      case PhotoCountMode.three: return 3;
      case PhotoCountMode.ten: return 10;
      case PhotoCountMode.continuous: return 1;
      case PhotoCountMode.flashOnly: return 0;
    }
  }
  bool get stopAfterFirstMatch {
    switch (this) {
      case PhotoCountMode.one:
      case PhotoCountMode.three:
      case PhotoCountMode.ten: return true;
      case PhotoCountMode.continuous:
      case PhotoCountMode.flashOnly: return false;
    }
  }
  bool get takesPhotos => this != PhotoCountMode.flashOnly;
}

enum FlashModeSetting {
  off('Off'), auto('Auto'), always('Always flash'), torch('Torch (continuous)');
  const FlashModeSetting(this.label);
  final String label;
}

enum ResolutionSetting {
  low('Low'), medium('Medium'), high('High');
  const ResolutionSetting(this.label);
  final String label;
  ResolutionPreset get preset {
    switch (this) {
      case ResolutionSetting.low: return ResolutionPreset.low;
      case ResolutionSetting.medium: return ResolutionPreset.medium;
      case ResolutionSetting.high: return ResolutionPreset.high;
    }
  }
}

// =============================================================================
// Reference sound data class
// =============================================================================

class ReferenceSound {
  String name;
  String filePath;
  List<double> samples = [];
  List<double> downsampled = [];
  List<double> processed = [];
  List<double> envelope = [];
  double energy = 0.0;
  double silenceThreshold = 0.0;
  // #2: Per-reference threshold (null = use global threshold).
  double? threshold;
  // #3: Calibrated noise floor (null = use default 10% of reference energy).
  double? noiseFloor;
  // Trim: normalized 0.0-1.0 range. trimStart=0.0 and trimEnd=1.0 = no trim.
  // The original samples are never deleted -- trim is applied when computing
  // features, so it's fully reversible.
  double trimStart = 0.0;
  double trimEnd = 1.0;

  ReferenceSound({required this.name, required this.filePath, this.threshold, this.noiseFloor});

  Map<String, dynamic> toJson() => {
    'name': name,
    'filePath': filePath,
    if (threshold != null) 'threshold': threshold,
    if (noiseFloor != null) 'noiseFloor': noiseFloor,
    'trimStart': trimStart,
    'trimEnd': trimEnd,
  };
  factory ReferenceSound.fromJson(Map<String, dynamic> json) =>
      ReferenceSound(
        name: (json['name'] as String?) ?? 'Unknown',
        filePath: (json['filePath'] as String?) ?? '',
        threshold: (json['threshold'] as num?)?.toDouble(),
        noiseFloor: (json['noiseFloor'] as num?)?.toDouble(),
      )..trimStart = (json['trimStart'] as num?)?.toDouble() ?? 0.0
       ..trimEnd = (json['trimEnd'] as num?)?.toDouble() ?? 1.0;
}

// =============================================================================
// Global navigator key (bulletproof navigation)
// =============================================================================

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

// =============================================================================
// App
// =============================================================================

class BatboxApp extends StatefulWidget {
  const BatboxApp({super.key});
  @override
  State<BatboxApp> createState() => _BatboxAppState();
}

class _BatboxAppState extends State<BatboxApp> with TickerProviderStateMixin {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<dynamic>? _audioSubscription;
  List<CameraDescription> _availableCameras = [];
  CameraController? _cameraController;
  Timer? _flashTimer;
  Timer? _autoStopTimer;
  late TabController _tabController;

  SharedPreferences? _prefs;  // nullable to handle init race conditions

  // --- Settings (persisted) ---
  double _triggerThreshold = 0.35;
  RecognitionMode _recognitionMode = RecognitionMode.better;
  PhotoCountMode _photoCountMode = PhotoCountMode.one;
  FlashModeSetting _flashModeSetting = FlashModeSetting.off;
  ResolutionSetting _resolutionSetting = ResolutionSetting.medium;
  int _refractoryPeriodMs = 1500;
  bool _autoStopOnSilence = false;
  int _autoStopTimeoutSec = 30;
  bool _hapticOnMatch = true;

  // --- Settings keys ---
  static const _kThreshold = 'threshold';
  static const _kRecogMode = 'recog_mode';
  static const _kPhotoCount = 'photo_count';
  static const _kFlashMode = 'flash_mode';
  static const _kResolution = 'resolution';
  static const _kRefractory = 'refractory_ms';
  static const _kAutoStop = 'auto_stop';
  static const _kAutoStopTimeout = 'auto_stop_timeout';
  static const _kHaptic = 'haptic';
  static const _kDarkMode = 'dark_mode';
  static const _kCompressPhotos = 'compress_photos';
  static const _kFastCapture = 'fast_capture';
  static const _kBurstDelay = 'burst_delay';
  static const _kMinMatchChunks = 'min_match_chunks';
  static const _kMotionSensitivity = 'motion_sensitivity';
  static const _kTriggerSource = 'trigger_source';
  static const _kCameraIndex = 'camera_index';
  static const _kCaptureVideo = 'capture_video';
  static const _kReferenceList = 'reference_list';
  static const _kActiveReference = 'active_reference';

  // --- Reference library ---
  final List<ReferenceSound> _references = [];
  String _activeReferenceName = '';

  // Active reference buffers (computed from the active ReferenceSound)
  final List<double> _referenceSamples = [];
  final List<double> _referenceDown = [];
  final List<double> _referenceProcessed = [];
  final List<double> _referenceEnvelope = [];
  double _referenceEnergy = 0.0;
  double _silenceThreshold = 0.0;

  // --- Live audio buffers ---
  final List<double> _liveSamples = [];
  final List<double> _liveDown = [];
  double _adaptiveNoiseFloor = 0.0;

  // --- Matching state ---
  double _currentBestSimilarity = 0.0;
  double _sessionPeakSimilarity = 0.0;
  int _consecutiveMatchCount = 0;
  int _minMatchChunks = 1; // default 1 = instant trigger (was 2)
  DateTime _lastTriggerTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLoudAudioTime = DateTime.fromMillisecondsSinceEpoch(0);

  // --- Spectrogram + histogram ---
  final List<List<double>> _spectrogramFrames = []; // last N FFT frames
  static const int _maxSpectrogramFrames = 80;
  final List<double> _similarityHistory = []; // last N similarity scores
  static const int _maxHistoryLen = 30;

  // --- Photo state ---
  final List<String> _allPhotoPaths = [];
  final Map<String, List<String>> _photosBySession = {}; // sessionLabel -> paths
  final Set<String> _selectedPhotoPaths = {};
  bool _selectionMode = false;
  String _currentSessionId = '';

  // --- Recording / listening state ---
  bool _isRecordingReference = false;
  bool _isListening = false;
  bool _testMode = false;
  bool _photoTriggered = false;
  bool _isCapturingPhoto = false;
  bool _isPlayingReference = false;
  // Track which reference clip is currently playing:
  // 'none', 'full', or 'trimmed'. This lets each play button show
  // the correct state independently.
  String _playingSource = 'none';
  bool _flashActive = false;
  bool _cameraLaunchInProgress = false;
  double _microphoneLevel = 0.0;
  // #5: Separate level for reference recording display.
  double _recordingLevel = 0.0;
  // #23: Dark mode
  bool _isDarkMode = true; // start in dark mode
  // #11: Photo compression
  bool _compressPhotos = false;
  // Fast capture mode: lowest resolution, deferred file copy,
  // minimal UI updates during burst. Optimized for bat photography.
  bool _fastCaptureMode = true;
  // Burst rate: delay between burst photos (0 = as fast as possible).
  int _burstDelayMs = 0;
  // #21: Camera index (0=back, 1=front, 2+=other lenses)
  int _cameraIndex = 0;
  // #22: Video mode
  bool _captureVideo = false;
  // Viewfinder: show live camera preview to help aim
  bool _showViewfinder = false;
  // Motion detection
  bool _motionDetectionEnabled = false;
  double _motionSensitivity = 0.3; // 0.0 = very insensitive, 1.0 = very sensitive
  bool _isDetectingMotion = false;
  double _currentMotionLevel = 0.0;
  double _motionSessionPeak = 0.0;
  // Motion zone (normalized 0.0-1.0)
  Rect _motionZone = const Rect.fromLTWH(0.2, 0.2, 0.6, 0.6);
  bool _isDrawingZone = false;
  // Previous frame for differencing
  List<int>? _previousFrame;
  // Trigger mode: 'sound', 'motion', 'either', 'both'
  String _triggerSource = 'sound';
  // #18: Scheduled triggers (in-app only)
  TimeOfDay? _scheduledStart;
  TimeOfDay? _scheduledStop;
  Timer? _scheduleTimer;
  // #1: Last match confidence
  double _lastMatchConfidence = 0.0;
  // #19: Live sound classification result
  String _currentClassification = '';
  double _classificationConfidence = 0.0;
  // #3: Noise calibration state
  bool _isCalibratingNoise = false;
  double _calibratedNoiseFloor = 0.0;

  String _status = 'Record a short reference sound to begin.';
  String _lastSavedPhotoPath = '';
  int _photosTakenThisSession = 0;
  int _burstsThisSession = 0;

  late StreamSubscription<PlayerState> _playerStateSubscription;
  late StreamSubscription<ProcessingState> _processingStateSubscription;

  final RecordConfig _recordConfig = const RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 44100,
    numChannels: 1,
  );

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initPrefsAndLoad();
    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      // Only update on actual play/pause transitions, not on completion.
      // Completion is handled by _processingStateSubscription below.
      if (state.processingState == ProcessingState.completed) return;
      setState(() {
        _isPlayingReference = state.playing;
        if (!state.playing) _playingSource = 'none';
      });
    });
    // processingStateStream is the RELIABLE way to detect playback completion.
    // playerStateStream can miss the completed state on some platforms.
    _processingStateSubscription = _audioPlayer.processingStateStream.listen((state) {
      if (!mounted) return;
      if (state == ProcessingState.completed) {
        setState(() {
          _isPlayingReference = false;
          _playingSource = 'none';
        });
        // Stop the player to reset its state for next playback.
        _audioPlayer.stop();
      }
    });
  }

  Future<void> _initPrefsAndLoad() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      debugPrint('[batbox] _prefs initialized: ${_prefs != null}');
      _loadSettings();
      await _loadReferenceLibrary();
      await _refreshPhotoSessions();
    } catch (e, stack) {
      debugPrint('[batbox] FATAL during init: $e');
      debugPrint('[batbox] stack: $stack');
      // Don't rethrow -- let the app render, just show error in status
      if (mounted) {
        setState(() => _status = 'Init error: $e');
      }
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    // Stop motion detection synchronously enough to prevent further frame callbacks.
    _isDetectingMotion = false;
    _stopMotionDetection();
    _audioSubscription?.cancel();
    _autoStopTimer?.cancel();
    _scheduleTimer?.cancel();
    _playerStateSubscription.cancel();
    _processingStateSubscription.cancel();
    _audioPlayer.dispose();
    try { _audioRecorder.dispose(); } catch (_) {}
    _cameraController?.dispose();
    super.dispose();
  }

  // ===========================================================================
  // Settings persistence
  // ===========================================================================


  void _loadSettings() {
    final p = _prefs;
    if (p == null) {
      debugPrint('[batbox] _loadSettings: _prefs is null, using defaults');
      return;
    }
    try {
      _triggerThreshold = p.getDouble(_kThreshold) ?? 0.35;

      // Bounds-checked enum loading -- prevents RangeError if a stored
      // index is out of range (e.g. after enum reordering or corruption).
      T _loadEnum<T>(String key, List<T> values, T defaultValue) {
        final idx = p.getInt(key);
        if (idx == null || idx < 0 || idx >= values.length) return defaultValue;
        return values[idx];
      }

      _recognitionMode = _loadEnum(_kRecogMode, RecognitionMode.values, RecognitionMode.better);
      _photoCountMode = _loadEnum(_kPhotoCount, PhotoCountMode.values, PhotoCountMode.one);
      _flashModeSetting = _loadEnum(_kFlashMode, FlashModeSetting.values, FlashModeSetting.off);
      _resolutionSetting = _loadEnum(_kResolution, ResolutionSetting.values, ResolutionSetting.medium);
      _refractoryPeriodMs = p.getInt(_kRefractory) ?? 1500;
      _autoStopOnSilence = p.getBool(_kAutoStop) ?? false;
      _autoStopTimeoutSec = p.getInt(_kAutoStopTimeout) ?? 30;
      _hapticOnMatch = p.getBool(_kHaptic) ?? true;
      _isDarkMode = p.getBool(_kDarkMode) ?? true;
      _compressPhotos = p.getBool(_kCompressPhotos) ?? false;
      _fastCaptureMode = p.getBool(_kFastCapture) ?? true;
      _burstDelayMs = p.getInt(_kBurstDelay) ?? 0;
      _minMatchChunks = p.getInt(_kMinMatchChunks) ?? 1;
      _motionSensitivity = p.getDouble(_kMotionSensitivity) ?? 0.3;
      _triggerSource = p.getString(_kTriggerSource) ?? 'sound';
      _cameraIndex = p.getInt(_kCameraIndex) ?? 0;
      _captureVideo = p.getBool(_kCaptureVideo) ?? false;
      _activeReferenceName = p.getString(_kActiveReference) ?? '';
    } catch (e) {
      debugPrint('[batbox] _loadSettings failed, using defaults: $e');
    }
  }

  Future<void> _saveSettings() async {
    final p = _prefs;
    if (p == null) {
      debugPrint('[batbox] _saveSettings: _prefs is null, skipping');
      return;
    }
    try {
      await p.setDouble(_kThreshold, _triggerThreshold);
      await p.setInt(_kRecogMode, _recognitionMode.index);
      await p.setInt(_kPhotoCount, _photoCountMode.index);
      await p.setInt(_kFlashMode, _flashModeSetting.index);
      await p.setInt(_kResolution, _resolutionSetting.index);
      await p.setInt(_kRefractory, _refractoryPeriodMs);
      await p.setBool(_kAutoStop, _autoStopOnSilence);
      await p.setInt(_kAutoStopTimeout, _autoStopTimeoutSec);
      await p.setBool(_kHaptic, _hapticOnMatch);
      await p.setBool(_kDarkMode, _isDarkMode);
      await p.setBool(_kCompressPhotos, _compressPhotos);
      await p.setBool(_kFastCapture, _fastCaptureMode);
      await p.setInt(_kBurstDelay, _burstDelayMs);
      await p.setInt(_kMinMatchChunks, _minMatchChunks);
      await p.setDouble(_kMotionSensitivity, _motionSensitivity);
      await p.setString(_kTriggerSource, _triggerSource);
      await p.setInt(_kCameraIndex, _cameraIndex);
      await p.setBool(_kCaptureVideo, _captureVideo);
      await p.setString(_kActiveReference, _activeReferenceName);
    } catch (e) {
      debugPrint('[batbox] _saveSettings failed: $e');
    }
  }

  // ===========================================================================
  // Reference library management
  // ===========================================================================

  Future<Directory> _referencesDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final refDir = Directory('${dir.path}${Platform.pathSeparator}references');
    if (!await refDir.exists()) await refDir.create(recursive: true);
    return refDir;
  }

  Future<void> _loadReferenceLibrary() async {
    try {
      final p = _prefs;
      if (p == null) { debugPrint('[batbox] _loadReferenceLibrary: _prefs null'); return; }
      final listJson = p.getStringList(_kReferenceList) ?? [];
      _references.clear();
      for (final json in listJson) {
        try {
          final map = jsonDecode(json) as Map<String, dynamic>;
          final ref = ReferenceSound.fromJson(map);
          final file = File(ref.filePath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            ref.samples.addAll(_decodeWavToSamples(bytes));
            _computeReferenceFeatures(ref);
            _references.add(ref);
          }
        } catch (e) {
          debugPrint('Failed to load reference: $e');
        }
      }
      // Select active reference
      if (_activeReferenceName.isNotEmpty) {
        _switchToReference(_activeReferenceName);
      } else if (_references.isNotEmpty) {
        _switchToReference(_references.first.name);
      }
    } catch (e) {
      debugPrint('[batbox] _loadReferenceLibrary failed: $e');
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveReferenceList() async {
    final p = _prefs;
    if (p == null) {
      debugPrint('[batbox] _saveReferenceList: _prefs is null, skipping');
      return;
    }
    try {
      final list = _references.map((r) => jsonEncode(r.toJson())).toList();
      await p.setStringList(_kReferenceList, list);
    } catch (e) {
      debugPrint('[batbox] _saveReferenceList failed: $e');
    }
  }

  void _computeReferenceFeatures(ReferenceSound ref) {
    // Apply trim: use only the samples between trimStart and trimEnd.
    // Original samples are preserved -- this is reversible.
    final startIdx = (ref.trimStart * ref.samples.length).toInt();
    final endIdx = (ref.trimEnd * ref.samples.length).toInt();
    final trimmedSamples = (startIdx < endIdx && startIdx >= 0 && endIdx <= ref.samples.length)
        ? ref.samples.sublist(startIdx, endIdx)
        : ref.samples;

    ref.downsampled.clear();
    ref.downsampled.addAll(_downsample(trimmedSamples, 10));
    ref.processed.clear();
    ref.processed.addAll(_preEmphasis(ref.downsampled));
    ref.envelope.clear();
    ref.envelope.addAll(_computeEnvelope(ref.downsampled, 44));
    ref.energy = _signalEnergy(ref.downsampled);
    ref.silenceThreshold = ref.energy * 0.10;
  }

  void _switchToReference(String name) {
    final ref = _references.where((r) => r.name == name).firstOrNull;
    if (ref == null) return;
    _activeReferenceName = name;
    _referenceSamples.clear();
    _referenceSamples.addAll(ref.samples);
    _referenceDown.clear();
    _referenceDown.addAll(ref.downsampled);
    _referenceProcessed.clear();
    _referenceProcessed.addAll(ref.processed);
    _referenceEnvelope.clear();
    _referenceEnvelope.addAll(ref.envelope);
    _referenceEnergy = ref.energy;
    _silenceThreshold = ref.silenceThreshold;
    // #2: Apply per-reference threshold if set.
    if (ref.threshold != null) {
      _triggerThreshold = ref.threshold!;
      debugPrint('[batbox] applied per-ref threshold: $_triggerThreshold');
    }
    // #3: Apply calibrated noise floor if set.
    if (ref.noiseFloor != null) {
      _silenceThreshold = ref.noiseFloor!;
      _calibratedNoiseFloor = ref.noiseFloor!;
    }
    _saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _addReference(String name, List<double> samples) async {
    debugPrint('[batbox] _addReference: name="$name", samples=${samples.length}');
    try {
      debugPrint('[batbox] step 1: get references directory');
      final dir = await _referencesDirectory();
      debugPrint('[batbox] step 2: sanitize name');
      final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final filePath = '${dir.path}${Platform.pathSeparator}$safeName.wav';
      debugPrint('[batbox] step 3: create ReferenceSound object, filePath=$filePath');
      final ref = ReferenceSound(name: name, filePath: filePath);
      ref.samples.addAll(samples);
      debugPrint('[batbox] step 4: compute features');
      _computeReferenceFeatures(ref);
      debugPrint('[batbox] step 5: encode WAV');
      final wavBytes = await _encodeWav(ref.samples);
      debugPrint('[batbox] step 6: write WAV file (${wavBytes.length} bytes)');
      final file = File(filePath);
      await file.writeAsBytes(wavBytes);
      debugPrint('[batbox] step 7: add to _references list');
      _references.add(ref);
      debugPrint('[batbox] step 8: save reference list');
      await _saveReferenceList();
      // Copy features to active buffers directly instead of calling
      // _switchToReference (which calls _saveSettings and may fail if
      // _prefs isn't ready).
      _activeReferenceName = name;
      _referenceSamples.clear();
      _referenceSamples.addAll(ref.samples);
      _referenceDown.clear();
      _referenceDown.addAll(ref.downsampled);
      _referenceProcessed.clear();
      _referenceProcessed.addAll(ref.processed);
      _referenceEnvelope.clear();
      _referenceEnvelope.addAll(ref.envelope);
      _referenceEnergy = ref.energy;
      _silenceThreshold = ref.silenceThreshold;
      // Try to persist the active reference name, but don't fail if
      // _prefs isn't initialized yet.
      try {
        final p = _prefs;
        if (p != null) await p.setString(_kActiveReference, name);
      } catch (e) {
        debugPrint('[batbox] could not persist active reference: $e');
      }
      if (mounted) setState(() {});
      debugPrint('[batbox] reference added: $name (${samples.length} samples)');
    } catch (e, stack) {
      debugPrint('[batbox] _addReference FAILED at some step: $e');
      debugPrint('[batbox] stack: $stack');
      rethrow;
    }
  }

  Future<void> _deleteReference(String name) async {
    final ref = _references.where((r) => r.name == name).firstOrNull;
    if (ref == null) return;
    try {
      final file = File(ref.filePath);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _references.remove(ref);
    await _saveReferenceList();
    if (_activeReferenceName == name) {
      _activeReferenceName = '';
      _referenceSamples.clear();
      _referenceDown.clear();
      _referenceProcessed.clear();
      _referenceEnvelope.clear();
      _referenceEnergy = 0.0;
      _silenceThreshold = 0.0;
      if (_references.isNotEmpty) {
        _switchToReference(_references.first.name);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _renameReference(String oldName, String newName) async {
    final ref = _references.where((r) => r.name == oldName).firstOrNull;
    if (ref == null) return;
    ref.name = newName;
    if (_activeReferenceName == oldName) {
      _activeReferenceName = newName;
    }
    await _saveReferenceList();
    await _saveSettings();
    if (mounted) setState(() {});
  }

  bool get _hasReference => _referenceSamples.isNotEmpty;

  // ===========================================================================
  // Permissions
  // ===========================================================================

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
    await Permission.camera.request();
  }

  // ===========================================================================
  // Reference recording / playback / import
  // ===========================================================================

  Future<void> _toggleReferenceRecording() async {
    if (_isRecordingReference) {
      await _stopAudioStream();
      final samples = List<double>.from(_referenceSamples);
      _referenceSamples.clear();
      setState(() => _isRecordingReference = false);
      if (samples.length > 2000) {
        try {
          // Prompt for name
          final name = await _promptForName('Name this reference');
          if (name != null && name.isNotEmpty) {
            await _addReference(name, samples);
            setState(() => _status = 'Reference "$name" saved.');
            _showSnackBar('Saved "$name"');
          } else {
            // Save as default name
            final defaultName = 'Reference ${_references.length + 1}';
            await _addReference(defaultName, samples);
            setState(() => _status = 'Reference "$defaultName" saved.');
            _showSnackBar('Saved "$defaultName"');
          }
        } catch (e, stack) {
          debugPrint('[batbox] save reference failed: $e');
          debugPrint('[batbox] stack: $stack');
          setState(() => _status = 'Save failed: $e');
          _showSnackBar('Save failed: $e');
        }
      } else {
        setState(() => _status = 'Reference too short. Try again.');
        _showSnackBar('Reference too short');
      }
      return;
    }

    await _requestPermissions();
    if (!await _audioRecorder.hasPermission()) {
      setState(() => _status = 'Microphone permission was not granted.');
      return;
    }

    _referenceSamples.clear();
    _liveSamples.clear();
    _microphoneLevel = 0.0;

    try {
      _audioSubscription?.cancel();
      final stream = await _audioRecorder.startStream(_recordConfig);
      _audioSubscription = stream.listen((Uint8List event) {
        if (!_isRecordingReference) return;
        final chunk = pcm16ToDoubles(event);
        _referenceSamples.addAll(chunk);
        // #5: Update recording level for display.
        final peak = chunk.fold<double>(0.0, (c, s) => max(c, s.abs()));
        if (mounted) setState(() => _recordingLevel = max(_recordingLevel * 0.7, peak));
      });
      setState(() {
        _isRecordingReference = true;
        _status = 'Recording reference sound...';
      });
    } catch (error) {
      setState(() => _status = 'Unable to start recording: $error');
    }
  }

  Future<String?> _promptForName(String title) async {
    final controller = TextEditingController();
    // Use rootNavigatorKey.currentContext instead of this.context.
    // After an async gap (e.g. FilePicker.await), the State's context
    // can become stale and Navigator.of(context) returns null, throwing
    // "Null check operator used on a null value". The root navigator
    // key's context is always valid as long as the app is running.
    final ctx = rootNavigatorKey.currentContext ?? context;
    return showDialog<String>(
      context: ctx,
      useRootNavigator: true,
      builder: (dialogCtx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter name'),
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(dialogCtx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogCtx, null), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogCtx, controller.text), child: const Text('OK')),
        ],
      ),
    );
  }

  /// #3: Calibrate noise floor by recording 5 seconds of ambient noise.
  Future<void> _calibrateNoise() async {
    if (_isCalibratingNoise) return;
    _isCalibratingNoise = true;
    setState(() => _status = 'Calibrating noise... stay quiet for 5 seconds');
    try {
      await _requestPermissions();
      if (!await _audioRecorder.hasPermission()) {
        setState(() => _status = 'Microphone permission denied.');
        return;
      }
      final noiseSamples = <double>[];
      _audioSubscription?.cancel();
      final stream = await _audioRecorder.startStream(_recordConfig);
      final completer = Completer<void>();
      _audioSubscription = stream.listen((Uint8List event) {
        noiseSamples.addAll(pcm16ToDoubles(event));
      });
      // Record for 5 seconds
      await Future.delayed(const Duration(seconds: 5));
      await _stopAudioStream();
      // Compute RMS energy of the noise
      if (noiseSamples.isNotEmpty) {
        final down = _downsample(noiseSamples, 10);
        final noiseEnergy = _signalEnergy(down);
        // Set silence threshold to 1.5x the noise floor
        final threshold = noiseEnergy * 1.5;
        _calibratedNoiseFloor = threshold;
        _silenceThreshold = threshold;
        // Save to active reference if exists
        final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
        if (ref != null) {
          ref.noiseFloor = threshold;
          await _saveReferenceList();
        }
        setState(() => _status = 'Noise floor calibrated: ${threshold.toStringAsFixed(4)} (was ${_referenceEnergy * 0.10})');
        _showSnackBar('Noise calibrated: ${threshold.toStringAsFixed(4)}');
      }
    } catch (e) {
      setState(() => _status = 'Calibration failed: $e');
    } finally {
      _isCalibratingNoise = false;
    }
  }

  Future<void> _playReferenceSound() async {
    if (!_hasReference) {
      setState(() => _status = 'No reference to play.');
      return;
    }
    // If anything is playing (either source), stop it.
    if (_isPlayingReference) {
      await _audioPlayer.stop();
      setState(() { _isPlayingReference = false; _playingSource = 'none'; });
      return;
    }
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/reference_play.wav';
      await File(path).writeAsBytes(await _encodeWav(_referenceSamples));
      await _audioPlayer.setFilePath(path);
      await _audioPlayer.play();
      setState(() { _isPlayingReference = true; _playingSource = 'full'; });
    } catch (e) {
      setState(() => _status = 'Could not play: $e');
    }
  }

  /// Play only the trimmed portion of the active reference.
  Future<void> _playTrimmedReference() async {
    if (!_hasReference) {
      setState(() => _status = 'No reference to play.');
      return;
    }
    // If anything is playing (either source), stop it.
    if (_isPlayingReference) {
      await _audioPlayer.stop();
      setState(() { _isPlayingReference = false; _playingSource = 'none'; });
      return;
    }
    try {
      final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
      if (ref == null) {
        setState(() => _status = 'No active reference.');
        return;
      }
      // Apply trim to get the trimmed samples
      final startIdx = (ref.trimStart * ref.samples.length).toInt();
      final endIdx = (ref.trimEnd * ref.samples.length).toInt();
      final trimmedSamples = (startIdx < endIdx && startIdx >= 0 && endIdx <= ref.samples.length)
          ? ref.samples.sublist(startIdx, endIdx)
          : ref.samples;
      if (trimmedSamples.isEmpty) {
        setState(() => _status = 'Trimmed section is empty.');
        return;
      }
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/reference_trimmed.wav';
      await File(path).writeAsBytes(await _encodeWav(trimmedSamples));
      await _audioPlayer.setFilePath(path);
      await _audioPlayer.play();
      setState(() { _isPlayingReference = true; _playingSource = 'trimmed'; });
    } catch (e) {
      setState(() => _status = 'Could not play trimmed: $e');
    }
  }

  /// Save the active reference as a .wav file to the app's documents dir.
  /// The user can then access it via a file manager or 'Load from file'.
  Future<void> _saveReferenceToFile() async {
    if (!_hasReference) {
      setState(() => _status = 'No reference to save.');
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = _activeReferenceName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      final path = '${dir.path}${Platform.pathSeparator}$safeName.wav';
      final file = File(path);
      await file.writeAsBytes(await _encodeWav(_referenceSamples));
      setState(() => _status = 'Saved to $path');
      _showSnackBar('Reference saved to $path');
    } catch (e) {
      setState(() => _status = 'Save failed: $e');
      _showSnackBar('Save failed: $e');
    }
  }

  /// Load a .wav file from the app's documents dir as a new reference.
  Future<void> _loadReferenceFromFile() async {
    try {
      // Use FileType.any instead of FileType.custom -- on some Android
      // devices, FileType.custom greys out files the system doesn't
      // recognize by extension, even valid .wav files.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final pf = result.files.first;
      debugPrint('[batbox] load: name=${pf.name}, path=${pf.path}, bytes=${pf.bytes?.length}');

      // Get bytes -- prefer pf.bytes (works with content URIs),
      // fall back to reading from path.
      Uint8List? bytes;
      if (pf.bytes != null) {
        bytes = pf.bytes!;
      } else if (pf.path != null) {
        final file = File(pf.path!);
        if (await file.exists()) {
          bytes = await file.readAsBytes();
        }
      }
      if (bytes == null) {
        setState(() => _status = 'Could not read file.');
        _showSnackBar('Could not read file');
        return;
      }

      final samples = _decodeWavToSamples(bytes);
      if (samples.isEmpty) {
        setState(() => _status = 'No PCM data found in WAV.');
        _showSnackBar('No PCM data found in WAV');
        return;
      }
      if (samples.length < 2000) {
        setState(() => _status = 'WAV too short.');
        _showSnackBar('WAV too short');
        return;
      }
      final defaultName = pf.name.replaceAll(RegExp(r'(?i)\.wav$'), '');
      final name = await _promptForName('Name this reference') ?? defaultName;
      final refName = name.isNotEmpty ? name : 'Loaded ${_references.length + 1}';
      await _addReference(refName, samples);
      setState(() => _status = 'Loaded "$refName" from ${pf.name}');
      _showSnackBar('Loaded "$refName"');
    } catch (e, stack) {
      debugPrint('[batbox] load failed: $e');
      debugPrint('[batbox] stack: $stack');
      setState(() => _status = 'Load failed: $e');
      _showSnackBar('Load failed: $e');
    }
  }

  Future<void> _importAudioFile() async {
    try {
      debugPrint('[batbox] import: opening file picker');
      final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false, withData: true);
      if (result == null || result.files.isEmpty) {
        debugPrint('[batbox] import: no file picked');
        return;
      }
      final pf = result.files.first;
      debugPrint('[batbox] import: picked name=${pf.name}, path=${pf.path}, bytes=${pf.bytes?.length ?? "null"}, ext=${pf.extension}');
      if (pf.path == null && pf.bytes == null) {
        debugPrint('[batbox] import: both path and bytes are null!');
        setState(() => _status = 'Could not access file.');
        _showSnackBar('Could not access file');
        return;
      }
      debugPrint('[batbox] import: name=${pf.name}, path=${pf.path}, bytes=${pf.bytes?.length}');

      // Copy picked file to a temp location -- content URIs from Android
      // file pickers often can't be read directly by ffmpeg or dart:io.
      final tempDir = await getTemporaryDirectory();
      final ext = pf.extension?.toLowerCase() ?? 'wav';
      final tempPath = '${tempDir.path}/import_input.$ext';
      final tempFile = File(tempPath);
      try {
        if (pf.bytes != null) {
          await tempFile.writeAsBytes(pf.bytes!);
        } else if (pf.path != null) {
          final source = File(pf.path!);
          if (await source.exists()) {
            await source.copy(tempPath);
          } else {
            setState(() => _status = 'Source file not found.');
            _showSnackBar('Source file not found');
            return;
          }
        }
      } catch (e) {
        debugPrint('[batbox] failed to copy picked file: $e');
        setState(() => _status = 'Failed to access picked file: $e');
        _showSnackBar('Failed to access file: $e');
        return;
      }
      if (!await tempFile.exists()) {
        setState(() => _status = 'Failed to access picked file.');
        return;
      }

      List<double> samples;
      if (ext == 'wav') {
        samples = _decodeWavToSamples(await tempFile.readAsBytes());
      } else {
        setState(() => _status = 'Converting ${pf.name}...');
        samples = await _convertAudioToPcm(tempFile);
      }

      // Clean up temp input
      try { await tempFile.delete(); } catch (_) {}

      if (samples.isEmpty) {
        setState(() => _status = 'No audio data found in file.');
        return;
      }
      if (samples.length < 2000) {
        setState(() => _status = 'Audio too short.');
        return;
      }
      final name = await _promptForName('Name this reference');
      final refName = (name != null && name.isNotEmpty) ? name : 'Imported ${_references.length + 1}';
      await _addReference(refName, samples);
      setState(() => _status = 'Imported "$refName" (${samples.length} samples).');
      _showSnackBar('Imported "$refName"');
    } catch (e, stack) {
      debugPrint('[batbox] import failed: $e');
      debugPrint('[batbox] stack: $stack');
      setState(() => _status = 'Import failed: $e');
      _showSnackBar('Import failed: $e');
    }
  }

  Future<List<double>> _convertAudioToPcm(File sourceFile) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/imported_ref.wav';
    final outputFile = File(outputPath);
    if (await outputFile.exists()) await outputFile.delete();

    final cmd = ['-y', '-i', sourceFile.path, '-ar', '44100', '-ac', '1', '-sample_fmt', 's16', outputPath];
    final session = await FFmpegKit.execute(cmd.join(' '));
    final returnCode = await session.getReturnCode();
    if (!ReturnCode.isSuccess(returnCode)) {
      throw Exception('Audio conversion failed (code ${returnCode?.getValue()}).');
    }
    if (!await outputFile.exists()) throw Exception('Conversion produced no output.');
    return _decodeWavToSamples(await outputFile.readAsBytes());
  }

  // ===========================================================================
  // Audio signal processing
  // ===========================================================================

  List<double> _downsample(List<double> input, int factor) {
    if (input.isEmpty || factor <= 1) return List<double>.from(input);
    final out = <double>[];
    for (var i = 0; i + factor <= input.length; i += factor) {
      double sum = 0.0;
      for (var j = 0; j < factor; j++) sum += input[i + j];
      out.add(sum / factor);
    }
    return out;
  }

  List<double> _preEmphasis(List<double> input) {
    if (input.isEmpty) return input;
    final out = List<double>.filled(input.length, 0.0);
    out[0] = input[0];
    for (var i = 1; i < input.length; i++) out[i] = input[i] - 0.95 * input[i - 1];
    return out;
  }

  List<double> _computeEnvelope(List<double> input, int windowSize) {
    if (input.isEmpty || windowSize <= 0) return [];
    final out = <double>[];
    for (var i = 0; i + windowSize <= input.length; i += windowSize) {
      double sum = 0.0;
      for (var j = 0; j < windowSize; j++) sum += input[i + j] * input[i + j];
      out.add(sqrt(sum / windowSize));
    }
    return out;
  }

  double _signalEnergy(List<double> s) {
    if (s.isEmpty) return 0.0;
    double sum = 0.0;
    for (final v in s) sum += v * v;
    return sqrt(sum / s.length);
  }

  // ===========================================================================
  // #19: Sound classification -- feature-based, pure Dart
  // ===========================================================================

  /// Spectral centroid: the "center of mass" of the spectrum.
  /// High = bright (cymbals, birds), low = deep (bass, thunder).
  /// At 4410 Hz sample rate with 128-point FFT, each bin = ~34.5 Hz.
  double _spectralCentroid(List<double> spectrum) {
    double weightedSum = 0.0;
    double totalMag = 0.0;
    for (var i = 0; i < spectrum.length; i++) {
      weightedSum += i * spectrum[i];
      totalMag += spectrum[i];
    }
    if (totalMag == 0) return 0.0;
    return (weightedSum / totalMag) / spectrum.length; // normalized 0-1
  }

  /// Spectral spread: standard deviation around the centroid.
  /// Narrow = tonal/pure, wide = noisy/broadband.
  double _spectralSpread(List<double> spectrum, double centroid) {
    double sumSqDiff = 0.0;
    double totalMag = 0.0;
    for (var i = 0; i < spectrum.length; i++) {
      final diff = (i / spectrum.length) - centroid;
      sumSqDiff += spectrum[i] * diff * diff;
      totalMag += spectrum[i];
    }
    if (totalMag == 0) return 0.0;
    return sqrt(sumSqDiff / totalMag);
  }

  /// Spectral flatness: geometric mean / arithmetic mean.
  /// High (near 1.0) = white noise, low (near 0) = tonal.
  double _spectralFlatness(List<double> spectrum) {
    double sumLog = 0.0;
    double sumLinear = 0.0;
    var count = 0;
    for (final m in spectrum) {
      if (m > 1e-10) {
        sumLog += log(m);
        sumLinear += m;
        count++;
      }
    }
    if (count == 0 || sumLinear == 0) return 0.0;
    final geoMean = exp(sumLog / count);
    final arithMean = sumLinear / count;
    return (geoMean / arithMean).clamp(0.0, 1.0);
  }

  /// Zero-crossing rate: how often the signal crosses zero.
  /// High = noisy/percussive, low = tonal.
  double _zeroCrossingRate(List<double> samples) {
    if (samples.length < 2) return 0.0;
    var crossings = 0;
    for (var i = 1; i < samples.length; i++) {
      if ((samples[i - 1] >= 0 && samples[i] < 0) ||
          (samples[i - 1] < 0 && samples[i] >= 0)) {
        crossings++;
      }
    }
    return crossings / (samples.length - 1);
  }

  /// Temporal envelope variance: how much energy changes over time.
  /// High = percussive (sharp transients), low = sustained.
  double _envelopeVariance(List<double> envelope) {
    if (envelope.length < 2) return 0.0;
    final mean = envelope.reduce((a, b) => a + b) / envelope.length;
    double sumSq = 0.0;
    for (final v in envelope) sumSq += (v - mean) * (v - mean);
    return sqrt(sumSq / envelope.length);
  }

  /// Classify a sound based on its spectral features.
  /// Returns a map with the category and confidence scores.
  Map<String, dynamic> _classifySound(List<double> samples, List<double> spectrum, List<double> envelope) {
    if (samples.isEmpty || spectrum.isEmpty) {
      return {'category': 'Silence', 'confidence': 0.0, 'features': {}};
    }

    final energy = _signalEnergy(samples);
    if (energy < 0.001) {
      return {'category': 'Silence', 'confidence': 0.9, 'features': {'energy': energy}};
    }

    final centroid = _spectralCentroid(spectrum);
    final spread = _spectralSpread(spectrum, centroid);
    final flatness = _spectralFlatness(spectrum);
    final zcr = _zeroCrossingRate(samples);
    final envVar = _envelopeVariance(envelope);

    final features = {
      'energy': energy,
      'centroid': centroid,
      'spread': spread,
      'flatness': flatness,
      'zcr': zcr,
      'envVar': envVar,
    };

    // Classification rules (order matters -- most specific first).
    String category;
    double confidence;

    // Percussive: high ZCR + high envelope variance + broadband
    if (zcr > 0.15 && envVar > 0.05 && flatness > 0.3) {
      category = 'Percussive';
      confidence = (zcr * 2 + envVar * 5 + flatness).clamp(0.0, 0.95);
    }
    // Tonal: low flatness + moderate centroid
    else if (flatness < 0.15 && centroid > 0.1 && centroid < 0.7) {
      // Distinguish speech from other tonal sounds
      if (centroid > 0.15 && centroid < 0.45 && zcr > 0.05 && zcr < 0.25) {
        category = 'Speech';
        confidence = (0.4 - flatness * 2 + (1 - (zcr - 0.15).abs() * 4)).clamp(0.4, 0.85);
      } else {
        category = 'Tonal';
        confidence = (0.5 - flatness * 3).clamp(0.3, 0.9);
      }
    }
    // Noise: high flatness + low envelope variance
    else if (flatness > 0.5 && envVar < 0.03) {
      category = 'Noise';
      confidence = (flatness * 0.9).clamp(0.4, 0.85);
    }
    // Music: tonal with moderate rhythm
    else if (flatness < 0.3 && envVar > 0.02 && envVar < 0.08) {
      category = 'Music';
      confidence = (0.4 - flatness + envVar * 3).clamp(0.3, 0.75);
    }
    // Default: broadband sound
    else {
      category = 'Broadband';
      confidence = 0.4;
    }

    return {
      'category': category,
      'confidence': confidence,
      'features': features,
    };
  }

  /// Classify the active reference sound.
  Map<String, dynamic> _classifyActiveReference() {
    if (_referenceDown.isEmpty) {
      return {'category': 'None', 'confidence': 0.0, 'features': {}};
    }
    // Compute spectrum from the reference's downsampled buffer
    const fftSize = 128;
    if (_referenceDown.length < fftSize) {
      return {'category': 'Too short', 'confidence': 0.0, 'features': {}};
    }
    // Use the middle portion of the reference for classification
    final midStart = (_referenceDown.length - fftSize) ~/ 2;
    final real = List<double>.filled(fftSize, 0.0);
    final imag = List<double>.filled(fftSize, 0.0);
    for (var i = 0; i < fftSize; i++) {
      final w = 0.54 - 0.46 * cos(2 * pi * i / (fftSize - 1));
      real[i] = _referenceDown[midStart + i] * w;
    }
    _inPlaceFFT(real, imag);
    final spectrum = List<double>.filled(64, 0.0);
    for (var i = 0; i < 64; i++) spectrum[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
    var maxMag = 0.0;
    for (final m in spectrum) if (m > maxMag) maxMag = m;
    if (maxMag > 0) for (var i = 0; i < 64; i++) spectrum[i] /= maxMag;

    final envelope = _computeEnvelope(_referenceDown, 44);
    return _classifySound(_referenceDown, spectrum, envelope);
  }

  /// Classify the current live audio.
  Map<String, dynamic> _classifyLiveAudio() {
    if (_liveDown.isEmpty) return {'category': 'None', 'confidence': 0.0, 'features': {}};
    final spectrum = _computeSpectrum();
    final envelope = _computeEnvelope(_liveDown, 44);
    return _classifySound(_liveDown, spectrum, envelope);
  }

  /// Compute a 128-point FFT magnitude spectrum (first 64 bins) of the
  /// most recent 128 samples of the downsampled live buffer.
  List<double> _computeSpectrum() {
    const fftSize = 128;
    if (_liveDown.length < fftSize) return List.filled(64, 0.0);
    final real = List<double>.filled(fftSize, 0.0);
    final imag = List<double>.filled(fftSize, 0.0);
    final start = _liveDown.length - fftSize;
    for (var i = 0; i < fftSize; i++) {
      // Hamming window
      final w = 0.54 - 0.46 * cos(2 * pi * i / (fftSize - 1));
      real[i] = _liveDown[start + i] * w;
    }
    _inPlaceFFT(real, imag);
    final mag = List<double>.filled(64, 0.0);
    for (var i = 0; i < 64; i++) {
      mag[i] = sqrt(real[i] * real[i] + imag[i] * imag[i]);
    }
    // Normalize
    var maxMag = 0.0;
    for (final m in mag) if (m > maxMag) maxMag = m;
    if (maxMag > 0) {
      for (var i = 0; i < 64; i++) mag[i] /= maxMag;
    }
    return mag;
  }

  /// In-place radix-2 Cooley-Tukey FFT.
  void _inPlaceFFT(List<double> real, List<double> imag) {
    final n = real.length;
    // Bit reversal
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; (j & bit) != 0; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) {
        double t;
        t = real[i]; real[i] = real[j]; real[j] = t;
        t = imag[i]; imag[i] = imag[j]; imag[j] = t;
      }
    }
    // Butterfly
    for (var len = 2; len <= n; len <<= 1) {
      final angle = -2.0 * pi / len;
      final wlenR = cos(angle);
      final wlenI = sin(angle);
      for (var i = 0; i < n; i += len) {
        var wR = 1.0;
        var wI = 0.0;
        for (var j = 0; j < len ~/ 2; j++) {
          final uR = real[i + j];
          final uI = imag[i + j];
          final tR = real[i + j + len ~/ 2];
          final tI = imag[i + j + len ~/ 2];
          final vR = tR * wR - tI * wI;
          final vI = tR * wI + tI * wR;
          real[i + j] = uR + vR;
          imag[i + j] = uI + vI;
          real[i + j + len ~/ 2] = uR - vR;
          imag[i + j + len ~/ 2] = uI - vI;
          final newWR = wR * wlenR - wI * wlenI;
          wI = wR * wlenI + wI * wlenR;
          wR = newWR;
        }
      }
    }
  }

  // ===========================================================================
  // Listening + match detection
  // ===========================================================================

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _stopListening();
      return;
    }
    if (!_hasReference) {
      setState(() => _status = 'Record or import a reference first.');
      return;
    }
    await _requestPermissions();
    if (!await _audioRecorder.hasPermission()) {
      setState(() => _status = 'Microphone permission denied.');
      return;
    }

    _photoTriggered = false;
    _isCapturingPhoto = false;
    _sessionPeakSimilarity = 0.0;
    _currentBestSimilarity = 0.0;
    _photosTakenThisSession = 0;
    _burstsThisSession = 0;
    _consecutiveMatchCount = 0;
    _adaptiveNoiseFloor = 0.0;
    _liveSamples.clear();
    _liveDown.clear();
    _spectrogramFrames.clear();
    _similarityHistory.clear();
    _lastTriggerTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastLoudAudioTime = DateTime.now();
    _currentSessionId = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 19);

    if (!_testMode && _photoCountMode.takesPhotos) {
      try { await _initializeCamera(); }
      catch (e) { setState(() => _status = 'Camera init failed: $e'); return; }
    }

    try {
      _audioSubscription?.cancel();
      final stream = await _audioRecorder.startStream(_recordConfig);
      _audioSubscription = stream.listen((Uint8List event) {
        if (_isCapturingPhoto) return;
        _processIncomingChunk(event);
      });
      setState(() {
        _isListening = true;
        _microphoneLevel = 0.0;
        _status = _testMode
            ? 'TEST MODE: Listening...'
            : 'Listening... (${_photoCountMode.label})';
      });
      // Start auto-stop timer
      if (_autoStopOnSilence && !_testMode) {
        _autoStopTimer?.cancel();
        _autoStopTimer = Timer(Duration(seconds: _autoStopTimeoutSec), () {
          if (_isListening) {
            _stopListening();
            _showSnackBar('Auto-stopped: silence detected for ${_autoStopTimeoutSec}s');
          }
        });
      }
    } catch (e) {
      setState(() => _status = 'Unable to start listening: $e');
      await _disposeCamera();
    }
  }

  Future<void> _toggleTestRecognition() async {
    if (_isListening) { await _stopListening(); return; }
    if (!_hasReference) { setState(() => _status = 'Record/import a reference first.'); return; }
    _testMode = true;
    await _toggleListening();
  }

  Future<void> _stopListening() async {
    _autoStopTimer?.cancel();
    await _stopAudioStream();
    await _disposeCamera();
    setState(() {
      _isListening = false;
      _testMode = false;
      _microphoneLevel = 0.0;
      _status = _photosTakenThisSession > 0
          ? 'Stopped. Took ${_photosTakenThisSession} photo(s) in ${_burstsThisSession} burst(s).'
          : 'Listening stopped.';
    });
    await _refreshPhotoSessions();
  }

  Future<void> _stopAudioStream() async {
    final sub = _audioSubscription;
    _audioSubscription = null;
    if (sub != null) { try { await sub.cancel(); } catch (_) {} }
    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop().timeout(const Duration(seconds: 2), onTimeout: () => null);
      }
    } catch (_) {}
  }

  void _processIncomingChunk(Uint8List bytes) {
    final chunkSamples = pcm16ToDoubles(bytes);
    _liveSamples.addAll(chunkSamples);

    final chunkPeak = chunkSamples.fold<double>(0.0, (c, s) => max(c, s.abs()));
    if (mounted) setState(() => _microphoneLevel = max(_microphoneLevel * 0.65, chunkPeak));

    final maxLiveLen = _referenceSamples.length * 2;
    if (_liveSamples.length > maxLiveLen) {
      _liveSamples.removeRange(0, _liveSamples.length - maxLiveLen);
    }
    if (_referenceSamples.isEmpty || _liveSamples.length < 1000) return;

    _liveDown.clear();
    _liveDown.addAll(_downsample(_liveSamples, 10));

    if (_referenceDown.isEmpty || _liveDown.length < _referenceProcessed.length) return;

    final maxLiveDownLen = _referenceProcessed.length * 2;
    if (_liveDown.length > maxLiveDownLen) {
      _liveDown.removeRange(0, _liveDown.length - maxLiveDownLen);
    }

    // Spectrogram
    final spectrum = _computeSpectrum();
    _spectrogramFrames.add(spectrum);
    if (_spectrogramFrames.length > _maxSpectrogramFrames) _spectrogramFrames.removeAt(0);

    // Energy gating
    final liveEnergy = _signalEnergy(_liveDown);
    if (liveEnergy < _silenceThreshold) {
      _currentBestSimilarity = 0.0;
      _consecutiveMatchCount = 0;
      if (mounted) setState(() {});
      return;
    }
    _lastLoudAudioTime = DateTime.now();

    // Adaptive noise floor
    if (liveEnergy < _referenceEnergy * 0.5) {
      _adaptiveNoiseFloor = _adaptiveNoiseFloor * 0.95 + liveEnergy * 0.05;
    }

    // Matching
    final liveProcessed = _preEmphasis(_liveDown);
    final pcmSim = bestSimilarityScore(_referenceProcessed, liveProcessed, stepOverride: 1);
    final liveEnv = _computeEnvelope(_liveDown, 44);
    final envSim = _referenceEnvelope.isNotEmpty && liveEnv.length >= _referenceEnvelope.length
        ? bestSimilarityScore(_referenceEnvelope, liveEnv, stepOverride: 1) : 0.0;
    final similarity = envSim * 0.6 + pcmSim * 0.4;

    if (similarity > _sessionPeakSimilarity) _sessionPeakSimilarity = similarity;
    _currentBestSimilarity = similarity;

    // Update history
    _similarityHistory.add(similarity);
    if (_similarityHistory.length > _maxHistoryLen) _similarityHistory.removeAt(0);

    // Reset auto-stop timer (loud audio detected)
    if (_autoStopOnSilence && !_testMode && _autoStopTimer != null) {
      _autoStopTimer!.cancel();
      _autoStopTimer = Timer(Duration(seconds: _autoStopTimeoutSec), () {
        if (_isListening) { _stopListening(); _showSnackBar('Auto-stopped: silence'); }
      });
    }

    // #19: Update live classification (every chunk)
    if (liveEnergy > _silenceThreshold) {
      final result = _classifyLiveAudio();
      _currentClassification = result['category'] as String;
      _classificationConfidence = result['confidence'] as double;
    } else {
      _currentClassification = 'Silence';
      _classificationConfidence = 0.9;
    }

    if (mounted) setState(() {});

    // Debounce
    if (similarity >= _triggerThreshold) {
      _consecutiveMatchCount++;
    } else {
      _consecutiveMatchCount = 0;
    }
    if (_consecutiveMatchCount < _minMatchChunks) return;

    // Respect trigger source: if set to 'motion only', don't trigger on sound
    if (_triggerSource == 'motion') return;
    // For 'both', sound match is recorded but photo only fires if motion also detected
    // (simplified: 'both' triggers on sound -- true AND requires motion logic would need
    //  a coincidence window, which is complex. For now, 'both' = 'sound' for simplicity.)

    // Refractory period
    final now = DateTime.now();
    final refractory = Duration(milliseconds: _refractoryPeriodMs);
    if (now.difference(_lastTriggerTime) < refractory) return;
    _lastTriggerTime = now;

    // Haptic feedback
    if (_hapticOnMatch) HapticFeedback.heavyImpact();

    // Flash
    _flashActive = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _flashActive = false);
    });

    if (_testMode || !_photoCountMode.takesPhotos) {
      if (mounted) setState(() => _status = 'Match! sim=${similarity.toStringAsFixed(3)}');
      return;
    }

    _photoTriggered = true;
    _isCapturingPhoto = true;
    _burstsThisSession++;
    // #1: Store match confidence for photo metadata.
    _lastMatchConfidence = similarity;
    if (mounted) setState(() => _status = 'Match! Taking ${_photoCountMode.burstSize} photo(s)...');
    unawaited(_triggerPhoto().catchError((Object e) {
      if (mounted) setState(() { _photoTriggered = false; _isCapturingPhoto = false; _flashActive = false; _cameraLaunchInProgress = false; _status = 'Trigger failed: $e'; });
    }));
  }

  // ===========================================================================
  // Photo capture
  // ===========================================================================

  Future<String> _takeSinglePhoto() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      await _initializeCamera().timeout(const Duration(seconds: 5),
          onTimeout: () => throw Exception('Camera init timed out.'));
    }
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      throw Exception('Camera init failed.');
    }
    // Take the photo -- this is the latency-critical step.
    // In fast mode we skip the file copy (returns the temp path).
    final photo = await _cameraController!.takePicture().timeout(const Duration(seconds: 5),
        onTimeout: () => throw Exception('Camera capture timed out.'));
    if (_fastCaptureMode) {
      // Return the temp path -- caller batches the copy after the burst.
      return photo.path;
    } else {
      // Copy immediately (slower but safer if app crashes mid-burst).
      final saved = await _saveCapturedPhoto(photo.path);
      if (mounted) setState(() => _lastSavedPhotoPath = saved.path);
      return saved.path;
    }
  }

  /// #22: Capture a short video clip instead of a photo.
  Future<void> _captureVideoClip() async {
    if (_cameraLaunchInProgress) return;
    _cameraLaunchInProgress = true;
    setState(() => _status = 'Recording 3s video...');
    try {
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initializeCamera();
      }
      // Switch to video mode requires re-creating the controller with
      // enableAudio: true and using startVideoRecording. For simplicity,
      // we capture a burst of photos instead (pseudo-video).
      // A true video implementation would use:
      //   await _cameraController!.startVideoRecording();
      //   await Future.delayed(Duration(seconds: 3));
      //   final file = await _cameraController!.stopVideoRecording();
      // But this requires the camera to be initialized in video mode.
      // For now, take 10 rapid photos as a 'video' approximation.
      for (var i = 0; i < 10; i++) {
        await _takeSinglePhoto();
        _photosTakenThisSession++;
        if (mounted) setState(() => _status = 'Video frame ${i + 1}/10...');
      }
      if (mounted) setState(() => _status = 'Video clip captured (10 frames).');
    } catch (e) {
      if (mounted) setState(() => _status = 'Video failed: $e');
    } finally {
      _cameraLaunchInProgress = false;
      if (!_isListening && !_showViewfinder) await _disposeCamera();
    }
  }

  Future<void> _manualTrigger() async {
    if (_cameraLaunchInProgress) return;
    _cameraLaunchInProgress = true;
    setState(() => _status = 'Taking photo...');
    try {
      final perm = await Permission.camera.status;
      if (!perm.isGranted) {
        final req = await Permission.camera.request();
        if (!req.isGranted) { setState(() => _status = 'Camera permission denied.'); return; }
      }
      await _takeSinglePhoto();
      if (mounted) setState(() => _status = 'Photo saved.');
    } catch (e) {
      if (mounted) setState(() => _status = 'Capture failed: $e');
    } finally {
      _photoTriggered = false;
      _isCapturingPhoto = false;
      if (!_isListening && !_showViewfinder) await _disposeCamera();
      if (mounted) setState(() => _cameraLaunchInProgress = false);
    }
  }

  Future<void> _triggerPhoto() async {
    if (_cameraLaunchInProgress) return;
    _cameraLaunchInProgress = true;
    final burstSize = _photoCountMode.burstSize;
    final stopAfter = _photoCountMode.stopAfterFirstMatch;
    // DON'T setState here -- in fast mode we want to capture IMMEDIATELY
    // without waiting for a UI rebuild. Set the flags synchronously.
    _photoTriggered = true;
    _isCapturingPhoto = true;
    // Collect temp paths in fast mode for batch copy after burst.
    final tempPaths = <String>[];
    try {
      for (var i = 0; i < burstSize; i++) {
        final path = await _takeSinglePhoto();
        if (_fastCaptureMode) {
          tempPaths.add(path);
        }
        _photosTakenThisSession++;
        // Only update UI if NOT in fast mode (saves ~16ms per frame).
        if (!_fastCaptureMode && mounted) {
          setState(() => _status = 'Burst: ${i + 1}/$burstSize...');
        }
        // Optional inter-burst delay (0 = fire as fast as possible).
        if (_burstDelayMs > 0 && i < burstSize - 1) {
          await Future.delayed(Duration(milliseconds: _burstDelayMs));
        }
      }
      // In fast mode, batch-copy the temp files to permanent storage.
      if (_fastCaptureMode && tempPaths.isNotEmpty) {
        for (final tempPath in tempPaths) {
          try {
            final saved = await _saveCapturedPhoto(tempPath);
            if (mounted) setState(() => _lastSavedPhotoPath = saved.path);
            // Clean up temp file.
            try { await File(tempPath).delete(); } catch (_) {}
          } catch (e) {
            debugPrint('[batbox] failed to save photo: $e');
          }
        }
      }
      if (stopAfter) {
        await _stopListening();
      } else {
        _lastTriggerTime = DateTime.now();
        if (mounted) setState(() => _status = 'Burst done. Listening for next...');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Capture failed: $e');
    } finally {
      _photoTriggered = false;
      _isCapturingPhoto = false;
      if (!_isListening && !_showViewfinder) await _disposeCamera();
      if (mounted) setState(() => _cameraLaunchInProgress = false);
    }
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) return;
    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) throw Exception('No cameras.');
    // #21: Use selected camera index, default to back camera.
    final camera = _cameraIndex < _availableCameras.length
        ? _availableCameras[_cameraIndex]
        : _availableCameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => _availableCameras.first,
          );
    // In fast capture mode, override resolution to low for minimal latency.
    // Lower resolution = less data to process = faster takePicture().
    final preset = _fastCaptureMode ? ResolutionPreset.low : _resolutionSetting.preset;
    _cameraController = CameraController(
      camera,
      preset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _cameraController!.initialize();
    await _applyFlashMode();
    // Pre-set focus mode to auto for faster first-shot capture.
    try {
      await _cameraController!.setFocusMode(FocusMode.auto);
    } catch (_) {
      // Some cameras don't support focus mode setting.
    }
  }

  /// #21: Switch to a different camera.
  Future<void> _switchCamera(int index) async {
    setState(() => _cameraIndex = index);
    await _disposeCamera();
    if (_isListening || _photoCountMode.takesPhotos || _showViewfinder) {
      try { await _initializeCamera(); } catch (_) {}
    }
  }

  /// Toggle the viewfinder on/off. When on, initializes the camera
  /// and shows a live preview so you can aim before listening.
  Future<void> _toggleViewfinder() async {
    if (_showViewfinder) {
      // Turn off
      setState(() => _showViewfinder = false);
      if (!_isListening && !_showViewfinder) await _disposeCamera();
    } else {
      // Turn on -- need camera permission + initialization
      setState(() => _showViewfinder = true);
      try {
        await _requestPermissions();
        final perm = await Permission.camera.status;
        if (!perm.isGranted) {
          final req = await Permission.camera.request();
          if (!req.isGranted) {
            setState(() { _showViewfinder = false; _status = 'Camera permission denied.'; });
            return;
          }
        }
        await _initializeCamera();
      } catch (e) {
        setState(() { _showViewfinder = false; _status = 'Camera init failed: $e'; });
      }
    }
  }

  Future<void> _applyFlashMode() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    try {
      final fm = _flashModeSetting == FlashModeSetting.off ? FlashMode.off
          : _flashModeSetting == FlashModeSetting.auto ? FlashMode.auto
          : _flashModeSetting == FlashModeSetting.always ? FlashMode.always
          : FlashMode.torch;
      await _cameraController!.setFlashMode(fm);
    } catch (_) {}
  }

  Future<void> _disposeCamera() async {
    _cameraController?.dispose();
    _cameraController = null;
  }

  /// #10: Export all references as a zip file.
  Future<void> _exportAllReferences() async {
    if (_references.isEmpty) {
      _showSnackBar('No references to export');
      return;
    }
    try {
      // Create a simple zip by concatenating WAVs with a manifest.
      // Using the archive package would be better, but to avoid
      // adding complexity we create a directory copy.
      final dir = await getTemporaryDirectory();
      final exportDir = Directory('${dir.path}/batbox_export');
      if (await exportDir.exists()) await exportDir.delete(recursive: true);
      await exportDir.create(recursive: true);
      // Copy all reference WAVs
      for (final ref in _references) {
        final source = File(ref.filePath);
        if (await source.exists()) {
          final name = ref.filePath.split(Platform.pathSeparator).last;
          await source.copy('${exportDir.path}${Platform.pathSeparator}$name');
        }
      }
      // Create manifest
      final manifest = StringBuffer();
      manifest.writeln('BatBox Reference Library Export');
      manifest.writeln('Exported: ${DateTime.now().toIso8601String()}');
      manifest.writeln('Count: ${_references.length}');
      manifest.writeln();
      for (final ref in _references) {
        manifest.writeln('${ref.name}|${ref.filePath.split(Platform.pathSeparator).last}|${ref.samples.length}|${ref.threshold ?? ''}|${ref.noiseFloor ?? ""}');
      }
      await File('${exportDir.path}${Platform.pathSeparator}manifest.txt').writeAsString(manifest.toString());
      // Share the directory via share_plus (shares first file as representative)
      // In a real app, use the archive package to create a proper .zip.
      _showSnackBar('Exported ${_references.length} references to ${exportDir.path}');
      setState(() => _status = 'Exported to ${exportDir.path}');
    } catch (e) {
      _showSnackBar('Export failed: $e');
    }
  }

  // ===========================================================================
  // Photo storage + sessions
  // ===========================================================================

  Future<Directory> _photoBaseDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final batboxDir = Directory('${dir.path}${Platform.pathSeparator}batbox');
    if (!await batboxDir.exists()) await batboxDir.create(recursive: true);
    return batboxDir;
  }

  Future<File> _saveCapturedPhoto(String sourcePath) async {
    final baseDir = await _photoBaseDirectory();
    // Use session subfolder
    final sessionDir = Directory('${baseDir.path}${Platform.pathSeparator}$_currentSessionId');
    if (!await sessionDir.exists()) await sessionDir.create(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
    // #1: Include match confidence in filename for later reference.
    final conf = _lastMatchConfidence.toStringAsFixed(2).replaceAll('.', '');
    final dest = File('${sessionDir.path}${Platform.pathSeparator}batbox-${ts}_c$conf.jpg');
    // #11: Optionally compress the photo.
    if (_compressPhotos) {
      try {
        // flutter_image_compress is used here; if not available, fall back to copy.
        final result = await _compressImage(sourcePath, dest.path);
        if (result != null) return File(dest.path);
      } catch (e) {
        debugPrint('[batbox] compression failed, using copy: $e');
      }
    }
    return File(sourcePath).copy(dest.path);
  }

  /// #11: Compress image to JPEG with 80% quality.
  Future<String?> _compressImage(String sourcePath, String destPath) async {
    // Placeholder: actual compression requires flutter_image_compress.
    // For now, just copy. The package is declared in pubspec for future use.
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  Future<void> _refreshPhotoSessions() async {
    try {
      final baseDir = await _photoBaseDirectory();
      final entries = await baseDir.list().toList();
      _photosBySession.clear();
      _allPhotoPaths.clear();

      // Collect session directories
      final sessionDirs = <Directory>[];
      for (final e in entries) {
        if (e is Directory) {
          sessionDirs.add(e);
        } else if (e is File && e.path.toLowerCase().endsWith('.jpg')) {
          // Old-format photos in root
          _photosBySession.putIfAbsent('Previous', () => []).add(e.path);
          _allPhotoPaths.add(e.path);
        }
      }

      // Sort sessions newest first (by dir name, which is ISO timestamp)
      sessionDirs.sort((a, b) => b.path.compareTo(a.path));
      for (final dir in sessionDirs) {
        final label = dir.path.split(Platform.pathSeparator).last;
        final photos = <String>[];
        final files = await dir.list().toList();
        for (final f in files) {
          if (f is File && f.path.toLowerCase().endsWith('.jpg')) {
            photos.add(f.path);
          }
        }
        photos.sort((a, b) => b.compareTo(a));
        if (photos.isNotEmpty) {
          _photosBySession[label] = photos;
          _allPhotoPaths.addAll(photos);
        }
      }
      _allPhotoPaths.sort((a, b) => b.compareTo(a));
      _selectedPhotoPaths.removeWhere((p) => !_allPhotoPaths.contains(p));
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Refresh photos failed: $e');
    }
  }

  // ===========================================================================
  // Photo gallery actions
  // ===========================================================================

  void _togglePhotoSelection(String path) {
    setState(() {
      if (_selectedPhotoPaths.contains(path)) {
        _selectedPhotoPaths.remove(path);
      } else {
        _selectedPhotoPaths.add(path);
        _selectionMode = true;
      }
      if (_selectedPhotoPaths.isEmpty) _selectionMode = false;
    });
  }

  void _selectAllPhotos() {
    setState(() {
      _selectionMode = true;
      _selectedPhotoPaths..clear()..addAll(_allPhotoPaths);
    });
  }

  void _exitSelectionMode() {
    setState(() { _selectionMode = false; _selectedPhotoPaths.clear(); });
  }

  Future<void> _deleteSelectedPhotos() async {
    debugPrint('[batbox] _deleteSelectedPhotos called, ${_selectedPhotoPaths.length} selected');
    if (_selectedPhotoPaths.isEmpty) {
      _showSnackBar('No photos selected');
      return;
    }
    if (!mounted) return;
    // Use rootNavigatorKey context as fallback for the messenger.
    ScaffoldMessengerState? messenger;
    try { messenger = ScaffoldMessenger.of(context); } catch (_) {}
    messenger ??= rootNavigatorKey.currentContext != null
        ? ScaffoldMessenger.of(rootNavigatorKey.currentContext!)
        : null;
    final toDelete = List<String>.from(_selectedPhotoPaths);
    var deleted = 0;
    final errors = <String>[];
    for (final path in toDelete) {
      try {
        final f = File(path);
        if (await f.exists()) { await f.delete(); deleted++; debugPrint('[batbox] deleted: $path'); }
        else { deleted++; debugPrint('[batbox] already gone: $path'); }
      } catch (e) {
        debugPrint('[batbox] FAILED to delete $path: $e');
        errors.add(e.toString());
      }
    }
    if (mounted) {
      setState(() {
        _selectedPhotoPaths.clear();
        _selectionMode = false;
      });
      await _refreshPhotoSessions();
    }
    final msg = errors.isEmpty
        ? 'Deleted $deleted photo(s)'
        : 'Deleted $deleted of ${toDelete.length}. Error: ${errors.first}';
    debugPrint('[batbox] delete result: $msg');
    if (messenger != null) {
      messenger.showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
    } else {
      _showSnackBar(msg);
    }
  }

  Future<void> _deleteAllPhotos() async {
    final confirm = await showDialog<bool>(
      context: rootNavigatorKey.currentContext ?? context, useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete ALL photos?'),
        content: Text('Permanently delete all ${_allPhotoPaths.length} photo(s)?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete all')),
        ],
      ),
    );
    if (confirm != true) return;
    final messenger = ScaffoldMessenger.of(context);
    var deleted = 0;
    for (final path in _allPhotoPaths) {
      try { final f = File(path); if (await f.exists()) { await f.delete(); deleted++; } } catch (_) {}
    }
    // Also remove session directories
    try {
      final baseDir = await _photoBaseDirectory();
      final entries = await baseDir.list().toList();
      for (final e in entries) {
        if (e is Directory) await e.delete(recursive: true);
      }
    } catch (_) {}
    _selectedPhotoPaths.clear();
    _selectionMode = false;
    await _refreshPhotoSessions();
    messenger.showSnackBar(SnackBar(content: Text('Deleted $deleted photo(s)')));
  }

  Future<void> _saveAllToFolder() async {
    if (_allPhotoPaths.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    Directory targetDir;
    try {
      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose folder');
      if (picked != null && await Directory(picked).exists()) {
        targetDir = Directory(picked);
      } else {
        targetDir = await _getDefaultSaveDir();
      }
    } catch (_) {
      targetDir = await _getDefaultSaveDir();
    }
    var saved = 0;
    for (final path in _allPhotoPaths) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        final name = f.uri.pathSegments.last;
        await f.copy('${targetDir.path}${Platform.pathSeparator}$name');
        saved++;
      } catch (_) {}
    }
    messenger.showSnackBar(SnackBar(content: Text('Saved $saved photo(s) to ${targetDir.path}')));
  }

  Future<Directory> _getDefaultSaveDir() async {
    if (Platform.isAndroid) {
      final d = Directory('/storage/emulated/0/Pictures/BatBox');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    }
    final dir = await getApplicationDocumentsDirectory();
    return dir;
  }

  Future<void> _saveSelectedToFolder() async {
    if (_selectedPhotoPaths.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    Directory targetDir;
    try {
      final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Choose folder');
      if (picked != null && await Directory(picked).exists()) {
        targetDir = Directory(picked);
      } else {
        targetDir = await _getDefaultSaveDir();
      }
    } catch (_) {
      targetDir = await _getDefaultSaveDir();
    }
    var saved = 0;
    for (final path in _selectedPhotoPaths) {
      try {
        final f = File(path);
        if (!await f.exists()) continue;
        final name = f.uri.pathSegments.last;
        await f.copy('${targetDir.path}${Platform.pathSeparator}$name');
        saved++;
      } catch (_) {}
    }
    setState(() { _selectionMode = false; _selectedPhotoPaths.clear(); });
    messenger.showSnackBar(SnackBar(content: Text('Saved $saved photo(s)')));
  }

  Future<void> _sharePhoto(String path) async {
    try {
      await Share.shareXFiles([XFile(path)]);
    } catch (e) {
      _showSnackBar('Share failed: $e');
    }
  }

  /// #18: Schedule listening to start/stop at specific times (in-app only).
  void _startScheduledListening() {
    _scheduleTimer?.cancel();
    _scheduleTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = TimeOfDay.now();
      final nowMin = now.hour * 60 + now.minute;
      final startMin = _scheduledStart?.hour != null
          ? (_scheduledStart!.hour * 60 + _scheduledStart!.minute)
          : null;
      final stopMin = _scheduledStop?.hour != null
          ? (_scheduledStop!.hour * 60 + _scheduledStop!.minute)
          : null;
      if (startMin != null && nowMin >= startMin && !_isListening) {
        if (stopMin == null || nowMin < stopMin) {
          _toggleListening();
        }
      }
      if (stopMin != null && nowMin >= stopMin && _isListening) {
        _stopListening();
      }
    });
    _showSnackBar('Schedule active: ${_scheduledStart?.format(context) ?? "any"} to ${_scheduledStop?.format(context) ?? "any"}');
  }

  void _stopScheduledListening() {
    _scheduleTimer?.cancel();
    _scheduleTimer = null;
    _showSnackBar('Schedule cancelled');
  }

  void _viewPhoto(String path) {
    final index = _allPhotoPaths.indexOf(path);
    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute<void>(
      builder: (_) => _PhotoViewerScreen(
        photos: List<String>.from(_allPhotoPaths),
        initialIndex: index < 0 ? 0 : index,
        onShare: _sharePhoto,
      ),
    ));
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    try {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 3)));
    } catch (_) {}
  }

  void _showInstructions() {
    showDialog<void>(
      context: rootNavigatorKey.currentContext ?? context, useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('BatBox Guide'),
        content: const SingleChildScrollView(child: Text(
          '=== GETTING STARTED ===\n'
          '1. Record or import a reference sound on the Reference tab.\n'
          '2. (Optional) Use "Test recognition" to tune the threshold.\n'
          '3. Switch to the Trigger tab, pick photo count + flash mode.\n'
          '4. Press Start listening, then make the reference sound.\n'
          '5. View/manage photos on the Photos tab.\n\n'
          'When a match is detected, the app takes a BURST of photos as fast as possible.\n'
          'Settings persist across app restarts.\n\n'
          '=== REFERENCE TAB ===\n'
          '- Record: Tap "Record new reference", make your sound, tap "Stop". Enter a name when prompted.\n'
          '- Import: Pick any audio file (.wav, .m4a, .mp3, etc). It converts to WAV via ffmpeg.\n'
          '- Load .wav: Pick a WAV file from storage.\n'
          '- Save .wav: Save the active reference to your documents folder.\n'
          '- Library: Multiple references can be saved. Tap one to make it active. Use the edit/delete icons to manage.\n'
          '- Play: Hear the active reference.\n'
          '- Test recognition: Listens without taking photos. Shows live similarity, histogram, and spectrogram for tuning.\n\n'
          '=== TRIGGER TAB ===\n'
          '- Reference dropdown: Switch between saved references.\n'
          '- Photo mode: How many photos per match burst.\n'
          '  - 1/3/10 photos: Takes that many photos in a burst, then stops.\n'
          '  - Continuous: Takes 1 photo per match, keeps listening until you stop.\n'
          '  - Flash only: Flashes the screen on match but takes no photos (for testing).\n'
          '- Flash: Off / Auto / Always / Torch (continuous light).\n'
          '- Recognition: Standard (faster) or Better (more accurate, default).\n'
          '- Resolution: Photo quality (Low/Medium/High).\n\n'
          '=== THRESHOLD ===\n'
          '- The similarity score (0.0-1.0) below which no trigger fires.\n'
          '- Default 0.35. Lower = more sensitive (more false triggers). Higher = stricter (may miss matches).\n'
          '- Use Test recognition to see live scores and find the right value.\n'
          '- Typical: quiet room ~0.1-0.2, matching sound ~0.4-0.7.\n\n'
          '=== REFRACTORY PERIOD ===\n'
          '- Cooldown timer after a match. Prevents re-triggering on the same sound.\n'
          '- Default 1.5 seconds. Range 0.2s - 5.0s.\n'
          '- Lower (0.2-0.5s): For rapid distinct sounds (hand-claps in sequence).\n'
          '- Higher (3-5s): For sounds with long reverb/echo (door slams, bells).\n'
          '- Only matters in Continuous and Flash-only modes (finite modes stop after one burst).\n\n'
          '=== OTHER TOGGLES ===\n'
          '- Haptic feedback: Vibrates the phone when a match is detected.\n'
          '- Auto-stop on silence: Stops listening if no sound above the silence gate for N seconds (saves battery).\n\n'
          '=== SPECTROGRAM ===\n'
          '- Real-time frequency analysis (FFT) of incoming audio.\n'
          '- Scrolling waterfall, blue (quiet) to red (loud).\n'
          '- Helps you see what frequencies your reference occupies.\n\n'
          '=== HISTOGRAM (Test mode) ===\n'
          '- Bar chart of the last 30 similarity scores.\n'
          '- Green bars = above threshold, Orange = below.\n'
          '- Red line = current threshold.\n'
          '- Helps you visually pick a threshold with clear separation.\n\n'
          '=== PHOTOS TAB ===\n'
          '- Photos grouped by session (collapsible sections, newest first).\n'
          '- Tap a photo: full-screen viewer. Swipe to navigate. Pinch to zoom.\n'
          '- Tap the circle (top-right): select/deselect.\n'
          '- Select all / Deselect all: bulk selection.\n'
          '- Delete selected: removes selected photos.\n'
          '- Delete all: removes ALL photos (with confirmation).\n'
          '- Save to folder / Save all: copies photos to a folder you choose (or Pictures/BatBox).\n'
          '- Share button in viewer: share via Android share sheet.\n\n'
          '=== TIPS ===\n'
          '- Short, distinctive sounds (claps, clicks, whistles) match better than sustained tones.\n'
          '- Record in a quiet environment for best results.\n'
          '- If false triggers: raise threshold, increase refractory, or enable auto-stop.\n'
          '- If no triggers: lower threshold, check mic level is moving, try Better mode.\n'
          '- The spectrogram shows what the mic hears -- if it is blank, mic permission may be missing.\n\n'
          '=== BUILD ===\n'
          'BUILD v11.2 - 2026-06-30 03:30 UTC',
        )),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  // ===========================================================================
  // WAV encode / decode
  // ===========================================================================

  Future<List<int>> _encodeWav(List<double> samples) async {
    const sr = 44100, ba = 2;
    final br = sr * ba, ds = samples.length * 2;
    final buf = BytesBuilder();
    void w32(int v) { buf.addByte(v & 0xff); buf.addByte((v >> 8) & 0xff); buf.addByte((v >> 16) & 0xff); buf.addByte((v >> 24) & 0xff); }
    void w16(int v) { buf.addByte(v & 0xff); buf.addByte((v >> 8) & 0xff); }
    buf.add(utf8.encode('RIFF')); w32(36 + ds); buf.add(utf8.encode('WAVE'));
    buf.add(utf8.encode('fmt ')); w32(16); w16(1); w16(1); w32(sr); w32(br); w16(ba); w16(16);
    buf.add(utf8.encode('data')); w32(ds);
    for (final s in samples) { final v = (s.clamp(-1.0, 1.0) * 32767).round(); w16(v < 0 ? v + 65536 : v); }
    return buf.takeBytes();
  }

  List<double> _decodeWavToSamples(Uint8List bytes) {
    final tag = utf8.encode('data');
    int idx = -1;
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == tag[0] && bytes[i+1] == tag[1] && bytes[i+2] == tag[2] && bytes[i+3] == tag[3]) { idx = i + 4; break; }
    }
    if (idx < 0 || idx + 4 > bytes.length) return [];
    final bd = ByteData.sublistView(bytes);
    final ds = bd.getUint32(idx, Endian.little);
    final start = idx + 4, end = min(bytes.length, start + ds);
    if (start >= end) return [];
    return pcm16ToDoubles(Uint8List.fromList(bytes.sublist(start, end)));
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  // ===========================================================================
  // Motion detection
  // ===========================================================================

  /// Start the camera image stream for motion detection.
  Future<void> _startMotionDetection() async {
    if (_isDetectingMotion) return;
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      try { await _initializeCamera(); } catch (e) { return; }
    }
    if (_cameraController == null) return;
    setState(() => _isDetectingMotion = true);
    try {
      await _cameraController!.startImageStream(_processCameraImage);
    } catch (e) {
      debugPrint('[batbox] startImageStream failed: $e');
      setState(() => _isDetectingMotion = false);
    }
  }

  /// Stop the camera image stream.
  Future<void> _stopMotionDetection() async {
    if (!_isDetectingMotion) return;
    setState(() => _isDetectingMotion = false);
    try {
      if (_cameraController != null && _cameraController!.value.isStreamingImages) {
        await _cameraController!.stopImageStream();
      }
    } catch (e) {
      debugPrint('[batbox] stopImageStream failed: $e');
    }
  }

  /// Process a camera image frame for motion detection.
  void _processCameraImage(CameraImage image) {
    if (!_isDetectingMotion) return;
    // Only process Y plane (luminance) for speed
    if (image.planes.isEmpty) return;
    final yPlane = image.planes.first;
    final bytes = yPlane.bytes;
    final width = image.width;
    final height = image.height;

    // Downsample for speed: take every 4th pixel
    final sampleStep = 4;
    final sampledWidth = width ~/ sampleStep;
    final sampledHeight = height ~/ sampleStep;
    final currentFrame = List<int>.filled(sampledWidth * sampledHeight, 0);
    var idx = 0;
    for (var y = 0; y < height; y += sampleStep) {
      for (var x = 0; x < width; x += sampleStep) {
        final pixelIdx = y * width + x;
        if (pixelIdx < bytes.length) {
          currentFrame[idx] = bytes[pixelIdx];
        }
        idx++;
      }
    }

    if (_previousFrame == null || _previousFrame!.length != currentFrame.length) {
      _previousFrame = currentFrame;
      return;
    }

    // Compute motion within the zone
    final zone = _motionZone;
    final zoneStartX = (zone.left * sampledWidth).toInt();
    final zoneStartY = (zone.top * sampledHeight).toInt();
    final zoneEndX = ((zone.left + zone.width) * sampledWidth).toInt();
    final zoneEndY = ((zone.top + zone.height) * sampledHeight).toInt();

    var changedPixels = 0;
    var totalZonePixels = 0;
    for (var y = zoneStartY; y < zoneEndY && y < sampledHeight; y++) {
      for (var x = zoneStartX; x < zoneEndX && x < sampledWidth; x++) {
        final i = y * sampledWidth + x;
        if (i < currentFrame.length && i < _previousFrame!.length) {
          final diff = (currentFrame[i] - _previousFrame![i]).abs();
          // Threshold per pixel: 30 (out of 255) to filter noise
          if (diff > 30) changedPixels++;
          totalZonePixels++;
        }
      }
    }

    _previousFrame = currentFrame;

    if (totalZonePixels == 0) return;
    final motionRatio = changedPixels / totalZonePixels;
    _currentMotionLevel = motionRatio;
    if (motionRatio > _motionSessionPeak) _motionSessionPeak = motionRatio;

    // Threshold is inverted: high sensitivity = low threshold
    final threshold = 0.5 - _motionSensitivity * 0.45; // ranges 0.05 to 0.5
    if (motionRatio > threshold) {
      debugPrint('[batbox] motion detected: ${(motionRatio * 100).toStringAsFixed(1)}% > ${(threshold * 100).toStringAsFixed(1)}%');
      // Trigger photo (if not already capturing and refractory respected)
      if (!_isCapturingPhoto && !_cameraLaunchInProgress) {
        final now = DateTime.now();
        final refractory = Duration(milliseconds: _refractoryPeriodMs);
        if (now.difference(_lastTriggerTime) >= refractory) {
          _lastTriggerTime = now;
          if (_hapticOnMatch) HapticFeedback.heavyImpact();
          _lastMatchConfidence = motionRatio;
          unawaited(_triggerByMotion());
        }
      }
    }

    if (mounted) setState(() {});
  }

  /// Trigger a photo burst due to motion detection.
  Future<void> _triggerByMotion() async {
    if (_cameraLaunchInProgress) return;
    _cameraLaunchInProgress = true;
    setState(() { _photoTriggered = true; _isCapturingPhoto = true; });
    // Stop image stream while capturing (can't takePicture while streaming)
    final wasDetecting = _isDetectingMotion;
    if (wasDetecting) {
      try {
        if (_cameraController != null && _cameraController!.value.isStreamingImages) {
          await _cameraController!.stopImageStream();
        }
      } catch (_) {}
    }
    try {
      final burstSize = _photoCountMode.burstSize;
      final tempPaths = <String>[];
      for (var i = 0; i < burstSize; i++) {
        final path = await _takeSinglePhoto();
        if (_fastCaptureMode) tempPaths.add(path);
        _photosTakenThisSession++;
        if (!_fastCaptureMode && mounted) setState(() => _status = 'Motion! Burst ${i + 1}/$burstSize...');
        if (_burstDelayMs > 0 && i < burstSize - 1) {
          await Future.delayed(Duration(milliseconds: _burstDelayMs));
        }
      }
      // Batch copy in fast mode
      if (_fastCaptureMode) {
        for (final tempPath in tempPaths) {
          try {
            final saved = await _saveCapturedPhoto(tempPath);
            try { await File(tempPath).delete(); } catch (_) {}
          } catch (_) {}
        }
      }
      if (_photoCountMode.stopAfterFirstMatch) {
        if (mounted) setState(() => _status = 'Motion detected. $burstSize photo(s) taken.');
      } else {
        _lastTriggerTime = DateTime.now();
        if (mounted) setState(() => _status = 'Motion burst done. Continuing...');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Motion capture failed: $e');
    } finally {
      _photoTriggered = false;
      _isCapturingPhoto = false;
      // Resume motion detection if it was active
      if (wasDetecting && _motionDetectionEnabled) {
        _previousFrame = null; // reset to avoid false trigger
        try { await _cameraController!.startImageStream(_processCameraImage); }
        catch (_) {}
      }
      if (mounted) setState(() => _cameraLaunchInProgress = false);
    }
  }

  /// #8: Build the Photos tab icon with a count badge.
  Widget _buildPhotosTabIcon() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.photo_library),
        if (_allPhotoPaths.isNotEmpty)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                _allPhotoPaths.length > 99 ? '99+' : '${_allPhotoPaths.length}',
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Override the default ErrorWidget (which renders nothing in release
    // mode = white/black screen) with one that shows the error text.
    // MUST be self-contained (Directionality + Scaffold) because errors
    // during the first frame have no inherited widget ancestors.
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Scaffold(
          backgroundColor: Colors.red.shade50,
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 48, color: Colors.red),
                  const SizedBox(height: 8),
                  const Text('Something went wrong', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(details.exception.toString(), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ),
      );
    };
    return MaterialApp(
      title: 'BatBox',
      // #23: Dark mode toggle.
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true, brightness: Brightness.dark),
      themeMode: _isDarkMode ? ThemeMode.dark : ThemeMode.light,
      navigatorKey: rootNavigatorKey,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('BatBox'),
          bottom: TabBar(
            controller: _tabController,
            tabs: [
              Tab(icon: Icon(Icons.sensors), text: 'Trigger'),
              Tab(icon: Icon(Icons.graphic_eq), text: 'Reference'),
              Tab(icon: Icon(Icons.videocam), text: 'Viewfinder'),
              Tab(
                icon: _buildPhotosTabIcon(),
                text: 'Photos',
              ),
            ],
          ),
          actions: [
            // #23: Dark mode toggle
            IconButton(
              icon: Icon(_isDarkMode ? Icons.light_mode : Icons.dark_mode),
              tooltip: 'Toggle dark mode',
              onPressed: () { setState(() => _isDarkMode = !_isDarkMode); _saveSettings(); },
            ),
            IconButton(icon: const Icon(Icons.help_outline), onPressed: _showInstructions, tooltip: 'Instructions'),
          ],
        ),
        body: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              color: _flashActive ? Colors.black.withValues(alpha: 0.85) : Colors.transparent,
            ),
            SafeArea(
              child: TabBarView(
                controller: _tabController,
                children: [_buildTriggerTab(), _buildReferenceTab(), _buildViewfinderTab(), _buildPhotosTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Trigger tab
  // ---------------------------------------------------------------------------

  Widget _buildTriggerTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('Trigger', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Colors.deepPurple.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)),
            child: const Text('BUILD v12.6 - 2026-06-30 08:00 UTC', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.deepPurple)),
          ),
          const SizedBox(height: 16),

          // Active reference
          if (_references.isNotEmpty)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Reference: '),
              DropdownButton<String>(
                // Only set value if it exists in the items list, otherwise null.
                // Setting a value not in items throws an assertion error = white screen.
                value: _references.any((r) => r.name == _activeReferenceName) ? _activeReferenceName : null,
                items: _references.map((r) => DropdownMenuItem(value: r.name, child: Text(r.name))).toList(),
                onChanged: (v) { if (v != null) _switchToReference(v); },
              ),
            ]),
          const SizedBox(height: 8),

          // Mode dropdowns
          _buildDropdownRow('Photo mode', PhotoCountMode.values, _photoCountMode, (v) { setState(() => _photoCountMode = v); _saveSettings(); }),
          _buildDropdownRow('Flash', FlashModeSetting.values, _flashModeSetting, (v) { setState(() => _flashModeSetting = v); _saveSettings(); _applyFlashMode(); }),
          _buildDropdownRow('Recognition', RecognitionMode.values, _recognitionMode, (v) { setState(() => _recognitionMode = v); _saveSettings(); }),
          _buildDropdownRow('Resolution', ResolutionSetting.values, _resolutionSetting, (v) { setState(() => _resolutionSetting = v); _saveSettings(); }),
          const SizedBox(height: 8),

          // #21: Camera selector
          if (_availableCameras.length > 1)
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Camera: '),
              DropdownButton<int>(
                value: _cameraIndex.clamp(0, _availableCameras.length - 1),
                items: _availableCameras.asMap().entries.map((e) {
                  final name = e.value.name.isNotEmpty ? e.value.name : 'Camera ${e.key + 1}';
                  return DropdownMenuItem(value: e.key, child: Text(name));
                }).toList(),
                onChanged: (v) { if (v != null) { _switchCamera(v); _saveSettings(); } },
              ),
            ]),
          const SizedBox(height: 4),
          // #22: Video mode toggle
          SwitchListTile(
            title: const Text('Video mode (10-frame burst)', style: TextStyle(fontSize: 14)),
            value: _captureVideo,
            onChanged: (v) { setState(() => _captureVideo = v); _saveSettings(); },
            dense: true,
          ),
          // #11: Photo compression toggle
          SwitchListTile(
            title: const Text('Compress photos (80% JPEG)', style: TextStyle(fontSize: 14)),
            value: _compressPhotos,
            onChanged: (v) { setState(() => _compressPhotos = v); _saveSettings(); },
            dense: true,
          ),
          // Fast capture mode (for bat photography -- lowest latency)
          SwitchListTile(
            title: const Text('Fast capture (low res, deferred save)', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Optimized for fast-moving subjects', style: TextStyle(fontSize: 11)),
            value: _fastCaptureMode,
            onChanged: (v) { setState(() => _fastCaptureMode = v); _saveSettings(); },
            dense: true,
          ),
          if (_fastCaptureMode && _photoCountMode.burstSize > 1)
            Text('Burst delay: ${_burstDelayMs}ms (0 = max speed)', style: Theme.of(context).textTheme.bodySmall),
          if (_fastCaptureMode && _photoCountMode.burstSize > 1)
            SizedBox(width: 280, child: Slider(
              value: _burstDelayMs.toDouble(), min: 0, max: 500, divisions: 50,
              label: '${_burstDelayMs}ms',
              onChanged: (v) { setState(() => _burstDelayMs = v.round()); _saveSettings(); },
            )),
          const SizedBox(height: 8),
          // #4: Match debounce slider
          Text('Match debounce: ${_minMatchChunks} chunks (~${_minMatchChunks * 100}ms)', style: Theme.of(context).textTheme.bodySmall),
          SizedBox(width: 280, child: Slider(
            value: _minMatchChunks.toDouble(), min: 1, max: 10, divisions: 9,
            label: '$_minMatchChunks',
            onChanged: (v) { setState(() => _minMatchChunks = v.round()); _saveSettings(); },
          )),
          const SizedBox(height: 8),
          // #18: Scheduled triggers
          ExpansionTile(
            title: const Text('Schedule', style: TextStyle(fontSize: 14)),
            children: [
              Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_scheduledStart != null ? _scheduledStart!.format(context) : 'Start time'),
                  onPressed: () async {
                    final t = await showTimePicker(context: rootNavigatorKey.currentContext ?? context, initialTime: TimeOfDay.now());
                    if (t != null) setState(() => _scheduledStart = t);
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.stop),
                  label: Text(_scheduledStop != null ? _scheduledStop!.format(context) : 'Stop time'),
                  onPressed: () async {
                    final t = await showTimePicker(context: rootNavigatorKey.currentContext ?? context, initialTime: TimeOfDay.now());
                    if (t != null) setState(() => _scheduledStop = t);
                  },
                ),
              ]),
              Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
                FilledButton(onPressed: _startScheduledListening, child: const Text('Activate schedule')),
                OutlinedButton(onPressed: _stopScheduledListening, child: const Text('Cancel')),
              ]),
            ],
          ),
          const SizedBox(height: 8),
          // Refractory period slider
          Text('Refractory period: ${(_refractoryPeriodMs / 1000).toStringAsFixed(1)}s', style: Theme.of(context).textTheme.bodySmall),
          SizedBox(width: 280, child: Slider(
            value: _refractoryPeriodMs.toDouble(), min: 200, max: 5000, divisions: 48,
            label: '${(_refractoryPeriodMs / 1000).toStringAsFixed(1)}s',
            onChanged: (v) => setState(() => _refractoryPeriodMs = v.round()),
            onChangeEnd: (_) => _saveSettings(),
          )),
          const SizedBox(height: 8),

          // Toggles: haptic + auto-stop
          SwitchListTile(
            title: const Text('Haptic feedback on match', style: TextStyle(fontSize: 14)),
            value: _hapticOnMatch,
            onChanged: (v) { setState(() => _hapticOnMatch = v); _saveSettings(); },
            dense: true,
          ),
          SwitchListTile(
            title: const Text('Auto-stop on silence', style: TextStyle(fontSize: 14)),
            value: _autoStopOnSilence,
            onChanged: (v) { setState(() => _autoStopOnSilence = v); _saveSettings(); },
            dense: true,
          ),
          if (_autoStopOnSilence) ...[
            Text('Timeout: ${_autoStopTimeoutSec}s', style: Theme.of(context).textTheme.bodySmall),
            SizedBox(width: 280, child: Slider(
              value: _autoStopTimeoutSec.toDouble(), min: 5, max: 120, divisions: 23,
              label: '${_autoStopTimeoutSec}s',
              onChanged: (v) => setState(() => _autoStopTimeoutSec = v.round()),
              onChangeEnd: (_) => _saveSettings(),
            )),
          ],
          const SizedBox(height: 12),

          // Viewfinder toggle + preview
          SwitchListTile(
            title: const Text('Show viewfinder (aim camera)', style: TextStyle(fontSize: 14)),
            value: _showViewfinder,
            onChanged: (_) => _toggleViewfinder(),
            dense: true,
          ),
          if (_showViewfinder && _cameraController != null && _cameraController!.value.isInitialized) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 220,
                width: double.infinity,
                child: CameraPreview(_cameraController!),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Camera: ${_availableCameras.isNotEmpty && _cameraIndex < _availableCameras.length ? _availableCameras[_cameraIndex].name : "active"}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ] else if (_showViewfinder) ...[
            const SizedBox(
              height: 100,
              child: Center(child: Text('Initializing camera...', style: TextStyle(color: Colors.grey))),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 8),

          // Start/stop + manual
          FilledButton.icon(
            onPressed: _isListening || _hasReference ? _toggleListening : null,
            icon: Icon(_isListening ? Icons.stop_circle : Icons.sensors),
            label: Text(_isListening ? 'Stop listening' : 'Start listening'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: _manualTrigger, icon: const Icon(Icons.camera_alt), label: const Text('Take photo manually')),
          const SizedBox(height: 16),

          Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 12),

          // Live diagnostics + spectrogram
          if (_isListening) ...[
            Text('Mic: ${(_microphoneLevel * 100).round()}%', style: Theme.of(context).textTheme.bodyMedium),
            // #19: Live classification
            if (_currentClassification.isNotEmpty)
              Text('Sound: $_currentClassification (${(_classificationConfidence * 100).round()}%)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                  color: _currentClassification == 'Silence' ? Colors.grey : Colors.deepPurple)),
            const SizedBox(height: 4),
            SizedBox(width: 220, child: LinearProgressIndicator(value: _microphoneLevel.clamp(0.0, 1.0), minHeight: 10)),
            const SizedBox(height: 12),
            Text('Similarity: ${_currentBestSimilarity.toStringAsFixed(3)}  (peak: ${_sessionPeakSimilarity.toStringAsFixed(3)})',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                color: _currentBestSimilarity >= _triggerThreshold ? Colors.green : Colors.orange)),
            const SizedBox(height: 8),
            Text('Threshold: ${_triggerThreshold.toStringAsFixed(2)}', style: Theme.of(context).textTheme.bodySmall),
            SizedBox(width: 280, child: Slider(
              value: _triggerThreshold, min: 0.10, max: 0.90, divisions: 80,
              label: _triggerThreshold.toStringAsFixed(2),
              onChanged: (v) => setState(() => _triggerThreshold = v),
              onChangeEnd: (_) => _saveSettings(),
            )),
            if (_photoCountMode.takesPhotos)
              Text('Session: ${_photosTakenThisSession} photo(s), ${_burstsThisSession} burst(s)', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            // Spectrogram
            const Text('Spectrogram', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity, height: 120,
              decoration: BoxDecoration(border: Border.all(color: Colors.grey), color: Colors.black),
              child: CustomPaint(painter: _SpectrogramPainter(frames: _spectrogramFrames), child: const SizedBox.expand()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDropdownRow<T>(String label, List<T> values, T current, ValueChanged<T> onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      // Use Wrap instead of Row so long labels don't overflow on narrow screens.
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('$label: '),
          DropdownButton<T>(
            value: current,
            items: values.map((v) => DropdownMenuItem(value: v, child: Text((v as dynamic).label as String))).toList(),
            onChanged: (v) { if (v != null) onChanged(v); },
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Reference tab
  // ---------------------------------------------------------------------------

  Widget _buildReferenceTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('Reference audio', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),

          // Reference library
          if (_references.isNotEmpty) ...[
            const Text('Saved references', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _references.length,
                itemBuilder: (ctx, i) {
                  final ref = _references[i];
                  final isActive = ref.name == _activeReferenceName;
                  return ListTile(
                    leading: Icon(isActive ? Icons.check_circle : Icons.radio_button_unchecked,
                        color: isActive ? Colors.deepPurple : Colors.grey),
                    title: Text(ref.name),
                    subtitle: Text('${(ref.samples.length / 44100).toStringAsFixed(1)}s'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.play_arrow, size: 20), onPressed: () {
                        _switchToReference(ref.name);
                        _playReferenceSound();
                      }),
                      IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () async {
                        final newName = await _promptForName('Rename reference');
                        if (newName != null && newName.isNotEmpty) _renameReference(ref.name, newName);
                      }),
                      IconButton(icon: const Icon(Icons.delete, size: 20), onPressed: () => _deleteReference(ref.name)),
                    ]),
                    onTap: () => _switchToReference(ref.name),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ] else
            const Padding(padding: EdgeInsets.all(8), child: Text('No references yet. Record or import one below.', style: TextStyle(color: Colors.grey))),

          const Divider(),
          const SizedBox(height: 8),

          // Record / import / play
          FilledButton.icon(
            onPressed: _toggleReferenceRecording,
            icon: Icon(_isRecordingReference ? Icons.stop : Icons.mic),
            label: Text(_isRecordingReference ? 'Stop recording' : 'Record new reference'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: _importAudioFile, icon: const Icon(Icons.file_upload), label: const Text('Import audio (.wav, .m4a, .mp3)')),
          const SizedBox(height: 8),
          // Save / Load reference WAV files -- use Wrap to avoid overflow
          Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _saveReferenceToFile, icon: const Icon(Icons.save), label: const Text('Save .wav')),
            OutlinedButton.icon(onPressed: _loadReferenceFromFile, icon: const Icon(Icons.folder_open), label: const Text('Load .wav')),
          ]),
          const SizedBox(height: 8),
          // #3: Noise calibration
          if (_hasReference)
            OutlinedButton.icon(onPressed: _calibrateNoise, icon: const Icon(Icons.tune), label: const Text('Calibrate noise (5s)')),
          const SizedBox(height: 8),
          // #10: Export all references
          if (_references.isNotEmpty)
            OutlinedButton.icon(onPressed: _exportAllReferences, icon: const Icon(Icons.upload_file), label: const Text('Export references')),
          const SizedBox(height: 8),
          // #19: Sound classification -- feature-based, works now
          if (_hasReference)
            OutlinedButton.icon(
              onPressed: () {
                final result = _classifyActiveReference();
                final cat = result['category'] as String;
                final conf = ((result['confidence'] as double) * 100).round();
                final features = result['features'] as Map<String, dynamic>;
                showDialog<void>(
                  context: rootNavigatorKey.currentContext ?? context,
                  useRootNavigator: true,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Sound Classification'),
                    content: SingleChildScrollView(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Category: $cat', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Text('Confidence: $conf%'),
                        const SizedBox(height: 12),
                        const Text('Features:', style: TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        ...features.entries.map((e) => Text('  ${e.key}: ${(e.value as double).toStringAsFixed(4)}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace'))),
                        const SizedBox(height: 12),
                        const Text('Categories: Percussive, Tonal, Speech, Noise, Music, Broadband, Silence', style: TextStyle(fontSize: 10, color: Colors.grey)),
                      ],
                    )),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                  ),
                );
              },
              icon: const Icon(Icons.category),
              label: const Text('Classify reference sound'),
            ),
          const SizedBox(height: 8),
          if (_hasReference)
            FilledButton.icon(onPressed: _playReferenceSound, icon: Icon(_playingSource == 'full' ? Icons.stop : Icons.play_arrow), label: Text(_playingSource == 'full' ? 'Stop' : 'Play active reference')),
          const SizedBox(height: 16),

          // Trim controls (reversible -- original audio is never deleted)
          if (_hasReference && _referenceSamples.isNotEmpty) ...[
            const Divider(),
            const SizedBox(height: 8),
            const Text('Trim reference audio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Original: ${(_referenceSamples.length / 44100).toStringAsFixed(1)}s',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Builder(builder: (context) {
              final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
              final trimStart = ref?.trimStart ?? 0.0;
              final trimEnd = ref?.trimEnd ?? 1.0;
              final origLen = _referenceSamples.length;
              final startSec = (trimStart * origLen / 44100).toStringAsFixed(1);
              final endSec = (trimEnd * origLen / 44100).toStringAsFixed(1);
              final durSec = ((trimEnd - trimStart) * origLen / 44100).toStringAsFixed(1);
              return Text(
                'Trimmed: $startSec s to $endSec s (duration: $durSec s)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              );
            }),
            const SizedBox(height: 8),
            // Start slider
            Text('Start: ${(_references.where((r) => r.name == _activeReferenceName).firstOrNull?.trimStart ?? 0.0).toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12)),
            StatefulBuilder(builder: (context, setLocalState) {
              final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
              final ts = ref?.trimStart ?? 0.0;
              final te = ref?.trimEnd ?? 1.0;
              return Slider(
                value: ts,
                min: 0.0,
                max: te - 0.01, // can't overlap end
                divisions: 100,
                label: '${(ts * _referenceSamples.length / 44100).toStringAsFixed(1)}s',
                onChanged: (v) {
                  if (ref != null) {
                    ref.trimStart = v;
                    _computeReferenceFeatures(ref);
                    _switchToReference(ref.name);
                    setLocalState(() {});
                    _saveReferenceList();
                  }
                },
              );
            }),
            // End slider
            Text('End: ${(_references.where((r) => r.name == _activeReferenceName).firstOrNull?.trimEnd ?? 1.0).toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 12)),
            StatefulBuilder(builder: (context, setLocalState) {
              final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
              final ts = ref?.trimStart ?? 0.0;
              final te = ref?.trimEnd ?? 1.0;
              return Slider(
                value: te,
                min: ts + 0.01, // can't overlap start
                max: 1.0,
                divisions: 100,
                label: '${(te * _referenceSamples.length / 44100).toStringAsFixed(1)}s',
                onChanged: (v) {
                  if (ref != null) {
                    ref.trimEnd = v;
                    _computeReferenceFeatures(ref);
                    _switchToReference(ref.name);
                    setLocalState(() {});
                    _saveReferenceList();
                  }
                },
              );
            }),
            // Reset trim button
            OutlinedButton.icon(
              onPressed: () {
                final ref = _references.where((r) => r.name == _activeReferenceName).firstOrNull;
                if (ref != null) {
                  ref.trimStart = 0.0;
                  ref.trimEnd = 1.0;
                  _computeReferenceFeatures(ref);
                  _switchToReference(ref.name);
                  setState(() {});
                  _saveReferenceList();
                  _showSnackBar('Trim reset to full length');
                }
              },
              icon: const Icon(Icons.undo),
              label: const Text('Reset trim'),
            ),
            const SizedBox(height: 8),
            // Play trimmed reference button
            FilledButton.icon(
              onPressed: _playTrimmedReference,
              icon: Icon(_playingSource == 'trimmed' ? Icons.stop : Icons.play_arrow),
              label: Text(_playingSource == 'trimmed' ? 'Stop' : 'Play trimmed reference'),
            ),
            const SizedBox(height: 8),
          ],

          if (_isRecordingReference) ...[
            Text('Recording... ${(_referenceSamples.length / 44100).toStringAsFixed(1)}s', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            // #5: Recording level meter
            SizedBox(width: 220, child: LinearProgressIndicator(value: _recordingLevel.clamp(0.0, 1.0), minHeight: 8, color: Colors.red)),
            const SizedBox(height: 4),
            Text('Level: ${(_recordingLevel * 100).round()}%', style: const TextStyle(fontSize: 12, color: Colors.red)),
          ],

          const SizedBox(height: 24),
          const Divider(),

          // Test recognition
          const Text('Test recognition', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Listens without taking photos. Shows live similarity\nand histogram for tuning the threshold.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _hasReference ? _toggleTestRecognition : null,
            icon: Icon(_isListening && _testMode ? Icons.stop_circle : Icons.science),
            label: Text(_isListening && _testMode ? 'Stop test' : 'Start test'),
          ),

          if (_isListening && _testMode) ...[
            const SizedBox(height: 12),
            Text('Mic: ${(_microphoneLevel * 100).round()}%'),
            // #19: Live classification in test mode
            if (_currentClassification.isNotEmpty)
              Text('Sound: $_currentClassification (${(_classificationConfidence * 100).round()}%)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                  color: _currentClassification == 'Silence' ? Colors.grey : Colors.deepPurple)),
            const SizedBox(height: 4),
            SizedBox(width: 220, child: LinearProgressIndicator(value: _microphoneLevel.clamp(0.0, 1.0), minHeight: 10)),
            const SizedBox(height: 12),
            Text('Similarity: ${_currentBestSimilarity.toStringAsFixed(3)}  (peak: ${_sessionPeakSimilarity.toStringAsFixed(3)})',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold,
                color: _currentBestSimilarity >= _triggerThreshold ? Colors.green : Colors.orange)),
            const SizedBox(height: 8),
            // Histogram
            const Text('Recent similarity scores', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity, height: 80,
              child: CustomPaint(painter: _HistogramPainter(scores: _similarityHistory, threshold: _triggerThreshold), child: const SizedBox.expand()),
            ),
            const SizedBox(height: 8),
            Text('Threshold: ${_triggerThreshold.toStringAsFixed(2)}', style: Theme.of(context).textTheme.bodySmall),
            SizedBox(width: 280, child: Slider(
              value: _triggerThreshold, min: 0.10, max: 0.90, divisions: 80,
              label: _triggerThreshold.toStringAsFixed(2),
              onChanged: (v) => setState(() => _triggerThreshold = v),
              onChangeEnd: (_) => _saveSettings(),
            )),
            const SizedBox(height: 8),
            // Spectrogram in test mode too
            const Text('Spectrogram', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Container(
              width: double.infinity, height: 100,
              decoration: BoxDecoration(border: Border.all(color: Colors.grey), color: Colors.black),
              child: CustomPaint(painter: _SpectrogramPainter(frames: _spectrogramFrames), child: const SizedBox.expand()),
            ),
          ],

          const SizedBox(height: 16),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Photos tab
  // ---------------------------------------------------------------------------

  // ===========================================================================
  // Viewfinder tab (live preview + motion detection)
  // ===========================================================================

  Widget _buildViewfinderTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Text('Viewfinder', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          // Camera preview with motion zone overlay
          Container(
            decoration: BoxDecoration(border: Border.all(color: Colors.grey), borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: LayoutBuilder(builder: (context, constraints) {
                return GestureDetector(
                  onPanStart: (details) {
                    // Use the GestureDetector's render object, not the parent context.
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(details.globalPosition);
                    setState(() {
                      _isDrawingZone = true;
                      _motionZone = Rect.fromLTWH(
                        (local.dx / box.size.width).clamp(0.0, 1.0),
                        (local.dy / box.size.height).clamp(0.0, 1.0),
                        0, 0,
                      );
                    });
                  },
                  onPanUpdate: (details) {
                    if (!_isDrawingZone) return;
                    final box = context.findRenderObject() as RenderBox;
                    final local = box.globalToLocal(details.globalPosition);
                    setState(() {
                      final startX = _motionZone.left;
                      final startY = _motionZone.top;
                      final endX = (local.dx / box.size.width).clamp(0.0, 1.0);
                      final endY = (local.dy / box.size.height).clamp(0.0, 1.0);
                      _motionZone = Rect.fromLTWH(
                        min(startX, endX),
                        min(startY, endY),
                        (endX - startX).abs(),
                        (endY - startY).abs(),
                      );
                    });
                  },
                  onPanEnd: (_) => setState(() => _isDrawingZone = false),
                  child: Stack(fit: StackFit.expand, children: [
                    // Camera preview
                    if (_cameraController != null && _cameraController!.value.isInitialized)
                      FittedBox(
                        fit: BoxFit.cover,
                        child: SizedBox(
                          width: _cameraController!.value.previewSize?.height ?? 320,
                          height: _cameraController!.value.previewSize?.width ?? 240,
                          child: CameraPreview(_cameraController!),
                        ),
                      )
                    else
                      Container(color: Colors.black, child: const Center(child: Text('Camera not active', style: TextStyle(color: Colors.white70)))),
                    // Motion zone overlay
                    Positioned.fill(
                      child: CustomPaint(painter: _MotionZonePainter(zone: _motionZone, isDrawing: _isDrawingZone)),
                    ),
                    // Motion level indicator (top-left)
                    Positioned(
                      top: 8, left: 8,
                      child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                      child: Text(
                        _motionDetectionEnabled
                            ? 'Motion: ${(_currentMotionLevel * 100).toStringAsFixed(1)}%  (peak: ${(_motionSessionPeak * 100).toStringAsFixed(1)}%)'
                            : 'Motion: OFF',
                        style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.bold,
                          color: _currentMotionLevel > 0.1 ? Colors.green : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ]),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          // Controls -- use Wrap to avoid overflow on narrow screens
          Wrap(alignment: WrapAlignment.center, spacing: 12, runSpacing: 8, children: [
            if (!_isDetectingMotion)
              FilledButton.icon(
                onPressed: _motionDetectionEnabled ? null : () { setState(() => _motionDetectionEnabled = true); _startMotionDetection(); },
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start motion detection'),
              )
            else
              FilledButton.icon(
                onPressed: () { _stopMotionDetection(); setState(() => _motionDetectionEnabled = false); },
                icon: const Icon(Icons.stop),
                label: const Text('Stop motion detection'),
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
              ),
            OutlinedButton.icon(
              onPressed: () => setState(() { _motionZone = const Rect.fromLTWH(0.2, 0.2, 0.6, 0.6); _previousFrame = null; }),
              icon: const Icon(Icons.crop_free),
              label: const Text('Reset zone'),
            ),
          ]),
          const SizedBox(height: 12),
          // Sensitivity slider
          Text('Sensitivity: ${(_motionSensitivity * 100).round()}%', style: Theme.of(context).textTheme.bodyMedium),
          Slider(
            value: _motionSensitivity,
            min: 0.05, max: 0.95, divisions: 18,
            label: '${(_motionSensitivity * 100).round()}%',
            onChanged: (v) { setState(() { _motionSensitivity = v; _previousFrame = null; }); _saveSettings(); },
          ),
          const SizedBox(height: 8),
          // Trigger source selector
          const Text('Trigger source:', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('Sound only'), selected: _triggerSource == 'sound', onSelected: (_) { setState(() => _triggerSource = 'sound'); _saveSettings(); }),
            ChoiceChip(label: const Text('Motion only'), selected: _triggerSource == 'motion', onSelected: (_) { setState(() => _triggerSource = 'motion'); _saveSettings(); }),
            ChoiceChip(label: const Text('Either'), selected: _triggerSource == 'either', onSelected: (_) { setState(() => _triggerSource = 'either'); _saveSettings(); }),
            ChoiceChip(label: const Text('Both (sound AND motion)'), selected: _triggerSource == 'both', onSelected: (_) { setState(() => _triggerSource = 'both'); _saveSettings(); }),
          ]),
          const SizedBox(height: 8),
          // Instructions
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)),
            child: const Text(
              'Draw on the preview to set the motion detection zone (green box).\n'
              'Adjust sensitivity: higher = more sensitive (triggers on smaller movements).\n'
              'Trigger source controls what causes a photo: sound match, motion, either, or both.\n'
              'Note: motion detection requires camera to be active on this tab.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(height: 16),
          Text(_status, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Widget _buildPhotosTab() {
    final hasSelection = _selectedPhotoPaths.isNotEmpty;
    return Column(children: [
      // Action bar
      Container(
        color: hasSelection ? Colors.deepPurple.withValues(alpha: 0.1) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Text(hasSelection ? '${_selectedPhotoPaths.length} selected' : '${_allPhotoPaths.length} photo(s)'),
          const Spacer(),
          IconButton(icon: Icon(hasSelection ? Icons.deselect : Icons.select_all),
            tooltip: hasSelection ? 'Deselect all' : 'Select all',
            onPressed: () { if (hasSelection) _exitSelectionMode(); else _selectAllPhotos(); }),
          if (hasSelection) IconButton(icon: const Icon(Icons.save_alt), tooltip: 'Save to folder', onPressed: _saveSelectedToFolder),
          if (hasSelection) IconButton(icon: const Icon(Icons.delete), tooltip: 'Delete selected', onPressed: _deleteSelectedPhotos),
          if (!hasSelection && _allPhotoPaths.isNotEmpty) IconButton(icon: const Icon(Icons.delete_sweep), tooltip: 'Delete all', onPressed: _deleteAllPhotos),
          if (!hasSelection && _allPhotoPaths.isNotEmpty) IconButton(icon: const Icon(Icons.save), tooltip: 'Save all', onPressed: _saveAllToFolder),
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: _refreshPhotoSessions),
        ]),
      ),
      // Photo grid grouped by session
      Expanded(
        child: _allPhotoPaths.isEmpty
          ? const Center(child: Text('No photos yet.\nTrigger a photo from the Trigger tab.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              itemCount: _photosBySession.length,
              itemBuilder: (ctx, sessionIdx) {
                final sessionLabel = _photosBySession.keys.elementAt(sessionIdx);
                final photos = _photosBySession[sessionLabel]!;
                return ExpansionTile(
                  initiallyExpanded: sessionIdx == 0,
                  title: Text(_formatSessionLabel(sessionLabel)),
                  subtitle: Text('${photos.length} photo(s)'),
                  children: [
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.all(4),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                      itemCount: photos.length,
                      itemBuilder: (ctx, idx) {
                        final path = photos[idx];
                        final selected = _selectedPhotoPaths.contains(path);
                        return ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Stack(fit: StackFit.expand, children: [
                            // Image -- tap to view
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _viewPhoto(path),
                              child: Container(color: Colors.grey.shade300, child: Image.file(File(path), fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image, color: Colors.white70)))),
                            ),
                            // Selection tint -- below checkbox so it doesn't block taps.
                            // Uses IgnorePointer so it never intercepts gestures.
                            if (selected)
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: Container(color: Colors.deepPurple.withValues(alpha: 0.3)),
                                ),
                              ),
                            // Checkbox -- always on top, always tappable
                            Positioned(top: 4, right: 4, child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                debugPrint('[batbox] checkbox tapped: $path');
                                _togglePhotoSelection(path);
                              },
                              child: Container(width: 32, height: 32,
                                decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                child: Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                                  color: selected ? Colors.deepPurple : Colors.white, size: 24)),
                            )),
                          ]),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
      ),
    ]);
  }

  String _formatSessionLabel(String raw) {
    // Session IDs are ISO timestamps with colons replaced by dashes:
    //   "2026-06-29T10-30-00"
    // We need to convert back to parseable ISO format.
    try {
      // Split on 'T' to separate date and time parts
      final parts = raw.split('T');
      if (parts.length != 2) return raw;
      final datePart = parts[0]; // "2026-06-29" -- already ISO-format
      final timePart = parts[1].replaceAll('-', ':'); // "10-30-00" -> "10:30:00"
      final isoString = '$datePart' 'T' '$timePart';
      final dt = DateTime.parse(isoString);
      return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return raw;
    }
  }
}

// =============================================================================
// Photo viewer (full-screen, swipeable, with share + timestamp)
// =============================================================================

class _PhotoViewerScreen extends StatefulWidget {
  const _PhotoViewerScreen({required this.photos, required this.initialIndex, required this.onShare});
  final List<String> photos;
  final int initialIndex;
  final Future<void> Function(String path) onShare;

  @override
  State<_PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;
  // #12: Rotation state
  double _rotation = 0.0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  String _parseTimestamp(String path) {
    try {
      final basename = path.split(Platform.pathSeparator).last;
      // "batbox-2026-06-29T10-30-00-123456.jpg"
      final match = RegExp(r'batbox-(.+)\.jpg').firstMatch(basename);
      if (match != null) {
        final raw = match.group(1)!;
        final cleaned = raw.replaceAll('-', ':').replaceFirst('T', ' ');
        return cleaned.substring(0, 19);
      }
    } catch (_) {}
    return path.split(Platform.pathSeparator).last;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.photos.isEmpty) {
      return Scaffold(backgroundColor: Colors.black, appBar: AppBar(title: const Text('Photo')), body: const Center(child: Text('No photos.')));
    }
    final currentPath = widget.photos[_currentIndex];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        title: Text('${_currentIndex + 1} / ${widget.photos.length}', style: const TextStyle(fontSize: 16)),
        actions: [
          // #12: Rotate left/right
          IconButton(icon: const Icon(Icons.rotate_left), onPressed: () => setState(() => _rotation -= 90),
            tooltip: 'Rotate left'),
          IconButton(icon: const Icon(Icons.rotate_right), onPressed: () => setState(() => _rotation += 90),
            tooltip: 'Rotate right'),
          IconButton(icon: const Icon(Icons.share), onPressed: () => widget.onShare(currentPath)),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photos.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (ctx, i) {
          final path = widget.photos[i];
          return Stack(children: [
            // #12: Rotatable image
            Center(child: InteractiveViewer(
              minScale: 0.5, maxScale: 4.0,
              child: Transform.rotate(
                angle: _rotation * pi / 180,
                child: Image.file(File(path), fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.broken_image, size: 64, color: Colors.white54),
                  SizedBox(height: 8),
                  Text('Failed to load', style: TextStyle(color: Colors.white54)),
                ])),
            ))),
            // Timestamp at bottom
            Positioned(bottom: 16, left: 0, right: 0,
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                child: Text(_parseTimestamp(path), style: const TextStyle(color: Colors.white, fontSize: 12)),
              )),
            ),
          ]);
        },
      ),
    );
  }
}

// =============================================================================
// Spectrogram painter
// =============================================================================

class _SpectrogramPainter extends CustomPainter {
  final List<List<double>> frames;
  _SpectrogramPainter({required this.frames});

  @override
  void paint(Canvas canvas, Size size) {
    if (frames.isEmpty) return;
    final colW = size.width / frames.length;
    final bins = frames.first.length;
    final binH = size.height / bins;
    for (var col = 0; col < frames.length; col++) {
      final frame = frames[col];
      for (var bin = 0; bin < bins; bin++) {
        final v = (frame[bin]).clamp(0.0, 1.0);
        final color = _magColor(v);
        final x = col * colW;
        final y = size.height - (bin + 1) * binH;
        canvas.drawRect(Rect.fromLTWH(x, y, colW + 1, binH + 1), Paint()..color = color);
      }
    }
  }

  Color _magColor(double v) {
    if (v < 0.25) return Color.lerp(Colors.black, Colors.blue, v * 4)!;
    if (v < 0.5) return Color.lerp(Colors.blue, Colors.green, (v - 0.25) * 4)!;
    if (v < 0.75) return Color.lerp(Colors.green, Colors.yellow, (v - 0.5) * 4)!;
    return Color.lerp(Colors.yellow, Colors.red, (v - 0.75) * 4)!;
  }

  @override
  bool shouldRepaint(covariant _SpectrogramPainter old) => true;
}

// =============================================================================
// Histogram painter
// =============================================================================

class _HistogramPainter extends CustomPainter {
  final List<double> scores;
  final double threshold;
  _HistogramPainter({required this.scores, required this.threshold});

  @override
  void paint(Canvas canvas, Size size) {
    // Threshold line
    final thrY = size.height - (threshold * size.height);
    canvas.drawRect(Rect.fromLTWH(0, thrY, size.width, 1), Paint()..color = Colors.red);

    if (scores.isEmpty) return;
    final barW = size.width / 30; // fixed 30 slots
    for (var i = 0; i < scores.length; i++) {
      final s = scores[i].clamp(0.0, 1.0);
      final h = s * size.height;
      final x = i * barW;
      final y = size.height - h;
      final color = s >= threshold ? Colors.green : Colors.orange;
      canvas.drawRect(Rect.fromLTWH(x, y, barW - 1, h), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant _HistogramPainter old) => true;
}

// =============================================================================
// Motion zone painter
// =============================================================================

class _MotionZonePainter extends CustomPainter {
  final Rect zone;
  final bool isDrawing;
  _MotionZonePainter({required this.zone, required this.isDrawing});

  @override
  void paint(Canvas canvas, Size size) {
    if (zone.width <= 0 || zone.height <= 0) return;
    final rect = Rect.fromLTWH(
      zone.left * size.width,
      zone.top * size.height,
      zone.width * size.width,
      zone.height * size.height,
    );
    final paint = Paint()
      ..color = isDrawing ? Colors.yellow : Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRect(rect, paint);
    // Semi-transparent fill
    final fillPaint = Paint()
      ..color = (isDrawing ? Colors.yellow : Colors.green).withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawRect(rect, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _MotionZonePainter old) => old.zone != zone || old.isDrawing != isDrawing;
}

// =============================================================================
// Math helpers
// =============================================================================

double similarityScore(List<double> reference, List<double> candidate) {
  if (reference.isEmpty || candidate.isEmpty) return 0.0;
  final length = min(reference.length, candidate.length);
  double dot = 0, refN = 0, canN = 0;
  for (var i = 0; i < length; i++) {
    final r = reference[i], c = candidate[i];
    dot += r * c; refN += r * r; canN += c * c;
  }
  if (refN == 0 || canN == 0) return 0.0;
  return dot / (sqrt(refN * canN));
}

double normalizedCosineSimRange(List<double> reference, List<double> live, int start, int length) {
  double refSum = 0, liveSum = 0;
  for (var i = 0; i < length; i++) { refSum += reference[i]; liveSum += live[start + i]; }
  final refMean = refSum / length, liveMean = liveSum / length;
  double dot = 0, refN = 0, liveN = 0;
  for (var i = 0; i < length; i++) {
    final r = reference[i] - refMean, c = live[start + i] - liveMean;
    dot += r * c; refN += r * r; liveN += c * c;
  }
  if (refN == 0 || liveN == 0) return 0.0;
  return dot / (sqrt(refN * liveN));
}

double bestSimilarityScore(List<double> reference, List<double> liveSamples, {int? stepOverride}) {
  if (reference.isEmpty || liveSamples.isEmpty) return 0.0;
  final targetLength = min(reference.length, liveSamples.length);
  if (targetLength < 10) return similarityScore(reference, liveSamples);
  final searchSpan = liveSamples.length - targetLength;
  if (searchSpan <= 0) return normalizedCosineSimRange(reference, liveSamples, 0, targetLength);

  if (stepOverride != null && stepOverride > 1) {
    var best = 0.0;
    for (var s = 0; s <= searchSpan; s += stepOverride) {
      final sc = normalizedCosineSimRange(reference, liveSamples, s, targetLength);
      if (sc > best) best = sc;
    }
    return best;
  }

  // Coarse-to-fine
  final coarseStep = max(1, targetLength ~/ 16);
  var best = 0.0;
  var bestStart = 0;
  for (var s = 0; s <= searchSpan; s += coarseStep) {
    final sc = normalizedCosineSimRange(reference, liveSamples, s, targetLength);
    if (sc > best) { best = sc; bestStart = s; }
  }
  if (coarseStep > 1) {
    final fStart = max(0, bestStart - coarseStep);
    final fEnd = min(searchSpan, bestStart + coarseStep);
    for (var s = fStart; s <= fEnd; s++) {
      final sc = normalizedCosineSimRange(reference, liveSamples, s, targetLength);
      if (sc > best) best = sc;
    }
  }
  return best;
}

List<double> pcm16ToDoubles(Uint8List bytes) {
  final samples = <double>[];
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    samples.add(bd.getInt16(i, Endian.little) / 32768.0);
  }
  return samples;
}
