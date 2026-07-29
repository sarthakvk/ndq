//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

const NdJsonReaderBufferSize: usize = (1 << 10);

pub const NdJsonReader = struct {
    buffer: []u8,
    file_reader: std.Io.File.Reader,
    io: std.Io,
    allocator: std.mem.Allocator,

    parseOptions: std.json.ParseOptions = .{
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

    pub fn next(self: *@This(), allocator: std.mem.Allocator) !?std.json.Parsed(std.json.Value) {
        const reader = &self.file_reader.interface;

        const line = try reader.takeDelimiter('\n') orelse return null;

        const parsedJson = try std.json.parseFromSlice(std.json.Value, allocator, line, self.parseOptions);
        
        return parsedJson;
    }

    pub fn deinit(self: *const @This()) void {
        self.file_reader.file.close(self.io);
        self.allocator.free(self.buffer);
    }
};
