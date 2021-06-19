/// Defines the structure of the document, and also contains the
/// computed values of every property for each box in the document.
pub const BoxTree = struct {
    pdfs_flat_tree: []BoxId,
    display: []Display,
    inline_size: []LogicalSize,
    block_size: []LogicalSize,
    latin1_text: []Latin1Text,
    // Only 1 font at a time can be set.
    font: Font,
    border: []Border,
    background: []Background,
    //position_inset: []PositionInset,
};

pub const BoxId = u16;

pub const Display = union(enum) {
    block_flow,
    inline_flow,
    text,
    none,
};

pub const LogicalSize = struct {
    pub const Size = union(enum) {
        px: f32,
        percentage: f32,
        auto,
    };
    pub const Min = union(enum) {
        px: f32,
        percentage: f32,
    };
    pub const Max = union(enum) {
        px: f32,
        percentage: f32,
        none,
    };
    pub const BorderWidth = union(enum) {
        px: f32,
    };
    pub const Padding = union(enum) {
        px: f32,
        percentage: f32,
    };
    pub const Margin = union(enum) {
        px: f32,
        percentage: f32,
        auto,
    };

    size: Size = .{ .auto = {} },
    min_size: Min = .{ .px = 0 },
    max_size: Max = .{ .none = {} },
    border_start_width: BorderWidth = .{ .px = 0 },
    border_end_width: BorderWidth = .{ .px = 0 },
    padding_start: Padding = .{ .px = 0 },
    padding_end: Padding = .{ .px = 0 },
    margin_start: Margin = .{ .px = 0 },
    margin_end: Margin = .{ .px = 0 },
};

//pub const PositionInset = struct {
//    pub const Position = union(enum) {
//        static,
//        relative,
//    };
//    pub const Inset = union(enum) {
//        px: f32,
//        percentage: f32,
//        auto,
//    };
//
//    position: Position = .{ .static = {} },
//    block_start: Inset = .{ .auto = {} },
//    block_end: Inset = .{ .auto = {} },
//    inline_start: Inset = .{ .auto = {} },
//    inline_end: Inset = .{ .auto = {} },
//};

pub const Latin1Text = struct {
    // TODO should this be nullable?
    text: []const u8 = "",
};

pub const Font = struct {
    const hb = @import("harfbuzz");
    pub const Color = union(enum) {
        rgba: u32,
    };

    font: ?*hb.hb_font_t,
    color: Color = .{ .rgba = 0xffffffff },
};

pub const Background = struct {
    pub const Image = union(enum) {
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
    };
    pub const Color = union(enum) {
        rgba: u32,
    };
    pub const Clip = union(enum) {
        border_box,
        padding_box,
        content_box,
    };
    pub const Origin = union(enum) {
        border_box,
        padding_box,
        content_box,
    };
    pub const Size = union(enum) {
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
    pub const Position = union(enum) {
        pub const Offset = union(enum) {
            px: f32,
            percentage: f32,
        };

        position: struct {
            horizontal: struct {
                side: enum { left, right },
                offset: Offset,
            },
            vertical: struct {
                side: enum { top, bottom },
                offset: Offset,
            },
        },
    };
    pub const Repeat = union(enum) {
        pub const Style = enum { repeat, space, round, no_repeat };

        repeat: struct {
            horizontal: Style,
            vertical: Style,
        },
    };

    image: Image = .{ .none = {} },
    color: Color = .{ .rgba = 0 },
    clip: Clip = .{ .border_box = {} },
    origin: Origin = .{ .padding_box = {} },
    size: Size = .{ .size = .{
        .width = .{ .auto = {} },
        .height = .{ .auto = {} },
    } },
    position: Position = .{ .position = .{
        .horizontal = .{ .side = .left, .offset = .{ .percentage = 0 } },
        .vertical = .{ .side = .top, .offset = .{ .percentage = 0 } },
    } },
    repeat: Repeat = .{ .repeat = .{
        .horizontal = .repeat,
        .vertical = .repeat,
    } },
};

pub const Border = struct {
    pub const Color = union(enum) {
        rgba: u32,
    };

    // TODO wrong defaults
    block_start_color: Color = .{ .rgba = 0 },
    block_end_color: Color = .{ .rgba = 0 },
    inline_start_color: Color = .{ .rgba = 0 },
    inline_end_color: Color = .{ .rgba = 0 },
};
