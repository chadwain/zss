//! Assigns unique indeces to CSS identifiers.
//! Indeces start from 0 and increase by 1 for every unique identifier.

// TODO: Delete this in favor of zss.StringInterner
// TODO: Consider turning this from a set into a map

const IdentifierSet = @This();

const zss = @import("../zss.zig");
const syntax = @import("../syntax.zig");

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const SegmentedList = std.SegmentedList;

/// Maps adapted keys to `Slice`. `Slice` represents a sub-range of `string_data`.
map: AutoArrayHashMapUnmanaged(void, Slice) = .{},
/// Stores identifiers as UTF-8 encoded strings.
string_data: SegmentedList(u8, 0) = .{},
/// Choose the maximum number of identifiers this set can hold.
max_size: usize,
/// Choose how to compare identifiers.
case: Case,

pub const Case = enum { sensitive, insensitive };

const Slice = struct {
    begin: u32,
    len: u32,
};

pub fn deinit(set: *IdentifierSet, allocator: Allocator) void {
    set.map.deinit(allocator);
    set.string_data.deinit(allocator);
}

fn adjustCase(case: Case, codepoint: u21) u21 {
    return switch (case) {
        .sensitive => codepoint,
        .insensitive => switch (codepoint) {
            'A'...'Z' => codepoint - 'A' + 'a',
            else => codepoint,
        },
    };
}

const AdapterGeneric = struct {
    set: *const IdentifierSet,

    pub fn hash(adapter: AdapterGeneric, key: anytype) u32 {
        var hasher = std.hash.Wyhash.init(0);
        var it = key.iterator();
        const case = adapter.set.case;
        while (it.next()) |codepoint| {
            const adjusted = adjustCase(case, codepoint);
            const bytes = std.mem.asBytes(&adjusted)[0..3];
            hasher.update(bytes);
        }
        return @truncate(hasher.final());
    }

    pub fn eql(adapter: AdapterGeneric, key: anytype, _: void, index: usize) bool {
        var key_it = key.iterator();

        var slice = adapter.set.map.values()[index];
        var string_it = adapter.set.string_data.constIterator(slice.begin);
        var buffer: [4]u8 = undefined;

        const case = adapter.set.case;
        while (slice.len > 0) {
            const key_codepoint = key_it.next() orelse return false;

            const string_codepoint = blk: {
                buffer[0] = string_it.next().?.*;
                const len = std.unicode.utf8ByteSequenceLength(buffer[0]) catch unreachable;
                slice.len -= len;
                for (1..len) |i| buffer[i] = string_it.next().?.*;
                break :blk std.unicode.utf8Decode(buffer[0..len]) catch unreachable;
            };

            if (adjustCase(case, key_codepoint) != string_codepoint) return false;
        }
        return key_it.next() == null;
    }
};

fn getGeneric(set: *const IdentifierSet, key: anytype) ?usize {
    const adapter = AdapterGeneric{ .set = set };
    return set.map.getIndexAdapted(key, adapter);
}

pub fn getFromString(
    set: *const IdentifierSet,
    // TODO: Ensure this is an ASCII string
    string: []const u8,
) ?usize {
    const Key = struct {
        string: []const u8,

        const Iterator = struct {
            string: []const u8,
            index: usize,

            fn next(self: *@This()) ?u21 {
                if (self.index == self.string.len) return null;
                defer self.index += 1;
                return self.string[self.index];
            }
        };

        fn iterator(self: @This()) Iterator {
            return .{ .string = self.string, .index = 0 };
        }
    };

    assert(syntax.stringIsIdentSequence(string));
    const key = Key{ .string = string };
    return set.getGeneric(key);
}

fn getOrPutGeneric(set: *IdentifierSet, allocator: Allocator, key: anytype) !usize {
    const adapter = AdapterGeneric{ .set = set };
    if (set.map.getIndexAdapted(key, adapter)) |index| return index;
    if (set.map.count() == set.max_size) return error.Overflow;

    const string_data_old_len: u32 = @intCast(set.string_data.len);
    errdefer set.string_data.shrink(string_data_old_len);

    const slice = slice: {
        const case = set.case;
        var slice = Slice{ .begin = string_data_old_len, .len = 0 };
        var it = key.iterator();
        var buffer: [4]u8 = undefined;
        while (it.next()) |codepoint| {
            const len = std.unicode.utf8Encode(adjustCase(case, codepoint), &buffer) catch unreachable;
            slice.len += len;
            _ = try std.math.add(u32, slice.begin, slice.len);
            try set.string_data.appendSlice(allocator, buffer[0..len]);
        }
        break :slice slice;
    };

    const gop_result = try set.map.getOrPutAdapted(allocator, key, adapter);
    assert(!gop_result.found_existing);
    assert(gop_result.index == set.map.count() - 1);
    gop_result.value_ptr.* = slice;
    return set.map.count() - 1;
}

pub fn getOrPutFromSource(
    set: *IdentifierSet,
    allocator: Allocator,
    source: syntax.TokenSource,
    ident_seq_it: syntax.IdentSequenceIterator,
) !usize {
    const Key = struct {
        source: syntax.TokenSource,
        ident_seq_it: syntax.IdentSequenceIterator,

        fn iterator(self: @This()) @This() {
            return self;
        }

        fn next(self: *@This()) ?u21 {
            return self.ident_seq_it.next(self.source);
        }
    };

    const key = Key{ .source = source, .ident_seq_it = ident_seq_it };
    return set.getOrPutGeneric(allocator, key);
}

// TODO: This is only used in tests
pub fn getOrPutFromString(
    set: *IdentifierSet,
    allocator: Allocator,
    // TODO: Ensure this is an ASCII string
    string: []const u8,
) !usize {
    const Key = struct {
        string: []const u8,

        const Iterator = struct {
            string: []const u8,
            index: usize,

            fn next(self: *@This()) ?u21 {
                if (self.index == self.string.len) return null;
                defer self.index += 1;
                return self.string[self.index];
            }
        };

        fn iterator(self: @This()) Iterator {
            return .{ .string = self.string, .index = 0 };
        }
    };

    assert(syntax.stringIsIdentSequence(string));
    const key = Key{ .string = string };
    return set.getOrPutGeneric(allocator, key);
}
