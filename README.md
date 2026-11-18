# Shelf Vision – Real-Time Supermarket Shelf & Product Detection (Flutter + TensorFlow Lite)

Shelf Vision is a Flutter app that uses YOLO and TensorFlow Lite for on-device inference, combining shelf segmentation with product detection in a live camera view.

## Screenshots

- Live detection: `docs/screenshot_live.png`
- Demo: `docs/demo.gif`

## Features

- Live camera preview
- Shelf row masks in blue
- Product boxes in green
- Empty-space boxes in red
- Detection labels with confidence scores
- FPS and inference-latency overlay
- Photo capture
- Video recording
- Retake, process, and save captured photos

## How it works

Camera frames are received as a YUV stream and processed in a background isolate. Each frame is rotated and letterboxed to `640x640`, converted to RGB float32 values in the `0-1` range, and passed to the TensorFlow Lite models. Outputs are decoded, filtered with NMS, and rendered with a `CustomPainter` overlay.

The product model runs on every processed frame. The shelf segmentation model runs on every fourth frame because shelf rows change more slowly.

```text
Camera YUV stream
        |
        v
Background isolate
  rotate + letterbox
     to 640x640
        |
        v
  +-------------------+
  | Product detector  |----> decode + NMS ----> green/red boxes
  +-------------------+
        |
  +-------------------+
  | Shelf segmentation|----> decode masks ----> blue row masks
  +-------------------+
        |
        v
 CustomPainter overlay
```

## Models

| Model | Task | Classes | Output |
| --- | --- | --- | --- |
| `detect_product_empty_space.tflite` | Detect | `0 empty`, `1 product` | `[1, 6, 8400]` |
| `segment_shelf_rows.tflite` | Segment | `0 row` | Detections `[1, 37, 8400]` plus protos `[1, 32, 160, 160]` |

Both models use the same input tensor: `[1, 3, 640, 640]`, float32 RGB values normalized to `0-1`.

## Build

Install Flutter and Android SDK tooling, then run:

```bash
flutter pub get
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

## Project structure

```text
lib/
├── main.dart                 # App entry point and theme
├── camera_screen.dart        # Camera preview, controls, and live inference
├── detection.dart            # Detection and shelf result models
├── detector_service.dart     # TFLite model lifecycle and frame processing
├── detector_worker.dart      # Background image preprocessing and inference
├── overlay_painter.dart      # Shelf and detection overlay rendering
└── review_screen.dart        # Captured photo review, processing, and saving
```

The model files are stored in `assets/models/`.

## Troubleshooting

- The camera permission dialog appears on the first launch. Allow camera access for live detection.
- If the app does not show the camera preview, verify that the device has a rear camera and that camera permission is enabled in Android settings.
- If a release APK is not found, run `flutter build apk --release` from the repository root and check `build/app/outputs/flutter-apk/`.

## License

MIT
