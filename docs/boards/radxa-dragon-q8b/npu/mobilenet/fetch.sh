#!/bin/sh
# Fetch MobileNetV2 (ONNX model zoo), ImageNet's class index, and sample
# images (one per class, github.com/EliSchwartz/imagenet-sample-images):
# every tenth class to evaluate (eval.txt), twenty others to calibrate
# (calib.txt).
set -e
fetch -qo mobilenetv2-12.onnx \
    https://github.com/onnx/models/raw/main/validated/vision/classification/mobilenet/model/mobilenetv2-12.onnx
fetch -qo imagenet_class_index.json \
    https://storage.googleapis.com/download.tensorflow.org/data/imagenet_class_index.json
fetch -qo - https://api.github.com/repos/EliSchwartz/imagenet-sample-images/contents |
    /usr/local/qnn/python/bin/python3.12 -c '
import json, sys
fs = sorted(f["name"] for f in json.load(sys.stdin) if f["name"].endswith(".JPEG"))
open("eval.txt", "w").write("\n".join(fs[0::10][:100]) + "\n")
open("calib.txt", "w").write("\n".join(fs[5::50][:20]) + "\n")'
mkdir -p img raw_nchw raw_nhwc
for f in $(cat eval.txt calib.txt); do
	fetch -qo img/$f \
	    https://raw.githubusercontent.com/EliSchwartz/imagenet-sample-images/master/$f
done
/usr/local/qnn/python/bin/python3.12 prep.py $(cat eval.txt calib.txt)
