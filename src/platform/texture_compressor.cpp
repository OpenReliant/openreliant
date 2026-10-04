// Improvement: compresses mods' pictures for the GPU (#503): BC7 with bc7enc, BC5 with rgbcx, a row
// of 4 by 4 blocks at a time, so that the Zig side can share the rows out between threads. The
// encoders are made ready once (`openreliant_texture_compressor_init`) and only read after that.
#include <bc7enc.h>
#include <rgbcx.h>
#include <stdint.h>
#include <string.h>

namespace {

// The 4 by 4 pixels at block (`bx`, `by`) of the RGBA level `width` by `height`, in `block`. Past
// the level's edge, the last row and column repeat, so a level smaller than a block fills it.
void gather(const uint8_t *rgba, uint32_t width, uint32_t height, uint32_t bx, uint32_t by, uint8_t block[64]) {
    for (uint32_t y = 0; y < 4; ++y) {
        const uint32_t row = by * 4 + y < height ? by * 4 + y : height - 1;
        for (uint32_t x = 0; x < 4; ++x) {
            const uint32_t column = bx * 4 + x < width ? bx * 4 + x : width - 1;
            memcpy(block + (y * 4 + x) * 4, rgba + (static_cast<size_t>(row) * width + column) * 4, 4);
        }
    }
}

uint32_t blocksAcross(uint32_t pixels) { return (pixels + 3) / 4; }

} // namespace

extern "C" void openreliant_texture_compressor_init() noexcept {
    bc7enc_compress_block_init();
    rgbcx::init();
}

// What a level holds, which picks the encoder and how it weighs the error.
enum Kind { colour = 0, data = 1, normals = 2 };

// Compresses the rows of blocks from `first` to `first + count` of the RGBA level `width` by
// `height` into `out`, the level's whole compressed size: BC7 for colours, weighed as the eye sees
// them, and for data, each channel alike; BC5 of red and green for normals.
extern "C" void openreliant_compress_rows(const uint8_t *rgba, uint32_t width, uint32_t height, uint32_t first,
                                          uint32_t count, int kind, uint8_t *out) noexcept {
    bc7enc_compress_block_params params;
    bc7enc_compress_block_params_init(&params);
    if (kind == data) bc7enc_compress_block_params_init_linear_weights(&params);
    // The fastest settings, as a large picture has a million blocks.
    params.m_max_partitions = 0;
    params.m_uber_level = 0;
    const uint32_t across = blocksAcross(width);
    uint8_t block[64];
    for (uint32_t by = first; by < first + count; ++by) {
        for (uint32_t bx = 0; bx < across; ++bx) {
            gather(rgba, width, height, bx, by, block);
            uint8_t *into = out + (static_cast<size_t>(by) * across + bx) * 16;
            if (kind == normals) rgbcx::encode_bc5_hq(into, block, 0, 1, 4);
            else bc7enc_compress_block(into, block, &params);
        }
    }
}
