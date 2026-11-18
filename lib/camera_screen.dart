import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

import 'detection.dart';
import 'detector_service.dart';
import 'overlay_painter.dart';
import 'review_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _svc = DetectorService.instance;
  final ValueNotifier<DetectionResult?> _result = ValueNotifier(null);
  CameraController? _cam;
  List<ShelfRegion> _shelves = const [];
  bool _detecting = true, _recording = false, _labels = true, _paused = false;
  int _frame = 0, _lastTs = 0;
  double _fps = 0;
  String? _error;
  bool _initializing = false; // guards against concurrent _init (permission dialog!)

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    if (_initializing || _cam != null) return;
    _initializing = true;
    try {
      await _svc.start();
      final cams = await availableCameras();
      final cam = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      final c = CameraController(cam, ResolutionPreset.high,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.yuv420);
      await c.initialize();
      await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await c.startImageStream(_onFrame);
      if (!mounted) return;
      setState(() => _cam = c);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera/model init failed:\n$e');
    } finally {
      _initializing = false;
    }
  }

  void _onFrame(CameraImage img) {
    final cam = _cam;
    if (cam == null || !_detecting || _paused || _svc.busy) return;
    final runShelf = (_frame++ % 4) == 0; // shelf rows are slower-changing
    _svc
        .detectFrame(img, cam.description.sensorOrientation, runShelf: runShelf)
        .then((r) {
      if (r == null || !mounted) return;
      if (r.shelvesFresh) _shelves = r.shelves;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_lastTs != 0) {
        final inst = 1000 / (now - _lastTs).clamp(1, 100000);
        _fps = _fps == 0 ? inst : _fps * 0.8 + inst * 0.2;
      }
      _lastTs = now;
      _result.value = r.withShelves(_shelves);
    }).catchError((e) {
      debugPrint('detect error: $e');
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (_initializing) return; // permission dialog / startup: ignore
    if (s == AppLifecycleState.paused) {
      final c = _cam;
      if (c == null) return;
      _cam = null;
      if (mounted) setState(() {});
      () async {
        try {
          if (c.value.isStreamingImages) await c.stopImageStream();
        } catch (_) {}
        await c.dispose();
      }();
    } else if (s == AppLifecycleState.resumed && _cam == null) {
      _init();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cam?.dispose();
    _result.dispose();
    super.dispose();
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _capture() async {
    final c = _cam;
    if (c == null || c.value.isTakingPicture) return;
    try {
      final f = await c.takePicture();
      _paused = true;
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ReviewScreen(path: f.path)));
    } catch (e) {
      _toast('Capture failed: $e');
    } finally {
      _paused = false;
    }
  }

  Future<void> _toggleRecord() async {
    final c = _cam;
    if (c == null) return;
    try {
      if (!_recording) {
        await c.startVideoRecording();
        setState(() => _recording = true);
      } else {
        final f = await c.stopVideoRecording();
        setState(() => _recording = false);
        try {
          await Gal.putVideo(f.path);
          _toast('Video saved to gallery');
        } catch (_) {
          _toast('Video saved: ${f.path}');
        }
      }
    } catch (e) {
      setState(() => _recording = false);
      _toast('Recording error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!))));
    }
    final c = _cam;
    if (c == null || !c.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1 / c.value.aspectRatio, // portrait
                child: Stack(fit: StackFit.expand, children: [
                  CameraPreview(c),
                  IgnorePointer(
                    child: CustomPaint(painter: DetectionPainter(_result, showLabels: _labels)),
                  ),
                  Positioned(left: 8, top: 8, child: _stats()),
                  if (_recording)
                    const Positioned(
                      right: 12,
                      top: 12,
                      child: Row(children: [
                        Icon(Icons.fiber_manual_record, color: Colors.red, size: 16),
                        SizedBox(width: 4),
                        Text('REC', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                      ]),
                    ),
                ]),
              ),
            ),
          ),
          _controls(),
        ]),
      ),
    );
  }

  Widget _stats() => ValueListenableBuilder<DetectionResult?>(
        valueListenable: _result,
        builder: (_, r, __) => Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
          child: DefaultTextStyle(
            style: const TextStyle(color: Colors.white, fontSize: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${_fps.toStringAsFixed(1)} FPS  •  ${r?.inferenceMs ?? 0} ms'),
              Text('Shelves: ${r?.shelves.length ?? 0}'),
              Text('Products: ${r?.productCount ?? 0}', style: const TextStyle(color: kProductColor)),
              Text('Empty: ${r?.emptyCount ?? 0}', style: const TextStyle(color: kEmptyColor)),
            ]),
          ),
        ),
      );

  Widget _controls() => Container(
        color: Colors.black,
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          IconButton(
            tooltip: 'Detection on/off',
            icon: Icon(_detecting ? Icons.visibility : Icons.visibility_off,
                color: _detecting ? kProductColor : Colors.white54),
            onPressed: () => setState(() {
              _detecting = !_detecting;
              if (!_detecting) _result.value = null;
            }),
          ),
          IconButton(
            tooltip: 'Labels on/off',
            icon: Icon(Icons.label, color: _labels ? Colors.white : Colors.white38),
            onPressed: () => setState(() => _labels = !_labels),
          ),
          GestureDetector(
            onTap: _capture,
            child: Container(
              width: 70,
              height: 70,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
              child: const Padding(
                  padding: EdgeInsets.all(5),
                  child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
            ),
          ),
          IconButton(
            tooltip: _recording ? 'Stop recording' : 'Record video',
            iconSize: 34,
            icon: Icon(_recording ? Icons.stop_circle : Icons.videocam,
                color: _recording ? Colors.red : Colors.white),
            onPressed: _toggleRecord,
          ),
        ]),
      );
}