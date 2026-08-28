/// Lexar for ndq
const std = @import("std");
const mem = std.mem;

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

fn extractToken(s: []const u8, inside_quote: bool, start_offset: usize, end_offset: usize) Token {
    const ttype: TokenType = if (inside_quote)
        .value
    else if (KeywordMap.get(s) != null)
        .keyword
    else
        .value;

    const token = Token{
        .type = ttype,
        .raw = s,
        .start_offset = start_offset,
        .end_offset = end_offset,
        .keyword = if (ttype == TokenType.keyword) KeywordMap.get(s) else null,
    };

    return token;
}

pub const Tokenizer = struct {
    tokens: []Token,
    buf: []const u8,
    allocator: mem.Allocator,

    /// Convert the raw query slice, into the token slice
    pub fn init(allocator: mem.Allocator, query: []const u8) !Tokenizer {
        var list = try std.ArrayList(Token).initCapacity(allocator, 16);
        errdefer list.deinit(allocator);

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
                    const token = extractToken(query[start .. i + 1], true, start, i + 1);
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
                    const token = extractToken(query[start..i], false, start, i);
                    try list.append(allocator, token);
                }
                open_quote = true;
                start = i;
                i += 1;
            } else if (std.mem.findScalar(u8, &delimeters, c) != null) {
                if (start < i) {
                    // token: [start, i)
                    const token = extractToken(query[start..i], false, start, i);
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
                        const token = extractToken(query[start..i], false, start, i);
                        try list.append(allocator, token);
                    }

                    // Token: [i, match.raw.len)
                    const end = i + match.raw.len;
                    const op = extractToken(query[i .. i + match.raw.len], false, i, end);
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
            // Token: [start, i)
            const token = extractToken(query[start..i], false, start, i);
            try list.append(allocator, token);
        }
        return .{
            .tokens = try list.toOwnedSlice(allocator),
            .buf = query,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.tokens);
    }
};
