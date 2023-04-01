const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const zss = @import("../../zss.zig");
const ReferencedSkipTree = zss.ReferencedSkipTree;
const ElementHashMap = zss.util.ElementHashMap;

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const ZssUnit = i32;

/// The number of ZssUnits contained wthin 1 screen pixel.
pub const units_per_pixel = 2;

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

    pub fn eql(lhs: Self, rhs: Self) bool {
        return lhs.x == rhs.x and lhs.y == rhs.y;
    }
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

    pub fn translate(rect: Self, vec: ZssVector) Self {
        return Self{
            .x = rect.x + vec.x,
            .y = rect.y + vec.y,
            .w = rect.w,
            .h = rect.h,
        };
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

pub const BoxOffsets = struct {
    /// The offset of the top-left corner of the border box, relative to
    /// the top-left corner of the parent block's content box (or the top-left
    /// corner of the screen, if this is the initial containing block).
    border_pos: ZssVector = .{ .x = 0, .y = 0 },
    /// The width and height of the border box.
    border_size: ZssSize = .{ .w = 0, .h = 0 },
    /// The offset of the top-left corner of the content box, relative to
    /// the top-left corner of this block's border box.
    content_pos: ZssVector = .{ .x = 0, .y = 0 },
    /// The width and height of the content box.
    content_size: ZssSize = .{ .w = 0, .h = 0 },
};

pub const Borders = struct {
    left: ZssUnit = 0,
    right: ZssUnit = 0,
    top: ZssUnit = 0,
    bottom: ZssUnit = 0,
};

pub const BorderColor = struct {
    left_rgba: Color = 0,
    right_rgba: Color = 0,
    top_rgba: Color = 0,
    bottom_rgba: Color = 0,
};

pub const Margins = struct {
    left: ZssUnit = 0,
    right: ZssUnit = 0,
    top: ZssUnit = 0,
    bottom: ZssUnit = 0,
};

pub const Insets = ZssVector;

pub const Background1 = struct {
    color_rgba: Color = 0,
    clip: enum { Border, Padding, Content } = .Border,
};

pub const Background2 = struct {
    pub const Origin = enum { Padding, Border, Content };
    pub const Position = struct { x: ZssUnit = 0, y: ZssUnit = 0 };
    pub const Size = struct { width: ZssUnit = 0, height: ZssUnit = 0 };
    pub const Repeat = struct {
        pub const Style = enum { None, Repeat, Space, Round };
        x: Style = .None,
        y: Style = .None,
    };

    image: ?*zss.values.BackgroundImage.Object.Data = null,
    position: Position = .{},
    size: Size = .{},
    repeat: Repeat = .{},
    origin: Origin = .Padding,
};

pub const BlockType = union(enum) {
    block: struct {
        stacking_context: ?StackingContextRef,
    },
    ifc_container: InlineFormattingContextIndex,
    subtree_proxy: SubtreeIndex,
};

pub const SubtreeIndex = u16;
pub const BlockBoxIndex = u16;
pub const BlockBox = struct {
    subtree: SubtreeIndex,
    index: BlockBoxIndex,
};
pub const BlockBoxSkip = BlockBoxIndex;

pub const BlockSubtree = struct {
    parent: ?BlockBox,

    skip: ArrayListUnmanaged(BlockBoxIndex) = .{},
    type: ArrayListUnmanaged(BlockType) = .{},
    box_offsets: ArrayListUnmanaged(BoxOffsets) = .{},
    borders: ArrayListUnmanaged(Borders) = .{},
    margins: ArrayListUnmanaged(Margins) = .{},
    insets: ArrayListUnmanaged(Insets) = .{},
    border_colors: ArrayListUnmanaged(BorderColor) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    background2: ArrayListUnmanaged(Background2) = .{},

    pub fn deinit(subtree: *BlockSubtree, allocator: Allocator) void {
        subtree.skip.deinit(allocator);
        subtree.type.deinit(allocator);
        subtree.box_offsets.deinit(allocator);
        subtree.borders.deinit(allocator);
        subtree.margins.deinit(allocator);
        subtree.insets.deinit(allocator);
        subtree.border_colors.deinit(allocator);
        subtree.background1.deinit(allocator);
        subtree.background2.deinit(allocator);
    }

    pub fn ensureTotalCapacity(subtree: *BlockSubtree, allocator: Allocator, capacity: usize) !void {
        try subtree.skip.ensureTotalCapacity(allocator, capacity);
        try subtree.type.ensureTotalCapacity(allocator, capacity);
        try subtree.box_offsets.ensureTotalCapacity(allocator, capacity);
        try subtree.borders.ensureTotalCapacity(allocator, capacity);
        try subtree.margins.ensureTotalCapacity(allocator, capacity);
        try subtree.insets.ensureTotalCapacity(allocator, capacity);
        try subtree.border_colors.ensureTotalCapacity(allocator, capacity);
        try subtree.background1.ensureTotalCapacity(allocator, capacity);
        try subtree.background2.ensureTotalCapacity(allocator, capacity);
    }
};

pub const BlockBoxTree = struct {
    subtrees: ArrayListUnmanaged(*BlockSubtree) = .{},

    fn deinit(tree: *BlockBoxTree, allocator: Allocator) void {
        for (tree.subtrees.items) |subtree| {
            subtree.deinit(allocator);
            allocator.destroy(subtree);
        }
        tree.subtrees.deinit(allocator);
    }

    pub fn makeSubtree(blocks: *BlockBoxTree, allocator: Allocator, value: BlockSubtree) !SubtreeIndex {
        const index = std.math.cast(SubtreeIndex, blocks.subtrees.items.len) orelse return error.TooManyBlockSubtrees;
        const entry = try blocks.subtrees.addOne(allocator);
        errdefer _ = blocks.subtrees.pop();
        const subtree = try allocator.create(BlockSubtree);
        entry.* = subtree;
        subtree.* = value;
        return index;
    }
};

pub const InlineBoxIndex = u16;
pub const InlineBoxSkip = InlineBoxIndex;
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
    parent_block: BlockBox,

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

    skip: ArrayListUnmanaged(InlineBoxSkip) = .{},
    inline_start: ArrayListUnmanaged(BoxProperties) = .{},
    inline_end: ArrayListUnmanaged(BoxProperties) = .{},
    block_start: ArrayListUnmanaged(BoxProperties) = .{},
    block_end: ArrayListUnmanaged(BoxProperties) = .{},
    background1: ArrayListUnmanaged(Background1) = .{},
    margins: ArrayListUnmanaged(MarginsInline) = .{},
    insets: ArrayListUnmanaged(Insets) = .{},

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
        /// The inline box that starts this line box.
        inline_box: InlineBoxIndex,
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
    };

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.glyph_indeces.deinit(allocator);
        self.metrics.deinit(allocator);
        self.line_boxes.deinit(allocator);

        self.skip.deinit(allocator);
        self.inline_start.deinit(allocator);
        self.inline_end.deinit(allocator);
        self.block_start.deinit(allocator);
        self.block_end.deinit(allocator);
        self.background1.deinit(allocator);
        self.margins.deinit(allocator);
        self.insets.deinit(allocator);
    }

    pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, count: usize) !void {
        try self.skip.ensureTotalCapacity(allocator, count);
        try self.inline_start.ensureTotalCapacity(allocator, count);
        try self.inline_end.ensureTotalCapacity(allocator, count);
        try self.block_start.ensureTotalCapacity(allocator, count);
        try self.block_end.ensureTotalCapacity(allocator, count);
        try self.background1.ensureTotalCapacity(allocator, count);
        try self.margins.ensureTotalCapacity(allocator, count);
        try self.insets.ensureTotalCapacity(allocator, count);
    }
};

pub const StackingContextIndex = u16;
pub const StackingContextRef = u17;
pub const ZIndex = i32;

pub const StackingContext = struct {
    /// The z-index of this stacking context.
    z_index: ZIndex,
    /// The block box that creates this stacking context.
    block_box: BlockBox,
    /// The list of inline formatting contexts in this stacking context.
    ifcs: ArrayListUnmanaged(InlineFormattingContextIndex),
};

pub const StackingContextTree = ReferencedSkipTree(StackingContextIndex, StackingContextRef, StackingContext);

/// The type of box(es) that an element generates.
pub const GeneratedBox = union(enum) {
    /// The element generated a single block box.
    block_box: BlockBox,
    /// The element generated a single inline box.
    inline_box: struct { ifc_index: InlineFormattingContextIndex, index: InlineBoxIndex },
    /// The element generated text.
    text,
};

/// The result of layout.
pub const BoxTree = struct {
    blocks: BlockBoxTree = .{},
    ifcs: ArrayListUnmanaged(*InlineFormattingContext) = .{},
    stacking_contexts: StackingContextTree = .{},
    element_to_generated_box: ElementHashMap(GeneratedBox) = .{},
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.allocator);
        for (self.ifcs.items) |ifc| {
            ifc.deinit(self.allocator);
            self.allocator.destroy(ifc);
        }
        self.ifcs.deinit(self.allocator);
        for (self.stacking_contexts.list.items(.ifcs)) |*ifc_list| {
            ifc_list.deinit(self.allocator);
        }
        self.stacking_contexts.deinit(self.allocator);
        self.element_to_generated_box.deinit(self.allocator);
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
