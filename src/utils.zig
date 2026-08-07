const std = @import("std");

pub fn isInt(s: []const u8) bool {
    if (s.len == 0) return false;
    var s_ = s;
    if (s[0] == '-') {
        if (s.len == 1) return false;
        s_ = s[1..];
    }

    for (s_) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}
