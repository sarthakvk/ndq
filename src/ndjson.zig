const std = @import("std");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");
const utils = @import("utils.zig");

const json = std.json;
const testing = std.testing;

const NdJsonMaxBufferSize: usize = (1 << 26); // 64 MB
const NdJsonInitialBufferSize: usize = (1 << 16); // 64 KB
const newline = '\n';

pub const NdJsonError = error{
    InvalidIndexError,
};

pub const NdJsonRecordReader = struct {
    // allocating writer for dynamic buffer
    writer: std.Io.Writer.Allocating,

    IoLimit: std.Io.Limit = std.Io.Limit.limited(NdJsonMaxBufferSize),

    parseOptions: json.ParseOptions = .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
        .parse_numbers = true,
    },

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        var writer = try std.Io.Writer.Allocating.initCapacity(allocator, NdJsonInitialBufferSize);
        errdefer writer.deinit();

        return .{
            .writer = writer,
        };
    }

    pub fn parseLine(self: *Self, allocator: std.mem.Allocator, reader: *std.Io.Reader) !?json.Parsed(json.Value) {
        // clear writer buffre for reuse;
        // This may free the previous json values
        self.writer.clearRetainingCapacity();

        const iwriter = &self.writer.writer;
        const limit = self.IoLimit;

        const streamed = reader.streamDelimiterLimit(iwriter, newline, limit) catch |err| blk: {
            switch (err) {

                // Discard the complete line since it didn't fit in memory
                // So that Reader is syncronized and next lines can be read.
                error.StreamTooLong => {
                    if (try Self.isNextEitherNewlineOrEOF(reader)) break :blk limit.toInt().?;

                    // Discard the overlimit line, for the next read
                    //
                    _ = reader.discardDelimiterInclusive(newline) catch |inner_err| {
                        switch (inner_err) {
                            // No further lines exists
                            // ParseLine never raises on EOF
                            // StreamTooLong will be raised below.
                            error.EndOfStream => {},
                            else => return inner_err,
                        }
                    };
                    return err;
                },
                else => return err,
            }
        };

        if (reader.buffered().len != 0) {
            std.debug.assert(reader.buffered()[0] == newline);
            reader.toss(1);
        } else if (streamed == 0) {
            return null;
        }

        const line = self.writer.written();

        const parsedJson = try json.parseFromSlice(json.Value, allocator, line, self.parseOptions);

        return parsedJson;
    }

    /// This function will check if the next byte, in reader
    /// is NewLine or EOF, it will consume next byte from the reader.
    fn isNextEitherNewlineOrEOF(reader: *std.Io.Reader) !bool {
        const byte = reader.peek(1) catch |err| {
            switch (err) {
                error.EndOfStream => return true,
                else => return err,
            }
        };

        return if (byte[0] == newline) true else false;
    }

    pub fn deinit(self: *Self) void {
        self.writer.deinit();
    }
};

/// Get a nested key value
/// if the keys is empty or any of the key does't exists return null
pub fn getValue(value: json.Value, keys: []const []const u8) !?json.Value {
    var value_ = value;

    for (keys) |key| {
        switch (value_) {
            .object => |val| {
                value_ = val.get(key) orelse return null;
            },
            .array => |val| {
                if (!lexer.isInt(key)) return NdJsonError.InvalidIndexError;
                const idx = try utils.parseIndex(key, val.items.len);
                value_ = val.items[idx];
            },
            else => return null,
        }
    }
    return value_;
}

pub fn jsonValueEql(expected: json.Value, actual: json.Value) bool {
    switch (expected) {
        .null => return actual == .null,
        .bool => |expected_value| switch (actual) {
            .bool => |actual_value| return expected_value == actual_value,
            else => return false,
        },
        .integer => |expected_value| switch (actual) {
            .integer => |actual_value| return expected_value == actual_value,
            else => return false,
        },
        .float => |expected_value| switch (actual) {
            .float => |actual_value| return expected_value == actual_value,
            else => return false,
        },
        .number_string => |expected_value| switch (actual) {
            .number_string => |actual_value| return std.mem.eql(u8, expected_value, actual_value),
            else => return false,
        },
        .string => |expected_value| switch (actual) {
            .string => |actual_value| return std.mem.eql(u8, expected_value, actual_value),
            else => return false,
        },
        .array => |expected_array| switch (actual) {
            .array => |actual_array| {
                if (expected_array.items.len != actual_array.items.len) return false;
                for (expected_array.items, actual_array.items) |expected_value, actual_value| {
                    if (!jsonValueEql(expected_value, actual_value)) return false;
                }
                return true;
            },
            else => return false,
        },
        .object => |expected_object| switch (actual) {
            .object => |actual_object| {
                if (expected_object.count() != actual_object.count()) return false;

                var iterator = expected_object.iterator();
                while (iterator.next()) |entry| {
                    const actual_value = actual_object.get(entry.key_ptr.*) orelse return false;
                    if (!jsonValueEql(entry.value_ptr.*, actual_value)) return false;
                }
                return true;
            },
            else => return false,
        },
    }
}

// tests
test "getValue returns values for valid keys and null for an incorrect key" {
    const value_str = "{\"person\": {\"name\": \"sarthak\", \"age\": 999, \"profession\": null}}";
    const parsed = try json.parseFromSlice(json.Value, testing.allocator, value_str, .{});
    defer parsed.deinit();
    const val = parsed.value;

    const cases = [_]struct {
        keys: []const []const u8,
        expected: ?json.Value,
    }{
        .{
            .keys = &[_][]const u8{"person"},
            .expected = val.object.get("person").?,
        },
        .{
            .keys = &[_][]const u8{ "person", "name" },
            .expected = .{ .string = "sarthak" },
        },
        .{
            .keys = &[_][]const u8{ "person", "age" },
            .expected = .{ .integer = 999 },
        },
        .{
            .keys = &[_][]const u8{ "person", "profession" },
            .expected = @as(json.Value, .null),
        },
        .{
            .keys = &[_][]const u8{ "person", "incorrect" },
            .expected = null,
        },
    };

    for (cases) |test_case| {
        try testing.expectEqualDeep(test_case.expected, getValue(val, test_case.keys));
    }
}

test "parseLine parse json line, when the limit is reached but the valid json is read" {
    const cases = [_][]const u8{
        "{\"person\": {\"name\": \"sarthak\", \"age\": 999, \"profession\": null}}",
        "{\"person\": {\"name\": \"sarthak\", \"age\": 999, \"profession\": null}}\n",
    };

    for (cases) |str| {
        const limit = std.mem.findScalar(u8, str, newline) orelse str.len;
        const buf = try testing.allocator.alloc(u8, 4);
        defer testing.allocator.free(buf);

        const call = [_]testing.Reader.Call{
            testing.Reader.Call{ .buffer = str },
        };

        var ndjson_reader = NdJsonRecordReader{
            .writer = std.Io.Writer.Allocating.init(testing.allocator),
            .IoLimit = std.Io.Limit.limited(limit),
        };
        defer ndjson_reader.deinit();

        var reader = testing.Reader.init(buf, &call);

        const parsed = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
        defer parsed.deinit();

        const expected = try json.parseFromSlice(json.Value, testing.allocator, str, .{});
        defer expected.deinit();

        try testing.expect(jsonValueEql(expected.value, parsed.value));
    }
}

test "parseLine reads consecutive records and returns null at EOF" {
    const input = "{\"first\":1}\n{\"second\":2}";
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = input }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    const first = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer first.deinit();
    try testing.expectEqual(@as(i64, 1), first.value.object.get("first").?.integer);

    const second = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer second.deinit();
    try testing.expectEqual(@as(i64, 2), second.value.object.get("second").?.integer);

    try testing.expect((try ndjson_reader.parseLine(testing.allocator, &reader.interface)) == null);
}

test "parseLine returns null for empty input" {
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = "" }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expect((try ndjson_reader.parseLine(testing.allocator, &reader.interface)) == null);
}

test "parseLine consumes a malformed record before reading the next record" {
    const input = "not-json\n{\"ok\":true}\n";
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = input }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expectError(error.SyntaxError, ndjson_reader.parseLine(testing.allocator, &reader.interface));

    const parsed = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.object.get("ok").?.bool);
}

test "parseLine discards an oversized record before reading the next record" {
    const input = "{\"long\":1}\n{\"a\":0}\n";
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = input }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    ndjson_reader.IoLimit = .limited(7);
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expectError(error.StreamTooLong, ndjson_reader.parseLine(testing.allocator, &reader.interface));

    const parsed = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 0), parsed.value.object.get("a").?.integer);
}

test "parseLine returns StreamTooLong for an oversized final record" {
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = "{\"long\":1}" }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    ndjson_reader.IoLimit = .limited(7);
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expectError(error.StreamTooLong, ndjson_reader.parseLine(testing.allocator, &reader.interface));
}

test "parseLine clears its buffer before reading the next record" {
    const input = "{\"long\":123456789}\n{\"id\":1}\n";
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = input }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    const first = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer first.deinit();
    try testing.expectEqual(@as(i64, 123456789), first.value.object.get("long").?.integer);

    const second = (try ndjson_reader.parseLine(testing.allocator, &reader.interface)).?;
    defer second.deinit();
    try testing.expectEqual(@as(i64, 1), second.value.object.get("id").?.integer);
    try testing.expect(second.value.object.get("long") == null);
}

test "parseLine rejects duplicate object fields" {
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = "{\"id\":1,\"id\":2}\n" }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expectError(error.DuplicateField, ndjson_reader.parseLine(testing.allocator, &reader.interface));
}

test "parseLine rejects blank records" {
    var buf: [4]u8 = undefined;
    const calls = [_]testing.Reader.Call{.{ .buffer = "\n" }};

    var ndjson_reader = try NdJsonRecordReader.init(testing.allocator);
    defer ndjson_reader.deinit();
    var reader = testing.Reader.init(&buf, &calls);

    try testing.expectError(error.UnexpectedEndOfInput, ndjson_reader.parseLine(testing.allocator, &reader.interface));
}
