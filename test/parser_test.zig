const std = @import("std");
const ndq = @import("ndq");
const lexer = ndq.lexer;
const parser = ndq.parser;
const test_utils = @import("test_utils.zig");

const testing = std.testing;
const mem = std.mem;
const Token = lexer.Token;
const Keyword = lexer.Keyword;
const ASTNode = parser.ASTNode;
const SyntaxError = parser.SyntaxError;
const Parse = parser.Parse;

// Tests

fn runQuery(allocator: mem.Allocator, query: []const u8) !struct { *ASTNode, lexer.Tokenizer } {
    var tokenizer = try lexer.Tokenizer.init(allocator, query);
    errdefer tokenizer.deinit();

    var root = try Parse(allocator, tokenizer.tokens);
    errdefer root.deinit(allocator);

    return .{ root, tokenizer };
}

test "parse bare expression" {
    const allocator = std.testing.allocator;
    const isAstEqual = test_utils.isAstEqual;
    var fail: usize = 0;
    var failed_query: [6][]const u8 = undefined;
    case: {
        const query = "person.name = \"sarthak\"";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..3] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[4..5] },
                .tokens_consumed = 5,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "age >= 18";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..1] },
                .op = Keyword.__gte__,
                .term2 = .{ .kind = .value, .value = tokens[2..3] },
                .tokens_consumed = 3,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "active = true & deleted = null";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var active: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..1] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[2..3] },
                .tokens_consumed = 3,
            },
        };
        var deleted: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[4..5] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[6..7] },
                .tokens_consumed = 3,
            },
        };
        var oprands = [_]*ASTNode{ &active, &deleted };
        const expectation: ASTNode = .{
            .exp = .{
                .type = .AND,
                .oprands = &oprands,
                .tokens_consumed = 7,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "!score < -1.5";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var comparison: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[1..2] },
                .op = Keyword.__lt__,
                .term2 = .{ .kind = .value, .value = tokens[3..6] },
                .tokens_consumed = 5,
            },
        };
        var oprands = [_]*ASTNode{&comparison};
        const expectation: ASTNode = .{
            .exp = .{
                .type = .NOT,
                .oprands = &oprands,
                .tokens_consumed = 6,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "(country = \"IN\" | country = \"US\")";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var india: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[1..2] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[3..4] },
                .tokens_consumed = 3,
            },
        };
        var usa: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[5..6] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[7..8] },
                .tokens_consumed = 3,
            },
        };
        var oprands = [_]*ASTNode{ &india, &usa };
        const expectation: ASTNode = .{
            .exp = .{
                .type = .OR,
                .oprands = &oprands,
                .tokens_consumed = 9,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "@\"odd key\" != profile.0";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..2] },
                .op = Keyword.__neq__,
                .term2 = .{ .kind = .field, .value = tokens[3..6] },
                .tokens_consumed = 6,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }

    if (fail > 0) {
        std.debug.print("Failed queries:\n", .{});
        for (failed_query[0..fail]) |query| {
            std.debug.print("  {s}\n", .{query});
        }
    }
    try testing.expect(fail == 0);
}

test "parse operator precedence" {
    const allocator = testing.allocator;
    const isAstEqual = test_utils.isAstEqual;
    var fail: usize = 0;
    var failed_query: [5][]const u8 = undefined;

    case: {
        const query = "a = 1 | b = 2 & !c = 3";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var a: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..1] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[2..3] },
                .tokens_consumed = 3,
            },
        };
        var b: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[4..5] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[6..7] },
                .tokens_consumed = 3,
            },
        };
        var c: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[9..10] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[11..12] },
                .tokens_consumed = 3,
            },
        };
        var not_oprands = [_]*ASTNode{&c};
        var not_c: ASTNode = .{
            .exp = .{
                .type = .NOT,
                .oprands = &not_oprands,
                .tokens_consumed = 4,
            },
        };
        var and_oprands = [_]*ASTNode{ &b, &not_c };
        var and_expr: ASTNode = .{
            .exp = .{
                .type = .AND,
                .oprands = &and_oprands,
                .tokens_consumed = 8,
            },
        };
        var or_oprands = [_]*ASTNode{ &a, &and_expr };
        const expectation: ASTNode = .{
            .exp = .{
                .type = .OR,
                .oprands = &or_oprands,
                .tokens_consumed = 12,
            },
        };

        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "(a = 1 | b = 2) & c = 3";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var a: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[1..2] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[3..4] },
                .tokens_consumed = 3,
            },
        };
        var b: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[5..6] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[7..8] },
                .tokens_consumed = 3,
            },
        };
        var or_oprands = [_]*ASTNode{ &a, &b };
        var or_expr: ASTNode = .{
            .exp = .{
                .type = .OR,
                .oprands = &or_oprands,
                .tokens_consumed = 9,
            },
        };
        var c: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[10..11] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[12..13] },
                .tokens_consumed = 3,
            },
        };
        var and_oprands = [_]*ASTNode{ &or_expr, &c };
        const expectation: ASTNode = .{
            .exp = .{
                .type = .AND,
                .oprands = &and_oprands,
                .tokens_consumed = 13,
            },
        };

        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }

    case: {
        const query = "!!a = 1";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var comparison: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[2..3] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[4..5] },
                .tokens_consumed = 3,
            },
        };
        var inner_oprands = [_]*ASTNode{&comparison};
        var inner_not: ASTNode = .{
            .exp = .{
                .type = .NOT,
                .oprands = &inner_oprands,
                .tokens_consumed = 4,
            },
        };
        var outer_oprands = [_]*ASTNode{&inner_not};
        const expectation: ASTNode = .{
            .exp = .{
                .type = .NOT,
                .oprands = &outer_oprands,
                .tokens_consumed = 5,
            },
        };

        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "a = 1 | b = 2 | c = 3";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        var a: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..1] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[2..3] },
                .tokens_consumed = 3,
            },
        };
        var b: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[4..5] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[6..7] },
                .tokens_consumed = 3,
            },
        };
        var c: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[8..9] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[10..11] },
                .tokens_consumed = 3,
            },
        };
        var oprands = [_]*ASTNode{ &a, &b, &c };
        const expectation: ASTNode = .{
            .exp = .{
                .type = .OR,
                .oprands = &oprands,
                .tokens_consumed = 11,
            },
        };

        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "((a = 1))";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[2..3] },
                .op = Keyword.__eq__,
                .term2 = .{ .kind = .value, .value = tokens[4..5] },
                .tokens_consumed = 7,
            },
        };

        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }

    if (fail > 0) {
        std.debug.print("Failed precedence queries:\n", .{});
        for (failed_query[0..fail]) |query| {
            std.debug.print("  {s}\n", .{query});
        }
    }
    try testing.expect(fail == 0);
}

test "parse numeric fields and remaining comparison forms" {
    const allocator = testing.allocator;
    const isAstEqual = test_utils.isAstEqual;
    var fail: usize = 0;
    var failed_query: [4][]const u8 = undefined;

    case: {
        const query = "@-1 <= data.-2.001";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..2] },
                .op = Keyword.__lte__,
                .term2 = .{ .kind = .field, .value = tokens[3..8] },
                .tokens_consumed = 8,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }
    case: {
        const query = "ratio > 0.05";
        const root, var tokenizer = runQuery(allocator, query) catch {
            failed_query[fail] = query;
            fail += 1;
            break :case;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .field, .value = tokens[0..1] },
                .op = Keyword.__gt__,
                .term2 = .{ .kind = .value, .value = tokens[2..5] },
                .tokens_consumed = 5,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = query;
            fail += 1;
        };
    }

    const term_cases = [_]struct {
        query: []const u8,
        term2_is_field: bool,
    }{
        .{ .query = "1 = field", .term2_is_field = true },
        .{ .query = "1 = 2", .term2_is_field = false },
    };

    for (term_cases) |tc| {
        const root, var tokenizer = runQuery(allocator, tc.query) catch {
            failed_query[fail] = tc.query;
            fail += 1;
            continue;
        };
        defer tokenizer.deinit();
        defer root.deinit(allocator);
        const tokens = tokenizer.tokens;

        const expectation: ASTNode = .{
            .comp = .{
                .term1 = .{ .kind = .value, .value = tokens[0..1] },
                .op = Keyword.__eq__,
                .term2 = .{
                    .kind = if (tc.term2_is_field) .field else .value,
                    .value = tokens[2..3],
                },
                .tokens_consumed = 3,
            },
        };
        testing.expect(isAstEqual(root, &expectation)) catch {
            failed_query[fail] = tc.query;
            fail += 1;
        };
    }

    if (fail > 0) {
        std.debug.print("Failed numeric-field queries:\n", .{});
        for (failed_query[0..fail]) |query| {
            std.debug.print("  {s}\n", .{query});
        }
    }
    try testing.expect(fail == 0);
}

test "reject malformed expressions" {
    const allocator = testing.allocator;
    const cases = [_]struct {
        query: []const u8,
        expected: SyntaxError,
    }{
        .{ .query = "", .expected = SyntaxError.EOFError },
        .{ .query = "a =", .expected = SyntaxError.EOFError },
        .{ .query = "a = 1 &", .expected = SyntaxError.EOFError },
        .{ .query = "(a = 1", .expected = SyntaxError.InvalidTokenError },
        .{ .query = "a = 1)", .expected = SyntaxError.UnexpectedTokenError },
        .{ .query = "@ name = 1", .expected = SyntaxError.SyntaxError },
        .{ .query = "a .b = 1", .expected = SyntaxError.SyntaxError },
        .{ .query = "a. b = 1", .expected = SyntaxError.SyntaxError },
        .{ .query = "a = 1 . 2", .expected = SyntaxError.UnexpectedTokenError },
        .{ .query = "a = 01", .expected = SyntaxError.SyntaxError },
        .{ .query = "a == 1", .expected = SyntaxError.SyntaxError },
        .{ .query = "a & 1", .expected = SyntaxError.UnexpectedTokenError },
        .{ .query = "a foo 1", .expected = SyntaxError.UnexpectedTokenError },
        .{ .query = "a..b = 1", .expected = SyntaxError.SyntaxError },
        .{ .query = "@@field = 1", .expected = SyntaxError.SyntaxError },
    };

    var fail: usize = 0;
    var failed_query: [cases.len][]const u8 = undefined;

    for (cases) |tc| {
        var tokenizer = try lexer.Tokenizer.init(allocator, tc.query);
        defer tokenizer.deinit();

        if (Parse(allocator, tokenizer.tokens)) |root| {
            root.deinit(allocator);
            failed_query[fail] = tc.query;
            fail += 1;
        } else |err| {
            testing.expectEqual(tc.expected, err) catch {
                failed_query[fail] = tc.query;
                fail += 1;
            };
        }
    }

    if (fail > 0) {
        std.debug.print("Malformed queries with unexpected results:\n", .{});
        for (failed_query[0..fail]) |query| {
            std.debug.print("  {s}\n", .{query});
        }
    }
    try testing.expect(fail == 0);
}

test "parser frees allocations on failure" {
    const queries = [_][]const u8{
        "a = 1",
        "!!a = 1",
        "(a = 1 | b = 2) & c = 3",
        "a = 1 | b = 2 & c = 3",
    };

    for (queries) |query| {
        var tokenizer = try lexer.Tokenizer.init(testing.allocator, query);
        defer tokenizer.deinit();

        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn run(allocator: mem.Allocator, tokens: []const Token) !void {
                const root = try Parse(allocator, tokens);
                defer root.deinit(allocator);
            }
        }.run, .{tokenizer.tokens});
    }
}
