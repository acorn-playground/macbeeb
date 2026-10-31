// GTK 4, libadwaita and OpenGL (through epoxy, as GTK uses it), for the
// Linux app (Sources/MacBeeb/Linux).
#include <gtk/gtk.h>
#include <adwaita.h>
#include <epoxy/gl.h>
#include <glib-unix.h>
#include <gio/gio.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

// What Swift can't call directly: GObject's variadic functions, and
// GTK's macros.

// MARK: libdispatch's main queue, run from GLib's main loop

/// The eventfd libdispatch pokes when the main queue has work (as
/// Foundation's run loop uses it).
extern int _dispatch_get_main_queue_handle_4CF(void);
/// Runs what's on the main queue.
extern void _dispatch_main_queue_callback_4CF(void *message);

// MARK: Signals and properties

static inline gulong macbeeb_signal_connect(gpointer instance, const char *signal, GCallback handler, gpointer data,
                                            GClosureNotify destroy, gboolean after) {
    return g_signal_connect_data(instance, signal, handler, data, destroy, after ? G_CONNECT_AFTER : 0);
}

static inline void macbeeb_set_bool(gpointer object, const char *property, gboolean value) {
    g_object_set(object, property, value, NULL);
}

static inline void macbeeb_set_int(gpointer object, const char *property, gint value) {
    g_object_set(object, property, value, NULL);
}

static inline void macbeeb_set_uint(gpointer object, const char *property, guint value) {
    g_object_set(object, property, value, NULL);
}

static inline void macbeeb_set_double(gpointer object, const char *property, gdouble value) {
    g_object_set(object, property, value, NULL);
}

static inline void macbeeb_set_string(gpointer object, const char *property, const char *value) {
    g_object_set(object, property, value, NULL);
}

static inline void macbeeb_set_object(gpointer object, const char *property, gpointer value) {
    g_object_set(object, property, value, NULL);
}

static inline gboolean macbeeb_get_bool(gpointer object, const char *property) {
    gboolean value = FALSE;
    g_object_get(object, property, &value, NULL);
    return value;
}

static inline void macbeeb_bind_property(gpointer source, const char *source_property, gpointer target,
                                         const char *target_property) {
    g_object_bind_property(source, source_property, target, target_property, G_BINDING_SYNC_CREATE);
}

// MARK: Types

static inline GType macbeeb_type_file_list(void) { return GDK_TYPE_FILE_LIST; }
static inline GType macbeeb_type_string(void) { return G_TYPE_STRING; }
static inline GType macbeeb_type_texture(void) { return GDK_TYPE_TEXTURE; }
static inline GType macbeeb_type_file(void) { return G_TYPE_FILE; }

static inline const GVariantType *macbeeb_variant_type_string(void) { return G_VARIANT_TYPE_STRING; }
static inline const GVariantType *macbeeb_variant_type_boolean(void) { return G_VARIANT_TYPE_BOOLEAN; }
static inline const GVariantType *macbeeb_variant_type_int32(void) { return G_VARIANT_TYPE_INT32; }

/// The files in a drop's value, as a list to free with g_slist_free (the
/// files belong to the value).
static inline GSList *macbeeb_drop_files(const GValue *value) {
    if (!G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) return NULL;
    return gdk_file_list_get_files(g_value_get_boxed(value));
}

static inline const char *macbeeb_drop_string(const GValue *value) {
    return G_VALUE_HOLDS(value, G_TYPE_STRING) ? g_value_get_string(value) : NULL;
}

/// A GValue holding a file list of one file, for a drag source.
static inline GdkContentProvider *macbeeb_content_for_files(GFile **files, gsize count) {
    GSList *list = NULL;
    for (gsize i = count; i > 0; i--) list = g_slist_prepend(list, files[i - 1]);
    GdkFileList *fileList = gdk_file_list_new_from_list(list);
    g_slist_free(list);
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, fileList);
    GdkContentProvider *provider = gdk_content_provider_new_for_value(&value);
    g_value_unset(&value);
    return provider;
}

// MARK: Menus

static inline void macbeeb_menu_item_set_string_target(GMenuItem *item, const char *action, const char *target) {
    g_menu_item_set_action_and_target_value(item, action, g_variant_new_string(target));
}

static inline void macbeeb_menu_item_set_attribute_string(GMenuItem *item, const char *attribute, const char *value) {
    g_menu_item_set_attribute_value(item, attribute, g_variant_new_string(value));
}

// MARK: Lists

static inline GtkStringObject *macbeeb_string_object(gpointer item) {
    return GTK_IS_STRING_OBJECT(item) ? GTK_STRING_OBJECT(item) : NULL;
}

// MARK: OpenGL (through epoxy, which GTK uses: its macros are function
// pointers Swift can't see)

static inline GLuint macbeeb_gl_create_shader(GLenum type) { return glCreateShader(type); }
static inline void macbeeb_gl_shader_source(GLuint shader, const char *source) {
    glShaderSource(shader, 1, &source, NULL);
}
static inline void macbeeb_gl_compile_shader(GLuint shader) { glCompileShader(shader); }
static inline GLint macbeeb_gl_shader_ok(GLuint shader) {
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    return ok;
}
static inline void macbeeb_gl_shader_log(GLuint shader, char *buffer, GLsizei size) {
    glGetShaderInfoLog(shader, size, NULL, buffer);
}
static inline GLuint macbeeb_gl_create_program(void) { return glCreateProgram(); }
static inline void macbeeb_gl_attach_shader(GLuint program, GLuint shader) { glAttachShader(program, shader); }
static inline void macbeeb_gl_link_program(GLuint program) { glLinkProgram(program); }
static inline GLint macbeeb_gl_program_ok(GLuint program) {
    GLint ok = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &ok);
    return ok;
}
static inline void macbeeb_gl_program_log(GLuint program, char *buffer, GLsizei size) {
    glGetProgramInfoLog(program, size, NULL, buffer);
}
static inline void macbeeb_gl_delete_shader(GLuint shader) { glDeleteShader(shader); }
static inline void macbeeb_gl_delete_program(GLuint program) { glDeleteProgram(program); }
static inline void macbeeb_gl_use_program(GLuint program) { glUseProgram(program); }
static inline GLint macbeeb_gl_uniform_location(GLuint program, const char *name) {
    return glGetUniformLocation(program, name);
}
static inline void macbeeb_gl_uniform1i(GLint location, GLint value) { glUniform1i(location, value); }
static inline void macbeeb_gl_uniform1f(GLint location, GLfloat value) { glUniform1f(location, value); }
static inline void macbeeb_gl_uniform2f(GLint location, GLfloat x, GLfloat y) { glUniform2f(location, x, y); }
static inline GLuint macbeeb_gl_gen_texture(void) {
    GLuint texture = 0;
    glGenTextures(1, &texture);
    return texture;
}
static inline void macbeeb_gl_delete_texture(GLuint texture) { glDeleteTextures(1, &texture); }
static inline void macbeeb_gl_bind_texture(GLuint unit, GLuint texture) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, texture);
}
static inline void macbeeb_gl_texture_parameters(void) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}
static inline void macbeeb_gl_texture_image(GLsizei width, GLsizei height, const void *pixels) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}
static inline void macbeeb_gl_texture_subimage(GLsizei width, GLsizei height, const void *pixels) {
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}
static inline void macbeeb_gl_copy_texture(GLuint from, GLuint to, GLsizei width, GLsizei height) {
    // (Through a framebuffer: copies the last frame into the afterglow's.)
    GLuint framebuffer = 0;
    GLint previous = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, from, 0);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, to);
    glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width, height);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)previous);
    glDeleteFramebuffers(1, &framebuffer);
}
static inline GLuint macbeeb_gl_gen_vertex_array(void) {
    GLuint array = 0;
    glGenVertexArrays(1, &array);
    return array;
}
static inline void macbeeb_gl_delete_vertex_array(GLuint array) { glDeleteVertexArrays(1, &array); }
static inline void macbeeb_gl_bind_vertex_array(GLuint array) { glBindVertexArray(array); }
static inline void macbeeb_gl_viewport(GLint x, GLint y, GLsizei width, GLsizei height) { glViewport(x, y, width, height); }
static inline void macbeeb_gl_clear(GLfloat r, GLfloat g, GLfloat b) {
    glClearColor(r, g, b, 1);
    glClear(GL_COLOR_BUFFER_BIT);
}
static inline void macbeeb_gl_draw_quad(void) { glDrawArrays(GL_TRIANGLE_STRIP, 0, 4); }
static inline void macbeeb_gl_read_pixels(GLint x, GLint y, GLsizei width, GLsizei height, void *pixels) {
    glPixelStorei(GL_PACK_ALIGNMENT, 4);
    glReadPixels(x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
}
static inline GLint macbeeb_gl_framebuffer_binding(void) {
    GLint binding = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &binding);
    return binding;
}
static inline gboolean macbeeb_gl_is_es(void) { return !epoxy_is_desktop_gl(); }
static inline int macbeeb_gl_version(void) { return epoxy_gl_version(); }

/// An offscreen framebuffer with a colour texture, for rendering the
/// display as shown to a picture (self-tests).
static inline GLuint macbeeb_gl_offscreen(GLsizei width, GLsizei height, GLuint *texture) {
    GLuint framebuffer = 0;
    glGenTextures(1, texture);
    glBindTexture(GL_TEXTURE_2D, *texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, *texture, 0);
    return framebuffer;
}
static inline void macbeeb_gl_delete_offscreen(GLuint framebuffer, GLuint texture, GLint restore) {
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)restore);
    glDeleteFramebuffers(1, &framebuffer);
    glDeleteTextures(1, &texture);
}

// MARK: The Secret Service (GNOME Keyring and the like), through libsecret,
// loaded when it's wanted: it's on every GNOME desktop, but needn't be
// built against.

#include <dlfcn.h>

typedef struct { const gchar *name; int type; } MacBeebSecretAttribute;
/// libsecret's SecretSchema, laid out as it is.
typedef struct {
    const gchar *name;
    int flags;
    MacBeebSecretAttribute attributes[32];
    gint reserved;
    gpointer reserved1, reserved2, reserved3, reserved4, reserved5, reserved6, reserved7;
} MacBeebSecretSchema;

typedef gboolean (*MacBeebSecretStore)(const MacBeebSecretSchema *, GHashTable *, const gchar *, const gchar *,
                                       const gchar *, GCancellable *, GError **);
typedef gchar *(*MacBeebSecretLookup)(const MacBeebSecretSchema *, GHashTable *, GCancellable *, GError **);
typedef gboolean (*MacBeebSecretClear)(const MacBeebSecretSchema *, GHashTable *, GCancellable *, GError **);
typedef void (*MacBeebSecretFree)(gchar *);

static inline void *macbeeb_secret_symbol(const char *name) {
    static void *library = NULL;
    static gboolean tried = FALSE;
    if (!tried) {
        tried = TRUE;
        library = dlopen("libsecret-1.so.0", RTLD_LAZY | RTLD_LOCAL);
    }
    return library ? dlsym(library, name) : NULL;
}

static inline const MacBeebSecretSchema *macbeeb_secret_schema(void) {
    static const MacBeebSecretSchema schema = {
        "com.accidentalfish.MacBeeb.InternetEconet", 0,
        { { "service", 0 }, { "account", 0 }, { NULL, 0 } },
        0, NULL, NULL, NULL, NULL, NULL, NULL, NULL
    };
    return &schema;
}

static inline GHashTable *macbeeb_secret_attributes(const char *account) {
    GHashTable *attributes = g_hash_table_new(g_str_hash, g_str_equal);
    g_hash_table_insert(attributes, (gpointer)"service", (gpointer)"MacBeeb Internet Econet");
    g_hash_table_insert(attributes, (gpointer)"account", (gpointer)account);
    return attributes;
}

static inline gboolean macbeeb_secret_available(void) {
    return macbeeb_secret_symbol("secret_password_storev_sync") != NULL;
}

/// Stores a secret for `account`; whether it could.
static inline gboolean macbeeb_secret_store(const char *account, const char *label, const char *secret) {
    MacBeebSecretStore store = (MacBeebSecretStore)macbeeb_secret_symbol("secret_password_storev_sync");
    if (!store) return FALSE;
    GHashTable *attributes = macbeeb_secret_attributes(account);
    GError *error = NULL;
    gboolean stored = store(macbeeb_secret_schema(), attributes, NULL, label, secret, NULL, &error);
    if (error) g_error_free(error);
    g_hash_table_unref(attributes);
    return stored;
}

/// The secret for `account` (to g_free), or NULL; `failed` says whether
/// the Secret Service couldn't be asked.
static inline char *macbeeb_secret_lookup(const char *account, gboolean *failed) {
    MacBeebSecretLookup lookup = (MacBeebSecretLookup)macbeeb_secret_symbol("secret_password_lookupv_sync");
    MacBeebSecretFree secretFree = (MacBeebSecretFree)macbeeb_secret_symbol("secret_password_free");
    *failed = lookup == NULL;
    if (!lookup) return NULL;
    GHashTable *attributes = macbeeb_secret_attributes(account);
    GError *error = NULL;
    gchar *secret = lookup(macbeeb_secret_schema(), attributes, NULL, &error);
    if (error) {
        *failed = TRUE;
        g_error_free(error);
    }
    g_hash_table_unref(attributes);
    char *copy = secret ? g_strdup(secret) : NULL;
    if (secret && secretFree) secretFree(secret);
    return copy;
}

static inline void macbeeb_secret_clear(const char *account) {
    MacBeebSecretClear clear = (MacBeebSecretClear)macbeeb_secret_symbol("secret_password_clearv_sync");
    if (!clear) return;
    GHashTable *attributes = macbeeb_secret_attributes(account);
    GError *error = NULL;
    clear(macbeeb_secret_schema(), attributes, NULL, &error);
    if (error) g_error_free(error);
    g_hash_table_unref(attributes);
}

// MARK: Pictures

/// A picture as JPEG (to g_free), from RGB bytes.
static inline gchar *macbeeb_jpeg(const guchar *rgb, int width, int height, int quality, gsize *size) {
    GdkPixbuf *pixbuf = gdk_pixbuf_new_from_data(rgb, GDK_COLORSPACE_RGB, FALSE, 8, width, height, width * 3, NULL, NULL);
    gchar *buffer = NULL;
    char value[8];
    g_snprintf(value, sizeof value, "%d", quality);
    char *keys[] = { "quality", NULL };
    char *values[] = { value, NULL };
    GError *error = NULL;
    if (!gdk_pixbuf_save_to_bufferv(pixbuf, &buffer, size, "jpeg", keys, values, &error)) {
        buffer = NULL;
        *size = 0;
    }
    if (error) g_error_free(error);
    g_object_unref(pixbuf);
    return buffer;
}

// MARK: Accessibility

static inline void macbeeb_set_accessible_label(GtkWidget *widget, const char *label) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

static inline void macbeeb_set_accessible_description(GtkWidget *widget, const char *description) {
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
}

/// Announces text to screen readers (as the Mac's announcement requests).
static inline void macbeeb_announce(GtkWidget *widget, const char *message) {
    gtk_accessible_announce(GTK_ACCESSIBLE(widget), message, GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_MEDIUM);
}

// MARK: Breakpoints (libadwaita): a widget hidden, or a property set, when
// the window's narrower than a size.

static inline AdwBreakpoint *macbeeb_breakpoint(const char *condition) {
    return adw_breakpoint_new(adw_breakpoint_condition_parse(condition));
}

static inline void macbeeb_breakpoint_hide(AdwBreakpoint *breakpoint, GtkWidget *widget) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, FALSE);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(widget), "visible", &value);
    g_value_unset(&value);
}

// MARK: Preferences and the welcome screen

/// Hides a decorative widget (a picture that says nothing) from screen
/// readers.
static inline void macbeeb_preferences_accessible_hidden(GtkWidget *widget) {
    gtk_accessible_update_state(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
}

/// A breakpoint setting an enum property (a box's orientation, say).
static inline void macbeeb_preferences_breakpoint_set_enum(AdwBreakpoint *breakpoint, gpointer object,
                                                           const char *property, gint value) {
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), property);
    if (!spec) return;
    GValue v = G_VALUE_INIT;
    g_value_init(&v, spec->value_type);
    g_value_set_enum(&v, value);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &v);
    g_value_unset(&v);
}

/// A breakpoint setting an integer property (a box's spacing, say).
static inline void macbeeb_preferences_breakpoint_set_int(AdwBreakpoint *breakpoint, gpointer object,
                                                          const char *property, gint value) {
    GValue v = G_VALUE_INIT;
    g_value_init(&v, G_TYPE_INT);
    g_value_set_int(&v, value);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &v);
    g_value_unset(&v);
}

/// A combo row of strings (a GtkStringList) with a search entry in its
/// pop-up, matching anywhere in an item.
static inline void macbeeb_preferences_combo_row_searchable(AdwComboRow *row) {
    GtkExpression *expression = gtk_property_expression_new(GTK_TYPE_STRING_OBJECT, NULL, "string");
    adw_combo_row_set_expression(row, expression);
    gtk_expression_unref(expression);
    adw_combo_row_set_enable_search(row, TRUE);
    adw_combo_row_set_search_match_mode(row, GTK_STRING_FILTER_MATCH_MODE_SUBSTRING);
}

// MARK: The debugger

/// A string property (to g_free) into `value`.
static inline void macbeeb_debugger_get_string_property(gpointer object, const char *property, char **value) {
    g_object_get(object, property, value, NULL);
}

// MARK: The Network Studio

/// Puts a GtkFixed's child with its top left at (x, y), scaled.
static inline void macbeeb_network_fixed_place(GtkFixed *fixed, GtkWidget *child, float x, float y, float scale) {
    graphene_point_t point = GRAPHENE_POINT_INIT(x, y);
    GskTransform *transform = gsk_transform_translate(NULL, &point);
    transform = gsk_transform_scale(transform, scale, scale);
    gtk_fixed_set_child_transform(fixed, child, transform);
    gsk_transform_unref(transform);
}

/// A string, for dragging.
static inline GdkContentProvider *macbeeb_network_content_for_string(const char *value) {
    return gdk_content_provider_new_typed(G_TYPE_STRING, value);
}

/// A breakpoint setting a boolean property.
static inline void macbeeb_network_breakpoint_set_bool(AdwBreakpoint *breakpoint, gpointer object, const char *property,
                                                       gboolean on) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, on);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

/// A breakpoint setting an enum property.
static inline void macbeeb_network_breakpoint_set_enum(AdwBreakpoint *breakpoint, gpointer object, const char *property,
                                                       gint number) {
    GParamSpec *spec = g_object_class_find_property(G_OBJECT_GET_CLASS(object), property);
    if (!spec) return;
    GValue value = G_VALUE_INIT;
    g_value_init(&value, spec->value_type);
    g_value_set_enum(&value, number);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

// MARK: The Game Library (Linux/Windows/Library)

/// A breakpoint setting a boolean property of `object`.
static inline void macbeeb_library_breakpoint_set_bool(AdwBreakpoint *breakpoint, gpointer object, const char *property,
                                                       gboolean on) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, on);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

/// A breakpoint setting a string property of `object`.
static inline void macbeeb_library_breakpoint_set_string(AdwBreakpoint *breakpoint, gpointer object, const char *property,
                                                         const char *text) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_STRING);
    g_value_set_string(&value, text);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

/// Hides a decorative widget (a cover, whose tile says what it is) from
/// screen readers.
static inline void macbeeb_library_accessible_hidden(GtkWidget *widget) {
    gtk_accessible_update_state(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_STATE_HIDDEN, TRUE, -1);
}

// MARK: Help windows (the guides, What's New, Credits, the AI agents')

/// A label that's a heading to assistive technologies, at `level` (1–6).
static inline GtkWidget *macbeeb_help_heading_label(int level) {
    GtkWidget *label = g_object_new(GTK_TYPE_LABEL, "accessible-role", GTK_ACCESSIBLE_ROLE_HEADING, NULL);
    gtk_accessible_update_property(GTK_ACCESSIBLE(label), GTK_ACCESSIBLE_PROPERTY_LEVEL, level, -1);
    return label;
}

/// A breakpoint's setter of a boolean property (a split view's
/// "collapsed", say).
static inline void macbeeb_help_breakpoint_set_bool(AdwBreakpoint *breakpoint, gpointer object, const char *property,
                                                    gboolean on) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_BOOLEAN);
    g_value_set_boolean(&value, on);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &value);
    g_value_unset(&value);
}

// MARK: Disc contents and the Print Centre

/// The widget as an image, if it is one (a table cell's icon).
static inline GtkImage *macbeeb_files_image(GtkWidget *widget) {
    return GTK_IS_IMAGE(widget) ? GTK_IMAGE(widget) : NULL;
}

/// A combo row's items shown in full (libadwaita's own labels stop at
/// twenty characters): the chosen one beside the title, and each in the
/// pop-up with a check by the chosen one.
static inline void macbeeb_preferences_combo_row_full_labels(AdwComboRow *row) {
    static const char *current =
        "<interface><template class=\"GtkListItem\"><property name=\"child\">"
        "<object class=\"GtkLabel\"><property name=\"xalign\">0</property>"
        "<property name=\"ellipsize\">end</property><property name=\"valign\">center</property>"
        "<binding name=\"label\"><lookup name=\"string\" type=\"GtkStringObject\">"
        "<lookup name=\"item\">GtkListItem</lookup></lookup></binding>"
        "</object></property></template></interface>";
    static const char *list =
        "<interface><template class=\"GtkListItem\"><property name=\"child\">"
        "<object class=\"GtkBox\"><property name=\"spacing\">6</property>"
        "<child><object class=\"GtkLabel\"><property name=\"xalign\">0</property><property name=\"hexpand\">true</property>"
        "<binding name=\"label\"><lookup name=\"string\" type=\"GtkStringObject\">"
        "<lookup name=\"item\">GtkListItem</lookup></lookup></binding></object></child>"
        "<child><object class=\"GtkImage\"><property name=\"icon-name\">object-select-symbolic</property>"
        "<property name=\"accessible-role\">presentation</property>"
        "<binding name=\"visible\"><lookup name=\"selected\">GtkListItem</lookup></binding></object></child>"
        "</object></property></template></interface>";
    GBytes *bytes = g_bytes_new_static(current, strlen(current));
    GtkListItemFactory *factory = gtk_builder_list_item_factory_new_from_bytes(NULL, bytes);
    adw_combo_row_set_factory(row, factory);
    g_object_unref(factory);
    g_bytes_unref(bytes);
    bytes = g_bytes_new_static(list, strlen(list));
    factory = gtk_builder_list_item_factory_new_from_bytes(NULL, bytes);
    adw_combo_row_set_list_factory(row, factory);
    g_object_unref(factory);
    g_bytes_unref(bytes);
}

/// A breakpoint setting a float property (a label's alignment, say).
static inline void macbeeb_preferences_breakpoint_set_float(AdwBreakpoint *breakpoint, gpointer object,
                                                            const char *property, gfloat value) {
    GValue v = G_VALUE_INIT;
    g_value_init(&v, G_TYPE_FLOAT);
    g_value_set_float(&v, value);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &v);
    g_value_unset(&v);
}

/// A breakpoint setting a boolean property (a box's homogeneity, say).
static inline void macbeeb_preferences_breakpoint_set_bool(AdwBreakpoint *breakpoint, gpointer object,
                                                           const char *property, gboolean value) {
    GValue v = G_VALUE_INIT;
    g_value_init(&v, G_TYPE_BOOLEAN);
    g_value_set_boolean(&v, value);
    adw_breakpoint_add_setter(breakpoint, G_OBJECT(object), property, &v);
    g_value_unset(&v);
}
