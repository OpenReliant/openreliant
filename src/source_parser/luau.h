/* The bridge between Luau's parser and mission source (`source_parser.zig`). Luau's syntax tree is
 * C++, so `luau.cpp` writes it into these flat arrays, which Zig reads as the library's tree
 * (`formats/dte/source/syntax.zig`). Lines and columns count from 0, as Luau counts them. */
#ifndef OPENRELIANT_SOURCE_PARSER_LUAU_H
#define OPENRELIANT_SOURCE_PARSER_LUAU_H

#include <stddef.h>
#include <stdint.h>

/* The kinds of node, which `syntax.Kind` repeats. */
enum {
    /* Statements. */
    OR_BLOCK = 0,
    OR_IF = 1,
    OR_RETURN = 2,
    OR_CALL_STATEMENT = 3,
    OR_LOCAL = 4,
    OR_ASSIGN = 5,
    OR_COMPOUND_ASSIGN = 6,
    /* Expressions. */
    OR_NIL = 20,
    OR_BOOLEAN = 21,
    OR_NUMBER = 22,
    OR_STRING = 23,
    OR_LOCAL_NAME = 24,
    OR_GLOBAL_NAME = 25,
    OR_FIELD = 26,
    OR_INDEX = 27,
    OR_CALL = 28,
    OR_FUNCTION = 29,
    OR_TABLE = 30,
    OR_ITEM = 31,
    OR_UNARY = 32,
    OR_BINARY = 33,
    OR_NAME = 34,
    /* Anything else Luau writes, such as a loop. */
    OR_UNSUPPORTED = 40,
};

/* The operators of unary, binary and compound assignment nodes, and the kinds of a table's item:
 * `value`, `key = value` and `[key] = value`, as Luau numbers them. */
enum {
    OR_UNARY_NOT = 0,
    OR_UNARY_MINUS = 1,
    OR_UNARY_LENGTH = 2,
};
enum {
    OR_BINARY_ADD = 0,
    OR_BINARY_SUB = 1,
    OR_BINARY_MUL = 2,
    OR_BINARY_DIV = 3,
    OR_BINARY_FLOOR_DIV = 4,
    OR_BINARY_MOD = 5,
    OR_BINARY_POW = 6,
    OR_BINARY_CONCAT = 7,
    OR_BINARY_NOT_EQUAL = 8,
    OR_BINARY_EQUAL = 9,
    OR_BINARY_LESS = 10,
    OR_BINARY_LESS_EQUAL = 11,
    OR_BINARY_GREATER = 12,
    OR_BINARY_GREATER_EQUAL = 13,
    OR_BINARY_AND = 14,
    OR_BINARY_OR = 15,
};
enum {
    OR_ITEM_LIST = 0,
    OR_ITEM_RECORD = 1,
    OR_ITEM_GENERAL = 2,
};

/* A node. Its kind decides what `op` holds (`syntax.Node.op`). `first` and `count` give its
 * children's indices in `OrTree.children`, and `text_start` and `text_length` its text in
 * `OrTree.text`. */
typedef struct {
    uint8_t kind;
    uint8_t op;
    uint32_t line;
    uint32_t column;
    uint32_t first;
    uint32_t count;
    uint32_t text_start;
    uint32_t text_length;
    double number;
} OrNode;

/* An error the parser found, its message in `OrTree.text`. */
typedef struct {
    uint32_t line;
    uint32_t column;
    uint32_t message_start;
    uint32_t message_length;
} OrError;

/* A parsed file. `or_free` frees it with its arrays. */
typedef struct {
    OrNode *nodes;
    size_t node_count;
    uint32_t *children;
    size_t child_count;
    char *text;
    size_t text_length;
    OrError *errors;
    size_t error_count;
    /* The chunk's block, by its index in `nodes`. */
    uint32_t root;
} OrTree;

#ifdef __cplusplus
extern "C" {
#endif

/* Parses `length` bytes of `source` as Luau. Null where memory runs out. */
OrTree *or_parse(const char *source, size_t length);

/* Frees what `or_parse` gave. */
void or_free(OrTree *tree);

#ifdef __cplusplus
}
#endif

#endif
