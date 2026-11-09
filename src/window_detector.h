#pragma once
#include <stdbool.h>

void window_detector_begin(void);

void window_detector_end(void);

typedef void (*window_detector_callback)(bool any_visible);

void window_detector_set_callback(window_detector_callback callback);
