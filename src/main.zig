const std = @import("std");
const Io = std.Io;

const ndq = @import("ndq");

const cli = @import("cli.zig");

const ndjson_mod = ndq.ndjson;

pub fn main(init: std.process.Init) !void {
    var gpa = init.arena;
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args_itr = init.minimal.args.iterate();
    const args = try cli.Cli.init(&args_itr);

    var tokenizer = try ndq.lexer.Tokenizer.init(allocator, args.query);
    defer tokenizer.deinit();

    const tokens = try tokenizer.tokens.toOwnedSlice(allocator);
    defer allocator.free(tokens);

    const ast_root = try ndq.parser.Parse(allocator, tokens);
    defer ast_root.deinit(allocator);

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
