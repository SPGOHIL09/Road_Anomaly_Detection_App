"""Export best.pt to the GPU TFLite model used by the app on Android.

    assets/models/best.pt  ->  assets/models/best_gpu_fp16.tflite

Why each step (measured on a Pixel 9, YOLO11s 640x640):
  * ONNX Runtime CPU (4 threads): ~215 ms/frame idle, ~550 ms while 4K decodes.
  * LiteRT GPU delegate, FP16:     ~35-50 ms/frame, unaffected by 4K decode.
  * The GPU delegate computes YOLO11's C2PSA attention block (model.10)
    wrongly when it is converted with 4-D BatchMatMul; recall dropped ~15%.
    `enable_batchmatmul_unfold=True` splits it into per-head MatMuls and the
    GPU output then matches the CPU (F1 0.588 vs 0.594 on 60 labelled images).
  * onnx2tf normally downloads a pickled sample-image .npy from the internet;
    this script passes local road images instead (nothing is downloaded or
    unpickled).

Requirements (separate virtualenvs avoid a torch/litert conflict):
  env A: pip install ultralytics onnx onnxslim
  env B: pip install "tensorflow==2.19.*" tf_keras onnx2tf onnx onnx_graphsurgeon \
         sng4onnx psutil ai_edge_litert onnxruntime "numpy<2.2" pillow

Usage:
  envA/bin/python tool/export_gpu_model.py onnx  <best.pt> <out.onnx>
  envB/bin/python tool/export_gpu_model.py tflite <in.onnx> <out_dir> <images_dir>
The FP16 file is <out_dir>/<name>_float16.tflite.
"""
import glob
import os
import random
import shutil
import sys

SIZE = 640


def export_onnx(pt, out):
    from ultralytics import YOLO

    path = YOLO(pt).export(format="onnx", imgsz=SIZE, opset=17, simplify=True)
    shutil.move(path, out)
    print("wrote", out)


def export_tflite(onnx_path, out_dir, images_dir):
    import numpy as np
    from PIL import Image
    import onnx2tf.onnx2tf as o2t
    import onnx2tf.utils.common_functions as cf

    imgs = sorted(glob.glob(os.path.join(images_dir, "*.jpg")))
    random.Random(0).shuffle(imgs)
    sample = np.stack(
        [np.asarray(Image.open(p).convert("RGB").resize((SIZE, SIZE)), np.float32) / 255.0 for p in imgs[:20]]
    )
    cf.download_test_image_data = lambda: sample
    o2t.download_test_image_data = lambda: sample
    o2t.convert(
        input_onnx_file_path=onnx_path,
        output_folder_path=out_dir,
        non_verbose=True,
        output_signaturedefs=True,
        enable_batchmatmul_unfold=True,
    )


if __name__ == "__main__":
    if sys.argv[1] == "onnx":
        export_onnx(sys.argv[2], sys.argv[3])
    elif sys.argv[1] == "tflite":
        export_tflite(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        sys.exit(__doc__)
