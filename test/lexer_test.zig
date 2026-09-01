const std = @import("std");
const lexer = @import("ndq").lexer;

const testing = std.testing;
const mem = std.mem;
const Keyword = lexer.Keyword;
const Token = lexer.Token;
const TokenType = lexer.TokenType;
const TokenizationError = lexer.TokenizationError;
const Tokenizer = lexer.Tokenizer;

// Tests

const Case = struct {
    query: []const u8,
    expected: []const Token,
};

const expected_keyword_map = std.StaticStringMap(Keyword).initComptime(.{
    .{ "!", .__not__ },
    .{ "@", .__at_rate__ },
    .{ "=", .__eq__ },
    .{ "!=", .__neq__ },
    .{ "&", .__and__ },
    .{ "|", .__or__ },
    .{ "<", .__lt__ },
    .{ ">", .__gt__ },
    .{ "<=", .__lte__ },
    .{ ">=", .__gte__ },
    .{ ".", .__period__ },
    .{ "(", .__lparen__ },
    .{ ")", .__rparen__ },
});

fn printTokens(tokens: []const Token) void {
    std.debug.print("total tokens: {d}\nTokens: ", .{tokens.len});

    for (tokens) |token| {
        std.debug.print(
            "{{type: {s}, value: {s}, start_offset: {d}, end_offset: {d}}}, ",
            .{ @tagName(token.type), token.raw, token.start_offset, token.end_offset },
        );
    }
    std.debug.print("\n", .{});
}

fn printCaseError(query: []const u8, expected: []const Token, actual: []const Token) void {
    std.debug.print("\nquery: {s}\nExpected:\n", .{query});
    printTokens(expected);
    std.debug.print("Actual:\n", .{});
    printTokens(actual);
}

fn expectTokens(query: []const u8, out: []const Token, exp: []const Token) !void {
    testing.expectEqual(exp.len, out.len) catch |err| {
        printCaseError(query, exp, out);
        return err;
    };

    for (out, exp) |token, expected| {
        testing.expectEqual(expected.type, token.type) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };
        testing.expectEqualStrings(expected.raw, token.raw) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };
        testing.expectEqual(expected.start_offset, token.start_offset) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };
        testing.expectEqual(expected.end_offset, token.end_offset) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };

        const expected_keyword = if (expected.type == .keyword)
            expected_keyword_map.get(expected.raw) orelse return error.UnknownExpectedKeyword
        else
            null;
        testing.expectEqual(expected_keyword, token.keyword) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };
    }
}

fn expectCases(comptime cases: []const Case) !void {
    var fail: usize = 0;
    var failed_query: [cases.len][]const u8 = undefined;

    for (cases) |tc| {
        var out = Tokenizer.init(testing.allocator, tc.query) catch |err| {
            std.debug.print("\nquery: {s} -> unexpected {any}\n", .{ tc.query, err });
            failed_query[fail] = tc.query;
            fail += 1;
            continue;
        };
        defer out.deinit();

        expectTokens(tc.query, out.tokens, tc.expected) catch {
            failed_query[fail] = tc.query;
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

test "tokenize splits bare words on delimiters and operators" {
    try expectCases(&.{
        .{
            .query = "name = sarthak",
            .expected = &.{
                .{ .type = .identifier, .raw = "name", .start_offset = 0, .end_offset = 4 },
                .{ .type = .keyword, .raw = "=", .start_offset = 5, .end_offset = 6 },
                .{ .type = .identifier, .raw = "sarthak", .start_offset = 7, .end_offset = 14 },
            },
        },
        // Repeated, leading and trailing delimiters collapse; \r and \n count.
        .{
            .query = "  name\t=\n sarthak\r\n",
            .expected = &.{
                .{ .type = .identifier, .raw = "name", .start_offset = 2, .end_offset = 6 },
                .{ .type = .keyword, .raw = "=", .start_offset = 7, .end_offset = 8 },
                .{ .type = .identifier, .raw = "sarthak", .start_offset = 10, .end_offset = 17 },
            },
        },
        .{
            .query = "= != & | < <= > >= . ) (",
            .expected = &.{
                .{ .type = .keyword, .raw = "=", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "!=", .start_offset = 2, .end_offset = 4 },
                .{ .type = .keyword, .raw = "&", .start_offset = 5, .end_offset = 6 },
                .{ .type = .keyword, .raw = "|", .start_offset = 7, .end_offset = 8 },
                .{ .type = .keyword, .raw = "<", .start_offset = 9, .end_offset = 10 },
                .{ .type = .keyword, .raw = "<=", .start_offset = 11, .end_offset = 13 },
                .{ .type = .keyword, .raw = ">", .start_offset = 14, .end_offset = 15 },
                .{ .type = .keyword, .raw = ">=", .start_offset = 16, .end_offset = 18 },
                .{ .type = .keyword, .raw = ".", .start_offset = 19, .end_offset = 20 },
                .{ .type = .keyword, .raw = ")", .start_offset = 21, .end_offset = 22 },
                .{ .type = .keyword, .raw = "(", .start_offset = 23, .end_offset = 24 },
            },
        },
        // Operators split a bare word without whitespace, longest match first.
        .{
            .query = "a<=>b",
            .expected = &.{
                .{ .type = .identifier, .raw = "a", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "<=", .start_offset = 1, .end_offset = 3 },
                .{ .type = .keyword, .raw = ">", .start_offset = 3, .end_offset = 4 },
                .{ .type = .identifier, .raw = "b", .start_offset = 4, .end_offset = 5 },
            },
        },
        .{
            .query = "a(b)c",
            .expected = &.{
                .{ .type = .identifier, .raw = "a", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "(", .start_offset = 1, .end_offset = 2 },
                .{ .type = .identifier, .raw = "b", .start_offset = 2, .end_offset = 3 },
                .{ .type = .keyword, .raw = ")", .start_offset = 3, .end_offset = 4 },
                .{ .type = .identifier, .raw = "c", .start_offset = 4, .end_offset = 5 },
            },
        },
        .{
            .query = "age 42 and or user.name",
            .expected = &.{
                .{ .type = .identifier, .raw = "age", .start_offset = 0, .end_offset = 3 },
                .{ .type = .int, .raw = "42", .start_offset = 4, .end_offset = 6 },
                .{ .type = .identifier, .raw = "and", .start_offset = 7, .end_offset = 10 },
                .{ .type = .identifier, .raw = "or", .start_offset = 11, .end_offset = 13 },
                .{ .type = .identifier, .raw = "user", .start_offset = 14, .end_offset = 18 },
                .{ .type = .keyword, .raw = ".", .start_offset = 18, .end_offset = 19 },
                .{ .type = .identifier, .raw = "name", .start_offset = 19, .end_offset = 23 },
            },
        },
        // A decimal is not a token: the parser reassembles `1 . 5` by adjacency.
        .{
            .query = "age >= 1.5",
            .expected = &.{ .{ .type = .identifier, .raw = "age", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = ">=", .start_offset = 4, .end_offset = 6 }, .{ .type = .int, .raw = "1", .start_offset = 7, .end_offset = 8 }, .{ .type = .keyword, .raw = ".", .start_offset = 8, .end_offset = 9 }, .{ .type = .int, .raw = "5", .start_offset = 9, .end_offset = 10 } },
        },
        // Offsets are byte offsets, not codepoint counts.
        .{
            .query = "x = \"café\"",
            .expected = &.{
                .{ .type = .identifier, .raw = "x", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "=", .start_offset = 2, .end_offset = 3 },
                .{ .type = .quoted, .raw = "\"café\"", .start_offset = 4, .end_offset = 11 },
            },
        },
        .{ .query = "", .expected = &.{} },
        .{ .query = " ", .expected = &.{} },
        .{ .query = "\t\n  ", .expected = &.{} },
    });
}

test "tokenize recognizes unary not and preserves longest operator matches" {
    try expectCases(&.{
        .{
            .query = "!active",
            .expected = &.{
                .{ .type = .keyword, .raw = "!", .start_offset = 0, .end_offset = 1 },
                .{ .type = .identifier, .raw = "active", .start_offset = 1, .end_offset = 7 },
            },
        },
        .{
            .query = "!!active",
            .expected = &.{
                .{ .type = .keyword, .raw = "!", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "!", .start_offset = 1, .end_offset = 2 },
                .{ .type = .identifier, .raw = "active", .start_offset = 2, .end_offset = 8 },
            },
        },
        .{
            .query = "!=active",
            .expected = &.{ .{ .type = .keyword, .raw = "!=", .start_offset = 0, .end_offset = 2 }, .{ .type = .identifier, .raw = "active", .start_offset = 2, .end_offset = 8 } },
        },
    });
}

test "tokenize keeps quoted text whole and preserves its escapes" {
    try expectCases(&.{
        .{
            .query = "city = \"New York\"",
            .expected = &.{ .{ .type = .identifier, .raw = "city", .start_offset = 0, .end_offset = 4 }, .{ .type = .keyword, .raw = "=", .start_offset = 5, .end_offset = 6 }, .{ .type = .quoted, .raw = "\"New York\"", .start_offset = 7, .end_offset = 17 } },
        },
        // Delimiters are ordinary bytes inside quotes, control characters included,
        // so every byte is expressible without an escape sequence table.
        .{
            .query = "msg = \" a\nb\tc \"",
            .expected = &.{ .{ .type = .identifier, .raw = "msg", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\" a\nb\tc \"", .start_offset = 6, .end_offset = 15 } },
        },
        .{
            .query = "x = \"\"",
            .expected = &.{ .{ .type = .identifier, .raw = "x", .start_offset = 0, .end_offset = 1 }, .{ .type = .keyword, .raw = "=", .start_offset = 2, .end_offset = 3 }, .{ .type = .quoted, .raw = "\"\"", .start_offset = 4, .end_offset = 6 } },
        },
        // Quoting is the escape hatch for the reserved set: a quoted `.` is data,
        // so each quoted section remains one quoted token.
        .{
            .query = "\"a.b\" = 1",
            .expected = &.{ .{ .type = .quoted, .raw = "\"a.b\"", .start_offset = 0, .end_offset = 5 }, .{ .type = .keyword, .raw = "=", .start_offset = 6, .end_offset = 7 }, .{ .type = .int, .raw = "1", .start_offset = 8, .end_offset = 9 } },
        },
        .{
            .query = "\"a(b)\" = 1",
            .expected = &.{ .{ .type = .quoted, .raw = "\"a(b)\"", .start_offset = 0, .end_offset = 6 }, .{ .type = .keyword, .raw = "=", .start_offset = 7, .end_offset = 8 }, .{ .type = .int, .raw = "1", .start_offset = 9, .end_offset = 10 } },
        },
        .{
            .query = "user.\"1\".name",
            .expected = &.{ .{ .type = .identifier, .raw = "user", .start_offset = 0, .end_offset = 4 }, .{ .type = .keyword, .raw = ".", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\"1\"", .start_offset = 5, .end_offset = 8 }, .{ .type = .keyword, .raw = ".", .start_offset = 8, .end_offset = 9 }, .{ .type = .identifier, .raw = "name", .start_offset = 9, .end_offset = 13 } },
        },
        // A backslash escapes the next byte for quote matching, while raw keeps
        // both bytes exactly as written in the query.
        .{
            .query = "msg = \"a\\\"b\"",
            .expected = &.{ .{ .type = .identifier, .raw = "msg", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\"a\\\"b\"", .start_offset = 6, .end_offset = 12 } },
        },
        .{
            .query = "msg = \"a\\\\b\"",
            .expected = &.{ .{ .type = .identifier, .raw = "msg", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\"a\\\\b\"", .start_offset = 6, .end_offset = 12 } },
        },
        .{
            .query = "msg = \"a\\zb\"",
            .expected = &.{ .{ .type = .identifier, .raw = "msg", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\"a\\zb\"", .start_offset = 6, .end_offset = 12 } },
        },
        // An escaped backslash is data and does not escape the closing quote.
        .{
            .query = "msg = \"\\\\\"",
            .expected = &.{ .{ .type = .identifier, .raw = "msg", .start_offset = 0, .end_offset = 3 }, .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 }, .{ .type = .quoted, .raw = "\"\\\\\"", .start_offset = 6, .end_offset = 10 } },
        },
    });
}

test "tokenize recognizes quoted fields" {
    try expectCases(&.{
        .{
            .query = "@\"name\" = \"sarthak\"",
            .expected = &.{ .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 }, .{ .type = .quoted, .raw = "\"name\"", .start_offset = 1, .end_offset = 7 }, .{ .type = .keyword, .raw = "=", .start_offset = 8, .end_offset = 9 }, .{ .type = .quoted, .raw = "\"sarthak\"", .start_offset = 10, .end_offset = 19 } },
        },
        // The quoted field token preserves its escaped source text.
        .{
            .query = "@\"a\\\"b\"",
            .expected = &.{ .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 }, .{ .type = .quoted, .raw = "\"a\\\"b\"", .start_offset = 1, .end_offset = 7 } },
        },
        .{
            .query = "@\"a.b\"",
            .expected = &.{ .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 }, .{ .type = .quoted, .raw = "\"a.b\"", .start_offset = 1, .end_offset = 6 } },
        },
        .{
            .query = "@\"\"",
            .expected = &.{ .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 }, .{ .type = .quoted, .raw = "\"\"", .start_offset = 1, .end_offset = 3 } },
        },
        // `@` must be adjacent to the opening quote, and field state must not
        // leak into a later quoted value.
        .{
            .query = "@ \"name\" @\"city\" \"value\"",
            .expected = &.{ .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 }, .{ .type = .quoted, .raw = "\"name\"", .start_offset = 2, .end_offset = 8 }, .{ .type = .keyword, .raw = "@", .start_offset = 9, .end_offset = 10 }, .{ .type = .quoted, .raw = "\"city\"", .start_offset = 10, .end_offset = 16 }, .{ .type = .quoted, .raw = "\"value\"", .start_offset = 17, .end_offset = 24 } },
        },
    });
}

test "tokenize spans a quoted token across its quotes" {
    // A quoted token's span and raw text both cover the quotes, so `end_offset`
    // stays the token's real end in the source. Adjacency is what separates the
    // decimal `1.5` from the path `1 . 5`, and what lets the parser reject the
    // juxtaposition in `x="a"b`.
    const allocator = testing.allocator;

    var juxtaposed = try Tokenizer.init(allocator, "x=\"a\"b");
    defer juxtaposed.deinit();
    try expectTokens("x=\"a\"b", juxtaposed.tokens, &.{ .{ .type = .identifier, .raw = "x", .start_offset = 0, .end_offset = 1 }, .{ .type = .keyword, .raw = "=", .start_offset = 1, .end_offset = 2 }, .{ .type = .quoted, .raw = "\"a\"", .start_offset = 2, .end_offset = 5 }, .{ .type = .identifier, .raw = "b", .start_offset = 5, .end_offset = 6 } });

    var joined = try Tokenizer.init(allocator, "1.5");
    defer joined.deinit();
    var spaced = try Tokenizer.init(allocator, "1 . 5");
    defer spaced.deinit();

    // Identical tokens; only the spans tell a decimal from a spaced path.
    try testing.expectEqual(joined.tokens.len, spaced.tokens.len);
    for (joined.tokens, spaced.tokens) |a, b| {
        try testing.expectEqual(a.type, b.type);
        try testing.expectEqualStrings(a.raw, b.raw);
    }

    for ([_][]const Token{ juxtaposed.tokens, joined.tokens }) |tokens| {
        for (tokens[1..], tokens[0 .. tokens.len - 1]) |cur, prev| {
            try testing.expectEqual(prev.end_offset, cur.start_offset);
        }
    }
    for (spaced.tokens[1..], spaced.tokens[0 .. spaced.tokens.len - 1]) |cur, prev| {
        try testing.expect(prev.end_offset < cur.start_offset);
    }
}

test "tokenize classifies token types" {
    const TypeCase = struct { value: []const u8, type: ?TokenType };
    const cases = [_]TypeCase{
        .{ .value = "0", .type = .int },
        .{ .value = "007", .type = .digits },
        .{ .value = "-3", .type = .int },
        .{ .value = "300", .type = .int },
        .{ .value = "99999999999999999999", .type = .int },
        .{ .value = "true", .type = .boolean },
        .{ .value = "false", .type = .boolean },
        .{ .value = "null", .type = .none },
        .{ .value = "field_1", .type = .identifier },
        .{ .value = "\"42\"", .type = .quoted },
        .{ .value = "\"=\"", .type = .quoted },
        .{ .value = "a-b", .type = .identifier },
        .{ .value = "+5", .type = null },
        .{ .value = "1_0", .type = null },
        .{ .value = "0x1f", .type = null },
        .{ .value = "1e5", .type = null },
        .{ .value = "12a", .type = null },
        .{ .value = "--3", .type = null },
        .{ .value = "-", .type = null },
        .{ .value = "%#$", .type = null },
        .{ .value = ",,,", .type = null },
        .{ .value = "a?b", .type = null },
        .{ .value = "café", .type = null },
        .{ .value = "a\\zb", .type = null },
    };

    for (cases) |tc| {
        var buf: [64]u8 = undefined;
        const query = try std.fmt.bufPrint(&buf, "x = {s}", .{tc.value});

        if (Tokenizer.init(testing.allocator, query)) |out| {
            var tokens = out;
            defer tokens.deinit();

            const expected = tc.type orelse return error.TestExpectedError;
            try testing.expectEqual(@as(usize, 3), tokens.tokens.len);
            testing.expectEqual(expected, tokens.tokens[2].type) catch |err| {
                std.debug.print("\nquery: {s}\n", .{query});
                printTokens(tokens.tokens);
                return err;
            };
        } else |err| {
            try testing.expectEqual(TokenizationError.InvalidTokenError, err);
            try testing.expect(tc.type == null);
        }
    }
}

test "tokenize rejects an unterminated quote" {
    const queries = [_][]const u8{
        "city = \"New York",
        // The closing quote is escaped, so it is data and the string never ends.
        "msg = \"a\\\"",
        // Input ends mid-escape.
        "msg = \"a\\",
        // A lone quote is an empty, unterminated string.
        "\"",
        // A field marker does not change unterminated-quote handling.
        "@\"name",
        // 20 tokens grow the list past its initial capacity before the failure,
        // so this also covers freeing a grown list on the error path.
        "a a a a a a a a a a a a a a a a a a a a \"x",
    };

    for (queries) |query| {
        if (Tokenizer.init(testing.allocator, query)) |out| {
            var tokens = out;
            defer tokens.deinit();
            std.debug.print("\nquery: {s} -> expected OpenQuoteError\n", .{query});
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(TokenizationError.OpenQuoteError, err);
        }
    }
}

test "tokenize borrows every token value from the query" {
    const allocator = testing.allocator;
    const queries = [_][]const u8{ "........", "<=<=<=<=", "abcdefgh", "a.b.c.d." };

    for (queries) |query| {
        var out = try Tokenizer.init(allocator, query);
        defer out.deinit();

        try testing.expectEqual(query.len, out.buf.len);
        try testing.expectEqual(@intFromPtr(query.ptr), @intFromPtr(out.buf.ptr));
        for (out.tokens) |token| {
            const source = query[token.start_offset..token.end_offset];
            try testing.expectEqualStrings(source, token.raw);
            try testing.expectEqual(@intFromPtr(source.ptr), @intFromPtr(token.raw.ptr));
        }
    }
}

fn tokenizeAndDiscard(allocator: mem.Allocator, query: []const u8) !void {
    var out = try Tokenizer.init(allocator, query);
    defer out.deinit();
}

test "tokenize frees everything when an allocation fails" {
    // Runs the query once per allocation site, failing that one allocation.
    const query = "a b c d e f g h i j k l m n o p q r s t = \"esc\\\"aped\"";

    try testing.checkAllAllocationFailures(testing.allocator, tokenizeAndDiscard, .{query});
}
