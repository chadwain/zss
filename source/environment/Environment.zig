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
                const end_of_prelude = extras[index].index();
                var selector_list = (try zss.selectors.parseSelectorList(env, source, slice, index + 1, end_of_prelude)) orelse continue;
                errdefer selector_list.deinit(env.allocator);

                var decls = try declsFromStyleBlock(env, slice, end_of_prelude);
                errdefer {
                    decls.normal.deinit(env.allocator);
                    decls.important.deinit(env.allocator);
                }

                stylesheet.rules.appendAssumeCapacity(.{
                    .selector = selector_list,
                    .normal_declarations = decls.normal,
                    .important_declarations = decls.important,
                });
            },
            else => unreachable,
        }
    }

    env.stylesheets.appendAssumeCapacity(stylesheet);
}

fn declsFromStyleBlock(env: *Environment, slice: ComponentTree.List.Slice, start_of_style_block: ComponentTree.Size) !struct {
    normal: Stylesheet.DeclarationList,
    important: Stylesheet.DeclarationList,
} {
    assert(slice.items(.tag)[start_of_style_block] == .style_block);

    var normal_declarations = ArrayListUnmanaged(Stylesheet.Declaration){};
    defer normal_declarations.deinit(env.allocator);
    var important_declarations = ArrayListUnmanaged(Stylesheet.Declaration){};
    defer important_declarations.deinit(env.allocator);

    var index = start_of_style_block + 1;
    const end_of_style_block = slice.items(.next_sibling)[start_of_style_block];

    while (index < end_of_style_block) {
        defer index = slice.items(.next_sibling)[index];
        if (slice.items(.tag)[index] != .declaration) continue;
        const appropriate_list = switch (slice.items(.extra)[index].important()) {
            true => &important_declarations,
            false => &normal_declarations,
        };
        try appropriate_list.append(env.allocator, .{ .component_index = index, .name = .unrecognized });
    }

    const normal_declarations_owned = try normal_declarations.toOwnedSlice(env.allocator);
    errdefer env.allocator.free(normal_declarations_owned);
    const important_declarations_owned = try important_declarations.toOwnedSlice(env.allocator);
    errdefer env.allocator.free(important_declarations_owned);

    return .{ .normal = .{ .list = normal_declarations_owned }, .important = .{ .list = important_declarations_owned } };
}

/// Assigns unique indeces to CSS identifiers.
const IdentifierSet = struct {
    /// Maps adapted keys to `Slice`. `Slice` represents a sub-range of `string_data`.
    map: AutoArrayHashMapUnmanaged(void, Slice) = .{},
    /// Stores identifiers as UTF-8 encoded strings.
    string_data: SegmentedList(u8, 0) = .{},
    /// The maximum number of identifiers this set can hold.
    max_size: usize,
    /// Choose how to compare identifiers.
    case: enum { sensitive, insensitive },

    const Slice = struct {
        begin: u32,
        len: u32,
    };

    fn deinit(set: *IdentifierSet, allocator: Allocator) void {
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
            var string_it = self.set.string_data.constIterator(slice.begin);
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

            var slice = Slice{ .begin = @intCast(u32, set.string_data.len), .len = 0 };
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

test "adding a stylesheet" {
    const allocator = std.testing.allocator;

    var env = Environment.init(allocator);
    defer env.deinit();

    const input = "test {}";
    const source = ParserSource.init(try zss.syntax.tokenize.Source.init(zss.util.ascii8ToAscii7(input)));
    try env.addStylesheet(source);
}
