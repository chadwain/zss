pub const PropertyEnum = enum {
    all,

    display,
    position,
    float,
    z_index,

    width,
    min_width,
    max_width,
    padding_left,
    padding_right,
    border_left,
    border_right,
    margin_left,
    margin_right,

    height,
    min_height,
    max_height,
    padding_top,
    padding_bottom,
    border_top,
    border_bottom,
    margin_top,
    margin_bottom,

    top,
    right,
    bottom,
    left,

    // Not yet implemented.
    direction,
    unicode_bidi,
    custom, // Custom property
};

pub fn Value(comptime property: PropertyEnum) type {
    return switch (property) {
        .all => All,
        .display => Display,
        .position => Position,
        .float => Float,
        .z_index => ZIndex,

        .width => Size,
        .min_width => MinSize,
        .max_width => MaxSize,
        .padding_left => Padding,
        .padding_right => Padding,
        .border_left => BorderWidth,
        .border_right => BorderWidth,
        .margin_left => Margin,
        .margin_right => Margin,

        .height => Size,
        .min_height => MinSize,
        .max_height => MaxSize,
        .padding_top => Padding,
        .padding_bottom => Padding,
        .border_top => BorderWidth,
        .border_bottom => BorderWidth,
        .margin_top => Margin,
        .margin_bottom => Margin,

        .top => Inset,
        .right => Inset,
        .bottom => Inset,
        .left => Inset,

        .direction,
        .unicode_bidi,
        .custom,
        => @compileError("TODO: Value(" ++ @tagName(property) ++ ")"),
    };
}

pub const InheritanceType = enum {
    inherited,
    not_inherited,
    neither,
};

pub fn inheritanceType(property: PropertyEnum) InheritanceType {
    return switch (property) {
        .all => .neither,

        .display,
        .position,
        .float,
        .z_index,
        .width,
        .min_width,
        .max_width,
        .padding_left,
        .padding_right,
        .border_left,
        .border_right,
        .margin_left,
        .margin_right,
        .height,
        .min_height,
        .max_height,
        .padding_top,
        .padding_bottom,
        .border_top,
        .border_bottom,
        .margin_top,
        .margin_bottom,
        .top,
        .right,
        .bottom,
        .left,
        .unicode_bidi,
        => .not_inherited,

        .direction,
        .custom,
        => .inherited,
    };
}

pub fn initialValue(comptime property: PropertyEnum) Value(property) {
    return switch (property) {
        .all => @compileError("Property 'all' has no initial value"),
        .display => Display.inline_,
        .position => Position.static,
        .float => Float.none,
        .z_index => ZIndex.auto,

        .width => Size.auto,
        .min_width => MinSize{ .px = 0 },
        .max_width => MaxSize.none,
        .padding_left => Padding{ .px = 0 },
        .padding_right => Padding{ .px = 0 },
        .border_left => BorderWidth.medium,
        .border_right => BorderWidth.medium,
        .margin_left => Margin{ .px = 0 },
        .margin_right => Margin{ .px = 0 },

        .height => Size.auto,
        .min_height => MinSize{ .px = 0 },
        .max_height => MaxSize.none,
        .padding_top => Padding{ .px = 0 },
        .padding_bottom => Padding{ .px = 0 },
        .border_top => BorderWidth.medium,
        .border_bottom => BorderWidth.medium,
        .margin_top => Margin{ .px = 0 },
        .margin_bottom => Margin{ .px = 0 },

        .top => Inset.auto,
        .right => Inset.auto,
        .bottom => Inset.auto,
        .left => Inset.auto,

        .direction,
        .unicode_bidi,
        .custom,
        => @compileError("TODO: initialValue(" ++ @tagName(property) ++ ")"),
    };
}

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
};

pub const ZIndex = union(enum) {
    integer: i32,
    auto,
    initial,
    inherit,
    unset,
};

pub const Float = enum {
    left,
    right,
    none,
    initial,
    inherit,
    unset,
};

pub const Clear = enum {
    left,
    right,
    both,
    none,
    initial,
    inherit,
    unset,
};

pub const Size = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
};

pub const MinSize = union(enum) {
    px: f32,
    percentage: f32,
    initial,
    inherit,
    unset,
};

pub const MaxSize = union(enum) {
    px: f32,
    percentage: f32,
    none,
    initial,
    inherit,
    unset,
};

pub const BorderWidth = union(enum) {
    px: f32,
    thin,
    medium,
    thick,
    initial,
    inherit,
    unset,
};

pub const Padding = union(enum) {
    px: f32,
    percentage: f32,
    initial,
    inherit,
    unset,
};

pub const Margin = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
};

pub const Inset = union(enum) {
    px: f32,
    percentage: f32,
    auto,
    initial,
    inherit,
    unset,
};

pub const Color = union(enum) {
    rgba: u32,
    current_color,
    initial,
    inherit,
    unset,

    pub const transparent = Color{ .rgba = 0 };
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
};

pub const BackgroundPosition = union(enum) {
    pub const Offset = union(enum) {
        px: f32,
        percentage: f32,
    };
    pub const SideX = enum { left, right };
    pub const SideY = enum { top, bottom };

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
};

pub const BackgroundClip = union(enum) {
    border_box,
    padding_box,
    content_box,
    initial,
    inherit,
    unset,
};

pub const BackgroundOrigin = union(enum) {
    border_box,
    padding_box,
    content_box,
    initial,
    inherit,
    unset,
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
};
