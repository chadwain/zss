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
    //inline_flow,
    text,
};

pub const Position = union(enum) {
    static,
    relative,
};

pub const Color = union(enum) {
    rgba: u32,
};

pub const Box = union(enum) {
    border_box,
    padding_box,
    content_box,
};

pub const BackgroundImage = union(enum) {
    pub const Data = opaque {};
    data: *Data,
};

pub const BackgroundSize = union(enum) {
    pub const SizeType = mergeUnions(Auto, LengthPercentage);

    size: struct {
        width: SizeType,
        height: SizeType,
    },
    contain,
    cover,
};

pub const BackgroundPosition = union(enum) {
    position: struct {
        horizontal: struct {
            side: enum { left, right },
            offset: LengthPercentage,
        },
        vertical: struct {
            side: enum { top, bottom },
            offset: LengthPercentage,
        },
    },
};

pub const RepeatStyle = union(enum) {
    pub const RepeatStyleEnum = enum { repeat, space, round, no_repeat };

    repeat: struct {
        horizontal: RepeatStyleEnum,
        vertical: RepeatStyleEnum,
    },
};
