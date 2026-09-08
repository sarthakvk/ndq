const std = @import("std");
const parser = @import("parser.zig");
const ndjson = @import("ndjson.zig");
const lexer = @import("lexer.zig");
const until = @import("utils.zig");

const json = std.json;
const Token = lexer.Token;

const Comparision = parser.Comparision;
const Expression = parser.Expression;

const EvaluationError = error{
    InvalidComparisionOperator,
};

pub const TermEvaluator = struct {
    allocator: std.mem.Allocator,
    key_cache: std.AutoHashMap(*const parser.Term, []const []const u8),
    value_cache: std.AutoHashMap(*const parser.Term, json.Parsed(json.Value)),
    parsed_cache: std.ArrayList(json.Parsed([]const u8)),
    qurey: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, query: []const u8) !Self {
        const list = try std.ArrayList(json.Parsed([]const u8)).initCapacity(allocator, 16);
        errdefer list.deinit();

        return .{
            .allocator = allocator,
            .key_cache = std.AutoHashMap(*const parser.Term, []const []const u8).init(allocator),
            .value_cache = std.AutoHashMap(*const parser.Term, json.Parsed(json.Value)).init(allocator),
            .parsed_cache = list,
            .qurey = query,
        };
    }

    pub fn evaluate(self: *Self, term: *const parser.Term, record: json.Value) !?json.Value {
        switch (term.kind) {
            .value => return try self.evaluateValue(term),
            .field => {
                const keys = try self.evaluateKey(term);
                return (try ndjson.getValue(record, keys)) orelse null;
            },
        }
    }
    fn evaluateKey(self: *Self, term: *const parser.Term) ![]const []const u8 {
        std.debug.assert(term.kind == .field);

        if (self.key_cache.get(term)) |out| return out;

        const tokens = term.value;
        var list = try std.ArrayList([]const u8).initCapacity(self.allocator, tokens.len);
        defer list.deinit(self.allocator);

        for (tokens) |token| {
            if (token.type == .keyword) continue;
            switch (token.type) {
                .quoted => {
                    const parsed = try json.parseFromSlice([]const u8, self.allocator, token.raw, .{});
                    errdefer parsed.deinit();

                    try self.parsed_cache.append(self.allocator, parsed);
                    errdefer parsed.deinit();

                    try list.append(self.allocator, parsed.value);
                },
                else => try list.append(self.allocator, token.raw),
            }
        }
        const out = try list.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(out);

        try self.key_cache.put(term, out);

        return out;
    }

    fn evaluateValue(self: *Self, term: *const parser.Term) !json.Value {
        std.debug.assert(term.kind == .value);

        if (self.value_cache.get(term)) |parsed| return parsed.value;

        const isFloat = isValueFloat(term);

        // float is the only multi-token literal <int><.><uint/digits>
        std.debug.assert(term.value.len == 1 or isFloat);

        const raw = if (isFloat) float_blk: {
            const fstart = term.value[0].start_offset;
            const fend = term.value[2].end_offset;
            break :float_blk self.qurey[fstart..fend];
        } else term.value[0].raw;

        const decoded = try json.parseFromSlice(
            json.Value,
            self.allocator,
            raw,
            .{},
        );
        errdefer decoded.deinit();

        try self.value_cache.put(term, decoded);
        return decoded.value;
    }

    pub fn deinit(self: *Self) void {
        var keycache_it = self.key_cache.valueIterator();
        while (keycache_it.next()) |val| {
            self.allocator.free(val.*);
        }
        self.key_cache.deinit();

        var valuecache_it = self.value_cache.valueIterator();
        while (valuecache_it.next()) |val| {
            val.deinit();
        }
        self.value_cache.deinit();

        for (self.parsed_cache.items) |parsed| {
            parsed.deinit();
        }

        self.parsed_cache.deinit(self.allocator);
    }

    pub fn evaluateAST(self: *Self, root: *const parser.ASTNode, record: json.Value) !bool {
        return switch (root.*) {
            .exp => |*exp| self.evaluateExpression(record, exp),
            .comp => |*comp| self.evaluateComparision(record, comp),
        };
    }

    fn evaluateExpression(self: *Self, record: json.Value, expression: *const Expression) !bool {
        // Invariant: NOT expression must have only 1 oprand``
        std.debug.assert(expression.type != .NOT or expression.oprands.len == 1);

        for (expression.oprands) |oprand| {
            const result = switch (oprand.*) {
                .comp => |*comp| try self.evaluateComparision(record, comp),
                .exp => |*exp| try self.evaluateExpression(record, exp),
            };

            switch (expression.type) {
                .AND => if (!result) return false,
                .OR => if (result) return true,
                .NOT => return !result,
            }
        }

        // If loop terminates, short circut did not triggered
        // i.e in case of AND every exp is true, and false for OR
        return if (expression.type == .AND) true else false;
    }

    fn evaluateComparision(self: *Self, record: json.Value, comp: *const Comparision) !bool {
        const term1 = try self.evaluate(&comp.term1, record) orelse return false;
        const term2 = try self.evaluate(&comp.term2, record) orelse return false;

        const op = comp.op;

        return try applyOperator(term1, term2, op);
    }
};

fn applyOperator(term1: json.Value, term2: json.Value, op: lexer.Keyword) EvaluationError!bool {
    return switch (op) {
        .__eq__ => eql(term1, term2),
        .__neq__ => !eql(term1, term2),
        .__lt__ => lt(term1, term2),
        .__gt__ => gt(term1, term2),
        .__lte__ => lte(term1, term2),
        .__gte__ => gte(term1, term2),
        else => EvaluationError.InvalidComparisionOperator,
    };
}

fn eql(term1: json.Value, term2: json.Value) bool {
    //handling if term1 or term2 is null.
    switch (term1) {
        .null => switch (term2) {
            .null => return true,
            else => return false,
        },
        else => switch (term2) {
            .null => return false,
            else => {},
        },
    }

    switch (term1) {
        .bool => |v1| switch (term2) {
            .bool => |v2| return v1 == v2,
            else => return false,
        },
        inline .float, .integer => |v1| switch (term2) {
            inline .float, .integer => |v2| {
                const v1_type = @TypeOf(v1);
                const v2_type = @TypeOf(v2);
                if (v1_type == f64 or v2_type == f64) {
                    const fv1: f128 = if (v1_type != f64) @floatFromInt(v1) else v1;
                    const fv2: f128 = if (v2_type != f64) @floatFromInt(v2) else v2;
                    return fv1 == fv2;
                }
                return v1 == v2;
            },
            else => return false,
        },
        .number_string, .string => |v1| switch (term2) {
            .number_string, .string => |v2| return std.mem.eql(u8, v1, v2),
            else => return false,
        },
        .array => |v1| switch (term2) {
            .array => |v2| {
                if (v1.items.len != v2.items.len) return false;
                for (v1.items, v2.items) |e1, e2| {
                    if (!eql(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
        .object => |v1| switch (term2) {
            .object => |v2| {
                if (v1.count() != v2.count()) return false;

                for (v1.keys()) |key| {
                    const e1 = v1.get(key) orelse unreachable;
                    const e2 = v2.get(key) orelse return false;
                    if (!eql(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
        .null => unreachable,
    }
}

fn lt(term1: json.Value, term2: json.Value) bool {
    switch (term1) {
        .null, .bool => return false,
        inline .float, .integer => |v1| switch (term2) {
            inline .float, .integer => |v2| {
                const v1_type = @TypeOf(v1);
                const v2_type = @TypeOf(v2);
                if (v1_type == f64 or v2_type == f64) {
                    const fv1: f128 = if (v1_type != f64) @floatFromInt(v1) else v1;
                    const fv2: f128 = if (v2_type != f64) @floatFromInt(v2) else v2;
                    return fv1 < fv2;
                }
                return v1 < v2;
            },
            else => return false,
        },
        .number_string, .string => |v1| switch (term2) {
            .number_string, .string => |v2| {
                const min_len = @min(v1.len, v2.len);
                for (v1[0..min_len], v2[0..min_len]) |c1, c2| {
                    if (c1 > c2) return false else if (c1 < c2) return true;
                }
                // if we reach here, that means
                // strings are equal or one of the string is a prefix.
                // i.e v1 is less than v2 iff `v1.len < v2.len`
                return v1.len < v2.len;
            },
            else => return false,
        },
        .array => |v1| switch (term2) {
            .array => |v2| {
                if (v1.items.len != v2.items.len or v1.items.len == 0) return false;

                for (v1.items, v2.items) |e1, e2| {
                    if (!lt(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
        .object => |v1| switch (term2) {
            .object => |v2| {
                if (v1.count() != v2.count() or v1.count() == 0) return false;

                for (v1.keys()) |key| {
                    const e1 = v1.get(key) orelse unreachable;
                    const e2 = v2.get(key) orelse return false;
                    if (!lt(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
    }
}

fn gt(term1: json.Value, term2: json.Value) bool {
    return lt(term2, term1);
}

fn lte(term1: json.Value, term2: json.Value) bool {
    //handling if term1 or term2 is null.
    switch (term1) {
        .null => switch (term2) {
            .null => return true,
            else => return false,
        },
        else => switch (term2) {
            .null => return false,
            else => {},
        },
    }

    switch (term1) {
        .bool => |v1| switch (term2) {
            .bool => |v2| return v1 == v2,
            else => return false,
        },
        inline .float, .integer => |v1| switch (term2) {
            inline .float, .integer => |v2| {
                const v1_type = @TypeOf(v1);
                const v2_type = @TypeOf(v2);
                if (v1_type == f64 or v2_type == f64) {
                    const fv1: f128 = if (v1_type != f64) @floatFromInt(v1) else v1;
                    const fv2: f128 = if (v2_type != f64) @floatFromInt(v2) else v2;
                    return fv1 <= fv2;
                }
                return v1 <= v2;
            },
            else => return false,
        },
        .number_string, .string => |v1| switch (term2) {
            .number_string, .string => |v2| {
                const min_len = @min(v1.len, v2.len);
                for (v1[0..min_len], v2[0..min_len]) |c1, c2| {
                    if (c1 > c2) return false else if (c1 < c2) return true;
                }
                // if we reach here, that means
                // strings are identical or one of the string is a prefix.
                // i.e `v1 <= v2` iff `v1.len <= v2.len`
                return v1.len <= v2.len;
            },
            else => return false,
        },
        .array => |v1| switch (term2) {
            .array => |v2| {
                if (v1.items.len != v2.items.len) return false;
                for (v1.items, v2.items) |e1, e2| {
                    if (!lte(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
        .object => |v1| switch (term2) {
            .object => |v2| {
                if (v1.count() != v2.count()) return false;

                for (v1.keys()) |key| {
                    const e1 = v1.get(key) orelse unreachable;
                    const e2 = v2.get(key) orelse return false;
                    if (!lte(e1, e2)) return false;
                }
                return true;
            },
            else => return false,
        },
        .null => unreachable,
    }
}

fn gte(term1: json.Value, term2: json.Value) bool {
    return lte(term2, term1);
}
fn isValueFloat(term: *const parser.Term) bool {
    std.debug.assert(term.kind == .value);

    if (term.value.len != 3) return false;

    if (term.value[0].type == .int and term.value[1].keyword == .__period__) {
        if (term.value[2].type == .digits or (term.value[2].type == .int and term.value[2].raw[0] != '-')) {
            return (term.value[0].end_offset == term.value[1].start_offset and term.value[1].end_offset == term.value[2].start_offset);
        }
        return false;
    }
    return false;
}
