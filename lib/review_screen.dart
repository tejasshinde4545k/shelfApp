import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';

import 'detection.dart';
import 'detector_service.dart';
import 'overlay_painter.dart';

/// Shown after a photo is captured: Retake / Process / Save.
class ReviewScreen extends StatefulWidget {
  final String path;
  const ReviewScreen({super.key, required this.path});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final ValueNotifier<DetectionResult?> _res = ValueNotifier(null);
  bool _busy = false;

  Future<void> _process() async {
    setState(() => _busy = true);
    try {
      _res.value = await DetectorService.instance.detectFile(widget.path);
    } catch (e) {
      _toast('Processing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    try {
      await Gal.putImage(widget.path);
      _toast('Saved to gallery');
    } catch (e) {
      _toast('Saved at ${widget.path}');
    }
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
    _res.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _res.value;
    Widget image = Image.file(File(widget.path), fit: BoxFit.contain);
    if (r != null && r.imageW > 0) {
      image = Center(
        child: AspectRatio(
          aspectRatio: r.imageW / r.imageH,
          child: Stack(fit: StackFit.expand, children: [
            Image.file(File(widget.path), fit: BoxFit.fill),
            CustomPaint(painter: DetectionPainter(_res)),
          ]),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(r == null
            ? 'Review photo'
            : '${r.shelves.length} shelves • ${r.productCount} products • ${r.emptyCount} empty'),
      ),
      body: Column(children: [
        Expanded(child: _busy ? const Center(child: CircularProgressIndicator()) : image),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              OutlinedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.replay),
                  label: const Text('Retake')),
              FilledButton.icon(
                  onPressed: _busy ? null : _process,
                  icon: const Icon(Icons.auto_awesome),
                  label: const Text('Process')),
              OutlinedButton.icon(
                  onPressed: _save, icon: const Icon(Icons.save_alt), label: const Text('Save')),
            ]),
          ),
        ),
      ]),
    );
  }
}
