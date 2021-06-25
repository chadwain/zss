/// Defines the structure of the document, and also contains the
/// computed values of every property for each box in the document.
pub const BoxTree = struct {
    // To use BoxTree, you must know how your document would be laid out as a tree data structure.
    // The "structure" field represents that tree as a flat array.
    // It can be generated in the following way.
    //
    // 1. Start with an empty array.
    // 2. Perform a pre-order depth first iteration of your document tree.
    // 3. For each node, append S to the array, where S is the size of that node's subtree.
    //    (A node's subtree includes itself, so S should always be at least 1.)
    //    The index into the array in which you inserted S becomes this node's "box id".
    //
    // Now, for each element, you must fill in its CSS properties using the other arrays
    // in this struct, and using the "box id" as the index into those arrays.
    // Note that because this struct uses just slices instead of maps/sets at the moment,
    // *every single property* of *every single element* must be filled in (even if you
    // just use the defaults).

    structure: []BoxId,
    display: []Display,
    inline_size: []LogicalSize,
    block_size: []LogicalSize,
    latin1_text: []Latin1Text,
    border: []Border,
    background: []Background,
    // zss is currently limited to just 1 font per document.
    font: Font,
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
    border_start: BorderWidth = .{ .px = 0 },
    border_end: BorderWidth = .{ .px = 0 },
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

    font: *hb.hb_font_t,
    color: Color = .{ .rgba = 0x000000ff },
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
            width: SizeType = .{ .auto = {} },
            height: SizeType = .{ .auto = {} },
        },
        contain,
        cover,
    };
    pub const Position = union(enum) {
        pub const Offset = union(enum) {
            px: f32,
            percentage: f32,
        };
        pub const SideX = enum { left, right };
        pub const SideY = enum { top, bottom };

        position: struct {
            x: struct {
                side: SideX = .left,
                offset: Offset = .{ .percentage = 0 },
            } = .{},
            y: struct {
                side: SideY = .top,
                offset: Offset = .{ .percentage = 0 },
            } = .{},
        },
    };
    pub const Repeat = union(enum) {
        pub const Style = enum { repeat, no_repeat, space, round };

        repeat: struct {
            x: Style = .repeat,
            y: Style = .repeat,
        },
    };

    image: Image = .{ .none = {} },
    color: Color = .{ .rgba = 0 },
    clip: Clip = .{ .border_box = {} },
    origin: Origin = .{ .padding_box = {} },
    size: Size = .{ .size = .{} },
    position: Position = .{ .position = .{} },
    repeat: Repeat = .{ .repeat = .{} },
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
