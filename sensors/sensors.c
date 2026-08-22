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

  return backend->common.methods->open(&backend->common, id, device);
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

  const struct sensor_t *accelerometer = NULL;
  int accelerometer_count = 0;
  for (int i = 0; i < stock_count; ++i) {
    if (stock_sensors[i].type == SENSOR_TYPE_ACCELEROMETER) {
      accelerometer = &stock_sensors[i];
      ++accelerometer_count;
    }
  }

  if (accelerometer_count != 1) {
    ALOGE("Expected exactly one accelerometer, found %d", accelerometer_count);
    return;
  }

  visible_sensor = accelerometer;
  visible_sensor_count = 1;
  ALOGI("Exposing the sole accelerometer from %d Stock sensor entries",
        stock_count);
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
