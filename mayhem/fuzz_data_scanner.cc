// Tokenizes a line with lnav's data scanner, then runs the data parser, the pretty
// printer and the JSON element writer over it, as test/drive_data_scanner.cc does.
#include <string>

#include <stdint.h>
#include <string.h>

#include "base/auto_mem.hh"
#include "config.h"
#include "data_parser.hh"
#include "data_scanner.hh"
#include "elem_to_json.hh"
#include "pretty_printer.hh"
#include "view_curses.hh"

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    std::string line((const char*) data, size);
    size_t nl = line.find('\n');
    if (nl != std::string::npos) {
        line.resize(nl);
    }

    {
        data_scanner ds(line);
        while (ds.tokenize2()) {
        }
    }

    data_scanner ds(line);
    data_parser dp(&ds);
    std::string msg_format;

    dp.dp_msg_format = &msg_format;
    dp.parse();

    {
        auto_mem<yajl_gen_t> gen(yajl_gen_free);

        gen = yajl_gen_alloc(nullptr);
        yajl_gen_config(gen.in(), yajl_gen_beautify, true);
        elements_to_json(gen, dp, &dp.dp_pairs);
    }

    {
        string_attrs_t sa;
        data_scanner ds2(line);
        pretty_printer pp(&ds2, sa);
        attr_line_t pretty_out;

        pp.append_to(pretty_out);
    }
    return 0;
}
