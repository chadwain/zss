const std = @import("std");

/// An enum `Base` is coercible to an enum `Derived` if: for every field of `Base`, there is a field in `Derived` with the same name and value.
pub fn coerceEnum(comptime Derived: type, from: anytype) Derived {
    comptime {
        @setEvalBranchQuota(@typeInfo(Derived).@"enum".fields.len * 1000);
        const Base = @TypeOf(from);
        const base_fields = switch (@typeInfo(Base)) {
            .@"enum" => |@"enum"| @"enum".fields,
            .@"union" => |@"union"| @typeInfo(@"union".tag_type.?).@"enum".fields,
            else => unreachable,
        };
        for (base_fields) |field_info| {
            const derived_field = std.enums.nameCast(Derived, field_info.name);
            const derived_value = @intFromEnum(derived_field);
            if (field_info.value != derived_value)
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} has value {}, expected {}",
                    .{ @typeName(Derived), field_info.name, derived_value, field_info.value },
                ));
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
