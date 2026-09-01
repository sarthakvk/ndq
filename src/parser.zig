const std = @import("std");
const lexer = @import("lexer.zig");

const mem = std.mem;
const Token = lexer.Token;
const Keyword = lexer.Keyword;

pub const SyntaxError = error{
    SyntaxError,
    EOFError,
    InvalidTokenError,
    UnexpectedTokenError,
    OutOfMemory,
};

const CompOperator = [_]Keyword{
    Keyword.__neq__,
    Keyword.__eq__,
    Keyword.__lt__,
    Keyword.__lte__,
    Keyword.__gt__,
    Keyword.__gte__,
};

pub const Term = struct {
    kind: enum { field, value },
    value: []const Token,
};

pub const Comparision = struct {
    term1: Term,
    op: Keyword,
    term2: Term,
    tokens_consumed: usize,

    const Self = @This();

    fn init(allocator: mem.Allocator, term1: Term, op: Keyword, term2: Term, tokens_consumed: usize) !*ASTNode {
        const node = try allocator.create(ASTNode);
        errdefer allocator.destroy(node);

        node.* = .{ .comp = .{
            .term1 = term1,
            .term2 = term2,
            .op = op,
            .tokens_consumed = tokens_consumed,
        } };

        return node;
    }
};

pub const ExpressionType = enum {
    OR,
    AND,
    NOT,
};

pub const Expression = struct {
    type: ExpressionType,
    oprands: []*ASTNode,
    tokens_consumed: usize,

    const Self = @This();

    fn init(allocator: mem.Allocator, etype: ExpressionType, oprands: []*ASTNode, tokens_consumed: usize) !*ASTNode {
        const node = try allocator.create(ASTNode);
        errdefer allocator.destroy(node);

        node.* = .{ .exp = .{
            .oprands = oprands,
            .type = etype,
            .tokens_consumed = tokens_consumed,
        } };
        return node;
    }

    fn deinit(self: *Self, allocator: mem.Allocator) void {
        for (self.oprands) |child| {
            child.deinit(allocator);
        }
        allocator.free(self.oprands);
    }
};

pub const ASTNode = union(enum) {
    exp: Expression,
    comp: Comparision,

    const Self = @This();

    pub fn incrementTokenConsumed(self: *Self, val: usize) void {
        switch (self.*) {
            .exp => |*exp| exp.tokens_consumed += val,
            .comp => |*comp| comp.tokens_consumed += val,
        }
    }

    pub fn deinit(self: *Self, allocator: mem.Allocator) void {
        switch (self.*) {
            .exp => |*exp| exp.deinit(allocator),
            .comp => {},
        }
        allocator.destroy(self);
    }

    pub fn tokensConsumed(self: *Self) usize {
        return switch (self.*) {
            .exp => |exp| exp.tokens_consumed,
            .comp => |comp| comp.tokens_consumed,
        };
    }
};

pub const ParsedTokenType = enum {
    keyword,
    identifier,
    quoted,
    int,
    digits,
    boolean,
    none,
};

const ParsedToken = struct {
    token_type: ParsedTokenType,
    raw: []const u8,
};

pub fn Parse(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    try ensureTokenSliceLen(tokens, 3);

    const root = try parseOr(allocator, tokens);
    errdefer root.deinit(allocator);

    if (root.tokensConsumed() != tokens.len) return SyntaxError.UnexpectedTokenError;
    return root;
}

fn parseOr(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    var oprands = try std.ArrayList(*ASTNode).initCapacity(allocator, 16);
    errdefer oprands.deinit(allocator);
    errdefer for (oprands.items) |item| item.deinit(allocator);

    var consumed: usize = 0;

    while (true) {
        if (consumed >= tokens.len) {
            std.log.debug("Expected expression", .{});
            return SyntaxError.EOFError;
        }
        const child = try parseAnd(allocator, tokens[consumed..]);
        errdefer child.deinit(allocator);

        try oprands.append(allocator, child);
        consumed += child.tokensConsumed();

        if (consumed < tokens.len) {
            if (tokens[consumed].keyword != Keyword.__or__) break;
            consumed += 1;
        } else break;
    }

    if (oprands.items.len > 1) {
        const node = try allocator.create(ASTNode);
        errdefer allocator.destroy(node);

        node.* = .{
            .exp = .{
                .oprands = try oprands.toOwnedSlice(allocator),
                .type = ExpressionType.OR,
                .tokens_consumed = consumed,
            },
        };
        return node;
    } else {
        defer oprands.deinit(allocator);

        std.debug.assert(oprands.items.len == 1);
        return oprands.pop() orelse unreachable;
    }
}

fn parseAnd(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    var oprands = try std.ArrayList(*ASTNode).initCapacity(allocator, 16);
    errdefer oprands.deinit(allocator);
    errdefer for (oprands.items) |item| item.deinit(allocator);

    var consumed: usize = 0;

    while (true) {
        if (consumed >= tokens.len) {
            std.log.debug("Expected expression", .{});
            return SyntaxError.EOFError;
        }
        const child = try parseNot(allocator, tokens[consumed..]);
        errdefer child.deinit(allocator);

        try oprands.append(allocator, child);
        consumed += child.tokensConsumed();

        if (consumed < tokens.len) {
            if (tokens[consumed].keyword != Keyword.__and__) break;
            consumed += 1;
        } else break;
    }

    if (oprands.items.len > 1) {
        const node = try allocator.create(ASTNode);
        errdefer allocator.destroy(node);

        node.* = .{
            .exp = .{
                .oprands = try oprands.toOwnedSlice(allocator),
                .type = ExpressionType.AND,
                .tokens_consumed = consumed,
            },
        };
        return node;
    } else {
        defer oprands.deinit(allocator);

        std.debug.assert(oprands.items.len == 1);
        return oprands.pop() orelse unreachable;
    }
}

fn parseNot(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    if (tokens.len == 0) return SyntaxError.EOFError;
    const cur = tokens[0];

    if (cur.keyword == Keyword.__not__) {
        const child = try parseNot(allocator, tokens[1..]);
        errdefer child.deinit(allocator);

        const oprands = try allocator.alloc(*ASTNode, 1);
        errdefer allocator.free(oprands);

        const node = try allocator.create(ASTNode);
        errdefer allocator.destroy(node);

        oprands[0] = child;
        node.* = .{
            .exp = .{
                .oprands = oprands,
                .type = ExpressionType.NOT,
                .tokens_consumed = 1 + child.tokensConsumed(),
            },
        };
        return node;
    } else return try parsePredicate(allocator, tokens);
}

fn parsePredicate(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    if (tokens.len < 2) return SyntaxError.EOFError;

    const cur = tokens[0];

    if (cur.keyword == Keyword.__lparen__) {
        const node = try parseOr(allocator, tokens[1..]);
        errdefer node.deinit(allocator);

        const tokens_consumed = switch (node.*) {
            .comp => |comp| comp.tokens_consumed,
            .exp => |exp| exp.tokens_consumed,
        };

        if (tokens_consumed + 1 == tokens.len or tokens[tokens_consumed + 1].keyword != Keyword.__rparen__) {
            std.log.debug("Unclosed parenthesis at {d}", .{cur.start_offset});
            return SyntaxError.InvalidTokenError;
        }

        node.incrementTokenConsumed(2);
        return node;
    }

    return try parseComp(allocator, tokens);
}

fn parseComp(allocator: mem.Allocator, tokens: []const Token) SyntaxError!*ASTNode {
    var tokens_consumed: usize = 0;
    var tokens_ = tokens;

    const term1 = try parseTerm(tokens_);
    tokens_consumed += term1.value.len;
    tokens_ = tokens_[tokens_consumed..];

    if (tokens_.len == 0) return SyntaxError.EOFError;
    const op = tokens_[0];
    tokens_consumed += 1;
    tokens_ = tokens_[1..];

    if (op.keyword) |keyword| {
        if (std.mem.findScalar(Keyword, &CompOperator, keyword) == null) {
            std.log.debug("Invalid operator {s} at {d}", .{ op.raw, op.start_offset });
            return SyntaxError.UnexpectedTokenError;
        }
    } else {
        std.log.debug("Expected comparision operator, found '{s}' at '{d}'", .{ op.raw, op.start_offset });
        std.log.debug("prev: {s}", .{term1.value[0].raw});
        return SyntaxError.UnexpectedTokenError;
    }

    const term2 = try parseTerm(tokens_);
    tokens_consumed += term2.value.len;

    return try Comparision.init(
        allocator,
        term1,
        op.keyword orelse unreachable,
        term2,
        tokens_consumed,
    );
}

fn parseTerm(tokens: []const Token) SyntaxError!Term {
    if (tokens.len == 0) return SyntaxError.EOFError;

    if (try isValue(tokens[0])) {
        return if (try isFloat(tokens)) Term{
            .kind = .value,
            .value = tokens[0..3],
        } else Term{
            .kind = .value,
            .value = tokens[0..1],
        };
    }

    const consumed = try parseField(tokens);

    return Term{
        .kind = .field,
        .value = tokens[0..consumed],
    };
}

fn isAdjacent(token1: Token, token2: Token) bool {
    return token1.end_offset == token2.start_offset;
}

fn ensureTokenSliceLen(tokens: []const Token, at_atleast: usize) SyntaxError!void {
    if (tokens.len < at_atleast) {
        std.log.debug("Expected at_least {d} token, found {d}", .{ at_atleast, tokens.len });
        return SyntaxError.EOFError;
    }
}

fn parseField(tokens: []const Token) SyntaxError!usize {
    const at_field = if (std.mem.eql(u8, tokens[0].raw, "@")) true else false;
    var consumed: usize = if (at_field) 1 else 0;

    try ensureTokenSliceLen(tokens, consumed + 1);
    const leading = tokens[consumed];

    if (!at_field) {
        switch (leading.type) {
            .identifier => consumed += 1,
            else => {
                std.log.debug("Expected key, found {s} at {d}", .{ leading.raw, leading.start_offset });
                return SyntaxError.SyntaxError;
            },
        }
    } else {
        std.debug.assert(consumed > 0);
        const at_token = tokens[consumed - 1];
        if (!isAdjacent(at_token, tokens[consumed])) {
            std.log.debug("Expected key after '@', found invalid value at {d}", .{at_token.end_offset});
            return SyntaxError.SyntaxError;
        }
        switch (leading.type) {
            .identifier, .digits, .boolean, .none, .quoted, .int => consumed += 1,
            else => {
                std.log.debug("Invalid value after '@' at {d}", .{at_token.end_offset});
                return SyntaxError.SyntaxError;
            },
        }
    }

    var last_token = if (at_field) tokens[1] else tokens[0];

    // {~ "." ~ nested_var}
    //

    while (consumed < tokens.len - 1) : (consumed += 2) {
        const period = tokens[consumed];
        if (period.type != lexer.TokenType.keyword or !std.mem.eql(u8, period.raw, ".")) {
            return consumed;
        } else if (last_token.end_offset != period.start_offset) {
            std.log.debug("Expected '.' at {d}", .{last_token.end_offset});
            return SyntaxError.SyntaxError;
        }

        const key = tokens[consumed + 1];

        if (key.start_offset != period.end_offset) {
            std.log.debug("Expected a key after period at {d}", .{period.end_offset});
            return SyntaxError.SyntaxError;
        }

        switch (key.type) {
            .identifier, .digits, .boolean, .none, .quoted, .int => {},
            else => {
                std.log.debug("Can't use {s} as a key, use quotes to escape", .{key.raw});
                return SyntaxError.SyntaxError;
            },
        }
        last_token = key;
    }
    return consumed;
}

fn isValue(token: Token) SyntaxError!bool {
    return switch (token.type) {
        .boolean, .none, .int, .quoted => true,
        else => false,
    };
}

fn isFloat(tokens: []const Token) !bool {
    if (tokens.len < 3) return false;
    const a = tokens[0];
    const b = tokens[2];

    if (a.type == .int and tokens[1].keyword == Keyword.__period__) {
        if (b.type == .digits or (b.type == .int and tokens[2].raw[0] != '-')) {
            return ((tokens[0].end_offset == tokens[1].start_offset) and (tokens[1].end_offset == tokens[2].start_offset));
        }
    }
    return false;
}
