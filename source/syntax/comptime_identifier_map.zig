const std = @import("std");
const mem = std.mem;

/// A modified version of the std.ComptimeStringMap, to be used to map CSS identifiers.
/// To do this, it compares strings case-insensitively.
///
/// Comptime string map optimized for small sets of disparate string keys.
/// Works by separating the keys by length at comptime and only checking strings of
/// equal length at runtime.
///
/// `kvs_list` expects a list of `struct { []const u8, V }` (key-value pair) tuples.
/// You can pass `struct { []const u8 }` (only keys) tuples if `V` is `void`.
pub fn ComptimeIdentifierMap(comptime V: type, comptime kvs_list: anytype) type {
    comptime {
        for (kvs_list) |kv| {
            for (kv[0]) |c| switch (c) {
                // NOTE: This could be extended to support underscores and digits, but for now it is not needed.
                'a'...'z', '-' => {},
                'A'...'Z' => @compileError("key is not lowercase: " ++ kv[0]),
                else => @compileError("only lowercase letters and dashes allowed in keys"),
            };
        }
    }

    const precomputed = comptime blk: {
        @setEvalBranchQuota(1500);
        const KV = struct {
            key: []const u8,
            value: V,
        };
        var sorted_kvs: [kvs_list.len]KV = undefined;
        for (kvs_list, 0..) |kv, i| {
            if (V != void) {
                sorted_kvs[i] = .{ .key = kv.@"0", .value = kv.@"1" };
            } else {
                sorted_kvs[i] = .{ .key = kv.@"0", .value = {} };
            }
        }

        const SortContext = struct {
            kvs: []KV,

            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                const lhs = ctx.kvs[a].key;
                const rhs = ctx.kvs[b].key;
                switch (std.math.order(lhs.len, rhs.len)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {
                        if (mem.eql(u8, lhs, rhs)) @compileError("duplicate identifier: " ++ lhs);
                        return false;
                    },
                }
            }

            pub fn swap(ctx: @This(), a: usize, b: usize) void {
                return std.mem.swap(KV, &ctx.kvs[a], &ctx.kvs[b]);
            }
        };
        mem.sortUnstableContext(0, sorted_kvs.len, SortContext{ .kvs = &sorted_kvs });

        const min_len = sorted_kvs[0].key.len;
        const max_len = sorted_kvs[sorted_kvs.len - 1].key.len;
        var len_indexes: [max_len + 1]usize = undefined;
        var len: usize = 0;
        var i: usize = 0;
        while (len <= max_len) : (len += 1) {
            // find the first keyword len == len
            while (len > sorted_kvs[i].key.len) {
                i += 1;
            }
            len_indexes[len] = i;
        }
        break :blk .{
            .min_len = min_len,
            .max_len = max_len,
            .sorted_kvs = sorted_kvs,
            .len_indexes = len_indexes,
        };
    };

    return struct {
        /// Returns the value for the key if any, else null.
        /// The string is compared case-insensitively.
        pub fn get(str: []const u8) ?V {
            if (str.len < precomputed.min_len or str.len > precomputed.max_len)
                return null;

            var i = precomputed.len_indexes[str.len];
            while (true) {
                const kv = precomputed.sorted_kvs[i];
                if (kv.key.len != str.len)
                    return null;
                if (stringEql(kv.key, str))
                    return kv.value;
                i += 1;
                if (i >= precomputed.sorted_kvs.len)
                    return null;
            }
        }

        fn stringEql(key: []const u8, str: []const u8) bool {
            for (key, str) |k, s| {
                const lowercase = switch (s) {
                    'A'...'Z' => s - 'A' + 'a',
                    else => s,
                };
                if (k != lowercase) return false;
            }
            return true;
        }
    };
}

const TestEnum = enum {
    A,
    B,
    C,
    D,
    E,
};

test "ComptimeIdentifierMap list literal of list literals" {
    const map = ComptimeIdentifierMap(TestEnum, .{
        .{ "these", .D },
        .{ "have", .A },
        .{ "nothing", .B },
        .{ "incommon", .C },
        .{ "samelen", .E },
    });

    try testMap(map);
}

test "ComptimeIdentifierMap array of structs" {
    const KV = struct { []const u8, TestEnum };
    const map = ComptimeIdentifierMap(TestEnum, [_]KV{
        .{ "these", .D },
        .{ "have", .A },
        .{ "nothing", .B },
        .{ "incommon", .C },
        .{ "samelen", .E },
    });

    try testMap(map);
}

test "ComptimeIdentifierMap slice of structs" {
    const KV = struct { []const u8, TestEnum };
    const slice: []const KV = &[_]KV{
        .{ "these", .D },
        .{ "have", .A },
        .{ "nothing", .B },
        .{ "incommon", .C },
        .{ "samelen", .E },
    };
    const map = ComptimeIdentifierMap(TestEnum, slice);

    try testMap(map);
}

fn testMap(comptime map: anytype) !void {
    try std.testing.expectEqual(TestEnum.A, map.get("have").?);
    try std.testing.expectEqual(TestEnum.B, map.get("nothing").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expectEqual(TestEnum.D, map.get("these").?);
    try std.testing.expectEqual(TestEnum.E, map.get("samelen").?);

    try std.testing.expect(map.get("missing") == null);
    try std.testing.expect(map.get("these") != null);
}

test "ComptimeIdentifierMap void value type, slice of structs" {
    const KV = struct { []const u8 };
    const slice: []const KV = &[_]KV{
        .{"these"},
        .{"have"},
        .{"nothing"},
        .{"incommon"},
        .{"samelen"},
    };
    const map = ComptimeIdentifierMap(void, slice);

    try testSet(map);
}

test "ComptimeIdentifierMap void value type, list literal of list literals" {
    const map = ComptimeIdentifierMap(void, .{
        .{"these"},
        .{"have"},
        .{"nothing"},
        .{"incommon"},
        .{"samelen"},
    });

    try testSet(map);
}

fn testSet(comptime map: anytype) !void {
    try std.testing.expectEqual({}, map.get("have").?);
    try std.testing.expectEqual({}, map.get("nothing").?);
    try std.testing.expect(null == map.get("missing"));
    try std.testing.expectEqual({}, map.get("these").?);
    try std.testing.expectEqual({}, map.get("samelen").?);

    try std.testing.expect(map.get("missing") == null);
    try std.testing.expect(map.get("these") != null);
}
