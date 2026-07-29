const std = @import("std");
const Io = std.Io;

const ndq = @import("ndq");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();

    const filename = "test.json";

    const allocator = gpa.allocator();

    var jsonReader = try ndq.NdJsonReader.init(allocator, init.io, filename);
    defer jsonReader.deinit();
    
    while (try jsonReader.next(allocator)) |json| {
        defer json.deinit();

        var it = json.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            switch (val) {
                .integer => |cval| {
                    std.debug.print("{s}={d}, ", .{key, cval});
                },
                .string => |cval| {
                    std.debug.print("{s}={s}, ", .{key, cval});
                },
                else => continue,
            }
        }
        std.debug.print("\n", .{});
    }

}
