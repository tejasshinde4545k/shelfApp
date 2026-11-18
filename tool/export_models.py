"""Re-create the bundled TFLite models from the supplied .pt files.
pip install ultralytics tensorflow onnx2tf litert-torch ai-edge-litert
"""
from ultralytics import YOLO
for m in ("detect_product_empty_space", "segment_shelf_rows"):
    YOLO(f"tool/{m}.pt").export(format="tflite", imgsz=640)   # -> *_saved_model/ or .tflite
