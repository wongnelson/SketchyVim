#include "helpers.h"
#include <assert.h>
#include <mach/mach.h>
#include <objc/runtime.h>
#include <pthread.h>

// Model the autoreleased objects returned by Cocoa without requiring a UI app.
static unsigned int live_applications;

@interface TestRunningApplication : NSObject {
  pid_t _pid;
}
- (id)initWithPid:(pid_t)pid;
- (NSString *)bundleIdentifier;
@end

@implementation TestRunningApplication
- (id)initWithPid:(pid_t)pid {
  if ((self = [super init])) {
    _pid = pid;
    live_applications++;
  }
  return self;
}
- (NSString *)bundleIdentifier {
  return _pid == 2 ? nil : [NSString stringWithFormat:@"com.example.sketchyvim.test.%d", _pid];
}
- (void)dealloc {
  live_applications--;
  [super dealloc];
}
@end

static id test_application_for_pid(id self, SEL selector, pid_t pid) {
  (void)self;
  (void)selector;
  return pid == 0 ? nil : [[[TestRunningApplication alloc] initWithPid:pid] autorelease];
}

static void *test_background_ownership(void *unused) {
  (void)unused;
  // Deliberately no caller pool: window_detector.c uses a POSIX worker thread.
  for (int i = 0; i < 10000; i++) {
    char *bundle_id = get_bundle_id_for_pid(1);
    assert(bundle_id && strcmp(bundle_id, "com.example.sketchyvim.test.1") == 0);
    free(bundle_id);
    assert(live_applications == 0);
    assert(get_bundle_id_for_pid(2) == NULL);
    assert(live_applications == 0);
    assert(get_bundle_id_for_pid(0) == NULL);
  }
  return NULL;
}

static void test_bundle_lookup(void) {
  Method method = class_getClassMethod([NSRunningApplication class],
      @selector(runningApplicationWithProcessIdentifier:));
  IMP original = method_setImplementation(method, (IMP)test_application_for_pid);
  pthread_t worker;
  assert(pthread_create(&worker, NULL, test_background_ownership, NULL) == 0);
  assert(pthread_join(worker, NULL) == 0);
  method_setImplementation(method, original);
  puts("PASS: background lookup releases Cocoa objects and returns an owned string");
}

static void write_fixture(const char *path, const char *data, size_t length) {
  FILE *file = fopen(path, "wb");
  assert(file);
  assert(fwrite(data, 1, length, file) == length);
  assert(fclose(file) == 0);
}

static void test_file_reader(void) {
  char directory[] = "/tmp/sketchyvim-helpers.XXXXXX";
  assert(mkdtemp(directory));
  char path[sizeof(directory) + 32];
  snprintf(path, sizeof(path), "%s/config", directory);
  assert(read_file(path) == NULL);
  assert(read_file(directory) == NULL);

  write_fixture(path, "", 0);
  const char *text = read_file(path);
  assert(text && text[0] == '\0');
  free((void *)text);

  const char config[] = "set number\nset ignorecase\n";
  write_fixture(path, config, sizeof(config) - 1);
  text = read_file(path);
  assert(text && strcmp(text, config) == 0);
  free((void *)text);

  // A full page with no trailing NUL catches reads past the file mapping.
  size_t length = (size_t)getpagesize();
  char *data = malloc(length);
  assert(data);
  memset(data, 'x', length);
  write_fixture(path, data, length);
  for (int i = 0; i < 3000; i++) {
    text = read_file(path);
    assert(text && memcmp(text, data, length) == 0 && text[length] == '\0');
    free((void *)text);
  }
  free(data);
  assert(unlink(path) == 0);
  assert(rmdir(directory) == 0);
  puts("PASS: missing, directory, empty, text, and repeated page-sized file reads");
}

static uint64_t footprint(void) {
  task_vm_info_data_t info;
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  assert(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS);
  return info.phys_footprint;
}

static void *stress_background_lookup(void *argument) {
  pid_t pid = *(pid_t *)argument;
  for (int i = 0; i < 500; i++) free(get_bundle_id_for_pid(pid));
  uint64_t before = footprint();
  for (int i = 0; i < 10000; i++) free(get_bundle_id_for_pid(pid));
  printf("10000 real background lookups: footprint growth = %lld bytes\n",
      (long long)footprint() - (long long)before);
  return NULL;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc == 2 && strcmp(argv[1], "--stress") == 0) {
      NSRunningApplication *app = [[NSRunningApplication
          runningApplicationsWithBundleIdentifier:@"com.apple.finder"] firstObject];
      assert(app);
      pid_t pid = app.processIdentifier;
      pthread_t worker;
      assert(pthread_create(&worker, NULL, stress_background_lookup, &pid) == 0);
      assert(pthread_join(worker, NULL) == 0);
    } else {
      if (argc == 1 || strcmp(argv[1], "--bundle") == 0) test_bundle_lookup();
      if (argc == 1 || strcmp(argv[1], "--files") == 0) test_file_reader();
    }
  }
  return 0;
}
