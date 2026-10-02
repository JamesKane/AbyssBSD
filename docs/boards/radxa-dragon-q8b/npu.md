# NPU: QNN on the compute DSP

The SC8280XP's NPU is the HTP (Hexagon v68, HVX and HMX) in the compute DSP
(CDSP). Qualcomm's QNN runtime (part of the QAIRT SDK) drives it from the
CPU through FastRPC. QNN comes only as Linux (glibc) binaries, so it runs
under FreeBSD's Linux layer, on Rocky Linux 9's userland (`linux_base-rl9`),
calling `/dev/fastrpc-cdsp` through `qcom_fastrpc_linux`.

Status (2026-10-02): `qnn-net-run` runs the SDK's Inception V3 example layer
on the NPU, as root or as a member of `wheel`, with results within one
quantization step of QNN's CPU backend: 0.94 ms per inference against
3.78 ms on the CPU.

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

The files are in [npu/](npu/). As root unless said otherwise.

1. **Prerequisites** (already on the Q8B for FastRPC):
   `/boot/firmware/qcom/sc8280xp/qccdsp8280.mbn` (the CDSP's firmware, from
   linux-firmware); the FastRPC shells in
   `/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp/cdsp/` (from Radxa's
   Ubuntu); and `/usr/share/qcom/conf.d/radxa-dragon-q8b.yaml`:

       machines:
         Radxa Dragon Q8B:
           DSP_LIBRARY_PATH: sc8280xp/radxa/dragon-q8b/dsp

2. **The Linux layer and Rocky 9.** The package's install script wants the
   layer loaded first:

       sysrc linux_enable=YES
       service linux start
       pkg install linux_base-rl9 linux-rl9-devtools

3. **QNN.** Download the QAIRT SDK from Qualcomm (its licence is yours to
   accept), unzip it, and install the parts that run here (the
   `aarch64-ubuntu-gcc9.4` tools and libraries, the `hexagon-v68` DSP
   libraries):

       sh npu/install-qairt.sh /path/to/qairt/2.51.0.260929

4. **The Linux FastRPC library.** QNN's needs `libcdsprpc` for Linux; Rocky's
   glibc 2.34 is older than the one Ubuntu's copy needs, so build it, as a
   user, from the fork (which builds without libbsd) and libyaml 0.2.5
   (https://pyyaml.org/download/libyaml/yaml-0.2.5.tar.gz,
   SHA-256 `c642ae9b75fee120b2d96c712538bd2cf283228d2337df2cf2988e3c02678ef4`),
   then install it as root:

       git clone -b freebsd https://github.com/JamesKane/fastrpc
       sh npu/build-linux-fastrpc.sh fastrpc yaml-0.2.5.tar.gz ~/lxbuild
       sh npu/build-linux-fastrpc.sh install fastrpc yaml-0.2.5.tar.gz ~/lxbuild

   The install puts only the libraries in `/usr/local/qnn/lib`: the full
   `make install` would add systemd and udev files to FreeBSD's `/lib`.

5. **The wrapper, the configuration and the service:**

       install -m 555 npu/qnn /usr/local/qnn/bin/qnn
       ln -sf /usr/local/qnn/bin/qnn /usr/local/bin/qnn
       install -m 444 npu/htp_config.json npu/htp_netrun.json /usr/local/qnn/etc/
       install -m 555 npu/qnn.rc /usr/local/etc/rc.d/qnn
       sysrc qnn_enable=YES
       service qnn start

## Running

`qnn TOOL ARGS` runs a QNN tool from `/usr/local/qnn/bin` (or a Linux
program, by path) with QNN's libraries, the DSP's search path and the board's
name for the FastRPC library's configuration. `/dev/fastrpc-cdsp` is
`root:wheel`, mode 0660.

    qnn qnn-net-run --backend /usr/local/qnn/lib/libQnnHtp.so \
        --model libqnn_model.so --input_list input_list.txt \
        --output_dir /tmp/out \
        --config_file /usr/local/qnn/etc/htp_netrun.json

Linux programs see FreeBSD's `/tmp` (Rocky's tree has none), and log to
syslog (`/var/log/messages`), QNN's backend included.

## Models

QNN's converters (ONNX, TFLite, PyTorch to QNN) run on x86-64 Linux, not
here. A converted model comes as C++ and a `.bin` of weights, which
`qnn-model-lib-generator` compiles into a Linux aarch64 `.so` with the SDK's
`share/QNN/converter/Makefile.ubuntu-aarch64-gcc9.4`: any aarch64 Linux
toolchain will do, Rocky's here included. The SDK's
`examples/QNN/converter/models` (the first layer of Inception V3) is the one
tried so far. The converters can also write a `.dlc`, which `qnn-net-run`
loads directly (`libQnnModelDlc.so`), preparing the graph on the board.

## Known issues

- QNN logs `unexpected GraphHtpSettings option 66` on every run; nothing
  fails for it.
- At the end of a run the DSP refuses QNN's heap unmap (`AEE_EBADSTATE`) and
  some optional calls (`AEE_ERPC`): the process is already going.
- The DSP's own log (adspmsgd) shows nothing.
