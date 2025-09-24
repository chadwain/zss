//! Assigns index numbers to UTF-8 strings.
//! Indeces start from 0 and increase by 1 for every unique string.
//! Unicode normalization is not taken into account.

const StringInterner = @This();

const zss = @import("zss.zig");
const Location = TokenSource.Location;
const TokenSource = zss.syntax.TokenSource;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

indexer: std.AutoArrayHashMapUnmanaged(void, Range),
string: zss.SegmentedUtf8String,
max_size: usize,

const Range = struct {
    position: zss.SegmentedUtf8String.Size,
    len: zss.SegmentedUtf8String.Size,
};

pub const Options = struct {
    /// The maximum amount of unique strings that can be held.
    max_size: usize,
    case: Case,

    pub const Case = enum {
        sensitive,
        insensitive,
    };
};

pub fn init(options: Options) StringInterner {
    // TODO: use options.case
    return .{
        .indexer = .empty,
        .string = .init(1 << 10, 1 << 31),
        .max_size = options.max_size - @intFromBool(options.max_size +% 1 == 0),
    };
}

pub fn deinit(interner: *StringInterner, allocator: Allocator) void {
    interner.indexer.deinit(allocator);
    interner.string.deinit(allocator);
}

const Hasher = struct {
    buffer: [32]u8 = undefined,
    len: u8 = 0,

    fn full(hasher: Hasher) bool {
        return hasher.len == hasher.buffer.len;
    }

    fn end(hasher: *Hasher, comptime case: Options.Case) u32 {
        const slice = hasher.buffer[0..hasher.len];
        switch (case) {
            .sensitive => {},
            .insensitive => {
                for (slice) |*c| {
                    c.* = std.ascii.toLower(c.*);
                }
            },
        }

        var wyhash = std.hash.Wyhash.init(0);
        wyhash.update(slice);
        return @truncate(wyhash.final());
    }

    fn addCodepoint(hasher: *Hasher, codepoint: u21) void {
        var codepoint_buffer: [4]u8 = undefined;
        const codepoint_len = std.unicode.utf8Encode(codepoint, &codepoint_buffer) catch unreachable;
        const hashed_len = @min(hasher.buffer.len - hasher.len, codepoint_len);
        @memcpy(hasher.buffer[hasher.len..][0..hashed_len], codepoint_buffer[0..hashed_len]);
        hasher.len += @intCast(hashed_len);
    }

    fn addString(hasher: *Hasher, string: []const u8) void {
        const hashed_len = @min(hasher.buffer.len - hasher.len, string.len);
        @memcpy(hasher.buffer[hasher.len..][0..hashed_len], string[0..hashed_len]);
        hasher.len += @intCast(hashed_len);
    }
};

fn adjustCase(interner: *const StringInterner, comptime case: Options.Case, range: Range) void {
    switch (case) {
        .sensitive => {},
        .insensitive => {
            var segment_iterator = interner.string.iterator(range.position, range.len);
            while (segment_iterator.next()) |segment| {
                for (segment) |*c| c.* = std.ascii.toLower(c.*);
            }
        },
    }
}

pub fn addFromIdentToken(
    interner: *StringInterner,
    allocator: Allocator,
    /// Must be the location of an <ident-token>.
    location: Location,
    token_source: TokenSource,
) !usize {
    return addFromGenericTokenIterator(interner, allocator, token_source, token_source.identTokenIterator(location), .insensitive);
}

pub fn addFromIdentTokenKeepCase(
    interner: *StringInterner,
    allocator: Allocator,
    /// Must be the location of an <ident-token>.
    location: Location,
    token_source: TokenSource,
) !usize {
    return addFromGenericTokenIterator(interner, allocator, token_source, token_source.identTokenIterator(location), .sensitive);
}

pub fn addFromStringToken(
    interner: *StringInterner,
    allocator: Allocator,
    /// Must be the location of a <string-token>.
    location: Location,
    token_source: TokenSource,
) !usize {
    return addFromGenericTokenIterator(interner, allocator, token_source, token_source.stringTokenIterator(location), .insensitive);
}

fn addFromGenericTokenIterator(
    interner: *StringInterner,
    allocator: Allocator,
    token_source: TokenSource,
    token_iterator: anytype,
    comptime case: Options.Case,
) !usize {
    const Key = struct {
        source: TokenSource,
        it: @TypeOf(token_iterator),
    };

    const Adapter = struct {
        interner: *const StringInterner,

        pub fn hash(_: @This(), key: Key) u32 {
            var hasher = Hasher{};
            var it = key.it;
            while (it.next(key.source)) |codepoint| {
                if (hasher.full()) break;
                hasher.addCodepoint(codepoint);
            }
            return hasher.end(case);
        }

        pub fn eql(adapter: @This(), key: Key, _: void, index: usize) bool {
            var key_it = key.it;
            const range = adapter.interner.indexer.values()[index];
            var string_it = adapter.interner.string.iterator(range.position, range.len);
            while (string_it.next()) |segment| {
                var string_index: usize = 0;
                while (string_index < segment.len) {
                    const key_codepoint = key_it.next(key.source) orelse return false;
                    const key_codepoint_adjusted = switch (case) {
                        .sensitive => key_codepoint,
                        .insensitive => zss.unicode.latin1ToLowercase(key_codepoint),
                    };
                    const string_codepoint_len = std.unicode.utf8ByteSequenceLength(segment[string_index]) catch unreachable;
                    const string_codepoint = std.unicode.utf8Decode(segment[string_index..][0..string_codepoint_len]) catch unreachable;
                    if (key_codepoint_adjusted != string_codepoint) return false;
                    string_index += string_codepoint_len;
                }
            }
            return key_it.next(key.source) == null;
        }
    };

    const gop = try interner.indexer.getOrPutAdapted(
        allocator,
        Key{ .source = token_source, .it = token_iterator },
        Adapter{ .interner = interner },
    );
    if (gop.found_existing) return gop.index;
    if (gop.index == interner.max_size) {
        interner.indexer.swapRemoveAt(gop.index);
        return error.MaxSizeExceeded;
    }

    // TODO: Find a way to reserve space upfront
    var range = Range{ .position = interner.string.position, .len = 0 };
    var it = token_iterator;
    var buffer: [4]u8 = undefined;
    while (it.next(token_source)) |codepoint| {
        const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
        try interner.string.append(allocator, buffer[0..len]);
        range.len += len;
    }
    adjustCase(interner, case, range);

    gop.value_ptr.* = range;
    return gop.index;
}

pub fn addFromString(interner: *StringInterner, allocator: Allocator, string: []const u8) !usize {
    const Adapter = struct {
        interner: *const StringInterner,

        pub fn hash(_: @This(), key: []const u8) u32 {
            var hasher = Hasher{};
            hasher.addString(key);
            return hasher.end(.insensitive);
        }

        pub fn eql(adapter: @This(), key: []const u8, _: void, index: usize) bool {
            const range = adapter.interner.indexer.values()[index];
            if (key.len != range.len) return false;

            var key_index: usize = 0;
            var segment_iterator = adapter.interner.string.iterator(range.position, range.len);
            while (segment_iterator.next()) |segment| {
                const key_slice = key[key_index..][0..segment.len];
                for (key_slice, segment) |a, b| {
                    if (std.ascii.toLower(a) != b) return false;
                }
                key_index += segment.len;
            }
            return true;
        }
    };

    const gop = try interner.indexer.getOrPutAdapted(allocator, string, Adapter{ .interner = interner });
    if (gop.found_existing) return gop.index;
    if (gop.index == interner.max_size) {
        interner.indexer.swapRemoveAt(gop.index);
        return error.MaxSizeExceeded;
    }

    const range = Range{ .position = interner.string.position, .len = @intCast(string.len) };
    try interner.string.append(allocator, string);
    adjustCase(interner, .insensitive, range);

    gop.value_ptr.* = range;
    return gop.index;
}

test "StringInterner" {
    const allocator = std.testing.allocator;
    const token_source = try TokenSource.init("apple banana cucumber durian \"apple\" CUCUMBER");
    var ast, const component_list_index = ast: {
        var parser = zss.syntax.Parser.init(token_source, allocator);
        defer parser.deinit();
        break :ast try parser.parseListOfComponentValues(allocator);
    };
    defer ast.deinit(allocator);
    var children = component_list_index.children(ast);
    const ast_nodes = .{
        .apple_ident = children.nextSkipSpaces(ast).?,
        .banana = children.nextSkipSpaces(ast).?,
        .cucumber = children.nextSkipSpaces(ast).?,
        .durian = children.nextSkipSpaces(ast).?,
        .apple_string = children.nextSkipSpaces(ast).?,
        .cucumber_uppercase = children.nextSkipSpaces(ast).?,
    };

    {
        var interner = init(.{ .max_size = 3, .case = .insensitive });
        defer interner.deinit(allocator);
        const indeces = .{
            .apple_ident = try interner.addFromIdentToken(allocator, ast_nodes.apple_ident.location(ast), token_source),
            .banana = try interner.addFromIdentToken(allocator, ast_nodes.banana.location(ast), token_source),
            .cucumber = try interner.addFromIdentToken(allocator, ast_nodes.cucumber.location(ast), token_source),
            .durian = durian: {
                try std.testing.expectError(error.MaxSizeExceeded, interner.addFromIdentToken(allocator, ast_nodes.durian.location(ast), token_source));
                break :durian undefined;
            },
            .apple_string = try interner.addFromStringToken(allocator, ast_nodes.apple_string.location(ast), token_source),
            .banana_string = try interner.addFromString(allocator, "banana"),
            .cucumber_uppercase = try interner.addFromIdentToken(allocator, ast_nodes.cucumber_uppercase.location(ast), token_source),
        };
        try std.testing.expectEqual(@as(usize, 0), indeces.apple_ident);
        try std.testing.expectEqual(@as(usize, 1), indeces.banana);
        try std.testing.expectEqual(@as(usize, 2), indeces.cucumber);
        try std.testing.expectEqual(@as(usize, 0), indeces.apple_string);
        try std.testing.expectEqual(@as(usize, 1), indeces.banana_string);
        try std.testing.expectEqual(@as(usize, 2), indeces.cucumber_uppercase);
    }

    {
        var interner = init(.{ .max_size = 2, .case = .sensitive });
        defer interner.deinit(allocator);
        const indeces = .{
            .cucumber_lowercase = try interner.addFromIdentTokenKeepCase(allocator, ast_nodes.cucumber.location(ast), token_source),
            .cucumber_uppercase = try interner.addFromIdentTokenKeepCase(allocator, ast_nodes.cucumber_uppercase.location(ast), token_source),
        };
        try std.testing.expectEqual(@as(usize, 0), indeces.cucumber_lowercase);
        try std.testing.expectEqual(@as(usize, 1), indeces.cucumber_uppercase);
    }
}
