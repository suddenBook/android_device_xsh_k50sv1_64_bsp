#!/usr/bin/env python3
"""Run the actual calibration serializer against host files and mocked I/O."""

import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("scratch", type=Path)
args = parser.parse_args()
args.scratch.mkdir(parents=True, exist_ok=True)
source = Path(__file__).with_name("main.cpp").read_text()
functions = source[source.index("bool write_data_to_driver("):source.index("int file_event_hander(")]
constants = "\n".join(line for line in source.splitlines()
                      if line.startswith(("#define MAX_RETRY_COUNT ",
                                          "#define NVRAM_MAC_ADDRESS_OFFSET ",
                                          "#define WIFI_LOADER_DEV ",
                                          "#define WIFI_MACADDR_FILE ")))
prefix = r'''
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <cassert>
#include <algorithm>

struct NullLog { template<class T> NullLog& operator<<(const T&) { return *this; } };
#define LOG(level) NullLog()
static bool driver_ok = true, property_ok = true, change_length = false;
static std::string custom_mac, driver_bytes;
static unsigned int driver_calls, property_calls;
static unsigned int skip_sleep(unsigned int) { return 0; }
#define sleep skip_sleep
static std::string Trim(const std::string& s) {
    auto begin = s.find_first_not_of(" \t\r\n");
    return begin == std::string::npos ? "" : s.substr(begin, s.find_last_not_of(" \t\r\n") - begin + 1);
}
static bool ReadFileToString(const std::string& path, std::string* out) {
    if (path == WIFI_MACADDR_FILE) {
        *out = custom_mac;
        return !custom_mac.empty();
    }
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    *out = std::string(std::istreambuf_iterator<char>(f), {});
    if (change_length) out->push_back('!');
    return true;
}
static bool WriteStringToFile(const std::string& bytes, const std::string& path) {
    assert(path == WIFI_LOADER_DEV);
    ++driver_calls;
    driver_bytes = bytes;
    return driver_ok;
}
static bool SetProperty(const std::string& key, const std::string& value) {
    assert(key == "vendor.mtk.nvram.ready" && value == "1");
    ++property_calls;
    return property_ok;
}
'''
tests = r'''
static void reset() {
    driver_ok = property_ok = true;
    change_length = false;
    custom_mac.clear(); driver_bytes.clear(); driver_calls = property_calls = 0;
}
static std::string payload(size_t size) {
    std::string value(size, '\0');
    for (size_t i = 0; i < size; ++i) value[i] = static_cast<char>((i * 37) & 255);
    return value;
}
static void save(const std::string& path, const std::string& data) {
    std::ofstream f(path, std::ios::binary | std::ios::trunc);
    f.write(data.data(), data.size());
    assert(f.good());
}
int main(int argc, char** argv) {
    assert(argc == 2);
    std::string path = std::string(argv[1]) + "/WIFI";
    for (size_t size : {256U, 512U, 65280U}) {
        reset(); auto data = payload(size); save(path, data + "\x12\x34");
        assert(write_nvram(path));
        assert(driver_calls == 1 && property_calls == 1);
        assert(driver_bytes == "WR-BUF:NVRAM" + data);
        std::cout << "PASS complete payload/trailer size=" << size << '\n';
    }
    for (size_t size : {0U, 1U, 2U, 3U, 257U, 65538U}) {
        reset(); save(path, payload(size));
        assert(!write_nvram(path)); assert(!driver_calls && !property_calls);
        std::cout << "PASS rejected invalid file size=" << size << '\n';
    }
    reset(); assert(!write_nvram(argv[1])); assert(!driver_calls && !property_calls);
    reset(); assert(!write_nvram(path + ".missing")); assert(!driver_calls && !property_calls);
    auto data = payload(256); save(path, data + "\x12\x34");
    for (const std::string& mac : {"zz:11:22:33:44:55", "00-11:22:33:44:55", "00:11:22:33:44:5", "00:11:22:33:44:55x"}) {
        reset(); custom_mac = mac; assert(write_nvram(path));
        assert(driver_bytes == "WR-BUF:NVRAM" + data);
    }
    reset(); custom_mac = "  02:Aa:22:33:44:fF\n"; assert(write_nvram(path));
    std::string expected = "WR-BUF:NVRAM" + data;
    const unsigned char mac[] = {2, 0xaa, 0x22, 0x33, 0x44, 0xff};
    for (size_t i = 0; i < 6; ++i) expected[12 + NVRAM_MAC_ADDRESS_OFFSET + i] = mac[i];
    assert(driver_bytes == expected);
    std::cout << "PASS strict MAC validation and exact override offset\n";
    reset(); change_length = true; assert(!write_nvram(path)); assert(!driver_calls && !property_calls);
    reset(); driver_ok = false; assert(!write_nvram(path)); assert(driver_calls == 1 && !property_calls);
    reset(); property_ok = false; assert(!write_nvram(path)); assert(driver_calls == 1 && property_calls == 1);
    std::cout << "PASS read-race, driver and property failures do not report readiness\n";
}
'''

with tempfile.TemporaryDirectory(prefix="wlan-payload-", dir=args.scratch) as temporary:
    directory = Path(temporary)
    unit = directory / "test.cpp"
    unit.write_text(constants + "\n" + prefix + functions + tests)
    executable = directory / "test"
    subprocess.run(["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    str(unit), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(directory)], check=True)
