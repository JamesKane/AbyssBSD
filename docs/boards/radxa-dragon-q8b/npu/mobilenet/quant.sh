#!/bin/sh
# Quantize mnv2.dlc to 8 bits (mnv2_q.dlc), calibrated on calib.txt's images.
sed "s|^\(.*\)\.JPEG$|raw_nchw/\1.raw|" calib.txt > calib_nchw.txt
qnn qairt-quantizer --input_dlc mnv2.dlc --input_list calib_nchw.txt \
    --output_dlc mnv2_q.dlc > quant.log 2>&1
echo "quantize: rc=$?"
