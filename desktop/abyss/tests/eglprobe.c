/* Does libEGL actually find a driver? — the check that "the file is present"
 * cannot make (PHASE4 §5.5).
 *
 * `libEGL.so.1` on FreeBSD is libglvnd: a vendor-neutral dispatch that finds the
 * real driver by reading the JSON in egl_vendor.d and dlopening what it names. Miss
 * either half and libEGL still loads, still resolves every symbol, and still
 * answers every call — it simply has no vendor behind it. The symptom names
 * none of that:
 *
 *     [render/egl.c:208] EGL_EXT_platform_base not supported
 *
 * The useful property being exploited here: **client extensions are queried on
 * `EGL_NO_DISPLAY`, before any device is opened.** So a machine with no GPU at
 * all — the build VM, every CI runner — can still tell whether the vendor
 * chain resolves. That turns a three-times-repeated runtime surprise into a
 * test that runs on every build.
 *
 * Point it at a tree with LD_LIBRARY_PATH and __EGL_VENDOR_LIBRARY_DIRS and it
 * reports on *that* tree rather than on the machine compiling it.
 *
 *   cc -o eglprobe eglprobe.c -lEGL && ./eglprobe
 *
 * Exit 0: the dispatch found a vendor.   Exit 1: it did not, and says so.
 */
#include <stdio.h>
#include <string.h>
#include <EGL/egl.h>

int main(void) {
    const char *ext = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
    if (ext == NULL || *ext == '\0') {
        printf("eglprobe: libEGL reports NO client extensions at all —"
               " the dispatch loaded and found no vendor\n");
        return 1;
    }
    printf("eglprobe: client extensions: %s\n", ext);
    /* The one wlroots requires before it will even try GLES2. */
    if (strstr(ext, "EGL_EXT_platform_base") == NULL) {
        printf("eglprobe: EGL_EXT_platform_base is MISSING —"
               " wlroots would skip the GLES2 renderer\n");
        return 1;
    }
    printf("eglprobe: EGL_EXT_platform_base present\n");
    return 0;
}
