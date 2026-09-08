const std = @import("std");
const options = @import("regression_test_options");

pub const ExpectedStream = union(enum) {
    stdout: []const u8,
    stderr: []const u8,
};

pub const Case = struct {
    name: []const u8,
    input: []const u8,
    query: []const u8,
    expected: ExpectedStream,
    exit_code: u8,
};

pub const cases = [_]Case{
    .{
        .name = "filter records to stdout",
        .input = "test/regression/users.jsonl",
        .query = "age >= 36",
        .expected = .{ .stdout = "test/regression/age-gte-36.jsonl" },
        .exit_code = 0,
    },
    .{
        .name = "invalid query to stderr",
        .input = "test/regression/users.jsonl",
        .query = "age",
        .expected = .{ .stderr = "test/regression/invalid-query.stderr" },
        .exit_code = 1,
    },
};

comptime {
    for (cases) |case| {
        _ = struct {
            test {
                try std.testing.expect(try runCase(
                    std.testing.allocator,
                    std.testing.io,
                    std.testing.environ,
                    options.ndq_executable,
                    case,
                    false,
                ));
            }
        };
    }
}

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    executable: []const u8,
    case: Case,
    update: bool,
) !bool {
    var environ_map = try std.process.Environ.createMap(environ, allocator);
    defer environ_map.deinit();
    _ = environ_map.swapRemove("CLICOLOR_FORCE");
    try environ_map.put("NO_COLOR", "1");

    const result = try std.process.run(allocator, io, .{
        .argv = &.{ executable, "-i", case.input, case.query },
        .environ_map = &environ_map,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!hasExitCode(result.term, case.exit_code)) {
        std.debug.print("FAIL {s}: expected exit code {d}, got {any}\n", .{ case.name, case.exit_code, result.term });
        return false;
    }

    const actual, const other, const expected_path = switch (case.expected) {
        .stdout => |path| .{ result.stdout, result.stderr, path },
        .stderr => |path| .{ result.stderr, result.stdout, path },
    };

    if (other.len != 0) {
        std.debug.print("FAIL {s}: unexpected content on the non-selected stream\n", .{case.name});
        return false;
    }

    if (update) {
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = expected_path,
            .data = actual,
        });
        std.debug.print("updated {s}\n", .{expected_path});
        return true;
    }

    const expected = std.Io.Dir.cwd().readFileAlloc(io, expected_path, allocator, .unlimited) catch |err| {
        std.debug.print("FAIL {s}: could not read {s}: {s}\n", .{ case.name, expected_path, @errorName(err) });
        return false;
    };
    defer allocator.free(expected);

    const actual_hash = hash(actual);
    const expected_hash = hash(expected);
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) {
        const actual_hex = std.fmt.bytesToHex(actual_hash, .lower);
        const expected_hex = std.fmt.bytesToHex(expected_hash, .lower);
        std.debug.print("FAIL {s}: content hash mismatch\n  expected {s}\n  actual   {s}\n", .{
            case.name,
            expected_hex,
            actual_hex,
        });
        return false;
    }

    return true;
}

fn hasExitCode(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn hash(content: []const u8) [Sha256.digest_length]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &digest, .{});
    return digest;
}
