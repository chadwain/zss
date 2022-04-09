const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const SkipTree = zss.SkipTree;

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const ZssUnit = i32;

/// The number of ZssUnits contained wthin 1 screen pixel.
pub const units_per_pixel = 1;

/// A floating point number usually between 0 and 1, but it can
/// exceed these values.
pub const Percentage = f32;

pub const ZssVector = struct {
    x: ZssUnit,
    y: ZssUnit,

    const Self = @This();
    pub fn add(lhs: Self, rhs: Self) Self {
        return Self{ .x = lhs.x + rhs.x, .y = lhs.y + rhs.y };
    }
};

pub const ZssLogicalVector = struct {
    x: ZssUnit,
    y: ZssUnit,
};

pub const ZssSize = struct {
    w: ZssUnit,
    h: ZssUnit,
};

pub const ZssRect = struct {
    x: ZssUnit,
    y: ZssUnit,
    w: ZssUnit,
    h: ZssUnit,

    const Self = @This();

    pub fn isEmpty(self: Self) bool {
        return self.w <= 0 or self.h <= 0;
    }

    pub fn intersect(a: Self, b: Self) Self {
        const left = std.math.max(a.x, b.x);
        const right = std.math.min(a.x + a.w, b.x + b.w);
        const top = std.math.max(a.y, b.y);
        const bottom = std.math.min(a.y + a.h, b.y + b.h);

        return Self{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

pub const Color = u32;

/// The offsets of various points of a block box, taken from the
/// inline-start/block-start corner of the content box of its parent.
pub const BoxOffsets = struct {
    border_start: ZssLogicalVector = .{ .x = 0, .y = 0 },
    border_end: ZssLogicalVector = .{ .x = 0, .y = 0 },
    content_start: ZssLogicalVector = .{ .x = 0, .y = 0 },
    content_end: ZssLogicalVector = .{ .x = 0, .y = 0 },
};

/// Contains the used values of the properties
/// 'border-block-start-width', 'border-inline-end-width',
/// 'border-block-end-width', and 'border-inline-start-width'.
pub const Borders = struct {
    inline_start: ZssUnit = 0,
    inline_end: ZssUnit = 0,
    block_start: ZssUnit = 0,
    block_end: ZssUnit = 0,
};

/// Contains the used values of the properties
/// 'border-block-start-color', 'border-inline-end-color',
/// 'border-block-end-color', and 'border-inline-start-color'.
pub const BorderColor = struct {
    inline_start_rgba: Color = 0,
    inline_end_rgba: Color = 0,
    block_start_rgba: Color = 0,
    block_end_rgba: Color = 0,
};

/// Contains the used values of the properties
/// 'margin-inline-start', 'margin-inline-end',
/// 'margin-block-start', and 'margin-block-end'.
pub const Margins = struct {
    inline_start: ZssUnit = 0,
    inline_end: ZssUnit = 0,
    block_start: ZssUnit = 0,
    block_end: ZssUnit = 0,
};

/// Contains the used values of the properties
/// 'background-color' and 'background-clip'.
pub const Background1 = struct {
    color_rgba: Color = 0,
    clip: enum { Border, Padding, Content } = .Border,
};

/// Contains the used values of the properties 'background-image',
/// 'background-origin', 'background-position', 'background-size',
/// and 'background-repeat'.
pub const Background2 = struct {
    pub const Origin = enum { Padding, Border, Content };
    pub const Position = struct { x: ZssUnit = 0, y: ZssUnit = 0 };
    pub const Size = struct { width: ZssUnit = 0, height: ZssUnit = 0 };
    pub const Repeat = struct {
        pub const Style = enum { None, Repeat, Space, Round };
        x: Style = .None,
        y: Style = .None,
    };

    image: ?*zss.value.BackgroundImage.Object.Data = null,
    position: Position = .{},
    size: Size = .{},
    repeat: Repeat = .{},
    origin: Origin = .Padding,
};

pub const BlockBoxIndex = u16;
pub const BlockBoxSkip = BlockBoxIndex;
pub const BlockBoxCount = BlockBoxIndex;

pub const BlockBoxTree = struct {
    skips: ArrayListUnmanaged(BlockBoxIndex) = .{},
    box_offsets: ArrayListUnmanaged(BoxOffsets) = .{},
    borders: ArrayListUnmanaged(Borders) = .{},
    margins: ArrayListUnmanaged(Margins) = .{},
    border_colors: ArrayListUnmanaged(BorderColor) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    background2: ArrayListUnmanaged(Background2) = .{},
    properties: ArrayListUnmanaged(BoxProperties) = .{},

    const Self = @This();

    pub const BoxProperties = struct {
        creates_stacking_context: bool = false,
    };

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.skips.deinit(allocator);
        self.box_offsets.deinit(allocator);
        self.borders.deinit(allocator);
        self.margins.deinit(allocator);
        self.border_colors.deinit(allocator);
        self.background1.deinit(allocator);
        self.background2.deinit(allocator);
        self.properties.deinit(allocator);
    }

    pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, capacity: usize) !void {
        try self.skips.ensureTotalCapacity(allocator, capacity);
        try self.box_offsets.ensureTotalCapacity(allocator, capacity);
        try self.borders.ensureTotalCapacity(allocator, capacity);
        try self.margins.ensureTotalCapacity(allocator, capacity);
        try self.border_colors.ensureTotalCapacity(allocator, capacity);
        try self.background1.ensureTotalCapacity(allocator, capacity);
        try self.background2.ensureTotalCapacity(allocator, capacity);
        try self.properties.ensureTotalCapacity(allocator, capacity);
    }
};

pub const InlineBoxIndex = u16;
pub const InlineFormattingContextIndex = u16;

/// Contains information about an inline formatting context.
/// Each glyph and its corresponding metrics are placed into arrays. (glyph_indeces and metrics)
/// Then, each element in line_boxes tells you which glyphs to include and the baseline position.
///
/// To represent things that are not glyphs (e.g. inline boxes), the glyph index 0 is reserved for special use.
/// When a glyph index of 0 is found, it does not actually correspond to that glyph index. Instead it tells you
/// that the next glyph index (which is guaranteed to exist) contains "special data." Use the Special.decode
/// function to recover and interpret that data. Note that this data still has metrics associated with it.
/// That metrics data is found in the same array index as that of the first glyph index (the one that was 0).
pub const InlineFormattingContext = struct {
    parent_block: BlockBoxIndex,
    origin: ZssVector,

    glyph_indeces: ArrayListUnmanaged(GlyphIndex) = .{},
    metrics: ArrayListUnmanaged(Metrics) = .{},

    line_boxes: ArrayListUnmanaged(LineBox) = .{},

    // zss is currently limited with what it can do with text. As a result,
    // font and font color will be the same for all glyphs, and
    // ascender and descender will be the same for all line boxes.
    font: *hb.hb_font_t = undefined,
    font_color_rgba: u32 = undefined,
    ascender: ZssUnit = undefined,
    descender: ZssUnit = undefined,

    inline_start: ArrayListUnmanaged(BoxProperties) = .{},
    inline_end: ArrayListUnmanaged(BoxProperties) = .{},
    block_start: ArrayListUnmanaged(BoxProperties) = .{},
    block_end: ArrayListUnmanaged(BoxProperties) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    margins: ArrayListUnmanaged(MarginsInline) = .{},

    const hb = @import("harfbuzz");

    const Self = @This();

    pub const GlyphIndex = hb.hb_codepoint_t;

    pub const BoxProperties = struct {
        border: ZssUnit = 0,
        padding: ZssUnit = 0,
        border_color_rgba: u32 = 0,
    };

    pub const Metrics = struct {
        offset: ZssUnit,
        advance: ZssUnit,
        width: ZssUnit,
    };

    pub const MarginsInline = struct {
        start: ZssUnit = 0,
        end: ZssUnit = 0,
    };

    pub const LineBox = struct {
        /// The vertical distance from the top of the containing block to this line box's baseline.
        baseline: ZssUnit,
        /// The interval of glyph indeces to take from the glyph_indeces array.
        /// It is a half-open interval of the form [a, b).
        elements: [2]usize,
    };

    /// Structure that represents things other than glyphs. It is guaranteed to never have a
    /// bit representation of 0.
    // NOTE Not making this an extern struct keeps crashing compiler
    pub const Special = extern struct {
        kind: Kind,
        data: u16,

        // This must start at 1 to make the Special struct never have a bit representation of 0.
        pub const Kind = enum(u16) {
            /// Represents a glyph index of 0.
            /// data has no meaning.
            ZeroGlyphIndex = 1,
            /// Represents an inline box's start fragment.
            /// data is the used id of the box.
            BoxStart,
            /// Represents an inline box's end fragment.
            /// data is the used id of the box.
            BoxEnd,
            /// Represents an inline block
            /// data is the used id of the block box.
            InlineBlock,
            /// Any other value of this enum should never appear in an end user's code.
            _,
        };

        /// Recovers the data contained within a glyph index.
        pub fn decode(encoded_glyph_index: GlyphIndex) Special {
            return @bitCast(Special, encoded_glyph_index);
        }

        // End users should not concern themselves with anything below this comment.

        pub const LayoutInternalKind = enum(u16) {
            // The explanations for some of these are above.
            ZeroGlyphIndex = 1,
            BoxStart,
            BoxEnd,
            InlineBlock,
            /// Represents a mandatory line break in the text.
            /// data has no meaning.
            LineBreak,
            /// Represents a continuation block.
            /// A "continuation block" is a block box that is the child of an inline box.
            /// It causes the inline formatting context to be split around this block,
            /// and creates anonymous block boxes, as per CSS2§9.2.1.1.
            /// data is the used id of the block box.
            ContinuationBlock,
        };

        comptime {
            for (std.meta.fields(Kind)) |f| {
                std.debug.assert(std.mem.eql(u8, f.name, @tagName(@intToEnum(LayoutInternalKind, f.value))));
            }
        }

        pub fn encodeBoxStart(index: InlineBoxIndex) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .BoxStart, .data = index });
        }

        pub fn encodeBoxEnd(index: InlineBoxIndex) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .BoxEnd, .data = index });
        }

        pub fn encodeInlineBlock(index: BlockBoxIndex) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .InlineBlock, .data = index });
        }

        pub fn encodeZeroGlyphIndex() GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .ZeroGlyphIndex, .data = undefined });
        }

        pub fn encodeLineBreak() GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = @intToEnum(Kind, @enumToInt(LayoutInternalKind.LineBreak)), .data = undefined });
        }

        pub fn encodeContinuationBlock(index: InlineBoxIndex) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = @intToEnum(Kind, @enumToInt(LayoutInternalKind.ContinuationBlock)), .data = index });
        }
    };

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.glyph_indeces.deinit(allocator);
        self.metrics.deinit(allocator);
        self.line_boxes.deinit(allocator);

        self.inline_start.deinit(allocator);
        self.inline_end.deinit(allocator);
        self.block_start.deinit(allocator);
        self.block_end.deinit(allocator);
        self.background1.deinit(allocator);
        self.margins.deinit(allocator);
    }

    pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: usize) !void {
        try self.inline_start.ensureTotalCapacity(allocator, count);
        try self.inline_end.ensureTotalCapacity(allocator, count);
        try self.block_start.ensureTotalCapacity(allocator, count);
        try self.block_end.ensureTotalCapacity(allocator, count);
        try self.background1.ensureTotalCapacity(allocator, count);
        try self.margins.ensureTotalCapacity(allocator, count);
    }
};

pub const StackingContextIndex = u16;
pub const ZIndex = i32;

pub const StackingContext = struct {
    /// The z-index of this stacking context.
    z_index: ZIndex,
    /// The block box that creates this stacking context.
    block_box: BlockBoxIndex,
    /// The list of inline formatting contexts in this stacking context.
    ifcs: ArrayListUnmanaged(InlineFormattingContextIndex),
};

// NOTE: This might benefit from being a SparseSkipTree instead.
pub const StackingContextTree = SkipTree(StackingContextIndex, StackingContext);

/// The result of layout.
pub const Boxes = struct {
    blocks: BlockBoxTree = .{},
    inlines: ArrayListUnmanaged(*InlineFormattingContext) = .{},
    stacking_contexts: StackingContextTree = .{},
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.allocator);
        for (self.inlines.items) |ifc| {
            ifc.deinit(self.allocator);
            self.allocator.destroy(ifc);
        }
        self.inlines.deinit(self.allocator);
        for (self.stacking_contexts.multi_list.items(.ifcs)) |*ifc_list| {
            ifc_list.deinit(self.allocator);
        }
        self.stacking_contexts.deinit(self.allocator);
    }
};

test "ZssRect" {
    const r1 = ZssRect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r2 = ZssRect{ .x = 3, .y = 5, .w = 17, .h = 4 };
    const r3 = ZssRect{ .x = 15, .y = 0, .w = 20, .h = 9 };
    const r4 = ZssRect{ .x = 20, .y = 1, .w = 10, .h = 0 };

    const intersect = ZssRect.intersect;
    try expect(std.meta.eql(intersect(r1, r2), ZssRect{ .x = 3, .y = 5, .w = 7, .h = 4 }));
    try expect(intersect(r1, r3).isEmpty());
    try expect(intersect(r1, r4).isEmpty());
    try expect(std.meta.eql(intersect(r2, r3), ZssRect{ .x = 15, .y = 5, .w = 5, .h = 4 }));
    try expect(intersect(r2, r4).isEmpty());
    try expect(intersect(r3, r4).isEmpty());
}
