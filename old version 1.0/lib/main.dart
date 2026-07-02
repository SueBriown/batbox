import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const BatboxApp());
}

enum RecognitionMode { standard, better }

class BatboxApp extends StatefulWidget {
  const BatboxApp({super.key});

  @override
  State<BatboxApp> createState() => _BatboxAppState();
}

class _BatboxAppState extends State<BatboxApp> {
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  StreamSubscription<dynamic>? _audioSubscription;
  List<CameraDescription> _availableCameras = <CameraDescription>[];
  CameraController? _cameraController;
  Timer? _flashTimer;
  static const double _triggerThreshold = 0.68;
  static const String _referenceSamplesKey = 'reference_samples';
  static const String _hasReferenceKey = 'has_reference';

  late SharedPreferences _prefs;
  late StreamSubscription<PlayerState> _playerStateSubscription;

  final RecordConfig _recordConfig = const RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: 44100,
    numChannels: 1,
  );

  final List<double> _referenceSamples = <double>[];
  final List<double> _liveSamples = <double>[];

  RecognitionMode _recognitionMode = RecognitionMode.standard;

  bool _isRecordingReference = false;
  bool _isListening = false;
  bool _hasReference = false;
  bool _photoTriggered = false;
  bool _isCapturingPhoto = false;
  bool _isPlayingReference = false;
  bool _flashActive = false;
  bool _cameraLaunchInProgress = false;
  double _microphoneLevel = 0.0;
  String _status = 'Record a short reference sound to begin.';
  String _lastSavedPhotoPath = '';

  @override
  void initState() {
    super.initState();
    _loadSavedReference();
    _playerStateSubscription = _audioPlayer.playerStateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _isPlayingReference = state.playing;
      });
      // Explicitly handle completion
      if (state.processingState == ProcessingState.completed) {
        if (mounted) {
          setState(() {
            _isPlayingReference = false;
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _audioSubscription?.cancel();
    _playerStateSubscription.cancel();
    _audioPlayer.dispose();
    _audioRecorder.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    final microphoneStatus = await Permission.microphone.request();
    final cameraStatus = await Permission.camera.request();

    if (microphoneStatus.isDenied || cameraStatus.isDenied) {
      if (mounted) {
        setState(() {
          _status = 'Microphone and camera permissions are required.';
        });
      }
    }
  }

  Future<void> _loadSavedReference() async {
    _prefs = await SharedPreferences.getInstance();
    final savedSamples = _prefs.getStringList(_referenceSamplesKey);
    final hasReference = _prefs.getBool(_hasReferenceKey) ?? false;

    if (savedSamples != null && savedSamples.isNotEmpty) {
      _referenceSamples.clear();
      _referenceSamples.addAll(savedSamples.map((sample) => double.parse(sample)).toList());
      _hasReference = true;
      if (mounted) {
        setState(() {
          _status = 'Loaded your saved reference sound.';
        });
      }
    } else if (hasReference) {
      _hasReference = true;
      if (mounted) {
        setState(() {
          _status = 'Reference available from a previous session.';
        });
      }
    }
  }

  Future<void> _saveReference() async {
    if (_referenceSamples.isEmpty) {
      await _prefs.setStringList(_referenceSamplesKey, <String>[]);
      await _prefs.setBool(_hasReferenceKey, false);
      return;
    }

    await _prefs.setStringList(
      _referenceSamplesKey,
      _referenceSamples.map((sample) => sample.toString()).toList(),
    );
    await _prefs.setBool(_hasReferenceKey, true);
  }

  Future<void> _toggleReferenceRecording() async {
    if (_isRecordingReference) {
      await _stopAudioStream();
      setState(() {
        _isRecordingReference = false;
        _hasReference = _referenceSamples.length > 2000;
        _status = _hasReference
            ? 'Reference sound saved. You can now listen for it.'
            : 'Reference sound was too short. Try again.';
      });
      if (_hasReference) {
        await _saveReference();
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
    _photoTriggered = false;
    _microphoneLevel = 0.0;
    await _prefs.setStringList(_referenceSamplesKey, <String>[]);
    await _prefs.setBool(_hasReferenceKey, false);

    try {
      _audioSubscription?.cancel();
      final stream = await _audioRecorder.startStream(_recordConfig);
      _audioSubscription = stream.listen((Uint8List event) {
        if (!_isRecordingReference) return;
        final bytes = event;
        final chunk = pcm16ToDoubles(bytes);
        _referenceSamples.addAll(chunk);
      });

      setState(() {
        _isRecordingReference = true;
        _status = 'Recording reference sound...';
      });
    } catch (error) {
      setState(() => _status = 'Unable to start reference recording: $error');
    }
  }

  Future<void> _toggleListening() async {
    if (_isListening) {
      await _stopAudioStream();
      await _disposeCamera();
      setState(() {
        _isListening = false;
        _microphoneLevel = 0.0;
        _status = 'Listening stopped.';
      });
      return;
    }

    if (!_hasReference) {
      setState(() => _status = 'Record a reference sound first.');
      return;
    }

    await _requestPermissions();
    if (!await _audioRecorder.hasPermission()) {
      setState(() => _status = 'Microphone permission was not granted.');
      return;
    }

    _photoTriggered = false;
    _isCapturingPhoto = false;
    
    // Pre-initialize camera to avoid delay when photo is triggered
    try {
      await _initializeCamera();
    } catch (error) {
      setState(() => _status = 'Failed to initialize camera: $error');
      return;
    }
    
    try {
      _audioSubscription?.cancel();
      final stream = await _audioRecorder.startStream(_recordConfig);
      _audioSubscription = stream.listen((Uint8List event) {
        if (_photoTriggered || _isCapturingPhoto) return;
        _processIncomingChunk(event);
      });

      setState(() {
        _isListening = true;
        _microphoneLevel = 0.0;
        _status = 'Listening for your reference sound...';
      });
    } catch (error) {
      setState(() => _status = 'Unable to start live listening: $error');
      await _disposeCamera();
    }
  }

  Future<void> _stopAudioStream() async {
    if (_audioSubscription != null) {
      await _audioSubscription!.cancel();
      _audioSubscription = null;
    }
    await _audioRecorder.stop();
  }

  Future<void> _playReferenceSound() async {
    if (!_hasReference || _referenceSamples.isEmpty) {
      setState(() => _status = 'No reference sound to play yet.');
      return;
    }

    if (_isPlayingReference) {
      await _audioPlayer.stop();
      setState(() => _isPlayingReference = false);
      return;
    }

    try {
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/reference_sound.wav';
      final file = File(path);
      await file.writeAsBytes(await _encodeWav(_referenceSamples));
      await _audioPlayer.setFilePath(path);
      await _audioPlayer.play();
      setState(() => _isPlayingReference = true);
    } catch (error) {
      setState(() => _status = 'Could not play reference sound: $error');
    }
  }

  Future<void> _saveReferenceToFile() async {
    if (_referenceSamples.isEmpty) {
      setState(() => _status = 'No reference to save.');
      return;
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/reference.wav';
      final file = File(path);
      await file.writeAsBytes(await _encodeWav(_referenceSamples));
      setState(() => _status = 'Reference saved to ${file.path}');
    } catch (error) {
      setState(() => _status = 'Failed to save reference: $error');
    }
  }

  Future<void> _loadReferenceFromFile() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final path = '${dir.path}/reference.wav';
      final file = File(path);
      if (!await file.exists()) {
        setState(() => _status = 'No saved reference found at ${file.path}');
        return;
      }

      final bytes = await file.readAsBytes();
      final samples = _decodeWavToSamples(bytes);
      if (samples.isEmpty) {
        setState(() => _status = 'No PCM data found in WAV file.');
        return;
      }

      _referenceSamples.clear();
      _referenceSamples.addAll(samples);
      _hasReference = true;
      await _saveReference();
      setState(() => _status = 'Reference loaded from ${file.path}');
    } catch (error) {
      setState(() => _status = 'Failed to load reference: $error');
    }
  }

  Future<List<int>> _encodeWav(List<double> samples) async {
    const sampleRate = 44100;
    const blockAlign = 2;
    final sampleCount = samples.length;
    final byteRate = sampleRate * blockAlign;
    final dataSize = sampleCount * 2;
    final buffer = BytesBuilder();

    void writeUint32(int value) {
      buffer.addByte(value & 0xff);
      buffer.addByte((value >> 8) & 0xff);
      buffer.addByte((value >> 16) & 0xff);
      buffer.addByte((value >> 24) & 0xff);
    }

    void writeUint16(int value) {
      buffer.addByte(value & 0xff);
      buffer.addByte((value >> 8) & 0xff);
    }

    buffer.add(utf8.encode('RIFF'));
    writeUint32(36 + dataSize);
    buffer.add(utf8.encode('WAVE'));
    buffer.add(utf8.encode('fmt '));
    writeUint32(16);
    writeUint16(1);
    writeUint16(1);
    writeUint32(44100);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(16);
    buffer.add(utf8.encode('data'));
    writeUint32(dataSize);

    for (final sample in samples) {
      final value = (sample.clamp(-1.0, 1.0) * 32767).round();
      writeUint16(value < 0 ? value + 65536 : value);
    }

    return buffer.takeBytes();
  }

  List<double> _decodeWavToSamples(Uint8List bytes) {
    // Find the 'data' chunk
    final dataTag = utf8.encode('data');
    int dataIndex = -1;
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == dataTag[0] && bytes[i + 1] == dataTag[1] && bytes[i + 2] == dataTag[2] && bytes[i + 3] == dataTag[3]) {
        dataIndex = i + 4;
        break;
      }
    }

    if (dataIndex < 0 || dataIndex + 4 > bytes.length) return <double>[];

    final byteData = ByteData.sublistView(bytes);
    final dataSize = byteData.getUint32(dataIndex, Endian.little);
    final dataStart = dataIndex + 4;
    final dataEnd = min(bytes.length, dataStart + dataSize);
    if (dataStart >= dataEnd) return <double>[];

    final audioBytes = bytes.sublist(dataStart, dataEnd);
    return pcm16ToDoubles(Uint8List.fromList(audioBytes));
  }

  void _processIncomingChunk(Uint8List bytes) {
    final chunkSamples = pcm16ToDoubles(bytes);
    _liveSamples.addAll(chunkSamples);

    final chunkPeak = chunkSamples.fold<double>(0.0, (current, sample) => max(current, sample.abs()));
    if (mounted) {
      setState(() {
        _microphoneLevel = max(_microphoneLevel * 0.65, chunkPeak);
      });
    }

    while (_liveSamples.length > _referenceSamples.length * 2) {
      _liveSamples.removeAt(0);
    }

    if (_referenceSamples.isEmpty || _liveSamples.length < 1000) {
      return;
    }

    final similarity = _recognitionMode == RecognitionMode.better
      ? bestSimilarityScore(_referenceSamples, _liveSamples, stepOverride: 1)
      : bestSimilarityScore(_referenceSamples, _liveSamples);
    if (similarity >= _triggerThreshold) {
      _photoTriggered = true;
      _isCapturingPhoto = true;
      _flashActive = true;
      _flashTimer?.cancel();
      _flashTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted) {
          setState(() => _flashActive = false);
        }
      });
      if (mounted) {
        setState(() => _status = 'Match detected. Taking photo...');
      }
      unawaited(_triggerPhoto());
    }
  }

  Future<void> _takePhoto({String reason = 'manual'}) async {
    if (_cameraLaunchInProgress) {
      return;
    }

    _cameraLaunchInProgress = true;
    if (mounted) {
      setState(() => _status = reason == 'trigger' ? 'Match detected. Taking photo...' : 'Taking photo...');
    }

    try {
      final cameraPermission = await Permission.camera.status;
      if (!cameraPermission.isGranted) {
        final requested = await Permission.camera.request();
        if (!requested.isGranted) {
          if (!mounted) return;
          setState(() => _status = 'Camera permission was not granted.');
          return;
        }
      }

      // Only initialize camera if not already initialized (during listening)
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        await _initializeCamera();
      }
      if (_cameraController == null || !_cameraController!.value.isInitialized) {
        throw Exception('Camera initialization failed.');
      }

      final photo = await _cameraController!.takePicture();
      if (!mounted) return;
      final saved = await _saveCapturedPhoto(photo.path);
      if (!mounted) return;
      setState(() {
        _lastSavedPhotoPath = saved.path;
        _status = 'Photo saved to ${saved.path}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'Could not capture photo: $error');
    } finally {
      _photoTriggered = false;
      _isCapturingPhoto = false;
      // Only dispose camera if we're not listening
      if (!_isListening) {
        await _disposeCamera();
      }
      if (mounted) {
        setState(() => _cameraLaunchInProgress = false);
      }
    }
  }

  Future<void> _manualTrigger() async {
    if (_cameraLaunchInProgress) {
      return;
    }

    await _takePhoto(reason: 'manual');
  }

  Future<void> _triggerPhoto() async {
    if (_cameraLaunchInProgress) {
      return;
    }

    setState(() {
      _isListening = false;
      _photoTriggered = true;
      _isCapturingPhoto = true;
    });

    await _stopAudioStream();
    await _takePhoto(reason: 'trigger');
  }

  Future<void> _initializeCamera() async {
    if (_cameraController != null && _cameraController!.value.isInitialized) {
      return;
    }

    _availableCameras = await availableCameras();
    if (_availableCameras.isEmpty) {
      throw Exception('No cameras available.');
    }

    final camera = _availableCameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _availableCameras.first,
    );

    _cameraController = CameraController(camera, ResolutionPreset.medium, enableAudio: false);
    await _cameraController!.initialize();
  }

  Future<void> _disposeCamera() async {
    _cameraController?.dispose();
    _cameraController = null;
  }

  Future<Directory> _photoDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final batboxDir = Directory('${dir.path}${Platform.pathSeparator}batbox');
    if (!await batboxDir.exists()) {
      await batboxDir.create(recursive: true);
    }
    return batboxDir;
  }

  Future<File> _saveCapturedPhoto(String sourcePath) async {
    final photoDir = await _photoDirectory();
    final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final destination = File('${photoDir.path}${Platform.pathSeparator}batbox-$timestamp.jpg');
    return File(sourcePath).copy(destination.path);
  }

  void _showInstructions() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Instructions'),
        content: const SingleChildScrollView(
          child: Text(
            'Record a short sound, then switch to listening mode. The app will listen for a close match and take a photo automatically when it hears the reference sound.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BatBox',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(title: const Text('BatBox')),
        body: Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              color: _flashActive ? Colors.black.withValues(alpha: 0.85) : Colors.transparent,
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text(
                      'Listen for your reference sound and trigger a photo',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _showInstructions,
                      icon: const Icon(Icons.help_outline),
                      label: const Text('Instructions'),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        const Text('Recognition mode:'),
                        DropdownButton<RecognitionMode>(
                          value: _recognitionMode,
                          items: const [
                            DropdownMenuItem(value: RecognitionMode.standard, child: Text('Standard')),
                            DropdownMenuItem(value: RecognitionMode.better, child: Text('Better')),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() => _recognitionMode = v);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.icon(
                          onPressed: _saveReferenceToFile,
                          icon: const Icon(Icons.save),
                          label: const Text('Save reference'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _loadReferenceFromFile,
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Load reference'),
                        ),
                      ],
                    ),
                    FilledButton.icon(
                      onPressed: _toggleReferenceRecording,
                      icon: Icon(_isRecordingReference ? Icons.stop : Icons.mic),
                      label: Text(_isRecordingReference ? 'Stop recording reference' : 'Record reference'),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _toggleListening,
                      icon: Icon(_isListening ? Icons.stop_circle : Icons.sensors),
                      label: Text(_isListening ? 'Stop listening' : 'Start listening'),
                    ),
                    const SizedBox(height: 24),
                    if (_hasReference)
                      FilledButton.icon(
                        onPressed: _playReferenceSound,
                        icon: Icon(_isPlayingReference ? Icons.stop : Icons.play_arrow),
                        label: Text(_isPlayingReference ? 'Stop playback' : 'Play reference sound'),
                      ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _manualTrigger,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('Take photo manually'),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _status,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16),
                    ),
                    if (_lastSavedPhotoPath.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Last saved image:\n$_lastSavedPhotoPath',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                    const SizedBox(height: 12),
                    if (_isListening)
                      Column(
                        children: [
                          Text(
                            'Microphone level: ${(_microphoneLevel * 100).clamp(0.0, 100.0).round()}%',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            width: 220,
                            child: LinearProgressIndicator(
                              value: _microphoneLevel.clamp(0.0, 1.0),
                              minHeight: 10,
                            ),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      'Reference captured: ${_hasReference ? _referenceSamples.length : 0} samples',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

double similarityScore(List<double> reference, List<double> candidate) {
  if (reference.isEmpty || candidate.isEmpty) return 0.0;

  final length = min(reference.length, candidate.length);
  final ref = reference.sublist(0, length);
  final cand = candidate.sublist(0, length);

  double dotProduct = 0.0;
  double refNorm = 0.0;
  double candNorm = 0.0;

  for (var i = 0; i < length; i++) {
    dotProduct += ref[i] * cand[i];
    refNorm += ref[i] * ref[i];
    candNorm += cand[i] * cand[i];
  }

  if (refNorm == 0 || candNorm == 0) return 0.0;
  return dotProduct / (sqrt(refNorm * candNorm));
}

double bestSimilarityScore(List<double> reference, List<double> liveSamples, {int? stepOverride}) {
  if (reference.isEmpty || liveSamples.isEmpty) return 0.0;

  final targetLength = min(reference.length, liveSamples.length);
  if (targetLength < 10) return similarityScore(reference, liveSamples);
  final step = stepOverride ?? max(1, targetLength ~/ 8);
  var bestScore = 0.0;

  for (var start = 0; start <= liveSamples.length - targetLength; start += step) {
    final window = liveSamples.sublist(start, start + targetLength);
    final score = similarityScore(reference, window);
    if (score > bestScore) {
      bestScore = score;
    }
  }

  return bestScore;
}

List<double> pcm16ToDoubles(Uint8List bytes) {
  final samples = <double>[];
  final byteData = ByteData.sublistView(bytes);
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    final sample = byteData.getInt16(i, Endian.little);
    samples.add(sample / 32768.0);
  }
  return samples;
}
