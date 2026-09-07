/* Host fixture declaration; production uses Android's real libcutils header. */
#ifndef TEST_PROPERTIES_H
#define TEST_PROPERTIES_H
#define PROPERTY_VALUE_MAX 92
int property_get(const char *key, char *value, const char *fallback);
int property_set(const char *key, const char *value);
#endif
