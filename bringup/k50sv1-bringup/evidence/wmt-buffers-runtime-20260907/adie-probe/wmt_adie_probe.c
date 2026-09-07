/* Exercise the existing AArch64 read-only A-die chip-ID ioctl and copy-out ABI. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define WMT_ADIE_READ _IOWR(0xa0, 26, char *)
#define PAYLOAD_CAPACITY 1029

int main(void)
{
    unsigned char buffer[sizeof(uintptr_t) + PAYLOAD_CAPACITY + 16];
    const size_t offset = sizeof(uintptr_t);
    int fd = open("/dev/stpwmt", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        printf("{\"status\":\"FAIL\",\"operation\":\"open\",\"errno\":%d}\n", errno);
        return 1;
    }
    memset(buffer, 0xa5, sizeof(buffer));
    errno = 0;
    int result = ioctl(fd, WMT_ADIE_READ, buffer);
    int saved_errno = errno;
    int close_result = close(fd);
    int guards_ok = 1;
    for (size_t i = 0; i < sizeof(buffer); ++i) {
        if ((i < offset || i >= offset + 2) && buffer[i] != 0xa5)
            guards_ok = 0;
    }
    int passed = result == 2 && saved_errno == 0 && guards_ok && close_result == 0;
    printf("{\"status\":\"%s\",\"operation\":\"read_adie_chip_id\","
           "\"ioctl\":%lu,\"returned_bytes\":%d,\"errno\":%d,"
           "\"output_offset\":%zu,\"chip_id_le\":%u,\"guards_unchanged\":%s,"
           "\"close_result\":%d}\n",
           passed ? "PASS" : "FAIL", (unsigned long)WMT_ADIE_READ, result,
           saved_errno, offset, (unsigned)buffer[offset] | ((unsigned)buffer[offset + 1] << 8),
           guards_ok ? "true" : "false", close_result);
    return passed ? 0 : 1;
}
