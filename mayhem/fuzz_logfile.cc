// Opens fuzzer bytes as a log file with every builtin log format loaded, then indexes it
// and reads back each line's time/level, like test/drive_logfile.cc does for its fixtures.
#include <algorithm>
#include <filesystem>
#include <memory>
#include <vector>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "base/injector.bind.hh"
#include "base/injector.hh"
#include "base/isc.hh"
#include "config.h"
#include "log_format.hh"
#include "log_format_loader.hh"
#include "logfile.hh"

static auto bound_file_options_hier
    = injector::bind<lnav::safe_file_options_hier>::to_singleton();

static std::unique_ptr<isc::supervisor> root_superv;

extern "C" int
LLVMFuzzerInitialize(int* argc, char*** argv)
{
    static auto builtin_formats
        = injector::get<std::vector<std::shared_ptr<log_format>>>();
    auto& root_formats = log_format::get_root_formats();

    root_formats.insert(
        root_formats.begin(), builtin_formats.begin(), builtin_formats.end());
    builtin_formats.clear();

    std::vector<std::filesystem::path> paths;
    std::vector<lnav::console::user_message> errors;
    load_formats(paths, errors);

    root_superv = std::make_unique<isc::supervisor>(
        injector::get<isc::service_list>());
    return 0;
}

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    const char* tmpdir = getenv("TMPDIR");
    std::string path = std::string(tmpdir != nullptr ? tmpdir : "/tmp")
        + "/fuzz_logfile.XXXXXX";
    int fd = mkstemp(path.data());
    if (fd < 0) {
        return 0;
    }
    ssize_t off = 0;
    while ((size_t) off < size) {
        ssize_t rc = write(fd, data + off, size - off);
        if (rc <= 0) {
            break;
        }
        off += rc;
    }
    close(fd);

    {
        logfile_open_options loo;
        auto open_res = logfile::open(path, loo);

        if (open_res.isOk()) {
            auto lf = open_res.unwrap();

            lf->rebuild_index();
            lf->rebuild_index();
            for (auto& ll : *lf) {
                if (ll.is_ignored()) {
                    continue;
                }
                (void) ll.get_time<std::chrono::milliseconds>();
                (void) ll.get_level_name();
            }
            for (auto iter = lf->begin(); iter != lf->end(); ++iter) {
                auto sbr = lf->read_line(iter);
                (void) sbr;
            }
        }
    }
    unlink(path.c_str());
    return 0;
}
