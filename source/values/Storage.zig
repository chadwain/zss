const Storage = @This();

const zss = @import("../zss.zig");
const types = zss.values.types;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const supported_types = [_]type{
    types.BackgroundImage,
    types.BackgroundRepeat,
    types.BackgroundAttachment,
    types.BackgroundPosition,
    types.BackgroundClip,
    types.BackgroundOrigin,
    types.BackgroundSize,
};

fn typeToFieldName(comptime T: type) [:0]const u8 {
    return switch (T) {
        types.BackgroundImage => "background_image",
        types.BackgroundRepeat => "background_repeat",
        types.BackgroundAttachment => "background_attachment",
        types.BackgroundPosition => "background_position",
        types.BackgroundClip => "background_clip",
        types.BackgroundOrigin => "background_origin",
        types.BackgroundSize => "background_size",
        else => @compileError("unsupported type '" ++ @typeName(T) ++ "'"),
    };
}

const Lists = blk: {
    var fields: [supported_types.len]std.builtin.Type.StructField = undefined;
    for (supported_types, &fields) |T, *out| {
        const List = ArrayListUnmanaged([]T);
        out.* = .{
            .name = typeToFieldName(T),
            .type = List,
            .default_value_ptr = &List{},
            .is_comptime = false,
            .alignment = @alignOf(List),
        };
    }
    break :blk @Type(std.builtin.Type{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
};

pub const Handle = enum(u32) { _ };

allocator: Allocator,
lists: Lists = .{},

pub fn deinit(storage: *Storage) void {
    inline for (std.meta.fields(Lists)) |field_info| {
        const list = &@field(storage.lists, field_info.name);
        for (list.items) |item| {
            storage.allocator.free(item);
        }
        list.deinit(storage.allocator);
    }
}

pub fn alloc(storage: *Storage, comptime T: type, amount: u8) !struct { Handle, []T } {
    std.debug.assert(amount > 0);
    const list = &@field(storage.lists, typeToFieldName(T));
    try list.ensureUnusedCapacity(storage.allocator, 1);
    const memory = try storage.allocator.alloc(T, amount);
    const handle: Handle = @enumFromInt(list.items.len);
    list.appendAssumeCapacity(memory);
    return .{ handle, memory };
}

pub fn get(storage: Storage, comptime T: type, handle: Handle) []const T {
    const list = &@field(storage.lists, typeToFieldName(T));
    return list.items[@intFromEnum(handle)];
}
