#include <android/looper.h>
#include <android/sensor.h>

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum {
    SENSOR_IDENT = 1,
    MAX_EVENTS = 32,
};

typedef struct {
    int type;
    const char *label;
    const ASensor *sensor;
    unsigned long count;
    float minimum;
    float maximum;
    bool initialized;
} ProbeTarget;

static double monotonic_seconds(void) {
    struct timespec now;

    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("clock_gettime");
        exit(2);
    }

    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static int parse_duration(const char *value) {
    char *end = NULL;
    long duration;

    errno = 0;
    duration = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || duration < 1 || duration > 120) {
        fprintf(stderr, "duration must be an integer from 1 to 120 seconds\n");
        exit(2);
    }

    return (int)duration;
}

static ProbeTarget *find_target(ProbeTarget *targets, size_t target_count, int type) {
    size_t index;

    for (index = 0; index < target_count; ++index) {
        if (targets[index].type == type) {
            return &targets[index];
        }
    }

    return NULL;
}

static void update_target(ProbeTarget *target, float value) {
    target->count += 1;
    if (!target->initialized) {
        target->minimum = value;
        target->maximum = value;
        target->initialized = true;
        return;
    }

    if (value < target->minimum) {
        target->minimum = value;
    }
    if (value > target->maximum) {
        target->maximum = value;
    }
}

int main(int argc, char **argv) {
    const int duration = argc > 1 ? parse_duration(argv[1]) : 20;
    ProbeTarget targets[] = {
        {.type = ASENSOR_TYPE_ACCELEROMETER, .label = "ACCELEROMETER"},
        {.type = ASENSOR_TYPE_LIGHT, .label = "LIGHT"},
        {.type = ASENSOR_TYPE_PROXIMITY, .label = "PROXIMITY"},
    };
    const size_t target_count = sizeof(targets) / sizeof(targets[0]);
    ASensorManager *manager;
    ASensorList sensors;
    ALooper *looper;
    ASensorEventQueue *queue;
    int sensor_count;
    size_t index;
    double deadline;

    if (argc > 2) {
        fprintf(stderr, "usage: %s [duration-seconds]\n", argv[0]);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);

    manager = ASensorManager_getInstanceForPackage("local.sensor.probe");
    if (manager == NULL) {
        fprintf(stderr, "ASensorManager_getInstanceForPackage failed\n");
        return 1;
    }

    sensor_count = ASensorManager_getSensorList(manager, &sensors);
    if (sensor_count < 0) {
        fprintf(stderr, "ASensorManager_getSensorList failed: %d\n", sensor_count);
        return 1;
    }

    printf("sensor_count=%d\n", sensor_count);
    for (int sensor_index = 0; sensor_index < sensor_count; ++sensor_index) {
        const ASensor *sensor = sensors[sensor_index];

        printf("sensor[%d] type=%d name=%s vendor=%s min_delay_us=%d resolution=%g\n",
               sensor_index,
               ASensor_getType(sensor),
               ASensor_getName(sensor),
               ASensor_getVendor(sensor),
               ASensor_getMinDelay(sensor),
               ASensor_getResolution(sensor));
    }

    looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
    if (looper == NULL) {
        fprintf(stderr, "ALooper_prepare failed\n");
        return 1;
    }

    queue = ASensorManager_createEventQueue(manager, looper, SENSOR_IDENT, NULL, NULL);
    if (queue == NULL) {
        fprintf(stderr, "ASensorManager_createEventQueue failed\n");
        return 1;
    }

    for (index = 0; index < target_count; ++index) {
        int enable_status;
        int delay_us;

        targets[index].sensor = ASensorManager_getDefaultSensor(manager, targets[index].type);
        if (targets[index].sensor == NULL) {
            printf("enable type=%d label=%s result=missing\n", targets[index].type, targets[index].label);
            continue;
        }

        enable_status = ASensorEventQueue_enableSensor(queue, targets[index].sensor);
        delay_us = ASensor_getMinDelay(targets[index].sensor);
        if (delay_us <= 0 || delay_us > 200000) {
            delay_us = 200000;
        }
        if (enable_status == 0) {
            (void)ASensorEventQueue_setEventRate(queue, targets[index].sensor, delay_us);
        }
        printf("enable type=%d label=%s result=%d (%s) rate_us=%d\n",
               targets[index].type,
               targets[index].label,
               enable_status,
               enable_status < 0 ? strerror(-enable_status) : "ok",
               delay_us);
    }

    printf("probe_seconds=%d action=alternate light/dark and cover/uncover proximity area\n", duration);
    deadline = monotonic_seconds() + (double)duration;

    while (monotonic_seconds() < deadline) {
        ASensorEvent events[MAX_EVENTS];
        ssize_t event_count;

        (void)ALooper_pollOnce(500, NULL, NULL, NULL);
        while ((event_count = ASensorEventQueue_getEvents(queue, events, MAX_EVENTS)) > 0) {
            for (ssize_t event_index = 0; event_index < event_count; ++event_index) {
                ASensorEvent *event = &events[event_index];
                ProbeTarget *target = find_target(targets, target_count, event->type);

                if (target == NULL) {
                    continue;
                }

                update_target(target, event->data[0]);
                if (target->type == ASENSOR_TYPE_ACCELEROMETER &&
                    target->count > 5 &&
                    target->count % 100 != 0) {
                    continue;
                }
                printf("event timestamp_ns=%" PRId64 " type=%d label=%s data=%g,%g,%g,%g\n",
                       event->timestamp,
                       event->type,
                       target->label,
                       event->data[0],
                       event->data[1],
                       event->data[2],
                       event->data[3]);
            }
        }
    }

    for (index = 0; index < target_count; ++index) {
        if (targets[index].sensor != NULL) {
            (void)ASensorEventQueue_disableSensor(queue, targets[index].sensor);
        }

        if (targets[index].initialized) {
            printf("summary type=%d label=%s events=%lu min=%g max=%g changed=%s\n",
                   targets[index].type,
                   targets[index].label,
                   targets[index].count,
                   targets[index].minimum,
                   targets[index].maximum,
                   targets[index].minimum != targets[index].maximum ? "yes" : "no");
        } else {
            printf("summary type=%d label=%s events=0 changed=no\n",
                   targets[index].type,
                   targets[index].label);
        }
    }

    ASensorManager_destroyEventQueue(manager, queue);
    return 0;
}
