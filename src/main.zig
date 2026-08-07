const std = @import("std");
const Io = std.Io;

const ndq = @import("ndq");

const ndjson_mod = ndq.ndjson;

pub fn main(init: std.process.Init) !void {
    var gpa = init.arena;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args_itr = init.minimal.args.iterate();
    _ = args_itr.next();

    _ = args_itr.next() orelse std.log.err("missing query", .{});

    var jsonReader = try ndjson_mod.NdJsonReader.init(allocator, init.io, null);
    defer jsonReader.deinit();

    while (try jsonReader.next(allocator)) |json| {
        defer json.deinit();

        var it = json.value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            switch (val) {
                .integer => |cval| {
                    std.debug.print("{s}={d}, ", .{ key, cval });
                },
                .string => |cval| {
                    std.debug.print("{s}={s}, ", .{ key, cval });
                },
                else => continue,
            }
        }
        std.debug.print("\n", .{});
    }
}

test {
    std.testing.refAllDecls(@This());
}
