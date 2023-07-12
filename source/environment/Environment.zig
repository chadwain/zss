const Environment = @This();

const zss = @import("../../zss.zig");
const syntax = zss.syntax;
const ComponentTree = syntax.ComponentTree;
const ParserSource = syntax.parse.Source;

const namespace = @import("./namespace.zig");
pub const NamespaceId = namespace.NamespaceId;

pub const Stylesheet = @import("./Stylesheet.zig");

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;
const SegmentedList = std.SegmentedList;

allocator: Allocator,
stylesheets: ArrayListUnmanaged(Stylesheet) = .{},
type_or_attribute_names: IdentifierSet = .{},
default_namespace: ?NamespaceId = null,

pub fn init(allocator: Allocator) Environment {
    return Environment{ .allocator = allocator };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    for (env.stylesheets.items) |*stylesheet| stylesheet.deinit(env.allocator);
    env.stylesheets.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: ParserSource) !void {
    var tree = try syntax.parse.parseStylesheet(source, env.allocator);
    defer tree.deinit(env.allocator);

    const slice = tree.components.slice();
    const tags = slice.items(.tag);
    const next_siblings = slice.items(.next_sibling);
    const extras = slice.items(.extra);

    try env.stylesheets.ensureUnusedCapacity(env.allocator, 1);
    var stylesheet = Stylesheet{};
    errdefer stylesheet.deinit(env.allocator);

    assert(tags[0] == .rule_list);
    var next_index: ComponentTree.Size = 1;
    const end_of_stylesheet = next_siblings[0];
    while (next_index < end_of_stylesheet) {
        const index = next_index;
        next_index = next_siblings[next_index];
        switch (tags[index]) {
            .at_rule => panic("TODO: At-rules in a stylesheet\n", .{}),
            .qualified_rule => {
                try stylesheet.rules.ensureUnusedCapacity(env.allocator, 1);
                const end_of_prelude = extras[index].size();
                const selector_list = (try zss.selectors.parseSelectorList(env, source, slice, index + 1, end_of_prelude)) orelse continue;
                stylesheet.rules.appendAssumeCapacity(.{ .selector = selector_list });
            },
            else => unreachable,
        }
    }

    env.stylesheets.appendAssumeCapacity(stylesheet);
}

/// Assigns unique indeces to CSS identifiers (<ident-token>'s).
/// Identifiers are compared case-insensitively.
const IdentifierSet = struct {
    map: AutoArrayHashMapUnmanaged(void, Slice) = .{},
    data: SegmentedList(u8, 0) = .{},

    const Slice = struct {
        begin: u32,
        len: u32,
    };

    const Index = u24;

    fn deinit(set: *IdentifierSet, allocator: Allocator) void {
        set.map.deinit(allocator);
        set.data.deinit(allocator);
    }

    const toLowercase = zss.util.unicode.toLowercase;

    const Hasher = struct {
        inner: std.hash.Wyhash = std.hash.Wyhash.init(0),

        fn update(hasher: *Hasher, codepoint: u21) void {
            const lowercase = toLowercase(codepoint);
            const bytes = std.mem.asBytes(&lowercase)[0..3];
            hasher.inner.update(bytes);
        }

        fn final(hasher: *Hasher) u32 {
            return @truncate(u32, hasher.inner.final());
        }
    };

    // Unfortunately, Zig's hash maps don't allow the use of generic hash and eql functions,
    // so this adapter can't be used directly.
    const AdapterGeneric = struct {
        set: *const IdentifierSet,

        pub fn hash(_: @This(), key: anytype) u32 {
            var hasher = Hasher{};
            var it = key.iterator();
            while (it.next()) |codepoint| {
                hasher.update(toLowercase(codepoint));
            }
            return hasher.final();
        }

        pub fn eql(self: @This(), key: anytype, _: void, index: usize) bool {
            var key_it = key.iterator();

            var slice = self.set.map.values()[index];
            var string_it = self.set.data.constIterator(slice.begin);
            var buffer: [4]u8 = undefined;
            while (slice.len > 0) {
                const key_codepoint = key_it.next() orelse return false;

                buffer[0] = string_it.next().?.*;
                const len = std.unicode.utf8ByteSequenceLength(buffer[0]) catch unreachable;
                slice.len -= len;
                for (1..len) |i| buffer[i] = string_it.next().?.*;
                const string_codepoint = std.unicode.utf8Decode(buffer[0..len]) catch unreachable;

                if (toLowercase(key_codepoint) != string_codepoint) return false;
            }
            return key_it.next() == null;
        }
    };

    fn getOrPutGeneric(set: *IdentifierSet, allocator: Allocator, key: anytype) !Index {
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

        const index = std.math.cast(Index, result.index) orelse return error.Overflow;
        if (!result.found_existing) {
            var slice = Slice{ .begin = @intCast(u32, set.data.len), .len = 0 };
            var it = key.iterator();
            var buffer: [4]u8 = undefined;
            while (it.next()) |codepoint| {
                const len = std.unicode.utf8Encode(toLowercase(codepoint), &buffer) catch unreachable;
                slice.len += len;
                _ = try std.math.add(u32, slice.begin, slice.len);
                try set.data.appendSlice(allocator, buffer[0..len]);
            }
            result.value_ptr.* = slice;
        }

        return index;
    }

    fn getOrPutFromParserSource(set: *IdentifierSet, allocator: Allocator, source: ParserSource, location: ParserSource.Location) !Index {
        const Key = struct {
            source: ParserSource,
            location: ParserSource.Location,

            fn iterator(self: @This()) Iterator {
                return Iterator{ .source = self.source, .it = self.source.identTokenIterator(self.location) };
            }

            const Iterator = struct {
                source: ParserSource,
                it: syntax.parse.IdentTokenIterator,

                fn next(self: *@This()) ?u21 {
                    return self.it.next(self.source);
                }
            };
        };

        const key = Key{ .source = source, .location = location };
        return set.getOrPutGeneric(allocator, key);
    }
};

pub const NameId = struct {
    value: Value,

    pub const Value = IdentifierSet.Index;
    pub const any = NameId{ .value = std.math.maxInt(Value) };
};

pub fn addTypeOrAttributeName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !NameId {
    const index = try env.type_or_attribute_names.getOrPutFromParserSource(env.allocator, source, identifier);
    return NameId{ .value = index };
}
