#include "window_detector.h"
#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

extern char *cfstring_get_cstring(CFStringRef text_ref);
extern char *string_copy(char *s);
extern char* get_bundle_id_for_pid(uint64_t pid);

static pthread_t detector_thread;
static bool detector_running = false;
static window_detector_callback user_callback = NULL;
static char **watched_apps = NULL;
static int watched_apps_count = 0;
static bool last_visibility = false;

static bool window_detector_is_app_visible(const char *app_name) {
  CFArrayRef window_list = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly,
      kCGNullWindowID);

  if (!window_list) {
    return false;
  }

  CFIndex window_count = CFArrayGetCount(window_list);

  // First pass: check owner name (fast, no extra lookup)
  for (CFIndex i = 0; i < window_count; i++) {
    CFDictionaryRef window_info = (CFDictionaryRef)CFArrayGetValueAtIndex(window_list, i);
    if (!window_info)
      continue;

    CFStringRef owner_name = (CFStringRef)CFDictionaryGetValue(window_info, kCGWindowOwnerName);
    if (owner_name) {
      char *owner_cstring = cfstring_get_cstring(owner_name);
      if (owner_cstring && strcmp(owner_cstring, app_name) == 0) {
        free(owner_cstring);
        CFRelease(window_list);
        return true;
      }
      if (owner_cstring)
        free(owner_cstring);
    }
  }

  // Second pass: check PID -> bundle-ID (for apps listed by bundle ID)
  for (CFIndex i = 0; i < window_count; i++) {
    CFDictionaryRef window_info = (CFDictionaryRef)CFArrayGetValueAtIndex(window_list, i);
    if (!window_info)
      continue;

    CFNumberRef pid_ref = (CFNumberRef)CFDictionaryGetValue(window_info, kCGWindowOwnerPID);
    if (!pid_ref)
      continue;

    pid_t pid = 0;
    CFNumberGetValue(pid_ref, kCFNumberIntType, &pid);

    const char *bundle_id = get_bundle_id_for_pid(pid);
    if (bundle_id && strcmp(bundle_id, app_name) == 0) {
      free((char*)bundle_id);
      CFRelease(window_list);
      return true;
    }
    free((char*)bundle_id);
  }

  CFRelease(window_list);
  return false;
}

static bool window_detector_any_watched_visible(void) {
  for (int i = 0; i < watched_apps_count; i++) {
    if (window_detector_is_app_visible(watched_apps[i]))
      return true;
  }
  return false;
}

static void load_watched_apps(void) {
  char *home = getenv("HOME");
  char buf[512];
  snprintf(buf, sizeof(buf), "%s/%s", home, ".config/svim/blacklist");

  FILE *file = fopen(buf, "r");
  if (!file)
    return;

  char line[255];
  while (fgets(line, 255, file)) {
    uint32_t len = strlen(line);
    if (line[len - 1] == '\n')
      line[len - 1] = '\0';

    if (len <= 1)
      continue;

    watched_apps = realloc(watched_apps, sizeof(char *) * (watched_apps_count + 1));

    watched_apps[watched_apps_count] = string_copy(line);
    watched_apps_count++;
  }
  fclose(file);
}

static void *detector_thread_func(void *arg) {
  (void)arg;

  bool first_sample = true;

  while (detector_running) {
    bool current_visible = window_detector_any_watched_visible();

    if (first_sample || current_visible != last_visibility) {
      if (user_callback) {
        user_callback(current_visible);
      }
      last_visibility = current_visible;
      first_sample = false;
    }

    usleep(500000);
  }

  return NULL;
}

void window_detector_set_callback(window_detector_callback callback) {
  user_callback = callback;
}

void window_detector_begin(void) {
  if (detector_running)
    return;

  load_watched_apps();

  if (watched_apps_count == 0) {
    return;
  }

  detector_running = true;

  if (pthread_create(&detector_thread, NULL, detector_thread_func, NULL) != 0) {
    detector_running = false;
    return;
  }
}

void window_detector_end(void) {
  if (!detector_running)
    return;

  detector_running = false;
  pthread_join(detector_thread, NULL);

  for (int i = 0; i < watched_apps_count; i++) {
    if (watched_apps[i]) {
      free(watched_apps[i]);
    }
  }

  if (watched_apps) {
    free(watched_apps);
    watched_apps = NULL;
  }

  watched_apps_count = 0;
  last_visibility = false;
  user_callback = NULL;
}
