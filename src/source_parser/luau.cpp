// The bridge from Luau's parser to mission source (`source_parser.zig`). Luau's syntax tree is
// C++, so this parses the text with `Luau::Parser` and writes the tree into the flat arrays of
// `luau.h`, children before their parents. Exceptions stay here: when memory runs out,
// `openreliant_parse_luau` gives null.
#include "luau.h"

#include <Luau/Ast.h>
#include <Luau/Parser.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <string_view>
#include <vector>

// The header numbers the operators and the forms of a table's item as Luau does.
static_assert(static_cast<int>(Luau::AstExprUnary::Op::Not) == OR_UNARY_NOT);
static_assert(static_cast<int>(Luau::AstExprUnary::Op::Minus) == OR_UNARY_MINUS);
static_assert(static_cast<int>(Luau::AstExprUnary::Op::Len) == OR_UNARY_LENGTH);
static_assert(Luau::AstExprBinary::Add == OR_BINARY_ADD);
static_assert(Luau::AstExprBinary::Sub == OR_BINARY_SUB);
static_assert(Luau::AstExprBinary::Mul == OR_BINARY_MUL);
static_assert(Luau::AstExprBinary::Div == OR_BINARY_DIV);
static_assert(Luau::AstExprBinary::FloorDiv == OR_BINARY_FLOOR_DIV);
static_assert(Luau::AstExprBinary::Mod == OR_BINARY_MOD);
static_assert(Luau::AstExprBinary::Pow == OR_BINARY_POW);
static_assert(Luau::AstExprBinary::Concat == OR_BINARY_CONCAT);
static_assert(Luau::AstExprBinary::CompareNe == OR_BINARY_NOT_EQUAL);
static_assert(Luau::AstExprBinary::CompareEq == OR_BINARY_EQUAL);
static_assert(Luau::AstExprBinary::CompareLt == OR_BINARY_LESS);
static_assert(Luau::AstExprBinary::CompareLe == OR_BINARY_LESS_EQUAL);
static_assert(Luau::AstExprBinary::CompareGt == OR_BINARY_GREATER);
static_assert(Luau::AstExprBinary::CompareGe == OR_BINARY_GREATER_EQUAL);
static_assert(Luau::AstExprBinary::And == OR_BINARY_AND);
static_assert(Luau::AstExprBinary::Or == OR_BINARY_OR);
static_assert(static_cast<int>(Luau::AstExprTable::Item::Kind::List) == OR_ITEM_LIST);
static_assert(static_cast<int>(Luau::AstExprTable::Item::Kind::Record) == OR_ITEM_RECORD);
static_assert(static_cast<int>(Luau::AstExprTable::Item::Kind::General) == OR_ITEM_GENERAL);

namespace {

// The most names, targets or parameters a node counts in its `op` byte.
constexpr size_t most_names = 255;

struct Builder {
    std::vector<OrNode> nodes;
    std::vector<uint32_t> children;
    std::string text;

    // Adds a node of `kind` at `location` with the children `kids`, and gives its index.
    uint32_t node(uint8_t kind, const Luau::Location &location, const std::vector<uint32_t> &kids,
                  uint8_t op = 0, double number = 0, std::string_view own_text = {}) {
        OrNode made = {};
        made.kind = kind;
        made.op = op;
        made.line = location.begin.line;
        made.column = location.begin.column;
        made.first = static_cast<uint32_t>(children.size());
        made.count = static_cast<uint32_t>(kids.size());
        children.insert(children.end(), kids.begin(), kids.end());
        made.text_start = static_cast<uint32_t>(text.size());
        made.text_length = static_cast<uint32_t>(own_text.size());
        text.append(own_text);
        made.number = number;
        nodes.push_back(made);
        return static_cast<uint32_t>(nodes.size() - 1);
    }

    // Adds an unsupported node: a construct mission source doesn't use, which `what` names, for
    // the compiler to refuse where it is.
    uint32_t unsupported(const Luau::Location &location, std::string_view what) {
        return node(OR_UNSUPPORTED, location, {}, 0, 0, what);
    }

    // Adds an unsupported node for more names, targets or parameters than a node counts.
    uint32_t tooMany(const Luau::Location &location, std::string_view what) {
        return unsupported(location, "more than " + std::to_string(most_names) + " " + std::string(what));
    }

    // Adds the name that a local or a parameter declares.
    uint32_t name(const Luau::AstLocal *local) {
        return node(OR_NAME, local->location, {}, 0, 0, local->name.value);
    }

    uint32_t string(const Luau::Location &location, const Luau::AstArray<char> &value) {
        return node(OR_STRING, location, {}, 0, 0, std::string_view(value.data, value.size));
    }

    // Adds the expressions of `list`, and puts them after `kids`.
    void append(std::vector<uint32_t> &kids, const Luau::AstArray<Luau::AstExpr *> &list) {
        for (Luau::AstExpr *expr : list) kids.push_back(expression(expr));
    }

    uint32_t block(Luau::AstStatBlock *found) {
        std::vector<uint32_t> kids;
        for (Luau::AstStat *stat : found->body) kids.push_back(statement(stat));
        return node(OR_BLOCK, found->location, kids);
    }

    uint32_t statement(Luau::AstStat *stat) {
        if (auto found = stat->as<Luau::AstStatBlock>()) return block(found);
        if (auto found = stat->as<Luau::AstStatIf>()) {
            if (found->conditionLocal) return unsupported(found->location, "an if that declares a local");
            std::vector<uint32_t> kids{expression(found->condition), block(found->thenbody)};
            if (found->elsebody) kids.push_back(statement(found->elsebody));
            return node(OR_IF, found->location, kids);
        }
        if (auto found = stat->as<Luau::AstStatReturn>()) {
            std::vector<uint32_t> kids;
            append(kids, found->list);
            return node(OR_RETURN, found->location, kids);
        }
        if (auto found = stat->as<Luau::AstStatExpr>())
            return node(OR_CALL_STATEMENT, found->location, {expression(found->expr)});
        if (auto found = stat->as<Luau::AstStatLocal>()) {
            if (found->vars.size > most_names) return tooMany(found->location, "locals in one statement");
            std::vector<uint32_t> kids;
            for (Luau::AstLocal *local : found->vars) kids.push_back(name(local));
            append(kids, found->values);
            return node(OR_LOCAL, found->location, kids, static_cast<uint8_t>(found->vars.size));
        }
        if (auto found = stat->as<Luau::AstStatAssign>()) {
            if (found->vars.size > most_names) return tooMany(found->location, "targets in one assignment");
            std::vector<uint32_t> kids;
            append(kids, found->vars);
            append(kids, found->values);
            return node(OR_ASSIGN, found->location, kids, static_cast<uint8_t>(found->vars.size));
        }
        if (auto found = stat->as<Luau::AstStatCompoundAssign>())
            return node(OR_COMPOUND_ASSIGN, found->location, {expression(found->var), expression(found->value)},
                        static_cast<uint8_t>(found->op));
        if (stat->is<Luau::AstStatWhile>() || stat->is<Luau::AstStatRepeat>() || stat->is<Luau::AstStatFor>() ||
            stat->is<Luau::AstStatForIn>())
            return unsupported(stat->location, "a loop");
        if (stat->is<Luau::AstStatBreak>() || stat->is<Luau::AstStatContinue>())
            return unsupported(stat->location, "a loop's break or continue");
        if (stat->is<Luau::AstStatFunction>() || stat->is<Luau::AstStatLocalFunction>())
            return unsupported(stat->location, "a function declared by name");
        if (stat->is<Luau::AstStatTypeAlias>() || stat->is<Luau::AstStatTypeFunction>())
            return unsupported(stat->location, "a type");
        return unsupported(stat->location, "this statement");
    }

    uint32_t expression(Luau::AstExpr *expr) {
        const Luau::Location &at = expr->location;
        // An expression in brackets, or with a type assertion such as `x :: number`, is the
        // expression itself.
        if (auto found = expr->as<Luau::AstExprGroup>()) return expression(found->expr);
        if (auto found = expr->as<Luau::AstExprTypeAssertion>()) return expression(found->expr);
        if (expr->is<Luau::AstExprConstantNil>()) return node(OR_NIL, at, {});
        if (auto found = expr->as<Luau::AstExprConstantBool>()) return node(OR_BOOLEAN, at, {}, found->value ? 1 : 0);
        if (auto found = expr->as<Luau::AstExprConstantNumber>()) return node(OR_NUMBER, at, {}, 0, found->value);
        if (auto found = expr->as<Luau::AstExprConstantInteger>())
            return node(OR_NUMBER, at, {}, 0, static_cast<double>(found->value));
        if (auto found = expr->as<Luau::AstExprConstantString>()) return string(at, found->value);
        // A string in backquotes with no values put into it is text like any other.
        if (auto found = expr->as<Luau::AstExprInterpString>()) {
            if (found->expressions.size > 0) return unsupported(at, "a string with values put into it");
            return string(at, found->strings.data[0]);
        }
        if (auto found = expr->as<Luau::AstExprLocal>()) return node(OR_LOCAL_NAME, at, {}, 0, 0, found->local->name.value);
        if (auto found = expr->as<Luau::AstExprGlobal>()) return node(OR_GLOBAL_NAME, at, {}, 0, 0, found->name.value);
        if (auto found = expr->as<Luau::AstExprIndexName>())
            return node(OR_FIELD, at, {expression(found->expr)}, 0, 0, found->index.value);
        if (auto found = expr->as<Luau::AstExprIndexExpr>())
            return node(OR_INDEX, at, {expression(found->expr), expression(found->index)});
        if (auto found = expr->as<Luau::AstExprCall>()) {
            if (found->self) return unsupported(at, "a method call");
            std::vector<uint32_t> kids{expression(found->func)};
            append(kids, found->args);
            return node(OR_CALL, at, kids);
        }
        if (auto found = expr->as<Luau::AstExprFunction>()) {
            if (found->vararg) return unsupported(at, "a function that takes `...`");
            if (found->args.size > most_names) return tooMany(at, "parameters in one function");
            std::vector<uint32_t> kids;
            for (Luau::AstLocal *parameter : found->args) kids.push_back(name(parameter));
            kids.push_back(block(found->body));
            return node(OR_FUNCTION, at, kids, static_cast<uint8_t>(found->args.size));
        }
        if (auto found = expr->as<Luau::AstExprTable>()) {
            std::vector<uint32_t> kids;
            for (const Luau::AstExprTable::Item &item : found->items) {
                std::vector<uint32_t> parts;
                if (item.key) parts.push_back(expression(item.key));
                parts.push_back(expression(item.value));
                // An item starts at its key, where it has one.
                kids.push_back(node(OR_ITEM, (item.key ? item.key : item.value)->location, parts,
                                    static_cast<uint8_t>(item.kind)));
            }
            return node(OR_TABLE, at, kids);
        }
        if (auto found = expr->as<Luau::AstExprUnary>())
            return node(OR_UNARY, at, {expression(found->expr)}, static_cast<uint8_t>(found->op));
        if (auto found = expr->as<Luau::AstExprBinary>())
            return node(OR_BINARY, at, {expression(found->left), expression(found->right)},
                        static_cast<uint8_t>(found->op));
        if (expr->is<Luau::AstExprIfElse>()) return unsupported(at, "an if expression");
        if (expr->is<Luau::AstExprVarargs>()) return unsupported(at, "a function's extra arguments, `...`");
        return unsupported(at, "this expression");
    }
};

// A copy of the `count` items at `items`, which `openreliant_luau_tree_free` frees. Null when
// memory runs out.
template <typename T> T *copy(const T *items, size_t count) {
    T *made = static_cast<T *>(malloc(count == 0 ? 1 : count * sizeof(T)));
    if (made && count > 0) memcpy(made, items, count * sizeof(T));
    return made;
}

} // namespace

extern "C" OrTree *openreliant_parse_luau(const char *source, size_t length) {
    OrTree *tree = static_cast<OrTree *>(calloc(1, sizeof(OrTree)));
    if (!tree) return nullptr;
    try {
        Luau::Allocator allocator;
        Luau::AstNameTable names(allocator);
        Luau::ParseResult result = Luau::Parser::parse(source, length, names, allocator);
        Builder builder;
        // An error that stops the parser, such as code nested too deep, leaves no chunk: the tree
        // is an empty block, with the error.
        tree->root = result.root ? builder.block(result.root) : builder.node(OR_BLOCK, Luau::Location(), {});
        std::vector<OrError> errors;
        for (const Luau::ParseError &error : result.errors) {
            OrError made = {};
            made.line = error.getLocation().begin.line;
            made.column = error.getLocation().begin.column;
            made.message_start = static_cast<uint32_t>(builder.text.size());
            made.message_length = static_cast<uint32_t>(error.getMessage().size());
            builder.text.append(error.getMessage());
            errors.push_back(made);
        }
        tree->nodes = copy(builder.nodes.data(), builder.nodes.size());
        tree->node_count = builder.nodes.size();
        tree->children = copy(builder.children.data(), builder.children.size());
        tree->child_count = builder.children.size();
        tree->text = copy(builder.text.data(), builder.text.size());
        tree->text_length = builder.text.size();
        tree->errors = copy(errors.data(), errors.size());
        tree->error_count = errors.size();
        if (!tree->nodes || !tree->children || !tree->text || !tree->errors) {
            openreliant_luau_tree_free(tree);
            return nullptr;
        }
        return tree;
    } catch (...) {
        openreliant_luau_tree_free(tree);
        return nullptr;
    }
}

extern "C" void openreliant_luau_tree_free(OrTree *tree) {
    if (!tree) return;
    free(tree->nodes);
    free(tree->children);
    free(tree->text);
    free(tree->errors);
    free(tree);
}
