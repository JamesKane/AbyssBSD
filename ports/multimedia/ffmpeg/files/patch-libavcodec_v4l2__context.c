--- libavcodec/v4l2_context.c.orig
+++ libavcodec/v4l2_context.c
@@ -400,6 +400,16 @@
             int bytesused = V4L2_TYPE_IS_MULTIPLANAR(buf.type) ?
                             buf.m.planes[0].bytesused : buf.bytesused;
             if (bytesused == 0) {
+#ifdef V4L2_BUF_FLAG_LAST
+                /* An empty buffer the driver failed (one the device returned
+                 * unfilled, as Qualcomm's Iris encoder does) does not end the
+                 * drain, which the LAST flag marks: give it back and wait on.
+                 */
+                if ((buf.flags & (V4L2_BUF_FLAG_ERROR | V4L2_BUF_FLAG_LAST)) ==
+                    V4L2_BUF_FLAG_ERROR &&
+                    !ff_v4l2_buffer_enqueue(&ctx->buffers[buf.index]))
+                    goto start;
+#endif
                 ctx->done = 1;
                 return NULL;
             }
