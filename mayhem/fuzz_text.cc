// Small text parsers from lnav's base library behind one selector byte: relative time
// expressions, timestamp scanning, ANSI escape scrubbing and fuzzy matching.
#include <string>

#include <stdint.h>
#include <string.h>
#include <sys/time.h>

#include "base/ansi_scrubber.hh"
#include "base/date_time_scanner.hh"
#include "base/fts_fuzzy_match.hh"
#include "base/relative_time.hh"
#include "base/string_attr_type.hh"
#include "config.h"

namespace {

// lnav hands the ANSI scrubber text that was already UTF-8 validated, and the
// regexes run with PCRE2_NO_UTF_CHECK.
bool
valid_utf8(const std::string& s)
{
    size_t i = 0;
    while (i < s.size()) {
        const auto c = (unsigned char) s[i];
        size_t n;
        uint32_t cp;
        if (c < 0x80) {
            n = 1;
            cp = c;
        } else if (c >= 0xC2 && c <= 0xDF) {
            n = 2;
            cp = c & 0x1F;
        } else if (c >= 0xE0 && c <= 0xEF) {
            n = 3;
            cp = c & 0x0F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            n = 4;
            cp = c & 0x07;
        } else {
            return false;
        }
        if (i + n > s.size()) {
            return false;
        }
        for (size_t j = 1; j < n; j++) {
            const auto cc = (unsigned char) s[i + j];
            if ((cc & 0xC0) != 0x80) {
                return false;
            }
            cp = (cp << 6) | (cc & 0x3F);
        }
        if ((n == 3 && cp < 0x800) || (n == 4 && (cp < 0x10000 || cp > 0x10FFFF))
            || (cp >= 0xD800 && cp <= 0xDFFF))
        {
            return false;
        }
        i += n;
    }
    return true;
}

}  // namespace

extern "C" int
LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
    if (size == 0) {
        return -1;
    }
    const uint8_t sel = data[0] % 5;
    const std::string text((const char*) data + 1, size - 1);

    if ((sel == 2 || sel == 3) && !valid_utf8(text)) {
        return 0;
    }

    switch (sel) {
        case 0: {
            auto res = relative_time::from_str(string_fragment::from_str(text));
            if (res.isOk()) {
                auto rt = res.unwrap();
                (void) rt.to_string();
            }
            break;
        }
        case 1: {
            date_time_scanner dts;
            struct exttm tm;
            struct timeval tv;

            dts.scan(text.c_str(), text.size(), nullptr, &tm, tv, false);
            break;
        }
        case 2: {
            std::string str = text;
            string_attrs_t sa;

            sa.emplace_back(line_range{0, (int) str.size()},
                            SA_ORIGINAL_LINE.value());
            scrub_ansi_string(str, &sa);
            break;
        }
        case 3: {
            std::string str = text;

            erase_ansi_escapes(string_fragment::from_str(str));
            break;
        }
        case 4: {
            size_t nul = text.find('\0');
            std::string pattern = text.substr(0, nul);
            std::string subject
                = nul == std::string::npos ? "" : text.substr(nul + 1);
            int score = 0;

            fts::fuzzy_match(pattern.c_str(), subject.c_str(), score);
            break;
        }
    }
    return 0;
}
