//! Assigns index numbers to strings.
//! Indeces start from 0 and increase by 1 for every unique string.

const StringInterner = @This();

const zss = @import("zss.zig");
const Location = TokenSource.Location;
const TokenSource = zss.syntax.TokenSource;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

indexer: std.AutoArrayHashMapUnmanaged(void, Range),
string: zss.SegmentedUtf8String,
options: Options,

const Range = struct {
    position: zss.SegmentedUtf8String.Size,
    len: zss.SegmentedUtf8String.Size,
};

pub const Options = struct {
    /// The maximum amount of unique strings that can be held.
    max_size: usize,
};

pub fn init(options: Options) StringInterner {
    return .{
        .indexer = .empty,
        .string = .init(1 << 10, 1 << 31),
        .options = .{
            .max_size = options.max_size - @intFromBool(options.max_size +% 1 == 0),
        },
    };
}

pub fn deinit(interner: *StringInterner, allocator: Allocator) void {
    interner.indexer.deinit(allocator);
    interner.string.deinit(allocator);
}

pub fn addFromIdentToken(
    interner: *StringInterner,
    allocator: Allocator,
    /// Must be the location of an <ident-token>.
    location: Location,
    token_source: TokenSource,
) !usize {
    return addFromGenericTokenIterator(interner, allocator, token_source, token_source.identTokenIterator(location));
}

pub fn addFromStringToken(
    interner: *StringInterner,
    allocator: Allocator,
    /// Must be the location of a <string-token>.
    location: Location,
    token_source: TokenSource,
) !usize {
    return addFromGenericTokenIterator(interner, allocator, token_source, token_source.stringTokenIterator(location));
}

fn addFromGenericTokenIterator(
    interner: *StringInterner,
    allocator: Allocator,
    token_source: TokenSource,
    token_iterator: anytype,
) !usize {
    const Key = struct {
        source: TokenSource,
        it: @TypeOf(token_iterator),
    };

    const Adapter = struct {
        interner: *const StringInterner,

        pub fn hash(_: @This(), key: Key) u32 {
            var hasher = std.hash.Wyhash.init(0);
            var it = key.it;
            var limit: usize = 32;
            while (it.next(key.source)) |codepoint| {
                if (limit == 0) break;
                std.hash.autoHash(&hasher, codepoint);
                limit -= 1;
            }
            return @truncate(hasher.final());
        }

        pub fn eql(adapter: @This(), key: Key, _: void, index: usize) bool {
            var key_it = key.it;
            const range = adapter.interner.indexer.values()[index];
            var string_it = adapter.interner.string.iterator(range.position, range.len);
            while (string_it.next()) |segment| {
                var string_index: usize = 0;
                while (string_index < segment.len) {
                    const key_codepoint = key_it.next(key.source) orelse return false;
                    const string_codepoint_len = std.unicode.utf8ByteSequenceLength(segment[string_index]) catch unreachable;
                    const string_codepoint = std.unicode.utf8Decode(segment[string_index..][0..string_codepoint_len]) catch unreachable;
                    if (key_codepoint != string_codepoint) return false;
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

    if (gop.index == interner.options.max_size) {
        interner.indexer.swapRemoveAt(gop.index);
        return error.MaxSizeExceeded;
    }

    var range = Range{ .position = interner.string.position, .len = 0 };
    var it = token_iterator;
    var buffer: [4]u8 = undefined;
    while (it.next(token_source)) |codepoint| {
        const len = std.unicode.utf8Encode(codepoint, &buffer) catch unreachable;
        try interner.string.append(allocator, buffer[0..len]);
        range.len += len;
    }
    gop.value_ptr.* = range;
    return gop.index;
}

test "StringInterner" {
    const allocator = std.testing.allocator;
    const token_source = try TokenSource.init("apple banana cucumber durian \"apple\"");
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
    };

    var interner = init(.{ .max_size = 3 });
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
    };
    try std.testing.expectEqual(@as(usize, 0), indeces.apple_ident);
    try std.testing.expectEqual(@as(usize, 1), indeces.banana);
    try std.testing.expectEqual(@as(usize, 2), indeces.cucumber);
    try std.testing.expectEqual(@as(usize, 0), indeces.apple_string);
}
