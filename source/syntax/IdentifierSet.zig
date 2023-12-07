//! Assigns unique indeces to CSS identifiers.

const IdentifierSet = @This();

const zss = @import("../../zss.zig");
const syntax = @import("../syntax.zig");
const Utf8String = zss.util.Utf8String;

const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const SegmentedList = std.SegmentedList;

/// Maps adapted keys to `Slice`. `Slice` represents a sub-range of `string_data`.
map: AutoArrayHashMapUnmanaged(void, Slice) = .{},
/// Stores identifiers as UTF-8 encoded strings.
string_data: SegmentedList(u8, 0) = .{},
/// The maximum number of identifiers this set can hold.
max_size: usize,
/// Choose how to compare identifiers.
// TODO: We may want to have identifiers that are compared either case-insensitively or case-sensitively in the same set.
case: enum { sensitive, insensitive },

const Slice = struct {
    begin: u32,
    len: u32,
};

pub fn deinit(set: *IdentifierSet, allocator: Allocator) void {
    set.map.deinit(allocator);
    set.string_data.deinit(allocator);
}

fn adjustCase(set: IdentifierSet, codepoint: u21) u21 {
    return switch (set.case) {
        .sensitive => codepoint,
        .insensitive => switch (codepoint) {
            'A'...'Z' => codepoint - 'A' + 'a',
            else => codepoint,
        },
    };
}

// Unfortunately, Zig's hash maps don't allow the use of generic hash and eql functions,
// so this adapter can't be used directly.
const AdapterGeneric = struct {
    set: *const IdentifierSet,

    pub fn hash(adapter: AdapterGeneric, key: anytype) u32 {
        var hasher = std.hash.Wyhash.init(0);
        var it = key.iterator();
        while (it.next()) |codepoint| {
            const adjusted = adapter.set.adjustCase(codepoint);
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
        while (slice.len > 0) {
            const key_codepoint = key_it.next() orelse return false;

            const string_codepoint = blk: {
                buffer[0] = string_it.next().?.*;
                const len = std.unicode.utf8ByteSequenceLength(buffer[0]) catch unreachable;
                slice.len -= len;
                for (1..len) |i| buffer[i] = string_it.next().?.*;
                break :blk std.unicode.utf8Decode(buffer[0..len]) catch unreachable;
            };

            if (adapter.set.adjustCase(key_codepoint) != string_codepoint) return false;
        }
        return key_it.next() == null;
    }
};

fn getOrPutGeneric(set: *IdentifierSet, allocator: Allocator, key: anytype) !usize {
    const Key = @TypeOf(key);

    const Adapter = struct {
        generic: AdapterGeneric,

        pub inline fn hash(self: @This(), k: Key) u32 {
            return self.generic.hash(k);
        }
        pub inline fn eql(self: @This(), k: Key, _: void, index: usize) bool {
            return self.generic.eql(k, {}, index);
        }
    };

    const adapter = Adapter{ .generic = .{ .set = set } };
    const result = try set.map.getOrPutAdapted(allocator, key, adapter);
    errdefer set.map.swapRemoveAt(result.index);

    if (!result.found_existing) {
        if (result.index >= set.max_size) return error.Overflow;

        var slice = Slice{ .begin = @intCast(set.string_data.len), .len = 0 };
        var it = key.iterator();
        var buffer: [4]u8 = undefined;
        while (it.next()) |codepoint| {
            const len = std.unicode.utf8Encode(set.adjustCase(codepoint), &buffer) catch unreachable;
            slice.len += len;
            _ = try std.math.add(u32, slice.begin, slice.len);
            try set.string_data.appendSlice(allocator, buffer[0..len]);
        }
        result.value_ptr.* = slice;
    }

    return result.index;
}

pub fn getOrPutFromSource(
    set: *IdentifierSet,
    allocator: Allocator,
    source: syntax.parse.Source,
    ident_seq_it: syntax.parse.IdentSequenceIterator,
) !usize {
    const Key = struct {
        source: syntax.parse.Source,
        ident_seq_it: syntax.parse.IdentSequenceIterator,

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

pub fn getOrPutFromString(
    set: *IdentifierSet,
    allocator: Allocator,
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

    std.debug.assert(syntax.tokenize.stringIsIdentSequence(Utf8String{ .data = string }) catch false);
    const key = Key{ .string = string };
    return set.getOrPutGeneric(allocator, key);
}
