const Environment = @This();

const zss = @import("../../zss.zig");
const syntax = zss.syntax;
const ComponentTree = syntax.ComponentTree;
const ParserSource = syntax.parse.Source;
const BoundedArrayHashMap = zss.util.BoundedArrayHashMap;

const namespace = @import("./namespace.zig");
pub const NamespaceId = namespace.NamespaceId;

pub const Stylesheet = @import("./Stylesheet.zig");

const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

allocator: Allocator,
stylesheets: ArrayListUnmanaged(Stylesheet) = .{},
type_names: IdentifierMap(void, std.math.maxInt(NameId.Value)) = .{},
default_namespace: ?NamespaceId = null,

pub fn init(allocator: Allocator) Environment {
    return Environment{ .allocator = allocator };
}

pub fn deinit(env: *Environment) void {
    env.type_names.deinit(env.allocator);
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

pub const NameId = struct {
    value: Value,

    pub const Value = u24;
    pub const any = NameId{ .value = std.math.maxInt(Value) };
};

pub fn addTypeName(env: *Environment, identifier: ParserSource.Location, source: ParserSource) !NameId {
    const result = try env.type_names.getOrPutContext(env.allocator, identifier, .{ .source = source });
    return NameId{ .value = result.index };
}

/// A map whose key is a CSS identifier.
fn IdentifierMap(comptime Value: type, comptime upper_bound: comptime_int) type {
    return BoundedArrayHashMap(ParserSource.Location, Value, IdentifierMapContext, true, upper_bound);
}

const IdentifierMapContext = struct {
    source: ParserSource,

    pub fn hash(self: IdentifierMapContext, location: ParserSource.Location) u32 {
        var hasher = std.hash.Wyhash.init(0);
        var it = self.source.identTokenIterator(location);
        while (it.next(self.source)) |codepoint| {
            const lowercase = zss.util.unicode.toLowercase(codepoint);
            const bytes = std.mem.asBytes(&lowercase)[0..3];
            hasher.update(bytes);
        }
        return @truncate(u32, hasher.final());
    }

    pub fn eql(self: IdentifierMapContext, a: ParserSource.Location, b: ParserSource.Location, _: usize) bool {
        return self.source.identTokensEqlIgnoreCase(a, b);
    }
};
