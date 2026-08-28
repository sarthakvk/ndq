const std = @import("std");
const lexer = @import("lexer.zig");
const test_utils = @import("test_utils.zig");

const testing = std.testing;
const mem = std.mem;
const Token = lexer.Token;
const Keyword = lexer.Keyword;
const KeywordMap = lexer.KeywordMap;

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

const Comparision = struct {
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

const Expression = struct {
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

const ParsedToken = enum {
    keyword,
    identifier,
    quoted,
    int,
    digits,
    boolean,
    none,
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
    const leading_type = try parseToken(tokens[consumed]);

    if (!at_field) {
        switch (leading_type) {
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
        switch (leading_type) {
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
        const pkey = try parseToken(key);

        if (key.start_offset != period.end_offset) {
            std.log.debug("Expected a key after period at {d}", .{period.end_offset});
            return SyntaxError.SyntaxError;
        }

        switch (pkey) {
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
    const parsed = try parseToken(token);
    return switch (parsed) {
        .boolean, .none, .int, .quoted => true,
        else => false,
    };
}

fn parseToken(token: Token) SyntaxError!ParsedToken {
    const isTrue = if (std.mem.eql(u8, token.raw, "true")) true else false;
    const isFalse = if (std.mem.eql(u8, token.raw, "false")) true else false;
    const isNUll = if (std.mem.eql(u8, token.raw, "null")) true else false;
    const int = isInt(token.raw);
    const id = isIdentifier(token.raw);
    const quoted = isQuoted(token.raw);
    const digit = isDigits(token.raw);

    return if (token.type == lexer.TokenType.keyword)
        return .keyword
    else if (isTrue or isFalse)
        return .boolean
    else if (isNUll)
        .none
    else if (int)
        .int
    else if (digit)
        .digits
    else if (id)
        .identifier
    else if (quoted)
        .quoted
    else
        SyntaxError.InvalidTokenError;
}

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;

    if (!(s[0] == '_' or std.ascii.isAlphabetic(s[0]))) return false;

    for (s[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-'))
            return false;
    }
    return true;
}

fn isQuoted(s: []const u8) bool {
    if (s.len < 2) return false;
    return s[0] == '"' and s[s.len - 1] == '"';
}

fn isDigits(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn isFloat(tokens: []const Token) !bool {
    if (tokens.len < 3) return false;
    const a = try parseToken(tokens[0]);
    const b = try parseToken(tokens[2]);

    if (a == .int and tokens[1].keyword == Keyword.__period__) {
        if (b == .digits or (b == .int and tokens[2].raw[0] != '-')) {
            return ((tokens[0].end_offset == tokens[1].start_offset) and (tokens[1].end_offset == tokens[2].start_offset));
        }
    }
    return false;
}

fn isInt(s: []const u8) bool {
    if (s.len == 0) return false;
    var start: usize = 0;

    if (s[0] == '-') start += 1;

    // Reject leading zero unless it's the only digit
    if (start >= s.len or (s[start] == '0' and start < s.len - 1)) return false;

    for (s[start..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

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
        .{ .query = "a = café", .expected = SyntaxError.InvalidTokenError },
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
