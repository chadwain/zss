const CascadedDeclarations = @This();

const zss = @import("../../zss.zig");
const values = zss.values;
const AggregateTag = zss.properties.aggregates.Tag;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListAlignedUnmanaged = std.ArrayListAlignedUnmanaged;
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

indeces: AutoArrayHashMapUnmanaged(AggregateTag, usize) = .{},
aggregates: AnytypeArrayList(1) = .{},
all: values.All = .undeclared,

pub fn deinit(cascaded: *CascadedDeclarations, allocator: Allocator) void {
    cascaded.indeces.deinit(allocator);
    cascaded.aggregates.deinit(allocator);
}

pub fn size(cascaded: CascadedDeclarations) usize {
    return cascaded.indeces.count();
}

pub fn get(cascaded: CascadedDeclarations, comptime tag: AggregateTag) ?tag.Value() {
    const index = cascaded.indeces.get(tag) orelse return null;
    return cascaded.aggregates.getPtr(tag.Value(), index).*;
}

pub fn setAggregate(cascaded: *CascadedDeclarations, allocator: Allocator, comptime tag: AggregateTag, aggregate: tag.Value()) !void {
    const Aggregate = tag.Value();
    const gop_result = try cascaded.indeces.getOrPut(allocator, tag);
    if (!gop_result.found_existing) {
        gop_result.value_ptr.* = try cascaded.aggregates.appendUninitialized(allocator, Aggregate);
    }

    const dest = cascaded.aggregates.getPtr(tag.Value(), gop_result.value_ptr.*);
    if (!gop_result.found_existing) {
        dest.* = aggregate;
        return;
    }

    inline for (std.meta.fields(Aggregate)) |field_info| {
        const dest_field_ptr = &@field(dest, field_info.name);
        if (dest_field_ptr.* == .undeclared) {
            dest_field_ptr.* = @field(aggregate, field_info.name);
        }
    }
}

fn AnytypeArrayList(comptime maximum_alignment: comptime_int) type {
    comptime assert(std.mem.isValidAlign(maximum_alignment));
    return struct {
        list: ArrayListAlignedUnmanaged(u8, maximum_alignment) = .{},

        const Self = @This();
        const Error = Allocator.Error || error{Overflow};

        fn deinit(list: *Self, allocator: Allocator) void {
            list.list.deinit(allocator);
        }

        fn len(list: Self) usize {
            return list.list.items.len;
        }

        fn shrink(list: *Self, new_len: usize) void {
            list.list.shrinkRetainingCapacity(new_len);
        }

        fn getPtr(list: Self, comptime T: type, index: usize) *T {
            const slice = list.list.items[index..][0..@sizeOf(T)];
            return @ptrCast(@alignCast(slice.ptr));
        }

        fn append(list: *Self, allocator: Allocator, comptime T: type, value: T) !usize {
            const index = try list.appendUninitialized(allocator, T);
            const dest = list.getPtr(T, index);
            dest.* = value;
            return index;
        }

        fn appendUninitialized(list: *Self, allocator: Allocator, comptime T: type) !usize {
            const alignment = @alignOf(T);
            const new_size = try list.calculateNewSize(T, alignment);
            try list.list.resize(allocator, new_size);
            return new_size - @sizeOf(T);
        }

        fn calculateNewSize(list: *Self, comptime T: type, comptime alignment: comptime_int) !usize {
            if (alignment > maximum_alignment) {
                @compileError(std.fmt.comptimePrint(
                    "{} is greater than the maximum allowable alignment of {}",
                    .{ alignment, maximum_alignment },
                ));
            }

            var checked_int = zss.util.CheckedInt(usize).init(list.len());
            checked_int.alignForward(alignment);
            checked_int.add(@sizeOf(T));
            return checked_int.unwrap();
        }
    };
}

pub const debug = struct {
    pub fn print(cascaded: CascadedDeclarations, writer: anytype) !void {
        try writer.print("(aggregates: num: {}, bytes: {})\n", .{ cascaded.indeces.count(), cascaded.aggregates.len() });

        for (cascaded.indeces.keys(), cascaded.indeces.values()) |aggregate_type, index| {
            switch (aggregate_type) {
                .direction, .unicode_bidi, .custom => @panic("TODO"),
                inline else => |aggregate_type_comptime| {
                    const ptr = cascaded.aggregates.getPtr(aggregate_type_comptime.Value(), index);
                    try writer.print("{s}: {}\n", .{ @tagName(aggregate_type), ptr.* });
                },
            }
        }

        try writer.print("all: {s}\n", .{@tagName(cascaded.all)});
    }
};
