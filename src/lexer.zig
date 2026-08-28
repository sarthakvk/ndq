/// Lexar for ndq
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const KeywordStr = struct {
    id: Keyword,
    raw: []const u8,
};

const keyword_list = [_]KeywordStr{
    .{ .raw = "!", .id = Keyword.__not__ },
    .{ .raw = "=", .id = Keyword.__eq__ },
    .{ .raw = "!=", .id = Keyword.__neq__ },
    .{ .raw = "&", .id = Keyword.__and__ },
    .{ .raw = "|", .id = Keyword.__or__ },
    .{ .raw = "<", .id = Keyword.__lt__ },
    .{ .raw = ">", .id = Keyword.__gt__ },
    .{ .raw = "<=", .id = Keyword.__lte__ },
    .{ .raw = ">=", .id = Keyword.__gte__ },
    .{ .raw = ".", .id = Keyword.__period__ },
    .{ .raw = "(", .id = Keyword.__lparen__ },
    .{ .raw = ")", .id = Keyword.__rparen__ },
    .{ .raw = "@", .id = Keyword.__at_rate__ },
};

const keyword_list_kv = blk: {
    var kvs: [keyword_list.len]struct { []const u8, Keyword } = undefined;
    for (0..keyword_list.len, keyword_list) |i, val| {
        kvs[i] = .{ val.raw, val.id };
    }
    break :blk kvs;
};

pub const KeywordMap = std.StaticStringMap(Keyword).initComptime(keyword_list_kv);

const delimeters = [_]u8{
    '\n',
    '\t',
    '\r',
    ' ',
};
const double_quote = '\"';
const escape = '\\';

pub const Keyword = enum {
    __not__,
    __at_rate__,
    __eq__,
    __neq__,
    __and__,
    __or__,
    __lt__,
    __gt__,
    __lte__,
    __gte__,
    __period__,
    __text__,
    __lparen__,
    __rparen__,
};

pub const TokenType = enum {
    value,
    keyword,
};

pub const TokenizationError = error{
    OpenQuoteError,
};

pub const Token = struct {
    type: TokenType,
    raw: []const u8,
    start_offset: usize,
    end_offset: usize,
    keyword: ?Keyword = null,
};

fn extractToken(s: []const u8, buf_slice: *[]u8, inside_quote: bool, start_offset: usize, end_offset: usize) Token {
    var written: usize = 0;
    var open_escape = false;

    const ttype: TokenType = if (inside_quote)
        .value
    else if (KeywordMap.get(s) != null)
        .keyword
    else
        .value;

    for (s) |c| {
        if (inside_quote and (c == escape or open_escape)) {
            open_escape = !open_escape;
            // skip the current char, as it opened escape.
            if (open_escape) continue;
        }
        buf_slice.*[written] = c;
        written += 1;
    }

    const raw = buf_slice.*[0..written];

    const token = Token{
        .type = ttype,
        .raw = raw,
        .start_offset = start_offset,
        .end_offset = end_offset,
        .keyword = if (ttype == TokenType.keyword) KeywordMap.get(raw) else null,
    };

    // move the buf slice
    buf_slice.* = buf_slice.*[written..];

    return token;
}

pub const Tokenizer = struct {
    tokens: std.ArrayList(Token),
    buf: []u8,
    allocator: mem.Allocator,

    /// Convert the raw query slice, into the token slice
    pub fn init(allocator: mem.Allocator, query: []const u8) !Tokenizer {
        var list = try std.ArrayList(Token).initCapacity(allocator, 16);
        errdefer list.deinit(allocator);

        const buf = try allocator.alloc(u8, query.len);
        errdefer allocator.free(buf);

        var buf_slice = buf[0..];

        var i: usize = 0;
        var start = i;
        var open_quote = false;
        var open_escape = false;

        while (i < query.len) {
            const c = query[i];

            // skip escaped character inside quotes
            if (open_quote and (c == escape or open_escape)) {
                open_escape = !open_escape;
                i += 1;
                continue;
            }

            if (open_quote) {
                // When quote is open
                // The lexar will advance until an unescaped `double_quote` is detected
                // Once the closing quote is detected, the lexer will extract the quoted token.
                if (c == double_quote) {
                    // token: [start, i+1)
                    const token = extractToken(query[start .. i + 1], &buf_slice, true, start, i + 1);
                    try list.append(allocator, token);
                    start = i + 1;
                    open_quote = false;
                }
                i += 1;
            } else if (c == double_quote) {
                // This is an opening quote
                // extract token till [start, i).

                if (start < i) {
                    // token: [start, i)
                    const token = extractToken(query[start..i], &buf_slice, false, start, i);
                    try list.append(allocator, token);
                }
                open_quote = true;
                start = i;
                i += 1;
            } else if (std.mem.findScalar(u8, &delimeters, c) != null) {
                if (start < i) {
                    // token: [start, i)
                    const token = extractToken(query[start..i], &buf_slice, false, start, i);
                    try list.append(allocator, token);
                }
                i += 1;
                start = i;
            } else {
                var match_op: ?KeywordStr = null;
                for (keyword_list) |op| {
                    if (std.mem.startsWith(u8, query[i..], op.raw)) {
                        if (match_op) |match| {
                            if (match.raw.len < op.raw.len) match_op = op;
                        } else match_op = op;
                    }
                }

                if (match_op) |match| {
                    if (start < i) {
                        // Token: [start, i)
                        const token = extractToken(query[start..i], &buf_slice, false, start, i);
                        try list.append(allocator, token);
                    }

                    // Token: [i, match.id_str.len)
                    const end = i + match.raw.len;
                    const op = extractToken(query[i .. i + match.raw.len], &buf_slice, false, i, end);
                    try list.append(allocator, op);

                    i = end;
                    start = i;
                } else {
                    i += 1;
                }
            }
        }

        if (open_quote) return TokenizationError.OpenQuoteError;
        if (start < i) {
            // Token: [start, i]
            const token = extractToken(query[start..i], &buf_slice, false, start, i);
            try list.append(allocator, token);
        }
        return .{
            .tokens = list,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.buf);
    }
};

// -------------------------------------------------------------------------------
// ------------------------------------Tests--------------------------------------
// -------------------------------------------------------------------------------

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

        const expected_keyword = switch (expected.type) {
            .value => null,
            .keyword => expected_keyword_map.get(expected.raw) orelse return error.UnknownExpectedKeyword,
        };
        testing.expectEqual(expected_keyword, token.keyword) catch |err| {
            printCaseError(query, exp, out);
            return err;
        };
    }
}

fn expectCases(cases: []const Case) !void {
    for (cases) |tc| {
        var out = Tokenizer.init(testing.allocator, tc.query) catch |err| {
            std.debug.print("\nquery: {s} -> unexpected {any}\n", .{ tc.query, err });
            return err;
        };
        defer out.deinit();

        try expectTokens(tc.query, out.tokens.items, tc.expected);
    }
}

test "tokenize splits bare words on delimiters and operators" {
    try expectCases(&.{
        .{
            .query = "name = sarthak",
            .expected = &.{
                .{ .type = .value, .raw = "name", .start_offset = 0, .end_offset = 4 },
                .{ .type = .keyword, .raw = "=", .start_offset = 5, .end_offset = 6 },
                .{ .type = .value, .raw = "sarthak", .start_offset = 7, .end_offset = 14 },
            },
        },
        // Repeated, leading and trailing delimiters collapse; \r and \n count.
        .{
            .query = "  name\t=\n sarthak\r\n",
            .expected = &.{
                .{ .type = .value, .raw = "name", .start_offset = 2, .end_offset = 6 },
                .{ .type = .keyword, .raw = "=", .start_offset = 7, .end_offset = 8 },
                .{ .type = .value, .raw = "sarthak", .start_offset = 10, .end_offset = 17 },
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
                .{ .type = .value, .raw = "a", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "<=", .start_offset = 1, .end_offset = 3 },
                .{ .type = .keyword, .raw = ">", .start_offset = 3, .end_offset = 4 },
                .{ .type = .value, .raw = "b", .start_offset = 4, .end_offset = 5 },
            },
        },
        .{
            .query = "a(b)c",
            .expected = &.{
                .{ .type = .value, .raw = "a", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "(", .start_offset = 1, .end_offset = 2 },
                .{ .type = .value, .raw = "b", .start_offset = 2, .end_offset = 3 },
                .{ .type = .keyword, .raw = ")", .start_offset = 3, .end_offset = 4 },
                .{ .type = .value, .raw = "c", .start_offset = 4, .end_offset = 5 },
            },
        },
        .{
            .query = "age 42 and or user.name",
            .expected = &.{
                .{ .type = .value, .raw = "age", .start_offset = 0, .end_offset = 3 },
                .{ .type = .value, .raw = "42", .start_offset = 4, .end_offset = 6 },
                .{ .type = .value, .raw = "and", .start_offset = 7, .end_offset = 10 },
                .{ .type = .value, .raw = "or", .start_offset = 11, .end_offset = 13 },
                .{ .type = .value, .raw = "user", .start_offset = 14, .end_offset = 18 },
                .{ .type = .keyword, .raw = ".", .start_offset = 18, .end_offset = 19 },
                .{ .type = .value, .raw = "name", .start_offset = 19, .end_offset = 23 },
            },
        },
        // A decimal is not a token: the parser reassembles `1 . 5` by adjacency.
        .{
            .query = "age >= 1.5",
            .expected = &.{
                .{ .type = .value, .raw = "age", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = ">=", .start_offset = 4, .end_offset = 6 },
                .{ .type = .value, .raw = "1", .start_offset = 7, .end_offset = 8 },
                .{ .type = .keyword, .raw = ".", .start_offset = 8, .end_offset = 9 },
                .{ .type = .value, .raw = "5", .start_offset = 9, .end_offset = 10 },
            },
        },
        // Backslash is only meaningful inside quotes.
        .{
            .query = "msg = a\\zb",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "a\\zb", .start_offset = 6, .end_offset = 10 },
            },
        },
        // Offsets are byte offsets, not codepoint counts.
        .{
            .query = "x = café",
            .expected = &.{
                .{ .type = .value, .raw = "x", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "=", .start_offset = 2, .end_offset = 3 },
                .{ .type = .value, .raw = "café", .start_offset = 4, .end_offset = 9 },
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
                .{ .type = .value, .raw = "active", .start_offset = 1, .end_offset = 7 },
            },
        },
        .{
            .query = "!!active",
            .expected = &.{
                .{ .type = .keyword, .raw = "!", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "!", .start_offset = 1, .end_offset = 2 },
                .{ .type = .value, .raw = "active", .start_offset = 2, .end_offset = 8 },
            },
        },
        .{
            .query = "!=active",
            .expected = &.{
                .{ .type = .keyword, .raw = "!=", .start_offset = 0, .end_offset = 2 },
                .{ .type = .value, .raw = "active", .start_offset = 2, .end_offset = 8 },
            },
        },
    });
}

test "tokenize keeps quoted text whole and decodes its escapes" {
    try expectCases(&.{
        .{
            .query = "city = \"New York\"",
            .expected = &.{
                .{ .type = .value, .raw = "city", .start_offset = 0, .end_offset = 4 },
                .{ .type = .keyword, .raw = "=", .start_offset = 5, .end_offset = 6 },
                .{ .type = .value, .raw = "\"New York\"", .start_offset = 7, .end_offset = 17 },
            },
        },
        // Delimiters are ordinary bytes inside quotes, control characters included,
        // so every byte is expressible without an escape sequence table.
        .{
            .query = "msg = \" a\nb\tc \"",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\" a\nb\tc \"", .start_offset = 6, .end_offset = 15 },
            },
        },
        .{
            .query = "x = \"\"",
            .expected = &.{
                .{ .type = .value, .raw = "x", .start_offset = 0, .end_offset = 1 },
                .{ .type = .keyword, .raw = "=", .start_offset = 2, .end_offset = 3 },
                .{ .type = .value, .raw = "\"\"", .start_offset = 4, .end_offset = 6 },
            },
        },
        // Quoting is the escape hatch for the reserved set: a quoted `.` is data,
        // so each quoted section remains one value token.
        .{
            .query = "\"a.b\" = 1",
            .expected = &.{
                .{ .type = .value, .raw = "\"a.b\"", .start_offset = 0, .end_offset = 5 },
                .{ .type = .keyword, .raw = "=", .start_offset = 6, .end_offset = 7 },
                .{ .type = .value, .raw = "1", .start_offset = 8, .end_offset = 9 },
            },
        },
        .{
            .query = "\"a(b)\" = 1",
            .expected = &.{
                .{ .type = .value, .raw = "\"a(b)\"", .start_offset = 0, .end_offset = 6 },
                .{ .type = .keyword, .raw = "=", .start_offset = 7, .end_offset = 8 },
                .{ .type = .value, .raw = "1", .start_offset = 9, .end_offset = 10 },
            },
        },
        .{
            .query = "user.\"1\".name",
            .expected = &.{
                .{ .type = .value, .raw = "user", .start_offset = 0, .end_offset = 4 },
                .{ .type = .keyword, .raw = ".", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\"1\"", .start_offset = 5, .end_offset = 8 },
                .{ .type = .keyword, .raw = ".", .start_offset = 8, .end_offset = 9 },
                .{ .type = .value, .raw = "name", .start_offset = 9, .end_offset = 13 },
            },
        },
        // `\X` -> `X` for every X: there is no escape table, so `\z` is a `z`.
        // Changing that rule should fail here.
        .{
            .query = "msg = \"a\\\"b\"",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\"a\"b\"", .start_offset = 6, .end_offset = 12 },
            },
        },
        .{
            .query = "msg = \"a\\\\b\"",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\"a\\b\"", .start_offset = 6, .end_offset = 12 },
            },
        },
        .{
            .query = "msg = \"a\\zb\"",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\"azb\"", .start_offset = 6, .end_offset = 12 },
            },
        },
        // An escaped backslash is data and does not escape the closing quote.
        .{
            .query = "msg = \"\\\\\"",
            .expected = &.{
                .{ .type = .value, .raw = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .keyword, .raw = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .value, .raw = "\"\\\"", .start_offset = 6, .end_offset = 10 },
            },
        },
    });
}

test "tokenize recognizes quoted fields" {
    try expectCases(&.{
        .{
            .query = "@\"name\" = \"sarthak\"",
            .expected = &.{
                .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 },
                .{ .type = .value, .raw = "\"name\"", .start_offset = 1, .end_offset = 7 },
                .{ .type = .keyword, .raw = "=", .start_offset = 8, .end_offset = 9 },
                .{ .type = .value, .raw = "\"sarthak\"", .start_offset = 10, .end_offset = 19 },
            },
        },
        // The field span includes the marker and quotes; its raw text is decoded.
        .{
            .query = "@\"a\\\"b\"",
            .expected = &.{
                .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 },
                .{ .type = .value, .raw = "\"a\"b\"", .start_offset = 1, .end_offset = 7 },
            },
        },
        .{
            .query = "@\"a.b\"",
            .expected = &.{
                .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 },
                .{ .type = .value, .raw = "\"a.b\"", .start_offset = 1, .end_offset = 6 },
            },
        },
        .{
            .query = "@\"\"",
            .expected = &.{
                .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 },
                .{ .type = .value, .raw = "\"\"", .start_offset = 1, .end_offset = 3 },
            },
        },
        // `@` must be adjacent to the opening quote, and field state must not
        // leak into a later quoted value.
        .{
            .query = "@ \"name\" @\"city\" \"value\"",
            .expected = &.{
                .{ .type = .keyword, .raw = "@", .start_offset = 0, .end_offset = 1 },
                .{ .type = .value, .raw = "\"name\"", .start_offset = 2, .end_offset = 8 },
                .{ .type = .keyword, .raw = "@", .start_offset = 9, .end_offset = 10 },
                .{ .type = .value, .raw = "\"city\"", .start_offset = 10, .end_offset = 16 },
                .{ .type = .value, .raw = "\"value\"", .start_offset = 17, .end_offset = 24 },
            },
        },
    });
}

test "tokenize spans a quoted token across its quotes" {
    // A quoted token's span covers the quotes even though its value does not,
    // so `end_offset` stays the token's real end in the source. Adjacency is
    // what separates the decimal `1.5` from the path `1 . 5`, and what lets the
    // parser reject the juxtaposition in `x="a"b`.
    const allocator = testing.allocator;

    var juxtaposed = try Tokenizer.init(allocator, "x=\"a\"b");
    defer juxtaposed.deinit();
    try expectTokens("x=\"a\"b", juxtaposed.tokens.items, &.{
        .{ .type = .value, .raw = "x", .start_offset = 0, .end_offset = 1 },
        .{ .type = .keyword, .raw = "=", .start_offset = 1, .end_offset = 2 },
        .{ .type = .value, .raw = "\"a\"", .start_offset = 2, .end_offset = 5 },
        .{ .type = .value, .raw = "b", .start_offset = 5, .end_offset = 6 },
    });

    var joined = try Tokenizer.init(allocator, "1.5");
    defer joined.deinit();
    var spaced = try Tokenizer.init(allocator, "1 . 5");
    defer spaced.deinit();

    // Identical tokens; only the spans tell a decimal from a spaced path.
    try testing.expectEqual(joined.tokens.items.len, spaced.tokens.items.len);
    for (joined.tokens.items, spaced.tokens.items) |a, b| {
        try testing.expectEqual(a.type, b.type);
        try testing.expectEqualStrings(a.raw, b.raw);
    }

    for ([_][]const Token{ juxtaposed.tokens.items, joined.tokens.items }) |tokens| {
        for (tokens[1..], tokens[0 .. tokens.len - 1]) |cur, prev| {
            try testing.expectEqual(prev.end_offset, cur.start_offset);
        }
    }
    for (spaced.tokens.items[1..], spaced.tokens.items[0 .. spaced.tokens.items.len - 1]) |cur, prev| {
        try testing.expect(prev.end_offset < cur.start_offset);
    }
}

test "tokenize classifies token types" {
    const TypeCase = struct { value: []const u8, type: TokenType };
    const cases = [_]TypeCase{
        .{ .value = "0", .type = .value },
        .{ .value = "007", .type = .value },
        .{ .value = "-3", .type = .value },
        .{ .value = "300", .type = .value },
        .{ .value = "99999999999999999999", .type = .value },
        .{ .value = "+5", .type = .value },
        .{ .value = "1_0", .type = .value },
        .{ .value = "0x1f", .type = .value },
        .{ .value = "1e5", .type = .value },
        .{ .value = "12a", .type = .value },
        .{ .value = "--3", .type = .value },
        .{ .value = "-", .type = .value },
        .{ .value = "\"42\"", .type = .value },
        .{ .value = "\"=\"", .type = .value },
        // Only delimiters, operators and the quote are reserved; the rest are
        // ordinary characters in a bare word.
        .{ .value = "%#$", .type = .value },
        .{ .value = ",,,", .type = .value },
        .{ .value = "a?b", .type = .value },
        .{ .value = "a-b", .type = .value },
    };

    for (cases) |tc| {
        var buf: [64]u8 = undefined;
        const query = try std.fmt.bufPrint(&buf, "x = {s}", .{tc.value});

        var out = try Tokenizer.init(testing.allocator, query);
        defer out.deinit();

        try testing.expectEqual(@as(usize, 3), out.tokens.items.len);
        testing.expectEqual(tc.type, out.tokens.items[2].type) catch |err| {
            std.debug.print("\nquery: {s}\n", .{query});
            printTokens(out.tokens.items);
            return err;
        };
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

test "tokenize owns every token value and fills its buffer exactly" {
    // Values are decoded copies inside Tokenizer.buf, never views into the
    // query, so the caller's query is not part of a Tokenizer's lifetime.
    // The buffer is sized at query.len, which is exact for a query of
    // single-byte tokens: every byte of the query lands in some token.
    const allocator = testing.allocator;
    const queries = [_][]const u8{ "........", "<=<=<=<=", "abcdefgh", "a.b.c.d." };

    for (queries) |query| {
        var out = try Tokenizer.init(allocator, query);
        defer out.deinit();

        const buf_start = @intFromPtr(out.buf.ptr);
        var written: usize = 0;
        for (out.tokens.items) |token| {
            written += token.raw.len;
            const value_start = @intFromPtr(token.raw.ptr);
            try testing.expect(value_start >= buf_start);
            try testing.expect(value_start + token.raw.len <= buf_start + out.buf.len);
        }
        try testing.expectEqual(query.len, written);
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
