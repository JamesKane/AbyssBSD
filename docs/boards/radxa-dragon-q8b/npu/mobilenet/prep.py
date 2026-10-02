# Preprocess ImageNet JPEGs for MobileNetV2 (ONNX model zoo): resize 256,
# centre crop 224, scale to [0,1], normalise, float32, NCHW and NHWC raws.
import sys, numpy as np
from PIL import Image
mean = np.array([0.485, 0.456, 0.406], np.float32)
std = np.array([0.229, 0.224, 0.225], np.float32)
for name in sys.argv[1:]:
    im = Image.open("img/" + name).convert("RGB")
    w, h = im.size
    s = 256 / min(w, h)
    im = im.resize((round(w * s), round(h * s)), Image.BILINEAR)
    w, h = im.size
    l, t = (w - 224) // 2, (h - 224) // 2
    im = im.crop((l, t, l + 224, t + 224))
    a = (np.asarray(im, np.float32) / 255 - mean) / std      # HWC
    base = name.rsplit(".", 1)[0]
    a.astype(np.float32).tofile("raw_nhwc/" + base + ".raw")
    a.transpose(2, 0, 1).astype(np.float32).tofile("raw_nchw/" + base + ".raw")
