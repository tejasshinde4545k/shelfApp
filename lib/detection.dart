import 'dart:ui';

/// Class names of detect_product_empty_space.pt (index = class id).
const List<String> kProductLabels = ['empty', 'product'];

/// One product / empty-space box. [box] is normalised (0..1) in the upright image.
class Detection {
  final Rect box;
  final int cls;
  final double conf;
  const Detection(this.box, this.cls, this.conf);
  String get label => kProductLabels[cls];
}

/// One shelf row from segment_shelf_rows.pt. [runs] are the mask as small
/// normalised rectangles (horizontal runs) so it can be painted cheaply.
class ShelfRegion {
  final Rect box;
  final double conf;
  final List<Rect> runs;
  const ShelfRegion(this.box, this.conf, this.runs);
}

class DetectionResult {
  final List<Detection> products;
  final List<ShelfRegion> shelves;
  final bool shelvesFresh; // true when the shelf model ran for this frame
  final int inferenceMs;
  final int imageW, imageH; // upright image size used (for still images)

  const DetectionResult({
    required this.products,
    required this.shelves,
    required this.shelvesFresh,
    required this.inferenceMs,
    this.imageW = 0,
    this.imageH = 0,
  });

  int get productCount => products.where((d) => d.cls == 1).length;
  int get emptyCount => products.where((d) => d.cls == 0).length;

  DetectionResult withShelves(List<ShelfRegion> s) => DetectionResult(
        products: products,
        shelves: s,
        shelvesFresh: shelvesFresh,
        inferenceMs: inferenceMs,
        imageW: imageW,
        imageH: imageH,
      );
}
