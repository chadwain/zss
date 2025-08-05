const std = @import("std");

const zss = @import("../zss.zig");
const SourceLocation = zss.syntax.TokenSource.Location;

pub const CssWideKeyword = enum(u2) {
    initial = 1,
    inherit = 2,
    unset = 3,
};

pub const Text = []const u8;

pub const Display = enum {
    block,
    @"inline",
    inline_block,
    none,
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
//};

pub const Position = enum {
    static,
    relative,
    absolute,
    sticky,
    fixed,
};

pub const ZIndex = union(enum) {
    integer: i32,
    auto,
};

pub const Float = enum {
    left,
    right,
    none,
};

pub const Clear = enum {
    left,
    right,
    both,
    none,
};

pub const LengthPercentageAuto = union(enum) {
    px: f32,
    percentage: f32,
    auto,
};

pub const Size = LengthPercentageAuto;
pub const Margin = LengthPercentageAuto;
pub const Inset = LengthPercentageAuto;

pub const LengthPercentage = union(enum) {
    px: f32,
    percentage: f32,
};

pub const MinSize = LengthPercentage;
pub const Padding = LengthPercentage;

pub const MaxSize = union(enum) {
    px: f32,
    percentage: f32,
    none,
};

pub const BorderWidth = union(enum) {
    px: f32,
    thin,
    medium,
    thick,
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
};

pub const Color = union(enum) {
    rgba: u32,
    current_color,
    transparent,

    pub const black = Color{ .rgba = 0xff };
};

pub const BackgroundImage = union(enum) {
    image: zss.Environment.Images.Handle,
    url: zss.Environment.UrlId,
    none,
};

pub const BackgroundRepeat = struct {
    pub const Style = enum { repeat, no_repeat, space, round };

    x: Style = .repeat,
    y: Style = .repeat,
};

pub const BackgroundAttachment = enum {
    scroll,
    fixed,
    local,
};

pub const BackgroundPosition = struct {
    pub const Side = enum { start, end, center };
    pub const Offset = union(enum) {
        px: f32,
        percentage: f32,
    };

    // TODO: Make this a tagged union instead
    pub const SideOffset = struct {
        /// `.start` corresponds to left (x-axis) and top (y-axis)
        /// `.end` corresponds to right (x-axis) and bottom (y-axis)
        /// `.center` corresponds to center (either axis), and will cause `offset` to be ignored during layout
        side: Side,
        offset: Offset,
    };

    x: SideOffset,
    y: SideOffset,
};

pub const BackgroundClip = enum {
    border_box,
    padding_box,
    content_box,
};

pub const BackgroundOrigin = enum {
    border_box,
    padding_box,
    content_box,
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
};

pub const Font = enum {
    default,
    none,
};
