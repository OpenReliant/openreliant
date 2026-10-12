// The bridge from Luau's parser to mission source (`source_parser.zig`, #1132). Luau's syntax tree
// is C++, so this parses the text with `Luau::Parser` and writes the tree into the flat arrays of
// `luau.h`, children before their parents. Brackets that only group an expression leave no node.
// No exception leaves it: memory running out gives a null tree.

#include "luau.h"

#include "Luau/Ast.h"
#include "Luau/Parser.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <string_view>
#include <vector>

static_assert(int(Luau::AstExprUnary::Op::Not) == OR_UNARY_NOT);
static_assert(int(Luau::AstExprUnary::Op::Minus) == OR_UNARY_MINUS);
static_assert(int(Luau::AstExprUnary::Op::Len) == OR_UNARY_LENGTH);
static_assert(int(Luau::AstExprBinary::Add) == OR_BINARY_ADD);
static_assert(int(Luau::AstExprBinary::Sub) == OR_BINARY_SUB);
static_assert(int(Luau::AstExprBinary::Mul) == OR_BINARY_MUL);
static_assert(int(Luau::AstExprBinary::Div) == OR_BINARY_DIV);
static_assert(int(Luau::AstExprBinary::FloorDiv) == OR_BINARY_FLOOR_DIV);
static_assert(int(Luau::AstExprBinary::Mod) == OR_BINARY_MOD);
static_assert(int(Luau::AstExprBinary::Pow) == OR_BINARY_POW);
static_assert(int(Luau::AstExprBinary::Concat) == OR_BINARY_CONCAT);
static_assert(int(Luau::AstExprBinary::CompareNe) == OR_BINARY_NOT_EQUAL);
static_assert(int(Luau::AstExprBinary::CompareEq) == OR_BINARY_EQUAL);
static_assert(int(Luau::AstExprBinary::CompareLt) == OR_BINARY_LESS);
static_assert(int(Luau::AstExprBinary::CompareLe) == OR_BINARY_LESS_EQUAL);
static_assert(int(Luau::AstExprBinary::CompareGt) == OR_BINARY_GREATER);
static_assert(int(Luau::AstExprBinary::CompareGe) == OR_BINARY_GREATER_EQUAL);
static_assert(int(Luau::AstExprBinary::And) == OR_BINARY_AND);
static_assert(int(Luau::AstExprBinary::Or) == OR_BINARY_OR);
static_assert(int(Luau::AstExprTable::Item::Kind::List) == OR_ITEM_LIST);
static_assert(int(Luau::AstExprTable::Item::Kind::Record) == OR_ITEM_RECORD);
static_assert(int(Luau::AstExprTable::Item::Kind::General) == OR_ITEM_GENERAL);

namespace {

// The most names, targets or parameters a node counts in its `op` byte.
constexpr size_t most_names = 255;

struct Builder {
    std::vector<OrNode> nodes;
    std::vector<uint32_t> children;
    std::string text;

    // A node of `kind` at `location`, after `kids`, its children.
    uint32_t node(uint8_t kind, const Luau::Location& location, const std::vector<uint32_t>& kids, uint8_t op = 0,
        double number = 0, std::string_view own_text = {})
    {
        OrNode made = {};
        made.kind = kind;
        made.op = op;
        made.line = location.begin.line;
        made.column = location.begin.column;
        made.first = uint32_t(children.size());
        made.count = uint32_t(kids.size());
        children.insert(children.end(), kids.begin(), kids.end());
        made.text_start = uint32_t(text.size());
        made.text_length = uint32_t(own_text.size());
        text.append(own_text);
        made.number = number;
        nodes.push_back(made);
        return uint32_t(nodes.size() - 1);
    }

    // A construct mission source doesn't use, which the compiler names where it refuses it.
    uint32_t unsupported(const Luau::Location& location, std::string_view what)
    {
        return node(OR_UNSUPPORTED, location, {}, 0, 0, what);
    }

    uint32_t block(Luau::AstStatBlock* found)
    {
        std::vector<uint32_t> kids;
        for (Luau::AstStat* stat : found->body)
            kids.push_back(statement(stat));
        return node(OR_BLOCK, found->location, kids);
    }

    uint32_t statement(Luau::AstStat* stat)
    {
        if (auto found = stat->as<Luau::AstStatBlock>())
            return block(found);
        if (auto found = stat->as<Luau::AstStatIf>())
        {
            if (found->conditionLocal)
                return unsupported(found->location, "an if that declares a local");
            std::vector<uint32_t> kids{expression(found->condition), block(found->thenbody)};
            if (found->elsebody)
                kids.push_back(statement(found->elsebody));
            return node(OR_IF, found->location, kids);
        }
        if (auto found = stat->as<Luau::AstStatReturn>())
            return node(OR_RETURN, found->location, expressions(found->list));
        if (auto found = stat->as<Luau::AstStatExpr>())
            return node(OR_CALL_STATEMENT, found->location, {expression(found->expr)});
        if (auto found = stat->as<Luau::AstStatLocal>())
        {
            if (found->vars.size > most_names)
                return unsupported(found->location, "more than 255 locals in one statement");
            std::vector<uint32_t> kids;
            for (Luau::AstLocal* local : found->vars)
                kids.push_back(node(OR_NAME, local->location, {}, 0, 0, local->name.value));
            for (uint32_t value : expressions(found->values))
                kids.push_back(value);
            return node(OR_LOCAL, found->location, kids, uint8_t(found->vars.size));
        }
        if (auto found = stat->as<Luau::AstStatAssign>())
        {
            if (found->vars.size > most_names)
                return unsupported(found->location, "more than 255 targets in one assignment");
            std::vector<uint32_t> kids = expressions(found->vars);
            for (uint32_t value : expressions(found->values))
                kids.push_back(value);
            return node(OR_ASSIGN, found->location, kids, uint8_t(found->vars.size));
        }
        if (auto found = stat->as<Luau::AstStatCompoundAssign>())
            return node(OR_COMPOUND_ASSIGN, found->location, {expression(found->var), expression(found->value)}, uint8_t(found->op));
        if (stat->is<Luau::AstStatWhile>() || stat->is<Luau::AstStatRepeat>() || stat->is<Luau::AstStatFor>() || stat->is<Luau::AstStatForIn>())
            return unsupported(stat->location, "a loop");
        if (stat->is<Luau::AstStatBreak>() || stat->is<Luau::AstStatContinue>())
            return unsupported(stat->location, "a loop's break or continue");
        if (stat->is<Luau::AstStatFunction>() || stat->is<Luau::AstStatLocalFunction>())
            return unsupported(stat->location, "a function declared by name");
        if (stat->is<Luau::AstStatTypeAlias>() || stat->is<Luau::AstStatTypeFunction>())
            return unsupported(stat->location, "a type");
        return unsupported(stat->location, "this statement");
    }

    std::vector<uint32_t> expressions(const Luau::AstArray<Luau::AstExpr*>& list)
    {
        std::vector<uint32_t> kids;
        for (Luau::AstExpr* expr : list)
            kids.push_back(expression(expr));
        return kids;
    }

    uint32_t expression(Luau::AstExpr* expr)
    {
        const Luau::Location& at = expr->location;
        if (auto found = expr->as<Luau::AstExprGroup>())
            return expression(found->expr);
        // A type assertion, `value :: type`, gives the value as it is.
        if (auto found = expr->as<Luau::AstExprTypeAssertion>())
            return expression(found->expr);
        if (expr->is<Luau::AstExprConstantNil>())
            return node(OR_NIL, at, {});
        if (auto found = expr->as<Luau::AstExprConstantBool>())
            return node(OR_BOOLEAN, at, {}, found->value ? 1 : 0);
        if (auto found = expr->as<Luau::AstExprConstantNumber>())
            return node(OR_NUMBER, at, {}, 0, found->value);
        if (auto found = expr->as<Luau::AstExprConstantInteger>())
            return node(OR_NUMBER, at, {}, 0, double(found->value));
        if (auto found = expr->as<Luau::AstExprConstantString>())
            return node(OR_STRING, at, {}, 0, 0, std::string_view(found->value.data, found->value.size));
        // A string in backquotes with nothing put into it is text like any other.
        if (auto found = expr->as<Luau::AstExprInterpString>())
        {
            if (found->expressions.size > 0)
                return unsupported(at, "a string with values put into it");
            const Luau::AstArray<char>& only = found->strings.data[0];
            return node(OR_STRING, at, {}, 0, 0, std::string_view(only.data, only.size));
        }
        if (auto found = expr->as<Luau::AstExprLocal>())
            return node(OR_LOCAL_NAME, at, {}, 0, 0, found->local->name.value);
        if (auto found = expr->as<Luau::AstExprGlobal>())
            return node(OR_GLOBAL_NAME, at, {}, 0, 0, found->name.value);
        if (auto found = expr->as<Luau::AstExprIndexName>())
            return node(OR_FIELD, at, {expression(found->expr)}, 0, 0, found->index.value);
        if (auto found = expr->as<Luau::AstExprIndexExpr>())
            return node(OR_INDEX, at, {expression(found->expr), expression(found->index)});
        if (auto found = expr->as<Luau::AstExprCall>())
        {
            if (found->self)
                return unsupported(at, "a method call");
            std::vector<uint32_t> kids{expression(found->func)};
            for (uint32_t argument : expressions(found->args))
                kids.push_back(argument);
            return node(OR_CALL, at, kids);
        }
        if (auto found = expr->as<Luau::AstExprFunction>())
        {
            if (found->vararg)
                return unsupported(at, "a function of any number of arguments");
            if (found->args.size > most_names)
                return unsupported(at, "a function of more than 255 parameters");
            std::vector<uint32_t> kids;
            for (Luau::AstLocal* parameter : found->args)
                kids.push_back(node(OR_NAME, parameter->location, {}, 0, 0, parameter->name.value));
            kids.push_back(block(found->body));
            return node(OR_FUNCTION, at, kids, uint8_t(found->args.size));
        }
        if (auto found = expr->as<Luau::AstExprTable>())
        {
            std::vector<uint32_t> kids;
            for (const Luau::AstExprTable::Item& item : found->items)
            {
                std::vector<uint32_t> pair;
                if (item.key)
                    pair.push_back(expression(item.key));
                pair.push_back(expression(item.value));
                kids.push_back(node(OR_ITEM, (item.key ? item.key : item.value)->location, pair, uint8_t(item.kind)));
            }
            return node(OR_TABLE, at, kids);
        }
        if (auto found = expr->as<Luau::AstExprUnary>())
            return node(OR_UNARY, at, {expression(found->expr)}, uint8_t(found->op));
        if (auto found = expr->as<Luau::AstExprBinary>())
            return node(OR_BINARY, at, {expression(found->left), expression(found->right)}, uint8_t(found->op));
        if (expr->is<Luau::AstExprIfElse>())
            return unsupported(at, "an if expression");
        if (expr->is<Luau::AstExprVarargs>())
            return unsupported(at, "a function's extra arguments, `...`");
        return unsupported(at, "this expression");
    }
};

// A copy of the `count` items at `items`, which `or_free` frees. Null where memory runs out.
template<typename T>
T* copy(const T* items, size_t count)
{
    T* made = static_cast<T*>(std::malloc(count == 0 ? 1 : count * sizeof(T)));
    if (made && count > 0)
        std::memcpy(made, items, count * sizeof(T));
    return made;
}

} // namespace

extern "C" OrTree* or_parse(const char* source, size_t length)
{
    OrTree* tree = static_cast<OrTree*>(std::calloc(1, sizeof(OrTree)));
    if (!tree)
        return nullptr;
    try
    {
        Luau::Allocator allocator;
        Luau::AstNameTable names(allocator);
        Luau::ParseResult result = Luau::Parser::parse(source, length, names, allocator);
        Builder builder;
        // An error that stops the parser, such as code nested too deep, leaves no chunk: the tree
        // is an empty block, with the error.
        tree->root = result.root ? builder.block(result.root) : builder.node(OR_BLOCK, Luau::Location(), {});
        std::vector<OrError> errors;
        for (const Luau::ParseError& error : result.errors)
        {
            OrError made = {};
            made.line = error.getLocation().begin.line;
            made.column = error.getLocation().begin.column;
            made.message_start = uint32_t(builder.text.size());
            made.message_length = uint32_t(error.getMessage().size());
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
        if (!tree->nodes || !tree->children || !tree->text || !tree->errors)
        {
            or_free(tree);
            return nullptr;
        }
        return tree;
    }
    catch (...)
    {
        or_free(tree);
        return nullptr;
    }
}

extern "C" void or_free(OrTree* tree)
{
    if (!tree)
        return;
    std::free(tree->nodes);
    std::free(tree->children);
    std::free(tree->text);
    std::free(tree->errors);
    std::free(tree);
}
