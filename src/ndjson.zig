const std = @import("std");
const json = std.json;
const testing = std.testing;

const NdJsonReaderBufferSize: usize = (1 << 10);

pub const NdJsonReader = struct {
    buffer: []u8,
    file_reader: std.Io.File.Reader,
    io: std.Io,
    allocator: std.mem.Allocator,

    parseOptions: json.ParseOptions = .{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .allocate = .alloc_if_needed,
        .parse_numbers = true,
    },

    pub fn init(allocator: std.mem.Allocator, io: std.Io, filepath: []const u8) !NdJsonReader {
        var file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
        errdefer file.close(io);

        const buffer = try allocator.alloc(u8, NdJsonReaderBufferSize);
        errdefer allocator.free(buffer);

        return .{
            .file_reader = file.reader(io, buffer),
            .buffer = buffer,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn next(self: *@This(), allocator: std.mem.Allocator) !?json.Parsed(json.Value) {
        const reader = &self.file_reader.interface;

        const line = try reader.takeDelimiter('\n') orelse return null;

        const parsedJson = try json.parseFromSlice(json.Value, allocator, line, self.parseOptions);

        return parsedJson;
    }

    pub fn deinit(self: *const @This()) void {
        self.file_reader.file.close(self.io);
        self.allocator.free(self.buffer);
    }
};

test NdJsonReader {
    // Initialize
    const gpa = testing.allocator;
    const io = testing.io;

    const testFileFields = enum {
        id,
        email,
        name,
    };

    // Test valid jsonl"
    {
        const filepath = "resources/ndjson_reader_test_valid.jsonl";
        var reader = try NdJsonReader.init(gpa, io, filepath);
        defer reader.deinit();

        for (0..10) |row| {
            const pval = try reader.next(gpa) orelse return error.NoRowFound;
            defer pval.deinit();

            var it = pval.value.object.iterator();

            while (it.next()) |entry| {
                const key = std.meta.stringToEnum(testFileFields, entry.key_ptr.*) orelse return error.UnknownKey;
                switch (key) {
                    .id => try testing.expect(entry.value_ptr.integer == row),
                    .email => {
                        try testing.expectFmt(entry.value_ptr.string, "example{d}@test.com", .{row});
                    },
                    .name => {
                        try testing.expectFmt(entry.value_ptr.string, "example {d}", .{row});
                    },
                }
            }
        }
        try testing.expectEqual(null, try reader.next(gpa));
    }

    // Test jsonl with invalid file
    {
        const filepath = "resources/ndjson_reader_test_invalid.jsonl";
        var reader = try NdJsonReader.init(gpa, io, filepath);
        defer reader.deinit();
        
        const UEOI_line: usize = 1;
        const SE_line: usize = 5;
        

        for (0..10) |row| {

            if (row == UEOI_line) {
                try testing.expectError(json.Scanner.Error.UnexpectedEndOfInput, reader.next(gpa));
                continue;
            } else if (row == SE_line) {
                try testing.expectError(json.Scanner.Error.SyntaxError, reader.next(gpa));
                continue;
            }


            const pval = try reader.next(gpa) orelse return error.NoRowFound;
            defer pval.deinit();

            var it = pval.value.object.iterator();

            while (it.next()) |entry| {
                const key = std.meta.stringToEnum(testFileFields, entry.key_ptr.*) orelse return error.UnknownKey;
                switch (key) {
                    .id => try testing.expect(entry.value_ptr.integer == row),
                    .email => {
                        try testing.expectFmt(entry.value_ptr.string, "example{d}@test.com", .{row});
                    },
                    .name => {
                        try testing.expectFmt(entry.value_ptr.string, "example {d}", .{row});
                    },
                }
            }
        }
        try testing.expectEqual(null, try reader.next(gpa));
    }

}
