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

    var output = try ndq.ndjson.Output.init(allocator, init.io, args.output);
    defer output.deinit(allocator);

    const iout = &output.writer.interface;

    var record_reader = try ndq.ndjson.NdJsonRecordReader.init(allocator);
    defer record_reader.deinit();

    var evaluator = try ndq.executor.TermEvaluator.init(allocator, tokenizer.buf);
    defer evaluator.deinit();
    while (try record_reader.readLine(&input.reader.interface)) |line| {
        if (line.len == 0) continue;

        defer allocator.free(line);
        const parsed = try record_reader.parseJsonLine(allocator, line) orelse continue;
        defer parsed.deinit();

        const eval = try evaluator.evaluateAST(ast_root, parsed.value);

        if (eval) {
            try iout.writeAll(line);
            try iout.writeByte('\n');
        }
    }
    try iout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
