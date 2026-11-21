/*
 * MinhAnh Popup v4 — minimal UIKit alert for iOS 17.
 * Uses runtime calls only; no Objective-C class definitions, no swizzling.
 * For applications the user is authorized to modify.
 */
#include <stdint.h>
#include <stddef.h>

typedef void *MAObject;
typedef void *MAClass;
typedef void *MASelector;
typedef signed char MABool;

extern MAClass objc_getClass(const char *name);
extern MASelector sel_registerName(const char *name);
extern MAObject objc_msgSend(void);
extern uint64_t dispatch_time(uint64_t when, int64_t delta);
extern void dispatch_after_f(uint64_t when, void *queue, void *context, void (*work)(void *));
extern char _dispatch_main_q;

static MAObject ma0(MAObject o, const char *method) {
    return ((MAObject (*)(MAObject, MASelector))objc_msgSend)(o, sel_registerName(method));
}
static MAObject ma1(MAObject o, const char *method, MAObject a) {
    return ((MAObject (*)(MAObject, MASelector, MAObject))objc_msgSend)(o, sel_registerName(method), a);
}
static MAObject maStr(const char *s) {
    MAClass c = objc_getClass("NSString");
    return c ? ((MAObject (*)(MAObject, MASelector, const char *))objc_msgSend)
        ((MAObject)c, sel_registerName("stringWithUTF8String:"), s) : NULL;
}
static MABool maBool(MAObject o, const char *method) {
    return ((MABool (*)(MAObject, MASelector))objc_msgSend)(o, sel_registerName(method));
}
static intptr_t maInteger(MAObject o, const char *method) {
    return ((intptr_t (*)(MAObject, MASelector))objc_msgSend)(o, sel_registerName(method));
}
static MAObject maIndex(MAObject a, uintptr_t idx) {
    return ((MAObject (*)(MAObject, MASelector, uintptr_t))objc_msgSend)
        (a, sel_registerName("objectAtIndex:"), idx);
}
static int maResponds(MAObject o, const char *method) {
    if (!o) return 0;
    return ((MABool (*)(MAObject, MASelector, MASelector))objc_msgSend)
        (o, sel_registerName("respondsToSelector:"), sel_registerName(method)) != 0;
}
static void maSchedule(double seconds, void (*work)(void *)) {
    dispatch_after_f(dispatch_time(0, (int64_t)(seconds * 1000000000.0)),
                     (void *)&_dispatch_main_q, NULL, work);
}
static MAObject maPool(void) {
    MAClass pool = objc_getClass("NSAutoreleasePool");
    return pool ? ma0((MAObject)pool, "new") : NULL;
}
static void maPoolEnd(MAObject pool) {
    if (pool) ma0(pool, "drain");
}

static int g_wasActive = 0;
static int g_shown = 0;
static int g_skipReturn = 0;
static unsigned g_ticks = 0;

static MAObject maPickWindow(MAObject app) {
    MAObject window = ma0(app, "keyWindow");
    if (window && !maBool(window, "isHidden") && ma0(window, "rootViewController"))
        return window;

    MAObject scenes = ma0(app, "connectedScenes");
    if (scenes) {
        MAObject array = ma0(scenes, "allObjects");
        uintptr_t count = (uintptr_t)maInteger(array, "count");
        for (uintptr_t i = 0; i < count && i < 32; i++) {
            MAObject scene = maIndex(array, i);
            if (!maResponds(scene, "windows")) continue;
            MAObject windows = ma0(scene, "windows");
            uintptr_t n = (uintptr_t)maInteger(windows, "count");
            for (uintptr_t j = 0; j < n && j < 32; j++) {
                MAObject w = maIndex(windows, j);
                if (w && maBool(w, "isKeyWindow") && !maBool(w, "isHidden") && ma0(w, "rootViewController"))
                    return w;
            }
        }
    }
    MAObject windows = ma0(app, "windows");
    uintptr_t n = (uintptr_t)maInteger(windows, "count");
    for (uintptr_t i = 0; i < n && i < 32; i++) {
        MAObject w = maIndex(windows, i);
        if (w && !maBool(w, "isHidden") && ma0(w, "rootViewController")) return w;
    }
    return NULL;
}

static void maOpenGroup(void) {
    MAClass urlClass = objc_getClass("NSURL");
    MAObject url = ma1((MAObject)urlClass, "URLWithString:", maStr("https://t.me/minhanhmulti"));
    MAObject app = ma0((MAObject)objc_getClass("UIApplication"), "sharedApplication");
    if (!app || !url) return;
    MAObject dict = ma0((MAObject)objc_getClass("NSDictionary"), "dictionary");
    if (maResponds(app, "openURL:options:completionHandler:")) {
        ((void (*)(MAObject, MASelector, MAObject, MAObject, void *))objc_msgSend)
            (app, sel_registerName("openURL:options:completionHandler:"), url, dict, NULL);
    } else {
        ((MABool (*)(MAObject, MASelector, MAObject))objc_msgSend)
            (app, sel_registerName("openURL:"), url);
    }
}

static int maTryPresent(MAObject app) {
    MAObject window = maPickWindow(app);
    if (!window) return 0;
    MAObject controller = ma0(window, "rootViewController");
    if (!controller) return 0;
    for (unsigned i = 0; i < 16; i++) {
        MAObject next = ma0(controller, "presentedViewController");
        if (!next) break;
        controller = next;
    }
    MAObject visibleView = ma0(controller, "viewIfLoaded");
    if (!visibleView || !ma0(visibleView, "window")) return 0;
    MAClass alertClass = objc_getClass("UIAlertController");
    MAClass actionClass = objc_getClass("UIAlertAction");
    if (!alertClass || !actionClass || !maResponds(controller, "presentViewController:animated:completion:"))
        return 0;
    if (((MABool (*)(MAObject, MASelector, MAClass))objc_msgSend)
            (controller, sel_registerName("isKindOfClass:"), alertClass)) return 0;

    MAObject alert = ((MAObject (*)(MAObject, MASelector, MAObject, MAObject, intptr_t))objc_msgSend)
        ((MAObject)alertClass, sel_registerName("alertControllerWithTitle:message:preferredStyle:"),
          maStr("Thông Báo"),
          maStr("Vào Nhóm Lấy Nhiều Mod Game Hơn Nha!!!\n\nMinhAnhMod - Multi Game"), 1);
    if (!alert) return 0;

    MAObject closeAction = ((MAObject (*)(MAObject, MASelector, MAObject, intptr_t, void *))objc_msgSend)
        ((MAObject)actionClass, sel_registerName("actionWithTitle:style:handler:"), maStr("✕ Đóng"), 1, NULL);
    if (closeAction) ma1(alert, "addAction:", closeAction);

    void (^joinHandler)(MAObject) = ^(MAObject ignored) {
        (void)ignored;
        g_skipReturn = 1;
        maOpenGroup();
    };
    MAObject joinAction = ((MAObject (*)(MAObject, MASelector, MAObject, intptr_t, void *))objc_msgSend)
        ((MAObject)actionClass, sel_registerName("actionWithTitle:style:handler:"), maStr("Vào Nhóm"), 0, (void *)joinHandler);
    if (joinAction) ma1(alert, "addAction:", joinAction);

    ((void (*)(MAObject, MASelector, MAObject, MABool, void *))objc_msgSend)
        (controller, sel_registerName("presentViewController:animated:completion:"), alert, (MABool)1, NULL);
    return 1;
}

static void maHeartbeat(void *unused) {
    (void)unused;
    MAObject pool = maPool();
    MAClass appClass = objc_getClass("UIApplication");
    MAObject app = appClass ? ma0((MAObject)appClass, "sharedApplication") : NULL;
    if (app && maInteger(app, "applicationState") == 0) {
        if (!g_wasActive) {
            g_wasActive = 1;
            g_shown = 0;
            g_ticks = 0;
            if (g_skipReturn) { g_shown = 1; g_skipReturn = 0; }
        }
        if (!g_shown && ++g_ticks >= 5 && maTryPresent(app)) g_shown = 1;
    } else {
        g_wasActive = 0;
        g_ticks = 0;
    }
    maPoolEnd(pool);
    maSchedule(1.0, maHeartbeat);
}

__attribute__((constructor)) static void maEntry(void) {
    maSchedule(4.0, maHeartbeat);
}
