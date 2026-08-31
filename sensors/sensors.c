/*
 * Copyright (C) 2026 The LineageOS Project
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#define LOG_TAG "sensors.mt6755.filter"

#include <dlfcn.h>
#include <errno.h>
#include <hardware/hardware.h>
#include <hardware/sensors.h>
#include <log/log.h>
#include <pthread.h>
#include <string.h>

#define STOCK_SENSORS_PATH "/vendor/lib64/hw/sensors.mt6755.stock.so"

static pthread_once_t backend_once = PTHREAD_ONCE_INIT;
static struct sensors_module_t *backend_module;
static int backend_error = -ENODEV;

static pthread_once_t sensor_list_once = PTHREAD_ONCE_INIT;
static struct sensor_t visible_sensor_storage;
static const struct sensor_t *visible_sensor;
static int visible_sensor_count;

static void load_backend(void) {
  void *handle = dlopen(STOCK_SENSORS_PATH, RTLD_NOW | RTLD_LOCAL);
  if (handle == NULL) {
    ALOGE("Unable to load Stock sensors backend %s: %s", STOCK_SENSORS_PATH,
          dlerror());
    return;
  }

  dlerror();
  struct sensors_module_t *module =
      (struct sensors_module_t *)dlsym(handle, HAL_MODULE_INFO_SYM_AS_STR);
  const char *error = dlerror();
  if (error != NULL || module == NULL) {
    ALOGE("Unable to resolve Stock sensors module: %s",
          error != NULL ? error : "missing HMI symbol");
    dlclose(handle);
    backend_error = -EINVAL;
    return;
  }

  if (module->common.tag != HARDWARE_MODULE_TAG || module->common.id == NULL ||
      strcmp(module->common.id, SENSORS_HARDWARE_MODULE_ID) != 0 ||
      module->common.methods == NULL || module->common.methods->open == NULL ||
      module->get_sensors_list == NULL) {
    ALOGE("Stock sensors backend has an invalid legacy HAL contract");
    dlclose(handle);
    backend_error = -EINVAL;
    return;
  }

  module->common.dso = handle;
  backend_module = module;
  backend_error = 0;
}

static struct sensors_module_t *get_backend(int *error) {
  pthread_once(&backend_once, load_backend);
  if (error != NULL) {
    *error = backend_error;
  }
  return backend_module;
}

static int open_sensors(const struct hw_module_t *module, const char *id,
                        struct hw_device_t **device) {
  (void)module;

  if (id == NULL || device == NULL) {
    return -EINVAL;
  }

  int error;
  struct sensors_module_t *backend = get_backend(&error);
  if (backend == NULL) {
    return error;
  }

  int rc = backend->common.methods->open(&backend->common, id, device);
  if (rc != 0 || device == NULL || *device == NULL) {
    return rc;
  }

  /*
   * Re-point the opened device at THIS module. The stock open() sets
   * common.module to its own sensors_module_t, and a caller that enumerates
   * through device->common.module->get_sensors_list rather than through the
   * hw_get_module result would then walk the unfiltered stock list and see
   * every phantom sensor this wrapper exists to hide. The HAL service here is
   * a MediaTek prebuilt, so which of the two paths it takes cannot be settled
   * by reading source; making both paths agree costs one store.
   */
  (*device)->module = &HAL_MODULE_INFO_SYM.common;
  return 0;
}

static void initialize_sensor_list(void) {
  int error;
  struct sensors_module_t *backend = get_backend(&error);
  if (backend == NULL) {
    ALOGE("Cannot enumerate Stock sensors: %s", strerror(-error));
    return;
  }

  const struct sensor_t *stock_sensors = NULL;
  int stock_count = backend->get_sensors_list(backend, &stock_sensors);
  if (stock_count <= 0 || stock_sensors == NULL) {
    ALOGE("Stock sensors backend returned an invalid sensor list");
    return;
  }

  /*
   * Prefer the NON-WAKE-UP accelerometer when the stock HAL lists more than
   * one. MTK HALs commonly publish a wake-up and a non-wake-up entry for the
   * same physical part, and the previous "exactly one or nothing" rule would
   * then have taken this device from one working sensor to NO sensors at all --
   * no auto-rotate, no shake gestures -- behind a single ALOGE, and
   * permanently, because pthread_once never retries. Failing closed is right
   * for a phantom sensor and wrong for the only real one.
   */
  const struct sensor_t *accelerometer = NULL;
  int accelerometer_count = 0;
  for (int i = 0; i < stock_count; ++i) {
    if (stock_sensors[i].type != SENSOR_TYPE_ACCELEROMETER) {
      continue;
    }
    ++accelerometer_count;
    if (accelerometer == NULL ||
        ((accelerometer->flags & SENSOR_FLAG_WAKE_UP) != 0 &&
         (stock_sensors[i].flags & SENSOR_FLAG_WAKE_UP) == 0)) {
      accelerometer = &stock_sensors[i];
    }
  }

  if (accelerometer == NULL) {
    ALOGE("No accelerometer in %d Stock sensor entries; exposing none",
          stock_count);
    return;
  }
  if (accelerometer_count != 1) {
    ALOGW("Found %d accelerometers in %d Stock sensor entries; exposing "
          "handle %d (flags 0x%x)",
          accelerometer_count, stock_count, accelerometer->handle,
          accelerometer->flags);
  }

  /*
   * Copy rather than alias. visible_sensor used to point INTO the stock HAL's
   * own array, which is only valid for as long as that HAL keeps it alive --
   * an assumption about a blob, for the price of ~100 bytes.
   */
  visible_sensor_storage = *accelerometer;
  visible_sensor = &visible_sensor_storage;
  visible_sensor_count = 1;
  ALOGI("Exposing accelerometer handle %d from %d Stock sensor entries",
        visible_sensor_storage.handle, stock_count);
}

static int get_sensors_list(struct sensors_module_t *module,
                            const struct sensor_t **list) {
  (void)module;

  if (list == NULL) {
    return 0;
  }

  pthread_once(&sensor_list_once, initialize_sensor_list);
  *list = visible_sensor;
  return visible_sensor_count;
}

static int set_operation_mode(unsigned int mode) {
  int error;
  struct sensors_module_t *backend = get_backend(&error);
  if (backend == NULL) {
    return error;
  }
  if (backend->set_operation_mode == NULL) {
    return -EINVAL;
  }
  return backend->set_operation_mode(mode);
}

static struct hw_module_methods_t module_methods = {
    .open = open_sensors,
};

struct sensors_module_t HAL_MODULE_INFO_SYM
    __attribute__((visibility("default"))) = {
        .common =
            {
                .tag = HARDWARE_MODULE_TAG,
                .module_api_version = SENSORS_MODULE_API_VERSION_0_1,
                .hal_api_version = HARDWARE_HAL_API_VERSION,
                .id = SENSORS_HARDWARE_MODULE_ID,
                .name = "MT6755 accelerometer-only sensor filter",
                .author = "The LineageOS Project",
                .methods = &module_methods,
            },
        .get_sensors_list = get_sensors_list,
        .set_operation_mode = set_operation_mode,
};
