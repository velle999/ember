/*
 * ember-egl-glx — an EGL that is really GLX, for the NVIDIA 304 stack.
 *
 * ── Why this exists ────────────────────────────────────────────────────────
 *
 * 304.137 is a GLX-only driver. It ships libGL and no EGL at all, and it
 * registers no DRM device — only its own /dev/nvidia0. So a program that asks
 * for EGL finds the one EGL vendor installed (Mesa), Mesa looks for
 * /dev/dri/card0 on a modprobe.blacklist=nouveau box, finds nothing, and hands
 * back llvmpipe. The machine renders in software while the X server is driving
 * the GPU perfectly well. Wine 11 does exactly this, and so does anything else
 * that reaches for EGL first.
 *
 * This library answers those EGL calls itself and performs them with GLX
 * against the 304 driver. It is installed as libEGL.so.1 inside
 * /opt/x11-19/lib/nvidia, which 50-ember-gl.sh already puts on LD_LIBRARY_PATH
 * for the session, so it is picked up ahead of libglvnd's libEGL only while the
 * 304 stack is the active one. On a nouveau boot nothing here is ever loaded.
 *
 * ⚠ IT IS A TRANSLATOR, NOT A DRIVER. It can only offer what GLX on this card
 * can do: desktop GL 2.1 contexts, GLES 2.0 contexts (304 has
 * GLX_EXT_create_context_es2_profile), window and pbuffer surfaces, swap
 * control. Everything that needs a DRM device is impossible here and is
 * refused honestly rather than faked:
 *
 *     EGLImage / dma-buf import      no DRM device to import from
 *     EGL_EXT_platform_device        no device enumeration without DRM
 *     EGL_MESA_platform_gbm          GBM needs a DRM device
 *     EGL_KHR_fence_sync             not exposed; callers fall back to glFinish
 *
 * A program that requires one of those still fails — but it fails at the call
 * that cannot work, instead of silently getting a software renderer.
 *
 * ⛔ NO EGL OR GLX HEADERS ARE USED. The P4 has no -devel packages, and this
 * has to build there. Every type, constant and prototype below is declared
 * against the published ABI, and every glX entry point is resolved by name from
 * libGL.so.1 at load time, so nothing links against the driver either.
 *
 * Diagnostics: set EMBER_EGL_DEBUG=1 to trace calls, including every refusal,
 * to stderr.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ── the EGL ABI, declared rather than included ─────────────────────────── */

typedef int32_t EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef void *EGLDisplay, *EGLConfig, *EGLSurface, *EGLContext, *EGLClientBuffer;
typedef void *EGLNativeDisplayType;
typedef unsigned long EGLNativeWindowType;
typedef unsigned long EGLNativePixmapType;
typedef intptr_t EGLAttrib;
typedef void (*__eglMustCastToProperFunctionPointerType)(void);

#define EGL_FALSE 0
#define EGL_TRUE  1
#define EGL_DONT_CARE ((EGLint)-1)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_SURFACE ((EGLSurface)0)
#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)

#define EGL_SUCCESS             0x3000
#define EGL_NOT_INITIALIZED     0x3001
#define EGL_BAD_ACCESS          0x3002
#define EGL_BAD_ALLOC           0x3003
#define EGL_BAD_ATTRIBUTE       0x3004
#define EGL_BAD_CONFIG          0x3005
#define EGL_BAD_CONTEXT         0x3006
#define EGL_BAD_CURRENT_SURFACE 0x3007
#define EGL_BAD_DISPLAY         0x3008
#define EGL_BAD_MATCH           0x3009
#define EGL_BAD_NATIVE_WINDOW   0x300B
#define EGL_BAD_PARAMETER       0x300C
#define EGL_BAD_SURFACE         0x300D

#define EGL_BUFFER_SIZE        0x3020
#define EGL_ALPHA_SIZE         0x3021
#define EGL_BLUE_SIZE          0x3022
#define EGL_GREEN_SIZE         0x3023
#define EGL_RED_SIZE           0x3024
#define EGL_DEPTH_SIZE         0x3025
#define EGL_STENCIL_SIZE       0x3026
#define EGL_CONFIG_CAVEAT      0x3027
#define EGL_CONFIG_ID          0x3028
#define EGL_LEVEL              0x3029
#define EGL_MAX_PBUFFER_HEIGHT 0x302A
#define EGL_MAX_PBUFFER_PIXELS 0x302B
#define EGL_MAX_PBUFFER_WIDTH  0x302C
#define EGL_NATIVE_RENDERABLE  0x302D
#define EGL_NATIVE_VISUAL_ID   0x302E
#define EGL_NATIVE_VISUAL_TYPE 0x302F
#define EGL_SAMPLES            0x3031
#define EGL_SAMPLE_BUFFERS     0x3032
#define EGL_SURFACE_TYPE       0x3033
#define EGL_TRANSPARENT_TYPE   0x3034
#define EGL_NONE               0x3038
#define EGL_BIND_TO_TEXTURE_RGB  0x3039
#define EGL_BIND_TO_TEXTURE_RGBA 0x303A
#define EGL_MIN_SWAP_INTERVAL  0x303B
#define EGL_MAX_SWAP_INTERVAL  0x303C
#define EGL_LUMINANCE_SIZE     0x303D
#define EGL_ALPHA_MASK_SIZE    0x303E
#define EGL_COLOR_BUFFER_TYPE  0x303F
#define EGL_RENDERABLE_TYPE    0x3040
#define EGL_CONFORMANT         0x3042
#define EGL_SLOW_CONFIG        0x3050
#define EGL_NON_CONFORMANT_CONFIG 0x3051
#define EGL_TRANSPARENT_RGB    0x3052
#define EGL_VENDOR             0x3053
#define EGL_VERSION            0x3054
#define EGL_EXTENSIONS         0x3055
#define EGL_HEIGHT             0x3056
#define EGL_WIDTH              0x3057
#define EGL_LARGEST_PBUFFER    0x3058
#define EGL_DRAW               0x3059
#define EGL_READ               0x305A
#define EGL_NO_TEXTURE         0x305C
#define EGL_TEXTURE_FORMAT     0x3080
#define EGL_TEXTURE_TARGET     0x3081
#define EGL_MIPMAP_TEXTURE     0x3082
#define EGL_BACK_BUFFER        0x3084
#define EGL_RENDER_BUFFER      0x3086
#define EGL_CLIENT_APIS        0x308D
#define EGL_RGB_BUFFER         0x308E
#define EGL_CONTEXT_CLIENT_VERSION 0x3098
#define EGL_CONTEXT_MAJOR_VERSION  0x3098
#define EGL_CONTEXT_MINOR_VERSION  0x30FB
#define EGL_CONTEXT_OPENGL_PROFILE_MASK 0x30FD
#define EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT          0x00000001
#define EGL_CONTEXT_OPENGL_COMPATIBILITY_PROFILE_BIT 0x00000002
#define EGL_OPENGL_ES_API      0x30A0
#define EGL_OPENVG_API         0x30A1
#define EGL_OPENGL_API         0x30A2
#define EGL_OPENGL_ES_BIT      0x0001
#define EGL_OPENGL_ES2_BIT     0x0004
#define EGL_OPENGL_BIT         0x0008
#define EGL_PBUFFER_BIT        0x0001
#define EGL_PIXMAP_BIT         0x0002
#define EGL_WINDOW_BIT         0x0004
#define EGL_PLATFORM_X11_KHR   0x31D5
#define EGL_BAD_NATIVE_PIXMAP_ 0x300A
#define EGL_CONDITION_SATISFIED 0x30F6
#define EGL_SYNC_TYPE_         0x30F7
#define EGL_SYNC_CONDITION_    0x30F8
#define EGL_SYNC_STATUS_       0x30F1
#define EGL_SIGNALED_          0x30F2
#define EGL_SYNC_PRIOR_COMMANDS_COMPLETE_ 0x30F0

/* ── the GLX ABI, likewise ──────────────────────────────────────────────── */

typedef void *GLXFBConfig;
typedef void *GLXContext;
typedef unsigned long GLXDrawable;
typedef unsigned long GLXWindow;
typedef unsigned long GLXPbuffer;
typedef void Display;

/* XVisualInfo's layout is fixed ABI; we only ever read `visualid`. */
typedef struct {
    void *visual;
    unsigned long visualid;
    int screen, depth, class_;
    unsigned long red_mask, green_mask, blue_mask;
    int colormap_size, bits_per_rgb;
} XVisualInfoABI;

#define GLX_BUFFER_SIZE   2
#define GLX_LEVEL         3
#define GLX_DOUBLEBUFFER  5
#define GLX_STEREO        6
#define GLX_RED_SIZE      8
#define GLX_GREEN_SIZE    9
#define GLX_BLUE_SIZE     10
#define GLX_ALPHA_SIZE    11
#define GLX_DEPTH_SIZE    12
#define GLX_STENCIL_SIZE  13
#define GLX_CONFIG_CAVEAT 0x20
#define GLX_TRANSPARENT_TYPE 0x23
#define GLX_VISUAL_ID     0x800B
#define GLX_NONE          0x8000
#define GLX_SLOW_CONFIG   0x8001
#define GLX_TRANSPARENT_RGB 0x8008
#define GLX_NON_CONFORMANT_CONFIG 0x800D
#define GLX_DRAWABLE_TYPE 0x8010
#define GLX_RENDER_TYPE   0x8011
#define GLX_X_RENDERABLE  0x8012
#define GLX_FBCONFIG_ID   0x8013
#define GLX_MAX_PBUFFER_WIDTH  0x8016
#define GLX_MAX_PBUFFER_HEIGHT 0x8017
#define GLX_MAX_PBUFFER_PIXELS 0x8018
#define GLX_WINDOW_BIT    0x0001
#define GLX_PIXMAP_BIT    0x0002
#define GLX_PBUFFER_BIT   0x0004
#define GLX_RGBA_BIT      0x0001
#define GLX_PBUFFER_HEIGHT 0x8040
#define GLX_PBUFFER_WIDTH  0x8041
#define GLX_SAMPLE_BUFFERS 100000
#define GLX_SAMPLES        100001
#define GLX_CONTEXT_MAJOR_VERSION_ARB 0x2091
#define GLX_CONTEXT_MINOR_VERSION_ARB 0x2092
#define GLX_CONTEXT_PROFILE_MASK_ARB  0x9126
#define GLX_CONTEXT_CORE_PROFILE_BIT_ARB          0x00000001
#define GLX_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB 0x00000002
#define GLX_CONTEXT_ES2_PROFILE_BIT_EXT           0x00000004
#define GLX_RGBA_TYPE 0x8014

static GLXFBConfig *(*p_glXGetFBConfigs)(Display *, int, int *);
static int  (*p_glXGetFBConfigAttrib)(Display *, GLXFBConfig, int, int *);
static XVisualInfoABI *(*p_glXGetVisualFromFBConfig)(Display *, GLXFBConfig);
static GLXWindow  (*p_glXCreateWindow)(Display *, GLXFBConfig, unsigned long, const int *);
static void       (*p_glXDestroyWindow)(Display *, GLXWindow);
static GLXPbuffer (*p_glXCreatePbuffer)(Display *, GLXFBConfig, const int *);
static void       (*p_glXDestroyPbuffer)(Display *, GLXPbuffer);
static GLXContext (*p_glXCreateNewContext)(Display *, GLXFBConfig, int, GLXContext, int);
static void       (*p_glXDestroyContext)(Display *, GLXContext);
static int        (*p_glXMakeContextCurrent)(Display *, GLXDrawable, GLXDrawable, GLXContext);
static void       (*p_glXSwapBuffers)(Display *, GLXDrawable);
static GLXContext (*p_glXGetCurrentContext)(void);
static GLXDrawable(*p_glXGetCurrentDrawable)(void);
static Display   *(*p_glXGetCurrentDisplay)(void);
static void       (*p_glXWaitGL)(void);
static void       (*p_glXWaitX)(void);
static int        (*p_glXQueryVersion)(Display *, int *, int *);
static void       (*p_glXQueryDrawable)(Display *, GLXDrawable, int, unsigned int *);
static const char *(*p_glXQueryExtensionsString)(Display *, int);
static __eglMustCastToProperFunctionPointerType (*p_glXGetProcAddressARB)(const unsigned char *);
static GLXContext (*p_glXCreateContextAttribsARB)(Display *, GLXFBConfig, GLXContext, int, const int *);
static void       (*p_glXSwapIntervalEXT)(Display *, GLXDrawable, int);
static unsigned long (*p_glXCreatePixmap)(Display *, GLXFBConfig, unsigned long, const int *);
static void       (*p_glXDestroyPixmap)(Display *, unsigned long);
static void       (*p_glFinish)(void);
static void       (*p_XFree)(void *);
static Display   *(*p_XOpenDisplay)(const char *);
static void *(*p_XSetErrorHandler)(void *);
static int   (*p_XSync)(Display *, int);

/* ⛔ A REFUSED CONTEXT ARRIVES AS AN X ERROR, AND XLIB'S DEFAULT HANDLER EXITS
 * THE PROCESS. GLX reports "this config cannot make that context" by sending
 * BadMatch, so eglinfo died outright the first time it asked 304 for a version
 * it does not have. EGL callers expect EGL_FALSE and a chance to ask for
 * something else, so every request that can be refused runs inside this trap.
 * ⚠ One global flag: like Mesa's own glX helpers, this assumes context
 * creation is not racing another thread on the same display. */
static int trap_fired;
static void *trap_prev;
static int trap_handler(Display *d, void *ev) { (void)d; (void)ev; trap_fired = 1; return 0; }

static void trap_begin(void)
{
    trap_fired = 0;
    if (p_XSetErrorHandler) trap_prev = p_XSetErrorHandler((void *)trap_handler);
}

static int trap_end(Display *dpy)   /* returns 1 if the server refused */
{
    if (p_XSync) p_XSync(dpy, 0);
    if (p_XSetErrorHandler) p_XSetErrorHandler(trap_prev);
    return trap_fired;
}

static int dbg;
#define D(...) do { if (dbg) { fprintf(stderr, "ember-egl-glx: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

/* ── objects ────────────────────────────────────────────────────────────── */

struct egl_display {
    Display *dpy;
    int screen;
    int initialized;
    GLXFBConfig *configs;
    int n_configs;
    struct egl_display *next;
};

struct egl_surface {
    struct egl_display *dsp;
    GLXDrawable drawable;
    GLXFBConfig config;
    int is_pbuffer;
    int is_pixmap;
    int width, height;   /* pbuffers only; windows are asked of GLX */
};

struct egl_context {
    struct egl_display *dsp;
    GLXContext ctx;
    GLXFBConfig config;
    EGLenum api;
};

static struct egl_display *displays;
static __thread EGLint tls_error = EGL_SUCCESS;
static __thread EGLenum tls_api = EGL_OPENGL_ES_API;
static __thread struct egl_context *tls_ctx;
static __thread struct egl_surface *tls_draw, *tls_read;

static EGLBoolean fail(EGLint err, const char *why)
{
    tls_error = err;
    D("refusing: %s (0x%x)", why, err);
    return EGL_FALSE;
}

static struct egl_display *disp_of(EGLDisplay d)
{
    struct egl_display *e;
    for (e = displays; e; e = e->next)
        if ((EGLDisplay)e == d) return e;
    return NULL;
}

/* ⛔ Resolve against the DRIVER's libGL, not whatever libGL.so.1 resolves to
 * globally: this library exists precisely because the search path matters. */
static void *load_gl(void)
{
    static void *h;
    if (h) return h;
    h = dlopen("/opt/x11-19/lib/nvidia/libGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) h = dlopen("libGL.so.1", RTLD_NOW | RTLD_GLOBAL);
    return h;
}

static void __attribute__((constructor)) init_shim(void)
{
    void *gl, *x11;
    const char *e = getenv("EMBER_EGL_DEBUG");
    dbg = e && *e && strcmp(e, "0");

    gl = load_gl();
    if (!gl) { D("libGL.so.1 will not load: %s", dlerror()); return; }
    x11 = dlopen("libX11.so.6", RTLD_NOW);

#define SYM(n) p_##n = dlsym(gl, #n)
    SYM(glXGetFBConfigs); SYM(glXGetFBConfigAttrib); SYM(glXGetVisualFromFBConfig);
    SYM(glXCreateWindow); SYM(glXDestroyWindow); SYM(glXCreatePbuffer);
    SYM(glXDestroyPbuffer); SYM(glXCreateNewContext); SYM(glXDestroyContext);
    SYM(glXMakeContextCurrent); SYM(glXSwapBuffers); SYM(glXGetCurrentContext);
    SYM(glXGetCurrentDrawable); SYM(glXGetCurrentDisplay); SYM(glXWaitGL);
    SYM(glXWaitX); SYM(glXQueryVersion); SYM(glXQueryDrawable);
    SYM(glXQueryExtensionsString); SYM(glXGetProcAddressARB);
    SYM(glXCreatePixmap); SYM(glXDestroyPixmap); SYM(glFinish);
#undef SYM
    if (x11) {
        p_XFree = dlsym(x11, "XFree");
        p_XOpenDisplay = dlsym(x11, "XOpenDisplay");
        p_XSetErrorHandler = dlsym(x11, "XSetErrorHandler");
        p_XSync = dlsym(x11, "XSync");
    }
    if (p_glXGetProcAddressARB) {
        p_glXCreateContextAttribsARB = (void *)p_glXGetProcAddressARB(
            (const unsigned char *)"glXCreateContextAttribsARB");
        p_glXSwapIntervalEXT = (void *)p_glXGetProcAddressARB(
            (const unsigned char *)"glXSwapIntervalEXT");
    }
    D("loaded; create_context_attribs=%s swap_control=%s",
      p_glXCreateContextAttribsARB ? "yes" : "no",
      p_glXSwapIntervalEXT ? "yes" : "no");
}

/* ── display ────────────────────────────────────────────────────────────── */

EGLDisplay eglGetDisplay(EGLNativeDisplayType native)
{
    struct egl_display *e;
    tls_error = EGL_SUCCESS;
    /* ⚠ EGL_DEFAULT_DISPLAY means "open one yourself". Returning NO_DISPLAY
     * here is what made eglinfo report `eglInitialize failed` with no other
     * clue — the caller never had a display to initialise. */
    if (!native) {
        static Display *own;
        if (!own && p_XOpenDisplay) own = p_XOpenDisplay(NULL);
        if (!own) { D("eglGetDisplay(DEFAULT): XOpenDisplay failed — is DISPLAY set?"); return EGL_NO_DISPLAY; }
        native = (EGLNativeDisplayType)own;
        D("eglGetDisplay(DEFAULT): opened our own X connection %p", own);
    }
    for (e = displays; e; e = e->next)
        if (e->dpy == (Display *)native) return (EGLDisplay)e;
    e = calloc(1, sizeof *e);
    if (!e) { tls_error = EGL_BAD_ALLOC; return EGL_NO_DISPLAY; }
    e->dpy = (Display *)native;
    e->next = displays; displays = e;
    D("eglGetDisplay(%p) -> %p", native, (void *)e);
    return (EGLDisplay)e;
}

EGLDisplay eglGetPlatformDisplay(EGLenum platform, void *native, const EGLAttrib *attr)
{
    (void)attr;
    if (platform != EGL_PLATFORM_X11_KHR) {
        D("eglGetPlatformDisplay: platform 0x%x is not X11 — 304 has no device or gbm platform", platform);
        tls_error = EGL_BAD_PARAMETER;
        return EGL_NO_DISPLAY;
    }
    return eglGetDisplay((EGLNativeDisplayType)native);
}

EGLDisplay eglGetPlatformDisplayEXT(EGLenum platform, void *native, const EGLint *attr)
{
    (void)attr;
    return eglGetPlatformDisplay(platform, native, NULL);
}

EGLBoolean eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
    struct egl_display *e = disp_of(dpy);
    int gmaj = 0, gmin = 0;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglInitialize on an unknown display");
    if (!p_glXGetFBConfigs) return fail(EGL_NOT_INITIALIZED, "the 304 libGL never loaded");
    if (!e->initialized) {
        if (!p_glXQueryVersion(e->dpy, &gmaj, &gmin))
            return fail(EGL_NOT_INITIALIZED, "the X server has no GLX");
        e->configs = p_glXGetFBConfigs(e->dpy, e->screen, &e->n_configs);
        if (!e->configs || e->n_configs <= 0)
            return fail(EGL_NOT_INITIALIZED, "GLX offered no framebuffer configs");
        e->initialized = 1;
        D("initialized: GLX %d.%d, %d configs", gmaj, gmin, e->n_configs);
    }
    if (major) *major = 1;
    if (minor) *minor = 4;
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglTerminate(EGLDisplay dpy)
{
    struct egl_display *e = disp_of(dpy);
    if (!e) return fail(EGL_BAD_DISPLAY, "eglTerminate on an unknown display");
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;   /* keep the config list; re-init is common and cheap */
}

const char *eglQueryString(EGLDisplay dpy, EGLint name)
{
    (void)dpy;
    tls_error = EGL_SUCCESS;
    switch (name) {
    case EGL_VENDOR:     return "Ember (EGL over GLX, NVIDIA 304)";
    case EGL_VERSION:    return "1.4 ember-egl-glx";
    case EGL_CLIENT_APIS: return "OpenGL OpenGL_ES";
    /* ⚠ Deliberately short. Every extension listed here is one a caller may
     * then depend on, and the DRM-backed ones cannot be honoured at all. */
    case EGL_EXTENSIONS: return "EGL_KHR_create_context EGL_EXT_platform_base EGL_KHR_platform_x11 EGL_EXT_swap_buffers_with_damage";
    default: tls_error = EGL_BAD_PARAMETER; return NULL;
    }
}

/* ── configs ────────────────────────────────────────────────────────────── */

static int cfg_attr(struct egl_display *e, GLXFBConfig c, int a)
{
    int v = 0;
    if (p_glXGetFBConfigAttrib(e->dpy, c, a, &v) != 0) return 0;
    return v;
}

static EGLBoolean cfg_get(struct egl_display *e, GLXFBConfig c, EGLint attr, EGLint *out)
{
    int v;
    switch (attr) {
    case EGL_RED_SIZE:     *out = cfg_attr(e, c, GLX_RED_SIZE); return EGL_TRUE;
    case EGL_GREEN_SIZE:   *out = cfg_attr(e, c, GLX_GREEN_SIZE); return EGL_TRUE;
    case EGL_BLUE_SIZE:    *out = cfg_attr(e, c, GLX_BLUE_SIZE); return EGL_TRUE;
    case EGL_ALPHA_SIZE:   *out = cfg_attr(e, c, GLX_ALPHA_SIZE); return EGL_TRUE;
    case EGL_DEPTH_SIZE:   *out = cfg_attr(e, c, GLX_DEPTH_SIZE); return EGL_TRUE;
    case EGL_STENCIL_SIZE: *out = cfg_attr(e, c, GLX_STENCIL_SIZE); return EGL_TRUE;
    case EGL_BUFFER_SIZE:  *out = cfg_attr(e, c, GLX_BUFFER_SIZE); return EGL_TRUE;
    case EGL_LEVEL:        *out = cfg_attr(e, c, GLX_LEVEL); return EGL_TRUE;
    case EGL_SAMPLES:      *out = cfg_attr(e, c, GLX_SAMPLES); return EGL_TRUE;
    case EGL_SAMPLE_BUFFERS: *out = cfg_attr(e, c, GLX_SAMPLE_BUFFERS); return EGL_TRUE;
    case EGL_CONFIG_ID:    *out = cfg_attr(e, c, GLX_FBCONFIG_ID); return EGL_TRUE;
    case EGL_MAX_PBUFFER_WIDTH:  *out = cfg_attr(e, c, GLX_MAX_PBUFFER_WIDTH); return EGL_TRUE;
    case EGL_MAX_PBUFFER_HEIGHT: *out = cfg_attr(e, c, GLX_MAX_PBUFFER_HEIGHT); return EGL_TRUE;
    case EGL_MAX_PBUFFER_PIXELS: *out = cfg_attr(e, c, GLX_MAX_PBUFFER_PIXELS); return EGL_TRUE;
    case EGL_NATIVE_RENDERABLE:  *out = cfg_attr(e, c, GLX_X_RENDERABLE) ? EGL_TRUE : EGL_FALSE; return EGL_TRUE;
    case EGL_LUMINANCE_SIZE:
    case EGL_ALPHA_MASK_SIZE:    *out = 0; return EGL_TRUE;
    case EGL_COLOR_BUFFER_TYPE:  *out = EGL_RGB_BUFFER; return EGL_TRUE;
    case EGL_MIN_SWAP_INTERVAL:  *out = 0; return EGL_TRUE;
    case EGL_MAX_SWAP_INTERVAL:  *out = 1; return EGL_TRUE;
    case EGL_BIND_TO_TEXTURE_RGB:
    case EGL_BIND_TO_TEXTURE_RGBA: *out = EGL_FALSE; return EGL_TRUE;
    case EGL_NATIVE_VISUAL_TYPE: *out = 0; return EGL_TRUE;
    case EGL_RENDERABLE_TYPE:
    case EGL_CONFORMANT:
        /* 304 can make both kinds of context out of any RGBA config. */
        *out = EGL_OPENGL_BIT | EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT;
        return EGL_TRUE;
    case EGL_SURFACE_TYPE:
        v = cfg_attr(e, c, GLX_DRAWABLE_TYPE);
        *out = ((v & GLX_WINDOW_BIT)  ? EGL_WINDOW_BIT  : 0)
             | ((v & GLX_PBUFFER_BIT) ? EGL_PBUFFER_BIT : 0)
             | ((v & GLX_PIXMAP_BIT)  ? EGL_PIXMAP_BIT  : 0);
        return EGL_TRUE;
    case EGL_CONFIG_CAVEAT:
        v = cfg_attr(e, c, GLX_CONFIG_CAVEAT);
        *out = v == GLX_SLOW_CONFIG ? EGL_SLOW_CONFIG
             : v == GLX_NON_CONFORMANT_CONFIG ? EGL_NON_CONFORMANT_CONFIG : EGL_NONE;
        return EGL_TRUE;
    case EGL_TRANSPARENT_TYPE:
        v = cfg_attr(e, c, GLX_TRANSPARENT_TYPE);
        *out = v == GLX_TRANSPARENT_RGB ? EGL_TRANSPARENT_RGB : EGL_NONE;
        return EGL_TRUE;
    case EGL_NATIVE_VISUAL_ID: {
        /* ⛔ Callers create their X window from this; a wrong answer here is a
         * BadMatch at window creation, far from the cause. */
        XVisualInfoABI *vi = p_glXGetVisualFromFBConfig ? p_glXGetVisualFromFBConfig(e->dpy, c) : NULL;
        *out = vi ? (EGLint)vi->visualid : 0;
        if (vi && p_XFree) p_XFree(vi);
        return EGL_TRUE;
    }
    default:
        return EGL_FALSE;
    }
}

EGLBoolean eglGetConfigAttrib(EGLDisplay dpy, EGLConfig cfg, EGLint attr, EGLint *value)
{
    struct egl_display *e = disp_of(dpy);
    if (!e || !e->initialized) return fail(EGL_BAD_DISPLAY, "eglGetConfigAttrib before initialize");
    if (!cfg || !value) return fail(EGL_BAD_PARAMETER, "eglGetConfigAttrib without a config");
    if (!cfg_get(e, (GLXFBConfig)cfg, attr, value))
        return fail(EGL_BAD_ATTRIBUTE, "eglGetConfigAttrib for an attribute GLX has no answer for");
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

static int usable_config(struct egl_display *e, GLXFBConfig c)
{
    return (cfg_attr(e, c, GLX_RENDER_TYPE) & GLX_RGBA_BIT)
        && (cfg_attr(e, c, GLX_DRAWABLE_TYPE) & (GLX_WINDOW_BIT | GLX_PBUFFER_BIT));
}

EGLBoolean eglGetConfigs(EGLDisplay dpy, EGLConfig *out, EGLint size, EGLint *num)
{
    struct egl_display *e = disp_of(dpy);
    int i, n = 0;
    if (!e || !e->initialized) return fail(EGL_BAD_DISPLAY, "eglGetConfigs before initialize");
    if (!num) return fail(EGL_BAD_PARAMETER, "eglGetConfigs without a count");
    for (i = 0; i < e->n_configs; i++) {
        if (!usable_config(e, e->configs[i])) continue;
        if (out && n >= size) break;
        if (out) out[n] = (EGLConfig)e->configs[i];
        n++;
    }
    *num = n;
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglChooseConfig(EGLDisplay dpy, const EGLint *attrs, EGLConfig *out,
                           EGLint size, EGLint *num)
{
    struct egl_display *e = disp_of(dpy);
    int i, n = 0;
    if (!e || !e->initialized) return fail(EGL_BAD_DISPLAY, "eglChooseConfig before initialize");
    if (!num) return fail(EGL_BAD_PARAMETER, "eglChooseConfig without a count");

    for (i = 0; i < e->n_configs; i++) {
        GLXFBConfig c = e->configs[i];
        const EGLint *a;
        int ok = 1;
        if (!usable_config(e, c)) continue;
        for (a = attrs; a && *a != EGL_NONE && ok; a += 2) {
            EGLint want = a[1], have = 0;
            if (want == EGL_DONT_CARE) continue;
            switch (a[0]) {
            case EGL_SURFACE_TYPE:
            case EGL_RENDERABLE_TYPE:
            case EGL_CONFORMANT:
                /* bitmasks: every requested bit must be present */
                if (!cfg_get(e, c, a[0], &have) || (have & want) != want) ok = 0;
                break;
            case EGL_CONFIG_ID:
            case EGL_NATIVE_VISUAL_ID:
            case EGL_CONFIG_CAVEAT:
            case EGL_COLOR_BUFFER_TYPE:
            case EGL_TRANSPARENT_TYPE:
                if (!cfg_get(e, c, a[0], &have) || have != want) ok = 0;
                break;
            case EGL_LEVEL:
                break;   /* GLX levels are not comparable the same way */
            default:
                /* the rest are "at least this much" */
                if (!cfg_get(e, c, a[0], &have)) { ok = 0; break; }
                if (have < want) ok = 0;
                break;
            }
        }
        if (!ok) continue;
        if (out && n >= size) break;
        if (out) out[n] = (EGLConfig)c;
        n++;
    }
    *num = n;
    D("eglChooseConfig -> %d config(s)", n);
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

/* ── surfaces ───────────────────────────────────────────────────────────── */

EGLSurface eglCreateWindowSurface(EGLDisplay dpy, EGLConfig cfg,
                                  EGLNativeWindowType win, const EGLint *attrs)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s;
    GLXWindow w;
    (void)attrs;
    if (!e || !e->initialized) { fail(EGL_BAD_DISPLAY, "window surface before initialize"); return EGL_NO_SURFACE; }
    if (!cfg) { fail(EGL_BAD_CONFIG, "window surface without a config"); return EGL_NO_SURFACE; }
    trap_begin();
    w = p_glXCreateWindow(e->dpy, (GLXFBConfig)cfg, (unsigned long)win, NULL);
    if (trap_end(e->dpy)) w = 0;   /* BadMatch: the window's visual is not this config's */
    if (!w) { fail(EGL_BAD_NATIVE_WINDOW, "glXCreateWindow refused the window"); return EGL_NO_SURFACE; }
    s = calloc(1, sizeof *s);
    if (!s) { fail(EGL_BAD_ALLOC, "out of memory"); return EGL_NO_SURFACE; }
    s->dsp = e; s->drawable = w; s->config = (GLXFBConfig)cfg;
    D("window surface %p for X window 0x%lx", (void *)s, (unsigned long)win);
    tls_error = EGL_SUCCESS;
    return (EGLSurface)s;
}

EGLSurface eglCreatePlatformWindowSurface(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLAttrib *a)
{
    (void)a;
    return eglCreateWindowSurface(dpy, cfg, *(EGLNativeWindowType *)win, NULL);
}

EGLSurface eglCreatePlatformWindowSurfaceEXT(EGLDisplay dpy, EGLConfig cfg, void *win, const EGLint *a)
{
    (void)a;
    return eglCreateWindowSurface(dpy, cfg, *(EGLNativeWindowType *)win, NULL);
}

EGLSurface eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig cfg, const EGLint *attrs)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s;
    int gattrs[7], n = 0, w = 0, h = 0;
    const EGLint *a;
    if (!e || !e->initialized) { fail(EGL_BAD_DISPLAY, "pbuffer before initialize"); return EGL_NO_SURFACE; }
    for (a = attrs; a && *a != EGL_NONE; a += 2) {
        if (a[0] == EGL_WIDTH)  w = a[1];
        if (a[0] == EGL_HEIGHT) h = a[1];
    }
    gattrs[n++] = GLX_PBUFFER_WIDTH;  gattrs[n++] = w;
    gattrs[n++] = GLX_PBUFFER_HEIGHT; gattrs[n++] = h;
    gattrs[n++] = 0;
    s = calloc(1, sizeof *s);
    if (!s) { fail(EGL_BAD_ALLOC, "out of memory"); return EGL_NO_SURFACE; }
    trap_begin();
    s->drawable = p_glXCreatePbuffer(e->dpy, (GLXFBConfig)cfg, gattrs);
    if (trap_end(e->dpy)) s->drawable = 0;
    if (!s->drawable) { free(s); fail(EGL_BAD_ALLOC, "glXCreatePbuffer failed"); return EGL_NO_SURFACE; }
    s->dsp = e; s->config = (GLXFBConfig)cfg; s->is_pbuffer = 1; s->width = w; s->height = h;
    tls_error = EGL_SUCCESS;
    return (EGLSurface)s;
}

EGLBoolean eglDestroySurface(EGLDisplay dpy, EGLSurface sur)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s = sur;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglDestroySurface on an unknown display");
    if (!s) return fail(EGL_BAD_SURFACE, "eglDestroySurface(NULL)");
    if (s->is_pbuffer)    p_glXDestroyPbuffer(e->dpy, s->drawable);
    else if (s->is_pixmap) { if (p_glXDestroyPixmap) p_glXDestroyPixmap(e->dpy, s->drawable); }
    else                  p_glXDestroyWindow(e->dpy, s->drawable);
    if (tls_draw == s) tls_draw = NULL;
    if (tls_read == s) tls_read = NULL;
    free(s);
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglQuerySurface(EGLDisplay dpy, EGLSurface sur, EGLint attr, EGLint *value)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s = sur;
    unsigned int v = 0;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglQuerySurface on an unknown display");
    if (!s || !value) return fail(EGL_BAD_SURFACE, "eglQuerySurface without a surface");
    switch (attr) {
    case EGL_WIDTH:
        if (s->is_pbuffer) { *value = s->width; return EGL_TRUE; }
        p_glXQueryDrawable(e->dpy, s->drawable, GLX_PBUFFER_WIDTH, &v); *value = (EGLint)v; return EGL_TRUE;
    case EGL_HEIGHT:
        if (s->is_pbuffer) { *value = s->height; return EGL_TRUE; }
        p_glXQueryDrawable(e->dpy, s->drawable, GLX_PBUFFER_HEIGHT, &v); *value = (EGLint)v; return EGL_TRUE;
    case EGL_CONFIG_ID:      return eglGetConfigAttrib(dpy, s->config, EGL_CONFIG_ID, value);
    case EGL_RENDER_BUFFER:  *value = EGL_BACK_BUFFER; return EGL_TRUE;
    case EGL_LARGEST_PBUFFER:*value = EGL_FALSE; return EGL_TRUE;
    case EGL_TEXTURE_FORMAT:
    case EGL_TEXTURE_TARGET: *value = EGL_NO_TEXTURE; return EGL_TRUE;
    case EGL_MIPMAP_TEXTURE: *value = EGL_FALSE; return EGL_TRUE;
    default: return fail(EGL_BAD_ATTRIBUTE, "eglQuerySurface for an attribute we do not keep");
    }
}

EGLBoolean eglSurfaceAttrib(EGLDisplay dpy, EGLSurface sur, EGLint attr, EGLint value)
{
    (void)dpy; (void)sur; (void)attr; (void)value;
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;   /* nothing we track; silently accepted, as EGL allows */
}

/* ── contexts ───────────────────────────────────────────────────────────── */

EGLBoolean eglBindAPI(EGLenum api)
{
    if (api != EGL_OPENGL_API && api != EGL_OPENGL_ES_API)
        return fail(EGL_BAD_PARAMETER, "eglBindAPI for an API 304 has no context type for");
    tls_api = api;
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLenum eglQueryAPI(void) { return tls_api; }

EGLContext eglCreateContext(EGLDisplay dpy, EGLConfig cfg, EGLContext share, const EGLint *attrs)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_context *c, *sh = share;
    int gattrs[11], n = 0, major = 0, minor = 0, profile = 0;
    const EGLint *a;
    if (!e || !e->initialized) { fail(EGL_BAD_DISPLAY, "eglCreateContext before initialize"); return EGL_NO_CONTEXT; }
    if (!cfg) { fail(EGL_BAD_CONFIG, "eglCreateContext without a config"); return EGL_NO_CONTEXT; }

    for (a = attrs; a && *a != EGL_NONE; a += 2) {
        if (a[0] == EGL_CONTEXT_MAJOR_VERSION) major = a[1];
        else if (a[0] == EGL_CONTEXT_MINOR_VERSION) minor = a[1];
        else if (a[0] == EGL_CONTEXT_OPENGL_PROFILE_MASK) {
            profile = a[1] & EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT
                    ? GLX_CONTEXT_CORE_PROFILE_BIT_ARB
                    : GLX_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB;
        }
    }
    if (tls_api == EGL_OPENGL_ES_API) profile = GLX_CONTEXT_ES2_PROFILE_BIT_EXT;

    c = calloc(1, sizeof *c);
    if (!c) { fail(EGL_BAD_ALLOC, "out of memory"); return EGL_NO_CONTEXT; }

    if (p_glXCreateContextAttribsARB && (major || profile)) {
        if (major) { gattrs[n++] = GLX_CONTEXT_MAJOR_VERSION_ARB; gattrs[n++] = major; }
        if (major) { gattrs[n++] = GLX_CONTEXT_MINOR_VERSION_ARB; gattrs[n++] = minor; }
        if (profile) { gattrs[n++] = GLX_CONTEXT_PROFILE_MASK_ARB; gattrs[n++] = profile; }
        gattrs[n++] = 0;
        trap_begin();
        c->ctx = p_glXCreateContextAttribsARB(e->dpy, (GLXFBConfig)cfg,
                                              sh ? sh->ctx : NULL, 1, gattrs);
        if (trap_end(e->dpy)) { c->ctx = NULL; D("GLX refused %d.%d profile 0x%x", major, minor, profile); }
    }
    /* ⚠ An explicitly requested version that 304 does not have must FAIL, not
     * quietly become GL 2.1 — a caller asking for 3.3 wants to hear no. Only a
     * request that named no version falls back to the driver's own best. */
    if (!c->ctx && !major) {
        trap_begin();
        c->ctx = p_glXCreateNewContext(e->dpy, (GLXFBConfig)cfg, GLX_RGBA_TYPE,
                                       sh ? sh->ctx : NULL, 1);
        if (trap_end(e->dpy)) c->ctx = NULL;
    }
    if (!c->ctx) { free(c); fail(EGL_BAD_MATCH, "GLX would not create that context"); return EGL_NO_CONTEXT; }
    c->dsp = e; c->config = (GLXFBConfig)cfg; c->api = tls_api;
    D("context %p (api %s, %d.%d)", (void *)c,
      tls_api == EGL_OPENGL_API ? "GL" : "GLES", major, minor);
    tls_error = EGL_SUCCESS;
    return (EGLContext)c;
}

EGLBoolean eglDestroyContext(EGLDisplay dpy, EGLContext ctx)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_context *c = ctx;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglDestroyContext on an unknown display");
    if (!c) return fail(EGL_BAD_CONTEXT, "eglDestroyContext(NULL)");
    p_glXDestroyContext(e->dpy, c->ctx);
    if (tls_ctx == c) tls_ctx = NULL;
    free(c);
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglMakeCurrent(EGLDisplay dpy, EGLSurface draw, EGLSurface read, EGLContext ctx)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_context *c = ctx;
    struct egl_surface *d = draw, *r = read;
    int ok;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglMakeCurrent on an unknown display");
    if (!c) {
        if (!p_glXMakeContextCurrent(e->dpy, 0, 0, NULL))
            return fail(EGL_BAD_ACCESS, "glXMakeContextCurrent(NULL) failed");
        tls_ctx = NULL; tls_draw = tls_read = NULL;
        tls_error = EGL_SUCCESS;
        return EGL_TRUE;
    }
    /* ⛔ SURFACELESS IS NOT AVAILABLE HERE. EGL lets a caller bind a context
     * with no surface; classic GLX requires a drawable, and 304 has neither
     * GLX_EXT_no_config_context nor a surfaceless path. Say so plainly instead
     * of letting the server answer BadMatch. */
    if (!d && !r)
        return fail(EGL_BAD_MATCH, "eglMakeCurrent with no surface: GLX on 304 needs a drawable");
    trap_begin();
    ok = p_glXMakeContextCurrent(e->dpy, d ? d->drawable : 0, r ? r->drawable : 0, c->ctx);
    if (trap_end(e->dpy)) ok = 0;
    if (!ok)
        return fail(EGL_BAD_MATCH, "glXMakeContextCurrent refused this context and drawable");
    tls_ctx = c; tls_draw = d; tls_read = r;
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLContext eglGetCurrentContext(void) { return (EGLContext)tls_ctx; }
EGLDisplay eglGetCurrentDisplay(void) { return tls_ctx ? (EGLDisplay)tls_ctx->dsp : EGL_NO_DISPLAY; }
EGLSurface eglGetCurrentSurface(EGLint which)
{
    return which == EGL_READ ? (EGLSurface)tls_read : (EGLSurface)tls_draw;
}

EGLBoolean eglQueryContext(EGLDisplay dpy, EGLContext ctx, EGLint attr, EGLint *value)
{
    struct egl_context *c = ctx;
    if (!c || !value) return fail(EGL_BAD_CONTEXT, "eglQueryContext without a context");
    switch (attr) {
    case EGL_CONFIG_ID:     return eglGetConfigAttrib(dpy, c->config, EGL_CONFIG_ID, value);
    case EGL_CONTEXT_CLIENT_VERSION: *value = c->api == EGL_OPENGL_API ? 0 : 2; return EGL_TRUE;
    case EGL_RENDER_BUFFER: *value = EGL_BACK_BUFFER; return EGL_TRUE;
    default: return fail(EGL_BAD_ATTRIBUTE, "eglQueryContext for an attribute we do not keep");
    }
}

/* ── frames ─────────────────────────────────────────────────────────────── */

EGLBoolean eglSwapBuffers(EGLDisplay dpy, EGLSurface sur)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s = sur;
    if (!e) return fail(EGL_BAD_DISPLAY, "eglSwapBuffers on an unknown display");
    if (!s) return fail(EGL_BAD_SURFACE, "eglSwapBuffers(NULL)");
    p_glXSwapBuffers(e->dpy, s->drawable);
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglSwapBuffersWithDamageEXT(EGLDisplay dpy, EGLSurface sur, EGLint *rects, EGLint n)
{
    (void)rects; (void)n;
    return eglSwapBuffers(dpy, sur);
}

EGLBoolean eglSwapInterval(EGLDisplay dpy, EGLint interval)
{
    struct egl_display *e = disp_of(dpy);
    if (!e) return fail(EGL_BAD_DISPLAY, "eglSwapInterval on an unknown display");
    if (p_glXSwapIntervalEXT && tls_draw)
        p_glXSwapIntervalEXT(e->dpy, tls_draw->drawable, interval);
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglWaitGL(void)     { if (p_glXWaitGL) p_glXWaitGL(); return EGL_TRUE; }
EGLBoolean eglWaitNative(EGLint e) { (void)e; if (p_glXWaitX) p_glXWaitX(); return EGL_TRUE; }
EGLBoolean eglWaitClient(void) { if (p_glXWaitGL) p_glXWaitGL(); return EGL_TRUE; }
EGLBoolean eglReleaseThread(void) { tls_ctx = NULL; tls_draw = tls_read = NULL; return EGL_TRUE; }

EGLint eglGetError(void)
{
    EGLint e = tls_error;
    tls_error = EGL_SUCCESS;
    return e;
}

/* ── the parts 304 cannot do, refused rather than faked ─────────────────── */

EGLBoolean eglBindTexImage(EGLDisplay d, EGLSurface s, EGLint b)
{ (void)d; (void)s; (void)b; return fail(EGL_BAD_MATCH, "eglBindTexImage: no texture_from_pixmap path here"); }
EGLBoolean eglReleaseTexImage(EGLDisplay d, EGLSurface s, EGLint b)
{ (void)d; (void)s; (void)b; return fail(EGL_BAD_MATCH, "eglReleaseTexImage"); }
void *eglCreateImageKHR(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b, const EGLint *a)
{ (void)d; (void)c; (void)t; (void)b; (void)a;
  fail(EGL_BAD_MATCH, "EGLImage needs a DRM device; 304 registers none"); return NULL; }
EGLBoolean eglDestroyImageKHR(EGLDisplay d, void *i)
{ (void)d; (void)i; return fail(EGL_BAD_PARAMETER, "eglDestroyImageKHR"); }
EGLBoolean eglQueryDevicesEXT(EGLint max, void **devs, EGLint *num)
{ (void)max; (void)devs; if (num) *num = 0;
  return fail(EGL_BAD_ACCESS, "EGL_EXT_device_base: enumeration needs DRM"); }

/* ── the rest of the EGL ABI ────────────────────────────────────────────── */
/*
 * ⛔ EVERY EGL ENTRY POINT MUST EXIST, EVEN THE ONES THAT REFUSE. A program
 * that LINKS libEGL resolves the whole set at load time: eglgears_x11 died with
 * `undefined symbol: eglCreatePixmapSurface` before it drew anything, because
 * this file implemented only what wine happens to call. Missing here is not
 * "unsupported", it is "will not start".
 */

EGLSurface eglCreatePixmapSurface(EGLDisplay dpy, EGLConfig cfg,
                                  EGLNativePixmapType pix, const EGLint *attrs)
{
    struct egl_display *e = disp_of(dpy);
    struct egl_surface *s;
    unsigned long gp;
    (void)attrs;
    if (!e || !e->initialized) { fail(EGL_BAD_DISPLAY, "pixmap surface before initialize"); return EGL_NO_SURFACE; }
    if (!p_glXCreatePixmap) { fail(EGL_BAD_MATCH, "this libGL has no glXCreatePixmap"); return EGL_NO_SURFACE; }
    trap_begin();
    gp = p_glXCreatePixmap(e->dpy, (GLXFBConfig)cfg, (unsigned long)pix, NULL);
    if (trap_end(e->dpy)) gp = 0;
    if (!gp) { fail(EGL_BAD_NATIVE_PIXMAP_, "glXCreatePixmap refused the pixmap"); return EGL_NO_SURFACE; }
    s = calloc(1, sizeof *s);
    if (!s) { fail(EGL_BAD_ALLOC, "out of memory"); return EGL_NO_SURFACE; }
    s->dsp = e; s->drawable = gp; s->config = (GLXFBConfig)cfg; s->is_pixmap = 1;
    tls_error = EGL_SUCCESS;
    return (EGLSurface)s;
}

EGLSurface eglCreatePlatformPixmapSurface(EGLDisplay dpy, EGLConfig cfg, void *pix, const EGLAttrib *a)
{ (void)a; return eglCreatePixmapSurface(dpy, cfg, *(EGLNativePixmapType *)pix, NULL); }
EGLSurface eglCreatePlatformPixmapSurfaceEXT(EGLDisplay dpy, EGLConfig cfg, void *pix, const EGLint *a)
{ (void)a; return eglCreatePixmapSurface(dpy, cfg, *(EGLNativePixmapType *)pix, NULL); }

EGLBoolean eglCopyBuffers(EGLDisplay d, EGLSurface s, EGLNativePixmapType t)
{ (void)d; (void)s; (void)t; return fail(EGL_BAD_MATCH, "eglCopyBuffers: no GLX equivalent to copy into a pixmap"); }

EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay d, EGLenum t, EGLClientBuffer b,
                                            EGLConfig c, const EGLint *a)
{ (void)d; (void)t; (void)b; (void)c; (void)a;
  fail(EGL_BAD_MATCH, "eglCreatePbufferFromClientBuffer: OpenVG only, never available here");
  return EGL_NO_SURFACE; }

/*
 * Fences. ⚠ Implemented honestly but bluntly: a GL fence here is a glFinish.
 * That is stronger than EGL asks for (it waits for everything, not just this
 * sync) and it is CPU-side, but it gives callers correct ordering, which is
 * what they use fences for. Nothing on 304 can do better — the fence
 * extensions it lacks are the DRM-backed ones.
 */
struct egl_sync { EGLenum type; };

void *eglCreateSync(EGLDisplay dpy, EGLenum type, const EGLAttrib *attrs)
{
    struct egl_sync *y;
    (void)attrs;
    if (!disp_of(dpy)) { fail(EGL_BAD_DISPLAY, "eglCreateSync on an unknown display"); return NULL; }
    y = calloc(1, sizeof *y);
    if (!y) { fail(EGL_BAD_ALLOC, "out of memory"); return NULL; }
    y->type = type;
    tls_error = EGL_SUCCESS;
    return y;
}
void *eglCreateSyncKHR(EGLDisplay dpy, EGLenum type, const EGLint *attrs)
{ (void)attrs; return eglCreateSync(dpy, type, NULL); }

EGLBoolean eglDestroySync(EGLDisplay dpy, void *sync)
{ (void)dpy; free(sync); tls_error = EGL_SUCCESS; return EGL_TRUE; }
EGLBoolean eglDestroySyncKHR(EGLDisplay dpy, void *sync) { return eglDestroySync(dpy, sync); }

EGLint eglClientWaitSync(EGLDisplay dpy, void *sync, EGLint flags, uint64_t timeout)
{
    (void)dpy; (void)flags; (void)timeout;
    if (!sync) { fail(EGL_BAD_PARAMETER, "eglClientWaitSync(NULL)"); return EGL_FALSE; }
    if (p_glFinish) p_glFinish();
    tls_error = EGL_SUCCESS;
    return EGL_CONDITION_SATISFIED;
}
EGLint eglClientWaitSyncKHR(EGLDisplay dpy, void *sync, EGLint flags, uint64_t timeout)
{ return eglClientWaitSync(dpy, sync, flags, timeout); }

EGLBoolean eglWaitSync(EGLDisplay dpy, void *sync, EGLint flags)
{
    (void)dpy; (void)flags;
    if (!sync) return fail(EGL_BAD_PARAMETER, "eglWaitSync(NULL)");
    if (p_glFinish) p_glFinish();
    tls_error = EGL_SUCCESS;
    return EGL_TRUE;
}

EGLBoolean eglGetSyncAttrib(EGLDisplay dpy, void *sync, EGLint attr, EGLAttrib *value)
{
    struct egl_sync *y = sync;
    (void)dpy;
    if (!y || !value) return fail(EGL_BAD_PARAMETER, "eglGetSyncAttrib without a sync");
    switch (attr) {
    case EGL_SYNC_TYPE_:      *value = y->type; return EGL_TRUE;
    case EGL_SYNC_STATUS_:    *value = EGL_SIGNALED_; return EGL_TRUE;  /* glFinish already did it */
    case EGL_SYNC_CONDITION_: *value = EGL_SYNC_PRIOR_COMMANDS_COMPLETE_; return EGL_TRUE;
    default: return fail(EGL_BAD_ATTRIBUTE, "eglGetSyncAttrib for an unknown attribute");
    }
}
EGLBoolean eglGetSyncAttribKHR(EGLDisplay dpy, void *sync, EGLint attr, EGLint *value)
{
    EGLAttrib v = 0;
    EGLBoolean r = eglGetSyncAttrib(dpy, sync, attr, &v);
    if (r && value) *value = (EGLint)v;
    return r;
}

void *eglCreateImage(EGLDisplay d, EGLContext c, EGLenum t, EGLClientBuffer b, const EGLAttrib *a)
{ (void)d; (void)c; (void)t; (void)b; (void)a;
  fail(EGL_BAD_MATCH, "EGLImage needs a DRM device; 304 registers none"); return NULL; }
EGLBoolean eglDestroyImage(EGLDisplay d, void *i)
{ (void)d; (void)i; return fail(EGL_BAD_PARAMETER, "eglDestroyImage"); }

const char *eglQueryDeviceStringEXT(void *dev, EGLint name)
{ (void)dev; (void)name; fail(EGL_BAD_ACCESS, "EGL_EXT_device_base needs DRM"); return NULL; }
EGLBoolean eglQueryDeviceAttribEXT(void *dev, EGLint attr, EGLAttrib *v)
{ (void)dev; (void)attr; (void)v; return fail(EGL_BAD_ACCESS, "EGL_EXT_device_base needs DRM"); }
EGLBoolean eglQueryDisplayAttribEXT(EGLDisplay d, EGLint attr, EGLAttrib *v)
{ (void)d; (void)attr; (void)v; return fail(EGL_BAD_ACCESS, "EGL_EXT_device_base needs DRM"); }

/* ── proc address ───────────────────────────────────────────────────────── */

__eglMustCastToProperFunctionPointerType eglGetProcAddress(const char *name)
{
    static const struct { const char *n; void *f; } own[] = {
        { "eglGetPlatformDisplayEXT", (void *)eglGetPlatformDisplayEXT },
        { "eglCreatePlatformWindowSurfaceEXT", (void *)eglCreatePlatformWindowSurfaceEXT },
        { "eglSwapBuffersWithDamageEXT", (void *)eglSwapBuffersWithDamageEXT },
        { "eglCreateImageKHR", (void *)eglCreateImageKHR },
        { "eglDestroyImageKHR", (void *)eglDestroyImageKHR },
        { "eglQueryDevicesEXT", (void *)eglQueryDevicesEXT },
        { "eglQueryDeviceStringEXT", (void *)eglQueryDeviceStringEXT },
        { "eglQueryDisplayAttribEXT", (void *)eglQueryDisplayAttribEXT },
        { "eglCreatePlatformPixmapSurfaceEXT", (void *)eglCreatePlatformPixmapSurfaceEXT },
        { "eglCreateSyncKHR", (void *)eglCreateSyncKHR },
        { "eglDestroySyncKHR", (void *)eglDestroySyncKHR },
        { "eglClientWaitSyncKHR", (void *)eglClientWaitSyncKHR },
        { "eglGetSyncAttribKHR", (void *)eglGetSyncAttribKHR },
        { NULL, NULL }
    };
    int i;
    if (!name) return NULL;
    for (i = 0; own[i].n; i++)
        if (!strcmp(name, own[i].n)) return (__eglMustCastToProperFunctionPointerType)own[i].f;
    /* ⚠ GL entry points go straight to the driver — that is the whole point. */
    if (p_glXGetProcAddressARB)
        return p_glXGetProcAddressARB((const unsigned char *)name);
    return NULL;
}
