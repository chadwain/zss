const zss = @import("zss.zig");
const groups = zss.values.groups;
const CssWideKeyword = zss.values.types.CssWideKeyword;
const Declarations = zss.Declarations;
const Importance = Declarations.Importance;

const std = @import("std");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const CascadedValues = @This();

// TODO: Use a map better suited for arena allocation
map: Map = .{},
all: ?CssWideKeyword = null,

const Map = AutoArrayHashMapUnmanaged(groups.Tag, usize);

pub fn applyDeclBlock(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    decls: *const Declarations,
    block: Declarations.Block,
    importance: Importance,
) !void {
    // TODO: The 'all' property does not affect some properties
    if (cascaded.all != null) return;

    const meta = decls.getMeta(block);
    if (meta.getAll(importance)) |all| cascaded.all = all;

    var iterator = meta.tagIterator(importance);
    while (iterator.next()) |group| {
        const gop_result = try cascaded.map.getOrPut(arena.allocator(), group);
        switch (group) {
            inline else => |comptime_group| {
                try initValues(comptime_group, arena, gop_result);
                const values = castValuePtr(comptime_group, gop_result.value_ptr);
                decls.apply(comptime_group, block, importance, meta, values);
            },
        }
    }
}

pub fn getPtr(cascaded: CascadedValues, comptime group: groups.Tag) ?*const group.CascadedValues() {
    const map_value_ptr = cascaded.map.getPtr(group) orelse return null;
    return castValuePtr(group, map_value_ptr);
}

fn initValues(comptime group: groups.Tag, arena: *ArenaAllocator, gop_result: Map.GetOrPutResult) !void {
    if (gop_result.found_existing) return;
    const Values = group.CascadedValues();
    if (canFitWithinUsize(Values)) {
        const values: *Values = @ptrCast(gop_result.value_ptr);
        values.* = .{};
    } else {
        const values = try arena.allocator().create(Values);
        values.* = .{};
        gop_result.value_ptr.* = @intFromPtr(values);
    }
}

fn castValuePtr(comptime group: groups.Tag, map_value_ptr: *usize) *group.CascadedValues() {
    const Values = group.CascadedValues();
    if (canFitWithinUsize(Values)) {
        return @ptrCast(map_value_ptr);
    } else {
        return @ptrFromInt(map_value_ptr.*);
    }
}

fn canFitWithinUsize(comptime T: type) bool {
    return (@alignOf(T) <= @alignOf(usize) and @sizeOf(T) <= @sizeOf(usize));
}

test {
    const ns = struct {
        fn testOne(cascaded: *CascadedValues, comptime group: groups.Tag, arena: *ArenaAllocator, values: group.CascadedValues()) !void {
            const gop_result = try cascaded.map.getOrPut(arena.allocator(), group);
            try initValues(group, arena, gop_result);
            const dest = castValuePtr(group, gop_result.value_ptr);
            dest.* = values;
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cascaded = CascadedValues{};
    try ns.testOne(&cascaded, .box_style, &arena, .{ .display = .{ .declared = .none } });
    try ns.testOne(&cascaded, .horizontal_edges, &arena, .{ .margin_left = .{ .declared = .auto } });
    try ns.testOne(&cascaded, .z_index, &arena, .{ .z_index = .{ .declared = .auto } });
}
