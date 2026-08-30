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

    const ast_root = try ndq.parser.Parse(allocator, tokenizer.tokens);
    defer ast_root.deinit(allocator);
}

test {
    std.testing.refAllDecls(@This());
}
