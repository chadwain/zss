const zss = @import("zss.zig");
const aggregates = zss.properties.aggregates;
const AggregateTag = aggregates.Tag;
const CssWideKeyword = zss.values.types.CssWideKeyword;

const std = @import("std");
const assert = std.debug.assert;
const ArenaAllocator = std.heap.ArenaAllocator;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const CascadedValues = @This();

// TODO: Use a map better suited for arena allocation
map: AutoArrayHashMapUnmanaged(AggregateTag, usize) = .{},
all: ?CssWideKeyword = null,

pub fn isEmpty(cascaded: CascadedValues) bool {
    return cascaded.map.count() == 0 and cascaded.all == null;
}

pub fn add(cascaded: *CascadedValues, arena: *ArenaAllocator, comptime tag: AggregateTag, value: tag.Value()) !void {
    if (cascaded.all != null) return;

    const gop_result = try cascaded.map.getOrPut(arena.allocator(), tag);
    errdefer cascaded.map.swapRemoveAt(gop_result.index);

    const Aggregate = tag.Value();
    if (gop_result.found_existing) {
        const aggregate_ptr = getAggregatePtr(tag, gop_result.value_ptr);
        inline for (std.meta.fields(Aggregate)) |field_info| {
            const aggregate_field_ptr = &@field(aggregate_ptr, field_info.name);
            if (aggregate_field_ptr.* == .undeclared) {
                aggregate_field_ptr.* = @field(value, field_info.name);
            }
        }
    } else {
        try initAggregate(arena, tag, gop_result.value_ptr, value);
    }
}

pub fn addValue(
    cascaded: *CascadedValues,
    arena: *ArenaAllocator,
    comptime tag: AggregateTag,
    comptime field: std.meta.FieldEnum(tag.Value()),
    value: std.meta.FieldType(tag.Value(), field),
) !void {
    if (cascaded.all != null) return;

    const gop_result = try cascaded.map.getOrPut(arena.allocator(), tag);
    errdefer cascaded.map.swapRemoveAt(gop_result.index);

    if (gop_result.found_existing) {
        const aggregate_ptr = getAggregatePtr(tag, gop_result.value_ptr);
        const aggregate_field_ptr = &@field(aggregate_ptr, @tagName(field));
        if (aggregate_field_ptr.* == .undeclared) {
            aggregate_field_ptr.* = value;
        }
    } else {
        var aggregate = tag.Value(){};
        @field(aggregate, @tagName(field)) = value;
        try initAggregate(arena, tag, gop_result.value_ptr, aggregate);
    }
}

pub fn addAll(cascaded: *CascadedValues, value: CssWideKeyword) void {
    if (cascaded.all != null) return;
    cascaded.all = value;
}

pub fn get(cascaded: CascadedValues, comptime tag: AggregateTag) ?tag.Value() {
    const map_value_ptr = cascaded.map.getPtr(tag) orelse return null;
    return getAggregatePtr(tag, map_value_ptr).*;
}

pub fn getByIndex(cascaded: CascadedValues, comptime tag: AggregateTag, index: usize) tag.Value() {
    assert(cascaded.map.keys()[index] == tag);
    return getAggregatePtr(tag, &cascaded.map.values()[index]).*;
}

fn initAggregate(arena: *ArenaAllocator, comptime tag: AggregateTag, map_value_ptr: *usize, initial_value: tag.Value()) !void {
    const Aggregate = tag.Value();
    if (!canFitWithinUsize(Aggregate)) {
        const aggregate_ptr = try arena.allocator().create(Aggregate);
        map_value_ptr.* = @intFromPtr(aggregate_ptr);
    }
    const aggregate_ptr = getAggregatePtr(tag, map_value_ptr);
    aggregate_ptr.* = initial_value;
}

fn getAggregatePtr(comptime tag: AggregateTag, map_value_ptr: *usize) *tag.Value() {
    const Aggregate = tag.Value();
    if (canFitWithinUsize(Aggregate)) {
        return @ptrCast(map_value_ptr);
    } else {
        return @ptrFromInt(map_value_ptr.*);
    }
}

fn canFitWithinUsize(comptime T: type) bool {
    return (@alignOf(T) <= @alignOf(usize) and @sizeOf(T) <= @sizeOf(usize));
}

test {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var cascaded = CascadedValues{};
    try cascaded.add(&arena, .box_style, .{ .display = .none });
    try cascaded.add(&arena, .box_style, .{ .display = .initial });
    try cascaded.add(&arena, .horizontal_edges, .{});
    try cascaded.add(&arena, .horizontal_edges, .{ .margin_left = .auto });
    cascaded.addAll(.initial);
    try cascaded.add(&arena, .z_index, .{ .z_index = .auto });

    const box_style = cascaded.get(.box_style) orelse return error.TestFailure;
    const horizontal_edges = cascaded.get(.horizontal_edges) orelse return error.TestFailure;
    const all = cascaded.all orelse return error.TestFailure;

    try expectEqual(CssWideKeyword.initial, all);
    try expectEqual(@as(?aggregates.ZIndex, null), cascaded.get(.z_index));
    try expect(std.meta.eql(box_style, .{ .display = .none }));
    try expect(std.meta.eql(horizontal_edges, .{ .margin_left = .auto }));
}
