const std = @import("std");

/// Returns a struct with a field corresponding to each named enum value.
/// The type and default value of each field is determined by `map`.
///
/// note: You can think of this as a generalized version of `std.enums.EnumFieldStruct`.
pub fn EnumFieldMapStruct(
    comptime Enum: type,
    /// Inputs a named enum value and outputs a type and a pointer to a default value.
    comptime fieldMap: fn (comptime Enum) struct { type, ?*const anyopaque },
) type {
    const fields = @typeInfo(Enum).@"enum".fields;
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, &struct_fields) |in, *out| {
        const field_type, const default_value_ptr = fieldMap(@enumFromInt(in.value));
        out.* = .{
            .name = in.name,
            .type = field_type,
            .default_value_ptr = default_value_ptr,
            .is_comptime = false,
            .alignment = @alignOf(field_type),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}
