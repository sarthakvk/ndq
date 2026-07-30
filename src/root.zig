//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ndjson = @import("ndjson.zig");

test {
    std.testing.refAllDecls(@This());
}

