/// NDQ Command Line Interface: {s}
/// Sarthak V. Kumar <me@sarthakvk.com>
///
/// NDQ is a tool to query ndjson files, The current version only supports filtering
/// queries. Due to it's streaming nature it can process large ndjson files efficiently.
///
/// Project homepage: https://github.com/sarthakvk/ndq
///
///
/// Usage:
///     ndq [OPTIONS] <query>
///
/// OPTIONS:
///     --input=INPUTFILE, -i INPUTFILE
///         Input ndjson filepath, if not provided stdin will be used as input
///
///     --output=OUTPUTFILE, -o OUTPUTFILE
///         Output filepath, if not provided stdout will be used for output
///
const std = @import("std");
const mem = std.mem;

pub const CliError = error{
    InvalidOption,
    MissingOptionValue,
    DuplicateOption,
    UnexpectedArgument,
    MissingQuery,
};

const Option = enum {
    inputArg,
    inputKwarg,
    outputArg,
    outputKwarg,
    none,

    fn strToFlag(s: []const u8) @This() {
        if (mem.eql(u8, s, "-i"))
            return .inputArg
        else if (mem.startsWith(u8, s, "--input="))
            return .inputKwarg
        else if (mem.eql(u8, s, "-o"))
            return .outputArg
        else if (mem.eql(u8, s, "--output="))
            return .outputKwarg
        else
            return .none;
    }

    fn extractKwarg(s: []const u8) ![]const u8 {
        var itr = mem.splitScalar(u8, s, '=');

        if (itr.next() == null) return CliError.InvalidOption;

        const out = itr.next() orelse return CliError.MissingOptionValue;

        if (itr.next() != null) return CliError.InvalidOption;

        return out;
    }
};

/// Defines the cli args for NDQ
pub const Cli = struct {
    /// Input file, if this is None
    /// the input is assumed to be stdio
    input: ?[]const u8,

    /// Output file, if this is None
    /// the output will be written to stdout
    output: ?[]const u8,

    /// Raw query
    query: []const u8,

    const Self = @This();

    pub fn init(args_itr: *std.process.Args.Iterator) !Self {
        // consume the executable argument
        _ = args_itr.next();
        var query: ?[]const u8 = null;
        var input: ?[]const u8 = null;
        var output: ?[]const u8 = null;

        while (args_itr.next()) |arg| {
            switch (Option.strToFlag(arg)) {
                .inputArg, .inputKwarg => |op| {
                    if (input != null) return CliError.DuplicateOption;

                    input = switch (op) {
                        .inputArg => args_itr.next() orelse return CliError.MissingOptionValue,
                        .inputKwarg => try Option.extractKwarg(arg),
                        else => unreachable,
                    };
                },
                .outputArg, .outputKwarg => |op| {
                    output = switch (op) {
                        .outputArg => args_itr.next() orelse return CliError.MissingOptionValue,
                        .outputKwarg => try Option.extractKwarg(arg),
                        else => unreachable,
                    };
                },
                .none => {
                    if (args_itr.next() != null) return CliError.UnexpectedArgument;
                    query = arg;
                    break;
                },
            }
        }

        return .{
            .query = query orelse return CliError.MissingQuery,
            .input = input,
            .output = output,
        };
    }
};
