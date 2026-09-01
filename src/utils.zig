const std = @import("std");

const ParseIndexError = std.fmt.ParseIntError || error{
    IndexOutOfRange,
};

/// This functions converst a base 10 integer string
/// to index, while safly handling the negitive index.
/// The negitive index follows the pythonic indexing
/// pattern i.e negitive int indexes from the end.
pub fn parseIndex(s: []const u8, len: usize) ParseIndexError!usize {
    // negitive case
    if (s.len > 0 and s[0] == '-') {
        const index = try std.fmt.parseInt(usize, s[1..], 10);
        if (index == 0 or index > len) return ParseIndexError.IndexOutOfRange;
        return len - index;
    }

    const index = try std.fmt.parseInt(usize, s, 10);
    if (index >= len) return ParseIndexError.IndexOutOfRange;

    return index;
}

test parseIndex {
    const Case = struct {
        s: []const u8,
        len: usize,
        exp: union(enum) {
            err: ParseIndexError,
            out: usize,
        },
    };

    const cases = [_]Case{
        .{
            .s = "-123",
            .len = 123,
            .exp = .{ .out = 0 },
        },
        .{
            .s = "123",
            .len = 122,
            .exp = .{ .err = ParseIndexError.IndexOutOfRange },
        },
        .{
            .s = "-125",
            .len = 123,
            .exp = .{ .err = ParseIndexError.IndexOutOfRange },
        },
        .{
            .s = "123",
            .len = 123,
            .exp = .{ .err = ParseIndexError.IndexOutOfRange },
        },
        .{
            .s = "133",
            .len = 125,
            .exp = .{ .err = ParseIndexError.IndexOutOfRange },
        },
        .{
            .s = "-",
            .len = 123,
            .exp = .{ .err = ParseIndexError.InvalidCharacter },
        },
        .{
            .s = "",
            .len = 123,
            .exp = .{ .err = ParseIndexError.InvalidCharacter },
        },
        .{
            .s = "12",
            .len = 123,
            .exp = .{ .out = 12 },
        },
        .{
            .s = "-2",
            .len = 123,
            .exp = .{ .out = 121 },
        },
    };

    for (cases) |case| {
        const actual = parseIndex(case.s, case.len) catch |err| {
            switch (case.exp) {
                .err => |exp_err| try std.testing.expectEqual(exp_err, err),
                .out => try std.testing.expect(false),
            }
            continue;
        };

        switch (case.exp) {
            .out => |exp| try std.testing.expectEqual(exp, actual),
            .err => try std.testing.expect(false),
        }
    }
}
