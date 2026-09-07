/* Host fixture declaration; production uses Android's real liblog header. */
#ifndef TEST_ANDROID_LOG_H
#define TEST_ANDROID_LOG_H
#define ANDROID_LOG_INFO 4
#define ANDROID_LOG_ERROR 6
int __android_log_print(int priority, const char *tag, const char *format, ...)
    __attribute__((format(printf, 3, 4)));
#endif
