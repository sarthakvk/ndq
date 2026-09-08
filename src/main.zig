const std = @import("std");
const Io = std.Io;

const ndq = @import("ndq");

const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var args_itr = init.minimal.args.iterate();
    const args = try cli.Cli.init(&args_itr);

    var tokenizer = try ndq.lexer.Tokenizer.init(allocator, args.query);
    defer tokenizer.deinit();

    const ast_root = try ndq.parser.Parse(allocator, tokenizer.tokens);
    defer ast_root.deinit(allocator);

    var input = try ndq.ndjson.Input.init(allocator, init.io, args.input);
    defer input.deinit(allocator);

    var record_reader = try ndq.ndjson.NdJsonRecordReader.init(allocator);
    defer record_reader.deinit();

    var evaluator = try ndq.executor.TermEvaluator.init(allocator, tokenizer.buf);
    defer evaluator.deinit();

    var i: usize = 0;
    while (try record_reader.parseLine(allocator, &input.reader.interface)) |parsed| {
        defer parsed.deinit();

        const eval = try evaluator.evaluateAST(ast_root, parsed.value);

        if (eval) {
            std.debug.print("{d}: {f}\n", .{
                i,
                std.json.fmt(parsed.value, .{}),
            });
        }
        i += 1;
    }
}

test {
    std.testing.refAllDecls(@This());
}
