# ports

A poudriere overlay: each directory replaces the port of the same origin in
the ports tree it is built against, or, where the tree has none, adds it.

Added here (the Q8B's NPU, see docs/boards/radxa-dragon-q8b/npu.md):

- `misc/linux-fastrpc`: the FastRPC library for Linux programs, and the
  Q8B's DSP files.
- `misc/qairt`: Qualcomm's QNN runtime, built from the user's own SDK
  download (`QAIRT_SDK=`), never packaged (`NO_PACKAGE`).
- `multimedia/ffmpeg`: FFmpeg 9.0.2 with `patch-libavcodec_v4l2__context.c`,
  so a V4L2 drain doesn't end at an empty buffer the driver failed (Iris's
  encoder returns those): without it FFmpeg loses an encode's last frame
  (docs/boards/radxa-dragon-q8b/vpu.md). For upstream FFmpeg.
- `multimedia/qcom-iris-firmware`: the video codec's firmware, from
  Radxa's firmware release (see docs/boards/radxa-dragon-q8b/vpu.md);
  packaged for local use only, as Radxa states no terms for it.

    poudriere ports -c -p abyss -m null -M $PWD/ports
    poudriere bulk -j <jail> -p default -O abyss <origins>

`graphics/libdrm`'s `patch-xf86drm.c` is the FreeBSD platform-device work
on https://github.com/JamesKane/libdrm, branch `freebsd-missing-node`, until
it is upstream: Mesa needs it to find the GPU's render node beside a
separate display driver (sysfbdrm with msm or panthor).

Taken from https://github.com/JamesKane/freebsd-ports, branch freedreno at
d80cb373e32b645d4d6a8347156c16b5011f65b6, over freebsd-ports 0766e9d7376671c8a404db90a2ac8f9ffdf099a4.
