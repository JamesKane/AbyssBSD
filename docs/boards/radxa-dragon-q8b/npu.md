# NPU: QNN on the compute DSP

The SC8280XP's NPU is the HTP (Hexagon v68, HVX and HMX) in the compute DSP
(CDSP). Qualcomm's QNN runtime (part of the QAIRT SDK) drives it from the
CPU through FastRPC. QNN comes only as Linux (glibc) binaries, so it runs
under FreeBSD's Linux layer, on Rocky Linux 9's userland (`linux_base-rl9`),
calling `/dev/fastrpc-cdsp` through `qcom_fastrpc_linux`.

Status (2026-10-02): MobileNetV2 (ImageNet, from ONNX), converted and
quantized to 8 bits on the board itself, classifies on the NPU in 0.94 ms an
image (0.65 ms of it on the accelerator), against 18.8 ms for the float model
on QNN's CPU backend; on 100 ImageNet sample images, 79 right first time (95
in its top five), against the float model's 84 (98). It runs as root or as a
member of `wheel`.

## How it fits together

| Piece | Where |
|---|---|
| CDSP start: RPMh votes while it boots, PAS load | `qcom_rpmh`, `qcom_adsp` (src) |
| FastRPC, Linux's ioctls: `/dev/fastrpc-cdsp` | `qcom_fastrpc` (src, in GENERIC) |
| Those ioctls for Linux programs | `qcom_fastrpc_linux` (src, module) |
| `/sys/devices/soc0` for Linux programs | `hw.soc` from `qcom_glink`'s socinfo; `linsysfs` (src) |
| Linux userland: glibc 2.34, libstdc++ | `linux_base-rl9`, `linux-rl9-devtools` (packages) |
| QNN's Linux tools and libraries, v68 DSP libraries | `/usr/local/qnn`, from the QAIRT SDK |
| Linux `libcdsprpc` (FastRPC user library), libyaml | `/usr/local/qnn/lib`, built from [the fastrpc fork](https://github.com/JamesKane/fastrpc), branch `freebsd` |
| Setup at boot | `linux` and `qnn` services |

Two things QNN expects of Linux that this board does differently:

- **The SoC.** QNN's Linux libraries don't know SC8280XP (soc_id 449): to
  Qualcomm it is a Windows part. Told it is a QCS6490 (498), QNN's Linux
  part with the same Hexagon v68, it runs. The kernel reports the truth
  (`hw.soc.soc_id` = 449); `compat.linux.soc_id`, which the `qnn` service
  sets, changes only what Linux programs read in `/sys/devices/soc0/soc_id`.
  `htp_config.json` says the same (`soc_model` 35, `dsp_arch` v68). Told it
  is an SA8295P (460) instead, the same die, QNN takes its automotive path and
  the DSP rejects the graph.
- **Coherency.** QNN writes weights and inputs into buffers the DSP already
  has mapped, with no cache maintenance, as on its parts whose FastRPC banks
  are dma-coherent. Linux's devicetree leaves SC8280XP's non-coherent, but
  the CDSP does snoop the CPU caches: `qcom_fastrpc` maps programs' buffers
  write-back and shareable (`hw.qcom_fastrpc.coherent`, on by default).
  Mapped uncached, graphs fail on the DSP (`Dma execution failed on the skel
  side`).

The CDSP's rail and path to memory are voted to their highest while it
boots, and let go once its GLINK edge is up, as Linux drops its proxy votes:
the DSP votes for itself as its work needs. Held, they warmed the idle SoC
by about half a degree; released, QNN runs as fast. `dev.qcom_adsp.1.votes`
shows them, and takes them back (1) by hand.

## Setting it up

Two ports in this repository's overlay ([ports/](../../../ports/)):

- **`misc/linux-fastrpc`**, a package like any other: the FastRPC library
  for Linux programs (built from [the fork](https://github.com/JamesKane/fastrpc),
  branch `freebsd`, which builds without libbsd, with libyaml, cross-built
  with LLVM's clang against Rocky 9's sysroot: nothing Linux runs to build
  it), and the Q8B's DSP files from Radxa's firmware packages (the CDSP's
  firmware in `/boot/firmware`, the FastRPC shells and the library's
  configuration in `/usr/local/share/qcom`).
- **`misc/qairt`**, which **may only be built locally**: Qualcomm's licence
  allows no standalone redistribution of the SDK (`NO_PACKAGE`). Download the
  QAIRT SDK from Qualcomm (the licence is yours to accept), unzip it, and
  build with `QAIRT_SDK` naming it; the port checks it is 2.51.0 build
  260929181845. It installs QNN's Linux tools and libraries and the v68 DSP
  libraries in `/usr/local/qnn`, the `qnn` command, the `qnn` rc service and
  the HTP configuration; with its `CONVERTERS` option (on), the SDK's
  converters, a Python 3.12 for aarch64 Linux and the packages they import
  (all distfiles, unpacked with nothing Linux run).

The Linux layer must be running before Rocky 9's packages install:

    sysrc linux_enable=YES
    service linux start
    cd /path/to/AbyssBSD/ports/misc/linux-fastrpc && make install clean
    cd ../qairt && make QAIRT_SDK=/path/to/qairt/2.51.0.260929 install clean
    sysrc qnn_enable=YES
    service qnn start

(Building from the overlay outside `/usr/ports`, add
`OVERLAYS=/path/to/AbyssBSD/ports` so `qairt` finds `linux-fastrpc`.)

## Running

`qnn TOOL ARGS` runs a QNN tool from `/usr/local/qnn/bin` (or a Linux
program, by path) with QNN's libraries, the DSP's search path and the board's
name for the FastRPC library's configuration, or one of the SDK's Python
tools (`qairt-converter`, `qairt-quantizer`) with its Python and modules.
`/dev/fastrpc-cdsp` is `root:wheel`, mode 0660.

    qnn qnn-net-run --backend /usr/local/qnn/lib/libQnnHtp.so \
        --model libqnn_model.so --input_list input_list.txt \
        --output_dir /tmp/out \
        --config_file /usr/local/qnn/etc/htp_netrun.json

Linux programs see FreeBSD's `/tmp` (Rocky's tree has none), and log to
syslog (`/var/log/messages`), QNN's backend included.

## Models

The converters run here, under the Linux layer (`CONVERTERS`): `qairt-converter`
turns an ONNX (or TFLite, TensorFlow, PyTorch) model into a `.dlc`;
`qairt-quantizer` quantizes it, calibrated on sample inputs, for the v68 HTP,
which runs fixed point only; `qnn-net-run` loads the `.dlc` through
`libQnnModelDlc.so` and prepares the graph for the NPU as it starts.

[npu/mobilenet/](npu/mobilenet/) does it for MobileNetV2 from the ONNX model
zoo, scored on ImageNet sample images (one per class, from
github.com/EliSchwartz/imagenet-sample-images): every tenth class to score,
twenty others to calibrate. As a user, in a copy of that directory:

    sh fetch.sh            # the model, the class index, the images, preprocessed
    qnn qairt-converter --input_network mobilenetv2-12.onnx \
        --source_model_input_shape input 1,3,224,224 \
        --onnx_skip_simplification --output_path mnv2.dlc
    sh quant.sh            # mnv2_q.dlc: 8 bits, 14 MB to 3.6 MB
    sh run.sh Htp mnv2_q.dlc nchw out_htp \
        --config_file /usr/local/qnn/etc/htp_netrun.json
    sh run.sh Cpu mnv2.dlc nchw out_cpu

| | Top-1 | Top-5 | Per image |
|---|---|---|---|
| NPU, 8 bits (`mnv2_q.dlc`) | 79/100 | 95/100 | 0.94 ms (0.65 on the HTP) |
| QNN's CPU backend, float (`mnv2.dlc`) | 84/100 | 98/100 | 18.8 ms |

The two agree on 90 of the 100. Quantizing MobileNetV2 after training costs
it a few points, here with 20 calibration images. QNN's CPU backend is a
reference, not the fastest way to run the model on the CPUs.

Inputs are raw float32 files in the model's own layout: the converted
MobileNetV2 takes NCHW as ONNX did (NHWC scores nothing). A converted model
can also come as C++ and a `.bin` of weights, which
`qnn-model-lib-generator` compiles into a Linux aarch64 `.so` (the SDK's
`share/QNN/converter/Makefile.ubuntu-aarch64-gcc9.4`, with any aarch64 Linux
toolchain, Rocky's included).

## Known issues

- QNN logs `unexpected GraphHtpSettings option 66` on every run; nothing
  fails for it.
- At the end of a run the DSP refuses QNN's heap unmap (`AEE_EBADSTATE`) and
  some optional calls (`AEE_ERPC`): the process is already going.
- The DSP's own log (adspmsgd) shows nothing.
