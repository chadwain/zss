pub fn mergeUnions(comptime A: type, comptime B: type) type {
    const std = @import("std");
    comptime const a = @typeInfo(A).Union;
    comptime const b = @typeInfo(B).Union;
    comptime const fields = a.fields ++ b.fields;
    comptime const Tag = blk: {
        var tag_fields: [fields.len]std.builtin.TypeInfo.EnumField = undefined;
        for (fields) |f, i| {
            tag_fields[i] = .{ .name = f.name, .value = i };
        }
        break :blk @Type(std.builtin.TypeInfo{
            .Enum = .{
                .layout = .Auto,
                .tag_type = std.math.IntFittingRange(0, fields.len - 1),
                .fields = &tag_fields,
                .decls = &[0]std.builtin.TypeInfo.Declaration{},
                .is_exhaustive = true,
            },
        });
    };
    return @Type(std.builtin.TypeInfo{
        .Union = .{
            .layout = .Auto,
            .tag_type = Tag,
            .fields = fields,
            .decls = &[0]std.builtin.TypeInfo.Declaration{},
        },
    });
}

pub const Initial = union(enum) {
    initial,
};

pub const Inherit = union(enum) {
    inherit,
};

pub const Unset = union(enum) {
    unset,
};

pub const None = union(enum) {
    none,
};

pub const Auto = union(enum) {
    auto,
};

pub const Percentage = union(enum) {
    percentage: f32,
};

pub const Length = union(enum) {
    px: f32,
};

pub const LengthPercentage = mergeUnions(Length, Percentage);

pub const LineWidth = mergeUnions(Length, union(enum) {
    thin,
    medium,
    thick,
});

pub const Display = union(enum) {
    block_flow,
    block_flow_root,
    inline_flow,
    text,
};

pub const Position = union(enum) {
    static,
    relative,
    absolute,
    sticky,
    // NOTE this field has a value because I need this union to have a non-zero size
    // because of https://github.com/ziglang/zig/issues/8277
    fixed: u1 = 0,
};