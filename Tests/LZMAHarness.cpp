#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <sstream>
#include <lzma.h>
#include "stream/lzma.hpp"
#include "util/load.hpp"

template<class Decoder> static void rejects(const std::vector<char> & header, int code) {
    Decoder decoder;
    const char * input = &header[0]; char output[32], *next = output;
    try { decoder.filter(input, input + header.size(), next, output + sizeof(output), true); }
    catch(const stream::lzma_error & error) { if(error.error() == code) return; throw; }
    throw std::runtime_error("Untrusted LZMA header was accepted");
}
template<class Decoder> static void roundtrip(lzma_vli kind, const std::vector<char> & header) {
    const char plain[] = "Gallery cursor-only decoder regression";
    lzma_options_lzma options = {}; lzma_lzma_preset(&options, 1); options.dict_size = 65536;
    lzma_filter filters[] = {{kind, &options}, {LZMA_VLI_UNKNOWN, NULL}};
    uint8_t encoded[1024]; size_t count = 0;
    if(lzma_raw_buffer_encode(filters, NULL, reinterpret_cast<const uint8_t *>(plain), sizeof(plain), encoded, &count, sizeof(encoded)) != LZMA_OK)
        throw std::runtime_error("Unable to create bounded LZMA fixture");
    std::vector<char> data = header; data.insert(data.end(), encoded, encoded + count);
    Decoder decoder; const char *input = &data[0]; char decoded[1024], *output = decoded;
    decoder.filter(input, input + data.size(), output, decoded + sizeof(decoded), true);
    if(size_t(output - decoded) != sizeof(plain) || std::memcmp(decoded, plain, sizeof(plain)))
        throw std::runtime_error("Normal Inno LZMA decoding changed");
}
int main() {
    try {
        const char huge[] = {char(255),char(255),char(255),char(255)};
        for(int mode = 0; mode < 3; ++mode) {
            std::istringstream input(mode == 0 ? std::string(huge,4) : mode == 1 ? std::string("\005\000\000\000x",5) : std::string("x"));
            std::string output; bool failed = false;
            try { util::binary_string::load(input, output); } catch(const std::exception &) { failed = true; }
            if(!failed) throw std::runtime_error("Invalid metadata length/truncation accepted");
        }
        std::istringstream valid(std::string("\003\000\000\000abc",7)); std::string text;
        util::binary_string::load(valid,text);
        if(text != "abc") throw std::runtime_error("Normal metadata parsing changed");
        const char oversized1[] = {93, char(255), char(255), char(255), char(127)};
        rejects<stream::inno_lzma1_decompressor_impl>(std::vector<char>(oversized1, oversized1 + 5), LZMA_MEMLIMIT_ERROR);
        rejects<stream::inno_lzma2_decompressor_impl>(std::vector<char>(1,40), LZMA_MEMLIMIT_ERROR);
        rejects<stream::inno_lzma2_decompressor_impl>(std::vector<char>(1,41), LZMA_FORMAT_ERROR);
        const char regular[] = {93,0,0,1,0};
        roundtrip<stream::inno_lzma1_decompressor_impl>(LZMA_FILTER_LZMA1, std::vector<char>(regular, regular + 5));
        roundtrip<stream::inno_lzma2_decompressor_impl>(LZMA_FILTER_LZMA2, std::vector<char>(1,8));
        std::printf("PASS bounded metadata/truncation and LZMA1/2 reject huge allocations; normal parsing/decoding preserved; liblzma %s\n", lzma_version_string());
        return 0;
    } catch(const std::exception & error) { std::fprintf(stderr,"FAIL %s\n",error.what()); return 1; }
}
