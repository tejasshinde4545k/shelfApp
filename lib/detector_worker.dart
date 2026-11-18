// Runs in a background isolate: pre-processing, both TFLite models, decoding.
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

const int kSize = 640; // model input (square, letterboxed)
const int kPlane = kSize * kSize;
const int kAnchors = 8400; // 80*80 + 40*40 + 20*20
const int kProto = 160; // mask prototype grid
const double kProductThr = 0.35;
const double kShelfThr = 0.25;
const int kMaxCandidates = 400;
const int kMaxShelves = 8;

class _Geo {
  final int uw, uh, newW, newH, padX, padY;
  final double scale;
  _Geo._(this.uw, this.uh, this.newW, this.newH, this.padX, this.padY, this.scale);
  factory _Geo(int uw, int uh) {
    final s = kSize / math.max(uw, uh);
    final nw = math.max(1, (uw * s).round());
    final nh = math.max(1, (uh * s).round());
    return _Geo._(uw, uh, nw, nh, (kSize - nw) ~/ 2, (kSize - nh) ~/ 2, s);
  }
  double nx(double x) => (((x - padX) / scale) / uw).clamp(0.0, 1.0);
  double ny(double y) => (((y - padY) / scale) / uh).clamp(0.0, 1.0);
}

class _Cand {
  final double x1, y1, x2, y2, conf;
  final int cls, idx;
  _Cand(this.x1, this.y1, this.x2, this.y2, this.conf, this.cls, this.idx);
}

double _iou(_Cand a, _Cand b) {
  final ix = math.max(0.0, math.min(a.x2, b.x2) - math.max(a.x1, b.x1));
  final iy = math.max(0.0, math.min(a.y2, b.y2) - math.max(a.y1, b.y1));
  final inter = ix * iy;
  final u = (a.x2 - a.x1) * (a.y2 - a.y1) + (b.x2 - b.x1) * (b.y2 - b.y1) - inter;
  return u <= 0 ? 0 : inter / u;
}

List<_Cand> _nms(List<_Cand> c, double thr) {
  c.sort((a, b) => b.conf.compareTo(a.conf));
  if (c.length > kMaxCandidates) c.removeRange(kMaxCandidates, c.length);
  final keep = <_Cand>[];
  for (final d in c) {
    bool ok = true;
    for (final k in keep) {
      if (k.cls == d.cls && _iou(k, d) > thr) {
        ok = false;
        break;
      }
    }
    if (ok) keep.add(d);
  }
  return keep;
}

// ---- pre-processing --------------------------------------------------------

void _fill(Float32List buf, _Geo g, int Function(int ux, int uy) sample) {
  buf.fillRange(0, buf.length, 114 / 255.0);
  final inv = 1.0 / g.scale;
  for (int cy = 0; cy < g.newH; cy++) {
    int uy = ((cy + 0.5) * inv).floor();
    if (uy >= g.uh) uy = g.uh - 1;
    final row = (cy + g.padY) * kSize + g.padX;
    for (int cx = 0; cx < g.newW; cx++) {
      int ux = ((cx + 0.5) * inv).floor();
      if (ux >= g.uw) ux = g.uw - 1;
      final p = sample(ux, uy);
      final i = row + cx;
      buf[i] = ((p >> 16) & 255) / 255.0;
      buf[kPlane + i] = ((p >> 8) & 255) / 255.0;
      buf[2 * kPlane + i] = (p & 255) / 255.0;
    }
  }
}

/// Sampler over an Android YUV_420_888 frame, rotated to upright by [rot].
int Function(int, int) _yuvSampler(Map m, int rot) {
  final y = (m['y'] as TransferableTypedData).materialize().asUint8List();
  final u = (m['u'] as TransferableTypedData).materialize().asUint8List();
  final v = (m['v'] as TransferableTypedData).materialize().asUint8List();
  final w = m['w'] as int, h = m['h'] as int;
  final yRow = m['yRow'] as int, uvRow = m['uvRow'] as int, uvPix = m['uvPix'] as int;
  return (int ux, int uy) {
    int sx, sy;
    switch (rot) {
      case 90:
        sx = uy;
        sy = h - 1 - ux;
        break;
      case 180:
        sx = w - 1 - ux;
        sy = h - 1 - uy;
        break;
      case 270:
        sx = w - 1 - uy;
        sy = ux;
        break;
      default:
        sx = ux;
        sy = uy;
    }
    final yy = y[sy * yRow + sx];
    final ui = (sy >> 1) * uvRow + (sx >> 1) * uvPix;
    final uu = u[ui] - 128, vv = v[ui] - 128;
    int r = (yy + 1.402 * vv).round();
    int g = (yy - 0.344136 * uu - 0.714136 * vv).round();
    int b = (yy + 1.772 * uu).round();
    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);
    return (r << 16) | (g << 8) | b;
  };
}

// ---- decoding --------------------------------------------------------------

List<_Cand> _decodeProducts(Float32List o) {
  final c = <_Cand>[];
  for (int i = 0; i < kAnchors; i++) {
    final a = o[4 * kAnchors + i], b = o[5 * kAnchors + i];
    final cls = b > a ? 1 : 0;
    final s = cls == 1 ? b : a;
    if (s < kProductThr) continue;
    final cx = o[i] * kSize, cy = o[kAnchors + i] * kSize;
    final w = o[2 * kAnchors + i] * kSize, h = o[3 * kAnchors + i] * kSize;
    c.add(_Cand(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, s, cls, i));
  }
  return _nms(c, 0.5);
}

List<_Cand> _decodeShelves(Float32List o) {
  final c = <_Cand>[];
  for (int i = 0; i < kAnchors; i++) {
    final s = o[4 * kAnchors + i];
    if (s < kShelfThr) continue;
    final cx = o[i] * kSize, cy = o[kAnchors + i] * kSize;
    final w = o[2 * kAnchors + i] * kSize, h = o[3 * kAnchors + i] * kSize;
    c.add(_Cand(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2, s, 0, i));
  }
  final r = _nms(c, 0.7);
  return r.length > kMaxShelves ? r.sublist(0, kMaxShelves) : r;
}

/// Mask runs (flat x1,y1,x2,y2 normalised) for one shelf detection.
List<double> _maskRuns(_Cand d, Float32List det, Float32List proto, _Geo g) {
  const cell = kSize / kProto; // 4 px
  final gx1 = (d.x1 / cell).floor().clamp(0, kProto - 1);
  final gx2 = (d.x2 / cell).ceil().clamp(0, kProto);
  final gy1 = (d.y1 / cell).floor().clamp(0, kProto - 1);
  final gy2 = (d.y2 / cell).ceil().clamp(0, kProto);
  final coef = List<double>.generate(32, (k) => det[(5 + k) * kAnchors + d.idx]);
  final out = <double>[];
  for (int gy = gy1; gy < gy2; gy++) {
    int start = -1;
    for (int gx = gx1; gx <= gx2; gx++) {
      bool on = false;
      if (gx < gx2) {
        double s = 0;
        final off = gy * kProto + gx;
        for (int k = 0; k < 32; k++) {
          s += coef[k] * proto[k * kProto * kProto + off];
        }
        on = s > 0; // sigmoid(s) > 0.5
      }
      if (on && start < 0) start = gx;
      if (!on && start >= 0) {
        out.addAll([
          g.nx(start * cell),
          g.ny(gy * cell),
          g.nx(gx * cell),
          g.ny((gy + 1) * cell),
        ]);
        start = -1;
      }
    }
  }
  return out;
}

Float32List _outF32(Interpreter it, int idx) {
  final b = Uint8List.fromList(it.getOutputTensor(idx).data);
  return b.buffer.asFloat32List();
}

// ---- isolate entry ---------------------------------------------------------

void detectorEntry(List<Object> args) {
  final SendPort main = args[0] as SendPort;
  Uint8List bytesOf(Object o) => (o as TransferableTypedData).materialize().asUint8List();
  InterpreterOptions opts() => InterpreterOptions()..threads = 4;
  late Interpreter prod;
  late Interpreter seg;
  late int protoIdx;
  late int detIdx;
  try {
    prod = Interpreter.fromBuffer(bytesOf(args[1]), options: opts());
    seg = Interpreter.fromBuffer(bytesOf(args[2]), options: opts());
    protoIdx = seg.getOutputTensor(0).shape.length == 4 ? 0 : 1;
    detIdx = 1 - protoIdx;
  } catch (e, st) {
    main.send({'startupError': 'Model initialization failed: $e\n$st'});
    return;
  }
  final input = Float32List(3 * kPlane);
  final inBytes = input.buffer.asUint8List();

  final rp = ReceivePort();
  main.send(rp.sendPort);

  rp.listen((dynamic raw) {
    final m = raw as Map;
    final id = m['id'];
    try {
      final sw = Stopwatch()..start();
      late _Geo geo;
      if (m['type'] == 'yuv') {
        final rot = m['rotation'] as int;
        final w = m['w'] as int, h = m['h'] as int;
        geo = rot % 180 == 0 ? _Geo(w, h) : _Geo(h, w);
        _fill(input, geo, _yuvSampler(m, rot));
      } else {
        var image = img.decodeImage(File(m['path'] as String).readAsBytesSync());
        if (image == null) throw Exception('cannot decode image');
        image = img.bakeOrientation(image);
        if (math.max(image.width, image.height) > 1600) {
          image = image.width >= image.height
              ? img.copyResize(image, width: 1600)
              : img.copyResize(image, height: 1600);
        }
        final rgb = image.getBytes(order: img.ChannelOrder.rgb);
        final w = image.width;
        geo = _Geo(w, image.height);
        _fill(input, geo, (ux, uy) {
          final i = (uy * w + ux) * 3;
          return (rgb[i] << 16) | (rgb[i + 1] << 8) | rgb[i + 2];
        });
      }

      // products + empty space
      prod.getInputTensor(0).data = inBytes;
      prod.invoke();
      final pc = _decodeProducts(_outF32(prod, 0));
      final pf = Float32List(pc.length * 6);
      for (int i = 0; i < pc.length; i++) {
        final c = pc[i];
        pf[i * 6] = geo.nx(c.x1);
        pf[i * 6 + 1] = geo.ny(c.y1);
        pf[i * 6 + 2] = geo.nx(c.x2);
        pf[i * 6 + 3] = geo.ny(c.y2);
        pf[i * 6 + 4] = c.conf;
        pf[i * 6 + 5] = c.cls.toDouble();
      }

      // shelf rows (only when asked – it is the heavier model)
      final shelfBoxes = <double>[];
      final shelfRuns = <Float32List>[];
      final runShelf = m['runShelf'] as bool;
      if (runShelf) {
        seg.getInputTensor(0).data = inBytes;
        seg.invoke();
        final det = _outF32(seg, detIdx);
        final proto = _outF32(seg, protoIdx);
        for (final d in _decodeShelves(det)) {
          shelfBoxes.addAll([geo.nx(d.x1), geo.ny(d.y1), geo.nx(d.x2), geo.ny(d.y2), d.conf]);
          shelfRuns.add(Float32List.fromList(_maskRuns(d, det, proto, geo)));
        }
      }
      main.send({
        'id': id,
        'prod': pf,
        'shelfBoxes': Float32List.fromList(shelfBoxes),
        'shelfRuns': shelfRuns,
        'shelfRan': runShelf,
        'ms': sw.elapsedMilliseconds,
        'iw': geo.uw,
        'ih': geo.uh,
      });
    } catch (e, st) {
      main.send({'id': id, 'error': '$e\n$st'});
    }
  });
}
