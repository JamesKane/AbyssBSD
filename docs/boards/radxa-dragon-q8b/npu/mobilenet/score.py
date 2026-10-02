# Top-1/top-5 of qnn-net-run outputs (Result_N/*.raw, 1000 scores) against
# the ImageNet class the image's name gives: score.py OUTDIR LIST
import glob, json, os, sys, numpy as np
out, lst = sys.argv[1], sys.argv[2]
idx = json.load(open("imagenet_class_index.json"))
syn = {v[0]: int(k) for k, v in idx.items()}
names = [l.split()[0] for l in open(lst) if l.strip()]
t1 = t5 = 0
preds = []
for i, n in enumerate(names):
    f = glob.glob(f"{out}/Result_{i}/*.raw")[0]
    s = np.fromfile(f, np.float32)
    want = syn[os.path.basename(n).split("_")[0]]
    top = np.argsort(s)[::-1][:5]
    t1 += top[0] == want
    t5 += want in top
    preds.append(int(top[0]))
print(f"{out}: {len(names)} images, top-1 {t1}/{len(names)}, top-5 {t5}/{len(names)}")
json.dump(preds, open(f"{out}/preds.json", "w"))
