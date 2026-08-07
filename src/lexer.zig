/// Lexar for ndq
/// Right now, this lexar only supports basic single key queries.
/// `key <comparison> value`, =, <, <=, >, >= and != are supported.
const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const utils = @import("utils.zig");

pub const Keyword = struct {
    id: Identifier,
    id_str: []const u8,
};

const operators_list = [_]Keyword{
    .{ .id_str = "=", .id = Identifier.__eq__ },
    .{ .id_str = "!=", .id = Identifier.__neq__ },
    .{ .id_str = "&", .id = Identifier.__and__ },
    .{ .id_str = "|", .id = Identifier.__or__ },
    .{ .id_str = "<", .id = Identifier.__lt__ },
    .{ .id_str = ">", .id = Identifier.__gt__ },
    .{ .id_str = "<=", .id = Identifier.__lte__ },
    .{ .id_str = ">=", .id = Identifier.__gte__ },
    .{ .id_str = ".", .id = Identifier.__period__ },
};

const operators_list_kv = blk: {
    var kvs: [operators_list.len]struct { []const u8, Identifier } = undefined;
    for (0..operators_list.len, operators_list) |i, val| {
        kvs[i] = .{ val.id_str, val.id };
    }
    break :blk kvs;
};

const operator_map = std.StaticStringMap(Identifier).initComptime(operators_list_kv);

const delimeters = [_]u8{
    '\n',
    '\t',
    '\r',
    ' ',
};
const double_quote = '\"';
const escape = '\\';

pub const Identifier = enum {
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
};

pub const TokenType = enum {
    string,
    integer,
    operator,
};

pub const TokenizationError = error{
    OpenQuoteError,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
    start_offset: usize,
    end_offset: usize,
};

fn extractToken(s: []const u8, buf_slice: *[]u8, inside_quote: bool, start_offset: usize, end_offset: usize) Token {
    const ttype: TokenType = if (inside_quote)
        .string
    else if (operator_map.get(s) != null)
        .operator
    else if (utils.isInt(s))
        .integer
    else
        .string;

    var written: usize = 0;
    var open_escape = false;

    for (s) |c| {
        if (inside_quote and (c == escape or open_escape)) {
            open_escape = !open_escape;
            // skip the current char, as it opened escape.
            if (open_escape) continue;
        }
        buf_slice.*[written] = c;
        written += 1;
    }

    const token = Token{
        .type = ttype,
        .value = buf_slice.*[0..written],
        .start_offset = start_offset,
        .end_offset = end_offset,
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

            const cur_slice = query[start..i];
            if (open_quote) {
                if (c == double_quote) {
                    // token: [start-1, i+1)
                    const token = extractToken(cur_slice, &buf_slice, true, start - 1, i + 1);
                    try list.append(allocator, token);
                    start = i + 1;
                    open_quote = false;
                }
                i += 1;
            } else if (c == double_quote) {
                if (start < i) {
                    // token: [start, i)
                    const token = extractToken(cur_slice, &buf_slice, false, start, i);
                    try list.append(allocator, token);
                }
                open_quote = true;
                i += 1;
                start = i;
            } else if (std.mem.findScalar(u8, &delimeters, c) != null) {
                if (start < i) {
                    // token: [start, i)
                    const token = extractToken(cur_slice, &buf_slice, false, start, i);
                    try list.append(allocator, token);
                }
                i += 1;
                start = i;
            } else {
                var match_op: ?Keyword = null;
                for (operators_list) |op| {
                    if (std.mem.startsWith(u8, query[i..], op.id_str)) {
                        if (match_op) |match| {
                            if (match.id_str.len < op.id_str.len) match_op = op;
                        } else match_op = op;
                    }
                }

                if (match_op) |match| {
                    if (start < i) {
                        // Token: [start, i)
                        const token = extractToken(cur_slice, &buf_slice, false, start, i);
                        try list.append(allocator, token);
                    }

                    // Token: [i, match.id_str.len)
                    const end = i + match.id_str.len;
                    const op = extractToken(query[i .. i + match.id_str.len], &buf_slice, false, i, end);
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

fn printTokens(tokens: []const Token) void {
    std.debug.print("total tokens: {d}\nTokens: ", .{tokens.len});

    for (tokens) |token| {
        std.debug.print(
            "{{type: {s}, value: {s}, start_offset: {d}, end_offset: {d}}}, ",
            .{ @tagName(token.type), token.value, token.start_offset, token.end_offset },
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
        testing.expectEqualStrings(expected.value, token.value) catch |err| {
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
                .{ .type = .string, .value = "name", .start_offset = 0, .end_offset = 4 },
                .{ .type = .operator, .value = "=", .start_offset = 5, .end_offset = 6 },
                .{ .type = .string, .value = "sarthak", .start_offset = 7, .end_offset = 14 },
            },
        },
        // Repeated, leading and trailing delimiters collapse; \r and \n count.
        .{
            .query = "  name\t=\n sarthak\r\n",
            .expected = &.{
                .{ .type = .string, .value = "name", .start_offset = 2, .end_offset = 6 },
                .{ .type = .operator, .value = "=", .start_offset = 7, .end_offset = 8 },
                .{ .type = .string, .value = "sarthak", .start_offset = 10, .end_offset = 17 },
            },
        },
        .{
            .query = "= != & | < <= > >= .",
            .expected = &.{
                .{ .type = .operator, .value = "=", .start_offset = 0, .end_offset = 1 },
                .{ .type = .operator, .value = "!=", .start_offset = 2, .end_offset = 4 },
                .{ .type = .operator, .value = "&", .start_offset = 5, .end_offset = 6 },
                .{ .type = .operator, .value = "|", .start_offset = 7, .end_offset = 8 },
                .{ .type = .operator, .value = "<", .start_offset = 9, .end_offset = 10 },
                .{ .type = .operator, .value = "<=", .start_offset = 11, .end_offset = 13 },
                .{ .type = .operator, .value = ">", .start_offset = 14, .end_offset = 15 },
                .{ .type = .operator, .value = ">=", .start_offset = 16, .end_offset = 18 },
                .{ .type = .operator, .value = ".", .start_offset = 19, .end_offset = 20 },
            },
        },
        // Operators split a bare word without whitespace, longest match first.
        .{
            .query = "a<=>b",
            .expected = &.{
                .{ .type = .string, .value = "a", .start_offset = 0, .end_offset = 1 },
                .{ .type = .operator, .value = "<=", .start_offset = 1, .end_offset = 3 },
                .{ .type = .operator, .value = ">", .start_offset = 3, .end_offset = 4 },
                .{ .type = .string, .value = "b", .start_offset = 4, .end_offset = 5 },
            },
        },
        .{
            .query = "age 42 and or user.name",
            .expected = &.{
                .{ .type = .string, .value = "age", .start_offset = 0, .end_offset = 3 },
                .{ .type = .integer, .value = "42", .start_offset = 4, .end_offset = 6 },
                .{ .type = .string, .value = "and", .start_offset = 7, .end_offset = 10 },
                .{ .type = .string, .value = "or", .start_offset = 11, .end_offset = 13 },
                .{ .type = .string, .value = "user", .start_offset = 14, .end_offset = 18 },
                .{ .type = .operator, .value = ".", .start_offset = 18, .end_offset = 19 },
                .{ .type = .string, .value = "name", .start_offset = 19, .end_offset = 23 },
            },
        },
        // A decimal is not a token: the parser reassembles `1 . 5` by adjacency.
        .{
            .query = "age >= 1.5",
            .expected = &.{
                .{ .type = .string, .value = "age", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = ">=", .start_offset = 4, .end_offset = 6 },
                .{ .type = .integer, .value = "1", .start_offset = 7, .end_offset = 8 },
                .{ .type = .operator, .value = ".", .start_offset = 8, .end_offset = 9 },
                .{ .type = .integer, .value = "5", .start_offset = 9, .end_offset = 10 },
            },
        },
        // Backslash is only meaningful inside quotes.
        .{
            .query = "msg = a\\zb",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "a\\zb", .start_offset = 6, .end_offset = 10 },
            },
        },
        // Offsets are byte offsets, not codepoint counts.
        .{
            .query = "x = café",
            .expected = &.{
                .{ .type = .string, .value = "x", .start_offset = 0, .end_offset = 1 },
                .{ .type = .operator, .value = "=", .start_offset = 2, .end_offset = 3 },
                .{ .type = .string, .value = "café", .start_offset = 4, .end_offset = 9 },
            },
        },
        .{ .query = "", .expected = &.{} },
        .{ .query = " ", .expected = &.{} },
        .{ .query = "\t\n  ", .expected = &.{} },
    });
}

test "tokenize keeps quoted text whole and decodes its escapes" {
    try expectCases(&.{
        .{
            .query = "city = \"New York\"",
            .expected = &.{
                .{ .type = .string, .value = "city", .start_offset = 0, .end_offset = 4 },
                .{ .type = .operator, .value = "=", .start_offset = 5, .end_offset = 6 },
                .{ .type = .string, .value = "New York", .start_offset = 7, .end_offset = 17 },
            },
        },
        // Delimiters are ordinary bytes inside quotes, control characters included,
        // so every byte is expressible without an escape sequence table.
        .{
            .query = "msg = \" a\nb\tc \"",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = " a\nb\tc ", .start_offset = 6, .end_offset = 15 },
            },
        },
        .{
            .query = "x = \"\"",
            .expected = &.{
                .{ .type = .string, .value = "x", .start_offset = 0, .end_offset = 1 },
                .{ .type = .operator, .value = "=", .start_offset = 2, .end_offset = 3 },
                .{ .type = .string, .value = "", .start_offset = 4, .end_offset = 6 },
            },
        },
        // Quoting is the escape hatch for the reserved set: a quoted `.` is data,
        // so `"a.b"` is one key and `user."1"` is a key, not the index `user.1`.
        .{
            .query = "\"a.b\" = 1",
            .expected = &.{
                .{ .type = .string, .value = "a.b", .start_offset = 0, .end_offset = 5 },
                .{ .type = .operator, .value = "=", .start_offset = 6, .end_offset = 7 },
                .{ .type = .integer, .value = "1", .start_offset = 8, .end_offset = 9 },
            },
        },
        .{
            .query = "user.\"1\".name",
            .expected = &.{
                .{ .type = .string, .value = "user", .start_offset = 0, .end_offset = 4 },
                .{ .type = .operator, .value = ".", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "1", .start_offset = 5, .end_offset = 8 },
                .{ .type = .operator, .value = ".", .start_offset = 8, .end_offset = 9 },
                .{ .type = .string, .value = "name", .start_offset = 9, .end_offset = 13 },
            },
        },
        // `\X` -> `X` for every X: there is no escape table, so `\z` is a `z`.
        // Changing that rule should fail here.
        .{
            .query = "msg = \"a\\\"b\"",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "a\"b", .start_offset = 6, .end_offset = 12 },
            },
        },
        .{
            .query = "msg = \"a\\\\b\"",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "a\\b", .start_offset = 6, .end_offset = 12 },
            },
        },
        .{
            .query = "msg = \"a\\zb\"",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "azb", .start_offset = 6, .end_offset = 12 },
            },
        },
        // An escaped backslash is data and does not escape the closing quote.
        .{
            .query = "msg = \"\\\\\"",
            .expected = &.{
                .{ .type = .string, .value = "msg", .start_offset = 0, .end_offset = 3 },
                .{ .type = .operator, .value = "=", .start_offset = 4, .end_offset = 5 },
                .{ .type = .string, .value = "\\", .start_offset = 6, .end_offset = 10 },
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
        .{ .type = .string, .value = "x", .start_offset = 0, .end_offset = 1 },
        .{ .type = .operator, .value = "=", .start_offset = 1, .end_offset = 2 },
        .{ .type = .string, .value = "a", .start_offset = 2, .end_offset = 5 },
        .{ .type = .string, .value = "b", .start_offset = 5, .end_offset = 6 },
    });

    var joined = try Tokenizer.init(allocator, "1.5");
    defer joined.deinit();
    var spaced = try Tokenizer.init(allocator, "1 . 5");
    defer spaced.deinit();

    // Identical tokens; only the spans tell a decimal from a spaced path.
    try testing.expectEqual(joined.tokens.items.len, spaced.tokens.items.len);
    for (joined.tokens.items, spaced.tokens.items) |a, b| {
        try testing.expectEqual(a.type, b.type);
        try testing.expectEqualStrings(a.value, b.value);
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
    // Range is the parser's problem: a digit run too large for an i64 is still
    // lexically an integer. Quoting demotes a number or an operator to a string,
    // which is how `user.1` (index) stays distinct from `user."1"` (key).
    const cases = [_]TypeCase{
        .{ .value = "0", .type = .integer },
        .{ .value = "007", .type = .integer },
        .{ .value = "-3", .type = .integer },
        .{ .value = "300", .type = .integer },
        .{ .value = "99999999999999999999", .type = .integer },
        .{ .value = "+5", .type = .string },
        .{ .value = "1_0", .type = .string },
        .{ .value = "0x1f", .type = .string },
        .{ .value = "1e5", .type = .string },
        .{ .value = "12a", .type = .string },
        .{ .value = "--3", .type = .string },
        .{ .value = "-", .type = .string },
        .{ .value = "\"42\"", .type = .string },
        .{ .value = "\"=\"", .type = .string },
        // Only delimiters, operators and the quote are reserved; the rest are
        // ordinary characters in a bare word.
        .{ .value = "@#$", .type = .string },
        .{ .value = ",,,", .type = .string },
        .{ .value = "a!b", .type = .string },
        .{ .value = "a-b", .type = .string },
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
            written += token.value.len;
            const value_start = @intFromPtr(token.value.ptr);
            try testing.expect(value_start >= buf_start);
            try testing.expect(value_start + token.value.len <= buf_start + out.buf.len);
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
