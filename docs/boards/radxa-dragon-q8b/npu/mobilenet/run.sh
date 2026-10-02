#!/bin/sh
# run.sh BACKEND DLC LAYOUT OUT [extra qnn-net-run args]: run the eval list.
b=$1 dlc=$2 l=$3 out=$4; shift 4
sed "s|^\(.*\)\.JPEG$|raw_$l/\1.raw|" eval.txt > eval_$l.txt
rm -rf $out
qnn qnn-net-run --backend /usr/local/qnn/lib/libQnn$b.so \
    --model /usr/local/qnn/lib/libQnnModelDlc.so --dlc_path $dlc \
    --input_list eval_$l.txt --output_dir $out "$@" > $out.log 2>&1
echo "$out: rc=$?"
/usr/local/qnn/python/bin/python3.12 score.py $out eval.txt
