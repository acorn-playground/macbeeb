// GStreamer, for recording video on Linux (BeebCapture).
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>

// What Swift can't call directly: GObject's variadic setters and
// GStreamer's casting macros.

static inline void macbeeb_gst_set_string(GstElement *element, const char *property, const char *value) {
    g_object_set(element, property, value, NULL);
}

static inline GstAppSrc *macbeeb_gst_app_src(GstElement *pipeline, const char *name) {
    GstElement *element = gst_bin_get_by_name(GST_BIN(pipeline), name);
    return element ? GST_APP_SRC(element) : NULL;
}

static inline GstBuffer *macbeeb_gst_buffer(const void *bytes, gsize size, GstClockTime pts, GstClockTime duration) {
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, size, NULL);
    gst_buffer_fill(buffer, 0, bytes, size);
    GST_BUFFER_PTS(buffer) = pts;
    GST_BUFFER_DURATION(buffer) = duration;
    return buffer;
}

/// The error a bus message carries, as text (to be g_free'd), or NULL.
static inline char *macbeeb_gst_error_text(GstMessage *message) {
    if (GST_MESSAGE_TYPE(message) != GST_MESSAGE_ERROR) return NULL;
    GError *error = NULL;
    gchar *debug = NULL;
    gst_message_parse_error(message, &error, &debug);
    gchar *text = g_strdup_printf("%s%s%s", error ? error->message : "error", debug ? " — " : "", debug ? debug : "");
    if (error) g_error_free(error);
    g_free(debug);
    return text;
}

static inline gboolean macbeeb_gst_is_eos(GstMessage *message) {
    return GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
}

static inline void macbeeb_gst_unref_app_src(GstAppSrc *source) {
    gst_object_unref(source);
}
