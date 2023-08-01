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
type_or_attribute_names: IdentifierSet = .{ .max_size = NameId.max_value, .case = .insensitive },
// TODO: Case sensitivity depends on whether quirks mode is on
id_or_class_names: IdentifierSet = .{ .max_size = IdId.max_value, .case = .sensitive },
default_namespace: ?NamespaceId = null,

pub fn init(allocator: Allocator) Environment {
    return Environment{ .allocator = allocator };
}

pub fn deinit(env: *Environment) void {
    env.type_or_attribute_names.deinit(env.allocator);
    env.id_or_class_names.deinit(env.allocator);
    for (env.stylesheets.items) |*stylesheet| stylesheet.deinit(env.allocator);
    env.stylesheets.deinit(env.allocator);
}

pub fn addStylesheet(env: *Environment, source: ParserSource) !void {
    var tree = try syntax.parse.parseCssStylesheet(source, env.allocator);
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
    max_size: usize,
    case: enum { sensitive, insensitive },

    const Slice = struct {
        begin: u32,
        len: u32,
    };

    fn deinit(set: *IdentifierSet, allocator: Allocator) void {
        set.map.deinit(allocator);
        set.data.deinit(allocator);
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

        pub fn hash(self: @This(), key: anytype) u32 {
            var hasher = std.hash.Wyhash.init(0);
            var it = key.iterator();
            while (it.next()) |codepoint| {
                const adjusted = self.set.adjustCase(codepoint);
                const bytes = std.mem.asBytes(&adjusted)[0..3];
                hasher.update(bytes);
            }
            return @truncate(u32, hasher.final());
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

                if (self.set.adjustCase(key_codepoint) != string_codepoint) return false;
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

            var slice = Slice{ .begin = @intCast(u32, set.data.len), .len = 0 };
            var it = key.iterator();
            var buffer: [4]u8 = undefined;
            while (it.next()) |codepoint| {
                const len = std.unicode.utf8Encode(set.adjustCase(codepoint), &buffer) catch unreachable;
                slice.len += len;
                _ = try std.math.add(u32, slice.begin, slice.len);
                try set.data.appendSlice(allocator, buffer[0..len]);
            }
            result.value_ptr.* = slice;
        }

        return result.index;
    }

    fn getOrPutFromParserSource(
        set: *IdentifierSet,
        allocator: Allocator,
        source: ParserSource,
        ident_seq_it: syntax.parse.IdentSequenceIterator,
    ) !usize {
        const Key = struct {
            source: ParserSource,
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
};

pub const NameId = enum(u24) {
    pub const Value = u24;
    const max_value = std.math.maxInt(Value) - 1;

    unspecified = max_value,
    any = max_value + 1,
    _,
};

pub fn addTypeOrAttributeName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !NameId {
    const index = try env.type_or_attribute_names.getOrPutFromParserSource(env.allocator, source, source.identTokenIterator(identifier));
    return @intToEnum(NameId, @intCast(NameId.Value, index));
}

pub const IdId = enum(u32) {
    pub const Value = u32;
    const max_value = std.math.maxInt(Value);

    _,
};

pub const ClassId = enum(u32) {
    pub const Value = u32;
    const max_value = std.math.maxInt(Value);

    _,
};

comptime {
    assert(IdId.max_value == ClassId.max_value);
}

pub fn addIdName(env: *Environment, hash_id: ParserSource.Location, source: ParserSource) !IdId {
    const index = try env.id_or_class_names.getOrPutFromParserSource(env.allocator, source, source.hashIdTokenIterator(hash_id));
    return @intToEnum(IdId, @intCast(IdId.Value, index));
}

pub fn addClassName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !ClassId {
    const index = try env.id_or_class_names.getOrPutFromParserSource(env.allocator, source, source.identTokenIterator(identifier));
    return @intToEnum(ClassId, @intCast(ClassId.Value, index));
}
