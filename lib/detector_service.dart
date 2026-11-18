import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import 'detection.dart';
import 'detector_worker.dart';

/// Owns the background isolate that runs both TFLite models.
class DetectorService {
  DetectorService._();
  static final DetectorService instance = DetectorService._();

  SendPort? _send;
  final ReceivePort _rx = ReceivePort();
  final Map<int, Completer<DetectionResult>> _pending = {};
  int _nextId = 0;
  bool _busy = false;
  Future<void>? _starting;

  bool get busy => _busy;

  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    Future<TransferableTypedData> load(String a) async {
      final d = await rootBundle.load(a);
      return TransferableTypedData.fromList(
          [d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes)]);
    }

    final prod = await load('assets/models/detect_product_empty_space.tflite');
    final seg = await load('assets/models/segment_shelf_rows.tflite');
    final ready = Completer<SendPort>();
    _rx.listen((dynamic m) {
      if (m is SendPort) {
        if (!ready.isCompleted) ready.complete(m);
      } else if (m is Map) {
        if (m['startupError'] != null) {
          if (!ready.isCompleted) ready.completeError(m['startupError'] as String);
          return;
        }
        final c = _pending.remove(m['id']);
        if (c == null) return;
        if (m['error'] != null) {
          c.completeError(m['error'] as String);
        } else {
          c.complete(_parse(m));
        }
      }
    });
    await Isolate.spawn(detectorEntry, <Object>[_rx.sendPort, prod, seg]);
    _send = await ready.future;
  }

  DetectionResult _parse(Map m) {
    final pf = m['prod'] as Float32List;
    final products = <Detection>[
      for (int i = 0; i + 5 < pf.length; i += 6)
        Detection(Rect.fromLTRB(pf[i], pf[i + 1], pf[i + 2], pf[i + 3]),
            pf[i + 5].toInt(), pf[i + 4]),
    ];
    final sb = m['shelfBoxes'] as Float32List;
    final runs = (m['shelfRuns'] as List).cast<Float32List>();
    final shelves = <ShelfRegion>[];
    for (int s = 0; s * 5 < sb.length; s++) {
      final r = runs[s];
      shelves.add(ShelfRegion(
        Rect.fromLTRB(sb[s * 5], sb[s * 5 + 1], sb[s * 5 + 2], sb[s * 5 + 3]),
        sb[s * 5 + 4],
        [
          for (int i = 0; i + 3 < r.length; i += 4)
            Rect.fromLTRB(r[i], r[i + 1], r[i + 2], r[i + 3]),
        ],
      ));
    }
    return DetectionResult(
      products: products,
      shelves: shelves,
      shelvesFresh: m['shelfRan'] as bool,
      inferenceMs: m['ms'] as int,
      imageW: m['iw'] as int,
      imageH: m['ih'] as int,
    );
  }

  /// Returns null if the worker is still busy (frame is dropped).
  Future<DetectionResult?> detectFrame(CameraImage img, int rotation,
      {required bool runShelf}) async {
    if (_busy || _send == null || img.planes.length < 3) return null;
    _busy = true;
    try {
      final id = _nextId++;
      final c = Completer<DetectionResult>();
      _pending[id] = c;
      _send!.send({
        'id': id,
        'type': 'yuv',
        'w': img.width,
        'h': img.height,
        'rotation': rotation,
        'runShelf': runShelf,
        'y': TransferableTypedData.fromList([img.planes[0].bytes]),
        'u': TransferableTypedData.fromList([img.planes[1].bytes]),
        'v': TransferableTypedData.fromList([img.planes[2].bytes]),
        'yRow': img.planes[0].bytesPerRow,
        'uvRow': img.planes[1].bytesPerRow,
        'uvPix': img.planes[1].bytesPerPixel ?? 1,
      });
      return await c.future;
    } finally {
      _busy = false;
    }
  }

  /// Full detection (products + shelves) on a captured still image.
  Future<DetectionResult> detectFile(String path) async {
    await start();
    final id = _nextId++;
    final c = Completer<DetectionResult>();
    _pending[id] = c;
    _send!.send({'id': id, 'type': 'file', 'path': path, 'runShelf': true});
    return c.future;
  }
}
