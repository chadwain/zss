const std = @import("std");

const zss = @import("../../zss.zig");
const Utf8String = zss.util.Utf8String;

pub const CssWideKeyword = enum {
    initial,
    inherit,
    unset,

    pub fn apply(cwk: CssWideKeyword, ptrs: anytype) void {
        switch (cwk) {
            inline else => |cwk_comptime| {
                const cwk_as_enum_literal = cwk_comptime.toEnumLiteral();
                inline for (ptrs) |ptr| {
                    ptr.* = cwk_as_enum_literal;
                }
            },
        }
    }

    fn toEnumLiteral(comptime cwk: CssWideKeyword) @Type(.EnumLiteral) {
        return switch (cwk) {
            .initial => .initial,
            .inherit => .inherit,
            .unset => .unset,
        };
    }
};

pub const Text = []const u8;

pub const Display = enum {
    block,
    inline_,
    inline_block,
    text,
    none,
    initial,
    inherit,
    unset,
    undeclared,
};

//pub const Display = enum {
//    // display-outside, display-inside
//    block,
//    inline_,
//    run_in,
//    flow,
//    flow_root,
//    table,
//    flex,
//    grid,
//    ruby,
//    block_flow,
//    block_flow_root,
//    block_table,
//    block_flex,
//    block_grid,
//    block_ruby,
//    inline_flow,
//    inline_flow_root,
//    inline_table,
//    inline_flex,
//    inline_grid,
//    inline_ruby,
//    run_in_flow,
//    run_in_flow_root,
//    run_in_table,
//    run_in_flex,
//    run_in_grid,
//    run_in_ruby,
//    // display-listitem
//    list_item,
//    block_list_item,
//    inline_list_item,
//    run_in_list_item,
//    flow_list_item,
//    flow_root_list_item,
//    block_flow_list_item,
//    block_flow_root_list_item,
//    inline_flow_list_item,
//    inline_flow_root_list_item,
//    run_in_flow_list_item,
//    run_in_flow_root_list_item,
//    // display-internal
//    table_row_group,
//    table_header_group,
//    table_footer_group,
//    table_row,
//    table_cell,
//    table_column_group,
//    table_column,
//    table_caption,
//    ruby_base,
//    ruby_text,
//    ruby_base_container,
//    ruby_text_container,
//    // display-box
//    contents,
//    none,
//    // display-legacy
//    legacy_inline_block,
//    legacy_inline_table,
//    legacy_inline_flex,
//    legacy_inline_grid,
//    // css-wide
//    initial,
//    inherit,
//    unset,
//};

pub const Position = enum {
    static,
    relative,
    absolute,
    sticky,
    fixed,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const ZIndex = union(enum) {
    integer: i32,
    auto,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Float = enum {
    left,
    right,
    none,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Clear = enum {
    left,
    right,
    both,
    none,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const LengthPercentageAuto = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Size = LengthPercentageAuto;
pub const Margin = LengthPercentageAuto;
pub const Inset = LengthPercentageAuto;

pub const LengthPercentage = union(enum) {
    px: f32,
    percentage: f32,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const MinSize = LengthPercentage;
pub const Padding = LengthPercentage;

pub const MaxSize = union(enum) {
    px: f32,
    percentage: f32,
    none,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BorderWidth = union(enum) {
    px: f32,
    thin,
    medium,
    thick,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BorderStyle = enum {
    none,
    hidden,
    dotted,
    dashed,
    solid,
    double,
    groove,
    ridge,
    inset,
    outset,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Color = union(enum) {
    rgba: u32,
    current_color,
    initial,
    inherit,
    unset,
    undeclared,

    pub const transparent = Color{ .rgba = 0 };
    pub const black = Color{ .rgba = 0xff };
};

pub const BackgroundImage = union(enum) {
    pub const Object = struct {
        pub const Data = opaque {};
        pub const Dimensions = struct {
            width: f32,
            height: f32,
        };

        data: *Data,
        // TODO: This should be able to return an error
        getNaturalSizeFn: *const fn (data: *Data) Dimensions,

        pub fn getNaturalSize(self: *Object) Dimensions {
            return self.getNaturalSizeFn(self.data);
        }
    };

    object: Object,
    url: Utf8String,
    none,
    initial,
    inherit,
    unset,
    undeclared,

    pub fn expectEqualBackgroundImages(lhs: BackgroundImage, rhs: BackgroundImage) !void {
        const expectEqual = std.testing.expectEqual;
        const expectEqualSlices = std.testing.expectEqualSlices;

        const Tag = std.meta.Tag(BackgroundImage);
        try expectEqual(@as(Tag, lhs), @as(Tag, rhs));
        switch (lhs) {
            .object => try expectEqual(lhs.object, rhs.object),
            .url => try expectEqualSlices(u8, lhs.url.data, rhs.url.data),
            .none,
            .initial,
            .inherit,
            .unset,
            .undeclared,
            => {},
        }
    }
};

pub const BackgroundRepeat = union(enum) {
    pub const Style = enum { repeat, no_repeat, space, round };

    pub const Repeat = struct {
        x: Style = .repeat,
        y: Style = .repeat,
    };

    repeat: Repeat,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundAttachment = union(enum) {
    scroll,
    fixed,
    local,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundPosition = union(enum) {
    pub const Side = enum { start, end, center };
    pub const Offset = union(enum) {
        px: f32,
        percentage: f32,
    };

    pub const SideOffset = struct {
        /// `.start` corresponds to left (x-axis) and top (y-axis)
        /// `.end` corresponds to right (x-axis) and bottom (y-axis)
        /// `.center` corresponds to center (either axis), and will cause `offset` to be ignored during layout
        side: Side,
        offset: Offset,
    };

    position: struct {
        x: SideOffset,
        y: SideOffset,
    },
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundClip = enum {
    border_box,
    padding_box,
    content_box,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundOrigin = enum {
    border_box,
    padding_box,
    content_box,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundSize = union(enum) {
    pub const SizeType = union(enum) {
        px: f32,
        percentage: f32,
        auto,
    };

    size: struct {
        width: SizeType,
        height: SizeType,
    },
    contain,
    cover,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Font = union(enum) {
    const hb = @import("harfbuzz");

    font: *hb.hb_font_t,
    zss_default,
    initial,
    inherit,
    unset,
    undeclared,
};
