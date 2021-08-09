const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const ZssUnit = i32;

/// The number of ZssUnits contained wthin 1 screen pixel.
pub const unitsPerPixel = 1;

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
    inline_start_rgba: u32 = 0,
    inline_end_rgba: u32 = 0,
    block_start_rgba: u32 = 0,
    block_end_rgba: u32 = 0,
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
    color_rgba: u32 = 0,
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

    image: ?*zss.BoxTree.Background.Image.Object.Data = null,
    position: Position = .{},
    size: Size = .{},
    repeat: Repeat = .{},
    origin: Origin = .Padding,
};

pub const UsedId = u16;
pub const UsedSubtreeSize = UsedId;
pub const UsedBoxCount = UsedId;
pub const StackingContextId = UsedId;
pub const InlineId = UsedId;
pub const ZIndex = i32;

/// Contains information about a set of block boxes.
/// Block boxes form a hierarchy, and therefore a tree structure, which is represented here.
pub const BlockLevelUsedValues = struct {
    // A "used id" is an index into the following arrays.
    // To know how to use the "structure" field and the group of fields following it,
    // see the explanation in BoxTree. It works in exactly the same way.
    structure: ArrayListUnmanaged(UsedId) = .{},
    box_offsets: ArrayListUnmanaged(BoxOffsets) = .{},
    borders: ArrayListUnmanaged(Borders) = .{},
    margins: ArrayListUnmanaged(Margins) = .{},
    border_colors: ArrayListUnmanaged(BorderColor) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    background2: ArrayListUnmanaged(Background2) = .{},
    properties: ArrayListUnmanaged(BoxProperties) = .{},
    // End of the "used id" indexed arrays.

    stacking_context_structure: ArrayListUnmanaged(StackingContextId) = .{},
    stacking_contexts: ArrayListUnmanaged(StackingContext) = .{},

    const Self = @This();

    pub const BoxProperties = struct {
        creates_stacking_context: bool = false,
        inline_context_index: ?InlineId = null,
        uses_shrink_to_fit_sizing: bool = false,
    };

    pub const StackingContext = struct {
        z_index: ZIndex,
        used_id: UsedId,
    };

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.structure.deinit(allocator);
        self.box_offsets.deinit(allocator);
        self.borders.deinit(allocator);
        self.margins.deinit(allocator);
        self.border_colors.deinit(allocator);
        self.background1.deinit(allocator);
        self.background2.deinit(allocator);
        self.properties.deinit(allocator);

        self.stacking_context_structure.deinit(allocator);
        self.stacking_contexts.deinit(allocator);
    }

    pub fn ensureCapacity(self: *Self, allocator: *Allocator, capacity: usize) !void {
        try self.structure.ensureCapacity(allocator, capacity);
        try self.box_offsets.ensureCapacity(allocator, capacity);
        try self.borders.ensureCapacity(allocator, capacity);
        try self.margins.ensureCapacity(allocator, capacity);
        try self.border_colors.ensureCapacity(allocator, capacity);
        try self.background1.ensureCapacity(allocator, capacity);
        try self.background2.ensureCapacity(allocator, capacity);
        try self.properties.ensureCapacity(allocator, capacity);
    }
};

/// Contains information about an inline formatting context.
/// Each glyph and its corresponding metrics are placed into arrays. (glyph_indeces and metrics)
/// Then, each element in line_boxes tells you which glyphs to include and the baseline position.
///
/// To represent things that are not glyphs (e.g. inline boxes), the glyph index 0 is reserved for special use.
/// When a glyph index of 0 is found, it does not actually correspond to that glyph index. Instead it tells you
/// that the next glyph index (which is guaranteed to exist) contains "special data." Use the Special.decode
/// function to recover and interpret that data. Note that this data still has metrics associated with it.
/// That metrics data is found in the same array index as that of the first glyph index (the one that was 0).
pub const InlineLevelUsedValues = struct {
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

    // A "used id" is an index into the following arrays.
    inline_start: ArrayListUnmanaged(BoxProperties) = .{},
    inline_end: ArrayListUnmanaged(BoxProperties) = .{},
    block_start: ArrayListUnmanaged(BoxProperties) = .{},
    block_end: ArrayListUnmanaged(BoxProperties) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    margins: ArrayListUnmanaged(MarginsInline) = .{},
    // End of the "used id" indexed arrays.

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
        pub const Kind = extern enum(u16) {
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

        pub const LayoutInternalKind = extern enum(u16) {
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

        pub fn encodeBoxStart(used_id: UsedId) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .BoxStart, .data = used_id });
        }

        pub fn encodeBoxEnd(used_id: UsedId) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .BoxEnd, .data = used_id });
        }

        pub fn encodeInlineBlock(used_id: UsedId) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .InlineBlock, .data = used_id });
        }

        pub fn encodeZeroGlyphIndex() GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = .ZeroGlyphIndex, .data = undefined });
        }

        pub fn encodeLineBreak() GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = @intToEnum(Kind, @enumToInt(LayoutInternalKind.LineBreak)), .data = undefined });
        }

        pub fn encodeContinuationBlock(used_id: UsedId) GlyphIndex {
            return @bitCast(GlyphIndex, Special{ .kind = @intToEnum(Kind, @enumToInt(LayoutInternalKind.ContinuationBlock)), .data = used_id });
        }
    };

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
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

    pub fn ensureCapacity(self: *Self, allocator: *Allocator, count: usize) !void {
        try self.line_boxes.ensureCapacity(allocator, count);
        try self.glyph_indeces.ensureCapacity(allocator, count);
        try self.metrics.ensureCapacity(allocator, count);
        try self.inline_start.ensureCapacity(allocator, count);
        try self.inline_end.ensureCapacity(allocator, count);
        try self.block_start.ensureCapacity(allocator, count);
        try self.block_end.ensureCapacity(allocator, count);
        try self.background1.ensureCapacity(allocator, count);
        try self.margins.ensureCapacity(allocator, count);
    }
};

/// The final result of layout.
pub const Document = struct {
    blocks: BlockLevelUsedValues,
    inlines: ArrayListUnmanaged(*InlineLevelUsedValues),
    allocator: *Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.allocator);
        for (self.inlines.items) |inl| {
            inl.deinit(self.allocator);
            self.allocator.destroy(inl);
        }
        self.inlines.deinit(self.allocator);
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
