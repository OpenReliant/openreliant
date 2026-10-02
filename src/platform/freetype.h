/* The FreeType interface the platform draws the outline fonts' glyphs with (`fonts.zig`),
 * translated to Zig by the build: the library, the faces it opens from memory, and the glyphs it
 * loads, makes heavier or lighter, and renders. */
#include <ft2build.h>
#include <freetype/freetype.h>
#include <freetype/ftoutln.h>
