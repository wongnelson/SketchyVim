#include "workspace.h"
#include "buffer.h"
#include "event_tap.h"

void workspace_begin(void **context) {
    workspace_context *ws_context = [workspace_context alloc];
    *context = ws_context;

    [ws_context init];

    window_detector_begin();
}

@implementation workspace_context
- (id)init {
    if ((self = [super init])) {
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self
                selector:@selector(appSwitched:)
                name:NSWorkspaceDidActivateApplicationNotification
                object:nil];

        window_detector_set_callback(window_detector_app_visibility_changed);
    }

    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)appSwitched:(NSNotification *)notification {
    char* name = NULL;
    char* bundle_id = NULL;
    pid_t pid = 0;
    if (notification && notification.userInfo) {
      NSRunningApplication* app = [notification.userInfo objectForKey:NSWorkspaceApplicationKey];
      if (app) {
        name = (char*)[[app localizedName] UTF8String];
        bundle_id = (char*)[[app bundleIdentifier] UTF8String];
        pid = app.processIdentifier;
      }
    }

    __atomic_store_n(&g_event_tap.front_app_ignored,
                     event_tap_check_blacklist(&g_event_tap, name, bundle_id),
                     __ATOMIC_RELEASE);
    ax_front_app_changed(&g_ax, pid);
}

static void window_detector_app_visibility_changed(bool any_visible) {
    if (any_visible) {
        printf("blacklisted app appeared\n");
        __atomic_store_n(&g_event_tap.front_app_ignored, true, __ATOMIC_RELEASE);
    } else {
        printf("blacklisted app disappeared\n");
        __atomic_store_n(&g_event_tap.front_app_ignored, false, __ATOMIC_RELEASE);
    }
}

@end

void workspace_end(void **context) {
    if (context && *context) {
        workspace_context *ws_context = (workspace_context *)*context;
        [ws_context dealloc];
        *context = NULL;
    }

    window_detector_end();
}
