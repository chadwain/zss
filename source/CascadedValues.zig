const zss = @import("zss.zig");
const aggregates = zss.property.aggregates;
const AggregateTag = aggregates.Tag;
const AllAggregateValues = Declarations.AllAggregateValues;
const CssWideKeyword = zss.values.types.CssWideKeyword;
const Declarations = zss.property.Declarations;

const std = @import("std");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const CascadedValues = @This();

// TODO: Use a map better suited for arena allocation
map: Map = .{},
all: ?CssWideKeyword = null,

const Map = AutoArrayHashMapUnmanaged(AggregateTag, usize);

pub fn applyDeclBlock(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    decls: *const Declarations,
    block: Declarations.Block,
    important: zss.property.Important,
) !void {
    // TODO: The 'all' property does not affect some properties
    if (cascaded.all != null) return;

    const meta = decls.getMeta(block);
    if (meta.getAll(important)) |all| cascaded.all = all;

    var iterator = meta.tagIterator(important);
    while (iterator.next()) |aggregate_tag| {
        const gop_result = try cascaded.map.getOrPut(arena.allocator(), aggregate_tag);
        switch (aggregate_tag) {
            inline else => |comptime_tag| {
                try initValues(comptime_tag, arena, gop_result);
                const values = castValuePtr(comptime_tag, gop_result.value_ptr);
                decls.apply(comptime_tag, block, important, meta, values);
            },
        }
    }
}

pub fn get(cascaded: CascadedValues, comptime tag: AggregateTag) ?*const AllAggregateValues(tag) {
    const map_value_ptr = cascaded.map.getPtr(tag) orelse return null;
    return castValuePtr(tag, map_value_ptr);
}

fn initValues(comptime tag: AggregateTag, arena: *ArenaAllocator, gop_result: Map.GetOrPutResult) !void {
    if (gop_result.found_existing) return;
    const Values = AllAggregateValues(tag);
    if (canFitWithinUsize(Values)) {
        const values: *Values = @ptrCast(gop_result.value_ptr);
        values.* = .{};
    } else {
        const values = try arena.allocator().create(Values);
        values.* = .{};
        gop_result.value_ptr.* = @intFromPtr(values);
    }
}

fn castValuePtr(comptime tag: AggregateTag, map_value_ptr: *usize) *AllAggregateValues(tag) {
    const Values = AllAggregateValues(tag);
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
        fn testOne(cascaded: *CascadedValues, comptime tag: AggregateTag, arena: *ArenaAllocator, values: AllAggregateValues(tag)) !void {
            const gop_result = try cascaded.map.getOrPut(arena.allocator(), tag);
            try initValues(tag, arena, gop_result);
            const dest = castValuePtr(tag, gop_result.value_ptr);
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
