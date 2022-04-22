pub const All = enum {
    initial,
    inherit,
    unset,
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

pub const Size = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const MinSize = union(enum) {
    px: f32,
    percentage: f32,
    initial,
    inherit,
    unset,
    undeclared,
};

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

pub const Padding = union(enum) {
    px: f32,
    percentage: f32,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Margin = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const Inset = union(enum) {
    px: f32,
    percentage: f32,
    auto,
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
        getNaturalSizeFn: fn (data: *Data) Dimensions,

        pub fn getNaturalSize(self: *Object) Dimensions {
            return self.getNaturalSizeFn(self.data);
        }
    };

    object: Object,
    none,
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundRepeat = union(enum) {
    pub const Style = enum { repeat, no_repeat, space, round };

    repeat: struct {
        x: Style = .repeat,
        y: Style = .repeat,
    },
    initial,
    inherit,
    unset,
    undeclared,
};

pub const BackgroundPosition = union(enum) {
    pub const Offset = union(enum) {
        px: f32,
        percentage: f32,
    };
    pub const SideX = enum { left, right };
    pub const SideY = enum { top, bottom };

    // TODO: This is not the full range of possible values.
    position: struct {
        x: struct {
            side: SideX,
            offset: Offset,
        },
        y: struct {
            side: SideY,
            offset: Offset,
        },
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
