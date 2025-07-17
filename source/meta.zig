const std = @import("std");

/// Let `From = @TypeOf(from)`.
/// `From` is coercible to an enum `To` if for every field of `From`, at least one of the following is true:
///     1. there is a field in `To` with the same name and value
///     2. `To` is non-exhaustive and does not have a field with the same name
///
/// `from` can be either an enum or tagged union.
pub fn coerceEnum(comptime To: type, from: anytype) To {
    comptime {
        const to_info = @typeInfo(To).@"enum";
        @setEvalBranchQuota(to_info.fields.len * 1000);
        const From = @TypeOf(from);
        const from_fields = switch (@typeInfo(From)) {
            .@"enum" => |@"enum"| @"enum".fields,
            .@"union" => |@"union"| @typeInfo(@"union".tag_type.?).@"enum".fields,
            else => unreachable,
        };
        for (from_fields) |field| {
            if (@hasField(To, field.name)) {
                const to_value = @intFromEnum(@field(To, field.name));
                if (field.value != to_value) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} has value {}, expected {}",
                        .{ @typeName(To), field.name, to_value, field.value },
                    ));
                }
            } else if (to_info.is_exhaustive) {
                @compileError(std.fmt.comptimePrint(
                    "{s} has no field named {s}",
                    .{ @typeName(To), field.name },
                ));
            } else {
                _ = std.math.cast(to_info.tag_type, field.value) orelse @compileError(std.fmt.comptimePrint(
                    "Value {} cannot cast into enum {s} with tag type {s}",
                    .{ field.value, @typeName(To), @typeName(to_info.tag_type) },
                ));
            }
        }
    }

    @setRuntimeSafety(false);
    return @enumFromInt(@intFromEnum(from));
}

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

/// Casts a union tag to a union value, asserting that the payload has type `void`.
pub fn unionTagToVoidPayload(comptime Union: type, tag: std.meta.Tag(Union)) Union {
    switch (tag) {
        inline else => |comptime_tag| {
            const Payload = @FieldType(Union, @tagName(comptime_tag));
            if (Payload != void) unreachable;
            return @unionInit(Union, @tagName(comptime_tag), {});
        },
    }
}
