const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("zss.zig");
const Element = zss.ElementTree.Element;
const ElementHashMap = zss.util.ElementHashMap;

/// The smallest unit of space in the zss coordinate system.
pub const ZssUnit = i32;

/// The number of ZssUnits contained wthin the width or height of 1 screen pixel.
pub const units_per_pixel = 4;

pub fn pixelsToZssUnits(px: anytype) ?ZssUnit {
    const casted = std.math.cast(ZssUnit, px) orelse return null;
    return std.math.mul(ZssUnit, casted, units_per_pixel) catch null;
}

pub const ZssVector = struct {
    x: ZssUnit,
    y: ZssUnit,

    const Self = @This();

    pub fn add(lhs: Self, rhs: Self) Self {
        return Self{ .x = lhs.x + rhs.x, .y = lhs.y + rhs.y };
    }

    pub fn sub(lhs: Self, rhs: Self) Self {
        return Self{ .x = lhs.x - rhs.x, .y = lhs.y - rhs.y };
    }

    pub fn eql(lhs: Self, rhs: Self) bool {
        return lhs.x == rhs.x and lhs.y == rhs.y;
    }
};

pub const ZssSize = struct {
    w: ZssUnit,
    h: ZssUnit,
};

pub const ZssRange = struct {
    start: ZssUnit,
    length: ZssUnit,
};

pub const ZssRect = struct {
    x: ZssUnit,
    y: ZssUnit,
    w: ZssUnit,
    h: ZssUnit,

    const Self = @This();

    pub fn xRange(rect: ZssRect) ZssRange {
        return .{ .start = rect.x, .length = rect.w };
    }

    pub fn yRange(rect: ZssRect) ZssRange {
        return .{ .start = rect.y, .length = rect.h };
    }

    pub fn isEmpty(self: Self) bool {
        return self.w < 0 or self.h < 0;
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
        const left = @max(a.x, b.x);
        const right = @min(a.x + a.w, b.x + b.w);
        const top = @max(a.y, b.y);
        const bottom = @min(a.y + a.h, b.y + b.h);

        return Self{
            .x = left,
            .y = top,
            .w = right - left,
            .h = bottom - top,
        };
    }
};

test "ZssRect" {
    const r1 = ZssRect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r2 = ZssRect{ .x = 3, .y = 5, .w = 17, .h = 4 };
    const r3 = ZssRect{ .x = 15, .y = 0, .w = 20, .h = 9 };
    const r4 = ZssRect{ .x = 20, .y = 1, .w = 10, .h = 0 };

    const expect = std.testing.expect;
    const intersect = ZssRect.intersect;
    try expect(std.meta.eql(intersect(r1, r2), ZssRect{ .x = 3, .y = 5, .w = 7, .h = 4 }));
    try expect(intersect(r1, r3).isEmpty());
    try expect(intersect(r1, r4).isEmpty());
    try expect(std.meta.eql(intersect(r2, r3), ZssRect{ .x = 15, .y = 5, .w = 5, .h = 4 }));
    try expect(intersect(r2, r4).isEmpty());
    try expect(!intersect(r3, r4).isEmpty());
}

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn toRgbaArray(color: Color) [4]u8 {
        return @bitCast(color);
    }

    pub fn toRgbaInt(color: Color) u32 {
        return std.mem.bigToNative(u32, @bitCast(color));
    }

    pub fn fromRgbaInt(value: u32) Color {
        return @bitCast(std.mem.nativeToBig(u32, value));
    }

    comptime {
        const eql = std.meta.eql;
        assert(eql(toRgbaArray(.{ .r = 0, .g = 0, .b = 0, .a = 0 }), .{ 0x00, 0x00, 0x00, 0x00 }));
        assert(eql(toRgbaArray(.{ .r = 255, .g = 0, .b = 0, .a = 128 }), .{ 0xff, 0x00, 0x00, 0x80 }));
        assert(eql(toRgbaArray(.{ .r = 0, .g = 20, .b = 50, .a = 200 }), .{ 0x00, 0x14, 0x32, 0xC8 }));

        assert(toRgbaInt(.{ .r = 0, .g = 0, .b = 0, .a = 0 }) == 0x00000000);
        assert(toRgbaInt(.{ .r = 255, .g = 0, .b = 0, .a = 128 }) == 0xff000080);
        assert(toRgbaInt(.{ .r = 0, .g = 20, .b = 50, .a = 200 }) == 0x001432C8);
    }

    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white = Color{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 0xff };
};

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
    left: Color = Color.transparent,
    right: Color = Color.transparent,
    top: Color = Color.transparent,
    bottom: Color = Color.transparent,
};

pub const Margins = struct {
    left: ZssUnit = 0,
    right: ZssUnit = 0,
    top: ZssUnit = 0,
    bottom: ZssUnit = 0,
};

pub const Insets = ZssVector;

pub const BoxStyle = struct {
    pub const InnerBlock = enum {
        /// display: block
        flow,
    };
    pub const InnerInline = union(enum) {
        /// display: inline
        @"inline",
        /// Text nodes
        text,
        /// display: inline-block, inline-grid, etc.
        block: InnerBlock,
    };
    pub const Position = enum { static, relative, absolute };

    /// Each field represents an "outer" display type, while each value represents an "inner" display type.
    outer: union(enum) {
        block: InnerBlock,
        @"inline": InnerInline,
        /// position: absolute
        absolute: InnerBlock,
        /// display: none
        none,
    },
    position: Position,

    pub const text = BoxStyle{
        .outer = .{ .@"inline" = .text },
        .position = .static,
    };
};

pub const BackgroundClip = enum { border, padding, content };

pub const InlineBoxBackground = struct {
    color: Color = Color.transparent,
    clip: BackgroundClip = .border,
};

pub const BlockBoxBackground = struct {
    color: Color = Color.transparent,
    color_clip: BackgroundClip = .border,
    images: BackgroundImages.Handle = .invalid,
};

pub const BackgroundImage = struct {
    pub const Origin = enum { padding, border, content };
    pub const Position = ZssVector;
    pub const Size = ZssSize;
    pub const Repeat = struct {
        pub const Style = enum { none, repeat, space, round };
        x: Style = .none,
        y: Style = .none,
    };

    handle: ?zss.Images.Handle = null,
    position: Position = .{ .x = 0, .y = 0 },
    size: Size = .{ .w = 0, .h = 0 },
    repeat: Repeat = .{},
    origin: Origin = .padding,
    clip: BackgroundClip = .border,
};

pub const BlockType = union(enum) {
    block,
    ifc_container: InlineFormattingContextId,
    subtree_proxy: Subtree.Id,
};

pub const BlockRef = struct {
    subtree: Subtree.Id,
    index: Subtree.Size,
};

pub const Subtree = struct {
    id: Subtree.Id,
    parent: ?BlockRef,
    blocks: List = .{},

    pub const Size = u16;
    pub const Id = enum(u16) { _ };

    pub const List = MultiArrayList(struct {
        skip: Size,
        type: BlockType,
        stacking_context: ?StackingContext.Id,
        box_offsets: BoxOffsets,
        borders: Borders,
        margins: Margins,
        insets: Insets,
        border_colors: BorderColor,
        background: BlockBoxBackground,
    });
    pub const View = List.Slice;

    pub fn deinit(subtree: *Subtree, allocator: Allocator) void {
        subtree.blocks.deinit(allocator);
    }

    pub const Iterator = struct {
        current: Size,
        end: Size,

        pub fn next(it: *Iterator, v: View) ?Size {
            if (it.current == it.end) return null;
            defer it.current += v.items(.skip)[it.current];
            return it.current;
        }
    };

    fn root(v: View) Iterator {
        return .{ .current = 0, .end = v.items(.skip)[0] };
    }

    fn children(v: View, index: Size) Iterator {
        return .{ .current = index + 1, .end = index + v.items(.skip)[index] };
    }

    pub fn view(subtree: Subtree) View {
        return subtree.blocks.slice();
    }

    pub fn size(subtree: Subtree) Size {
        return @intCast(subtree.blocks.len);
    }

    pub fn ensureTotalCapacity(subtree: *Subtree, allocator: Allocator, capacity: Size) !void {
        try subtree.blocks.ensureTotalCapacity(allocator, capacity);
    }

    pub fn appendBlock(subtree: *Subtree, allocator: Allocator) !Size {
        const new_size = std.math.add(Size, subtree.size(), 1) catch return error.TooManyBlocks;
        assert(new_size - 1 == try subtree.blocks.addOne(allocator));
        return new_size - 1;
    }

    pub fn setIfcContainer(
        subtree: *Subtree,
        ifc: InlineFormattingContextId,
        index: Size,
        skip: Size,
        y_pos: ZssUnit,
        width: ZssUnit,
        height: ZssUnit,
    ) void {
        const v = subtree.view();
        v.items(.skip)[index] = skip;
        v.items(.type)[index] = .{ .ifc_container = ifc };
        v.items(.stacking_context)[index] = null;
        v.items(.box_offsets)[index] = .{
            .border_pos = .{ .x = 0, .y = y_pos },
            .border_size = .{ .w = width, .h = height },
            .content_pos = .{ .x = 0, .y = 0 },
            .content_size = .{ .w = width, .h = height },
        };
    }

    pub fn setSubtreeProxy(
        subtree: *Subtree,
        index: Size,
        proxied_subtree: Id,
    ) void {
        const v = subtree.view();
        v.items(.skip)[index] = 1;
        v.items(.type)[index] = .{ .subtree_proxy = proxied_subtree };
        v.items(.stacking_context)[index] = null;
    }
};

pub const BlockBoxTree = struct {
    subtrees: ArrayListUnmanaged(*Subtree) = .{},
    initial_containing_block: BlockRef = undefined,

    fn deinit(blocks: *BlockBoxTree, allocator: Allocator) void {
        for (blocks.subtrees.items) |tree| {
            tree.deinit(allocator);
            allocator.destroy(tree);
        }
        blocks.subtrees.deinit(allocator);
    }

    pub fn subtree(blocks: BlockBoxTree, id: Subtree.Id) *Subtree {
        return blocks.subtrees.items[@intFromEnum(id)];
    }

    pub fn makeSubtree(blocks: *BlockBoxTree, allocator: Allocator) !*Subtree {
        const id: Subtree.Id = @enumFromInt(blocks.subtrees.items.len);
        const tree_ptr = try blocks.subtrees.addOne(allocator);
        errdefer _ = blocks.subtrees.pop();
        const tree = try allocator.create(Subtree);
        tree_ptr.* = tree;
        tree.* = .{ .id = id, .parent = null };
        return tree;
    }
};

pub const InlineBoxIndex = u16;
pub const InlineBoxSkip = InlineBoxIndex;
pub const InlineFormattingContextId = enum(u16) { _ };

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
    id: InlineFormattingContextId,
    parent_block: BlockRef,

    glyph_indeces: ArrayListUnmanaged(GlyphIndex) = .{},
    metrics: ArrayListUnmanaged(Metrics) = .{},

    line_boxes: ArrayListUnmanaged(LineBox) = .{},

    // zss is currently limited with what it can do with text. As a result,
    // font and font color will be the same for all glyphs, and
    // ascender and descender will be the same for all line boxes.
    // NOTE: The descender is a positive value.
    font: zss.Fonts.Handle = .invalid,
    font_color: Color = undefined,
    ascender: ZssUnit = undefined,
    descender: ZssUnit = undefined,

    inline_boxes: InlineBoxList = .{},

    pub const InlineBoxList = MultiArrayList(struct {
        skip: InlineBoxSkip,
        inline_start: BoxProperties,
        inline_end: BoxProperties,
        block_start: BoxProperties,
        block_end: BoxProperties,
        background: InlineBoxBackground,
        margins: MarginsInline,
        insets: Insets,
    });
    pub const Slice = InlineBoxList.Slice;

    const hb = @import("mach-harfbuzz").c;

    pub const GlyphIndex = hb.hb_codepoint_t;

    pub const BoxProperties = struct {
        border: ZssUnit = 0,
        padding: ZssUnit = 0,
        border_color: Color = Color.transparent,
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
        // TODO: Make this non-optional
        inline_box: ?InlineBoxIndex,
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
            return @bitCast(encoded_glyph_index);
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
            for (std.meta.fields(Kind)) |field| {
                assert(field.value != 0);
                assert(std.mem.eql(u8, field.name, @tagName(@as(LayoutInternalKind, @enumFromInt(field.value)))));
            }
        }

        pub fn encodeBoxStart(index: InlineBoxIndex) GlyphIndex {
            return @bitCast(Special{ .kind = .BoxStart, .data = index });
        }

        pub fn encodeBoxEnd(index: InlineBoxIndex) GlyphIndex {
            return @bitCast(Special{ .kind = .BoxEnd, .data = index });
        }

        pub fn encodeInlineBlock(index: Subtree.Size) GlyphIndex {
            return @bitCast(Special{ .kind = .InlineBlock, .data = index });
        }

        pub fn encodeZeroGlyphIndex() GlyphIndex {
            return @bitCast(Special{ .kind = .ZeroGlyphIndex, .data = undefined });
        }

        pub fn encodeLineBreak() GlyphIndex {
            return @bitCast(Special{ .kind = @as(Kind, @enumFromInt(@intFromEnum(LayoutInternalKind.LineBreak))), .data = undefined });
        }
    };

    pub fn deinit(ifc: *InlineFormattingContext, allocator: Allocator) void {
        ifc.glyph_indeces.deinit(allocator);
        ifc.metrics.deinit(allocator);
        ifc.line_boxes.deinit(allocator);
        ifc.inline_boxes.deinit(allocator);
    }

    pub fn numInlineBoxes(ifc: InlineFormattingContext) InlineBoxSkip {
        return @intCast(ifc.inline_boxes.len);
    }

    pub fn slice(ifc: InlineFormattingContext) Slice {
        return ifc.inline_boxes.slice();
    }

    pub fn ensureTotalCapacity(ifc: *InlineFormattingContext, allocator: Allocator, count: usize) !void {
        ifc.inline_boxes.ensureTotalCapacity(allocator, count);
    }

    pub fn appendInlineBox(ifc: *InlineFormattingContext, allocator: Allocator) !InlineBoxIndex {
        const new_size = std.math.add(InlineBoxIndex, ifc.numInlineBoxes(), 1) catch return error.TooManyInlineBoxes;
        assert(new_size - 1 == try ifc.inline_boxes.addOne(allocator));
        return new_size - 1;
    }
};

pub const ZIndex = i32;

pub const StackingContext = struct {
    pub const Index = u16;
    pub const Skip = Index;
    pub const Id = enum(u16) { _ };

    skip: Skip,
    /// A unique identifier.
    id: Id,
    /// The z-index of this stacking context.
    z_index: ZIndex,
    /// The block box that created this stacking context.
    ref: BlockRef,
    /// The list of inline formatting contexts contained within this stacking context.
    ifcs: ArrayListUnmanaged(InlineFormattingContextId),
};

pub const StackingContextTree = MultiArrayList(StackingContext);

/// The type of box(es) that an element generates.
pub const GeneratedBox = union(enum) {
    /// The element generated a single block box.
    block_ref: BlockRef,
    /// The element generated a single inline box.
    inline_box: struct { ifc_id: InlineFormattingContextId, index: InlineBoxIndex },
    /// The element generated text.
    text: InlineFormattingContextId,
};

pub const BackgroundImages = struct {
    pub const Handle = enum(u32) {
        invalid = 0,
        _,
    };

    const Slice = struct {
        begin: u32,
        end: u32,
    };

    slices: ArrayListUnmanaged(Slice) = .{},
    images: ArrayListUnmanaged(BackgroundImage) = .{},

    pub fn deinit(self: *BackgroundImages, allocator: Allocator) void {
        self.slices.deinit(allocator);
        self.images.deinit(allocator);
    }

    pub fn alloc(self: *BackgroundImages, allocator: Allocator, count: u32) !struct { Handle, []BackgroundImage } {
        try self.slices.ensureUnusedCapacity(allocator, 1);
        const begin: u32 = @intCast(self.images.items.len);
        const images = try self.images.addManyAsSlice(allocator, count);
        self.slices.appendAssumeCapacity(.{ .begin = begin, .end = begin + count });
        const handle: Handle = @enumFromInt(self.slices.items.len);
        return .{ handle, images };
    }

    pub fn get(self: BackgroundImages, handle: Handle) ?[]const BackgroundImage {
        if (handle == .invalid) return null;
        const slice = self.slices.items[@intFromEnum(handle) - 1];
        return self.images.items[slice.begin..slice.end];
    }
};

/// The result of layout.
pub const BoxTree = struct {
    blocks: BlockBoxTree = .{},
    ifcs: ArrayListUnmanaged(*InlineFormattingContext) = .{},
    stacking_contexts: StackingContextTree = .{},
    element_to_generated_box: ElementHashMap(GeneratedBox) = .{},
    background_images: BackgroundImages = .{},
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.blocks.deinit(self.allocator);
        for (self.ifcs.items) |ctx| {
            ctx.deinit(self.allocator);
            self.allocator.destroy(ctx);
        }
        self.ifcs.deinit(self.allocator);
        for (self.stacking_contexts.items(.ifcs)) |*ifc_list| {
            ifc_list.deinit(self.allocator);
        }
        self.stacking_contexts.deinit(self.allocator);
        self.element_to_generated_box.deinit(self.allocator);
        self.background_images.deinit(self.allocator);
    }

    pub fn mapElementToBox(box_tree: *BoxTree, element: Element, generated_box: GeneratedBox) !void {
        try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);
    }

    pub fn ifc(box_tree: BoxTree, id: InlineFormattingContextId) *InlineFormattingContext {
        return box_tree.ifcs.items[@intFromEnum(id)];
    }

    pub fn makeIfc(box_tree: *BoxTree, parent_block: BlockRef) !*InlineFormattingContext {
        const id = std.math.cast(std.meta.Tag(InlineFormattingContextId), box_tree.ifcs.items.len) orelse return error.TooManyIfcs;
        try box_tree.ifcs.ensureUnusedCapacity(box_tree.allocator, 1);
        const ptr = try box_tree.allocator.create(InlineFormattingContext);
        box_tree.ifcs.appendAssumeCapacity(ptr);
        ptr.* = .{ .id = @enumFromInt(id), .parent_block = parent_block };
        return ptr;
    }

    pub fn print(box_tree: BoxTree, writer: std.io.AnyWriter, allocator: Allocator) !void {
        var stack = zss.util.Stack(struct {
            iterator: Subtree.Iterator,
            subtree: Subtree.View,
        }){};
        defer stack.deinit(allocator);

        {
            const icb = box_tree.blocks.initial_containing_block;
            const subtree = box_tree.blocks.subtree(icb.subtree).view();
            try printBlock(subtree, icb.index, writer);
            stack.top = .{ .iterator = Subtree.children(subtree, icb.index), .subtree = subtree };
        }

        while (stack.top) |*top| {
            const index = top.iterator.next(top.subtree) orelse {
                _ = stack.pop();
                continue;
            };
            try writer.writeByteNTimes(' ', stack.len() * 4);
            try printBlock(top.subtree, index, writer);

            switch (top.subtree.items(.type)[index]) {
                .subtree_proxy => |subtree_id| {
                    const subtree = box_tree.blocks.subtree(subtree_id).view();
                    try writer.writeByteNTimes(' ', stack.len() * 4);
                    try writer.print("Subtree({}) size ({})\n", .{ @intFromEnum(subtree_id), subtree.len });
                    try stack.push(allocator, .{ .iterator = Subtree.root(subtree), .subtree = subtree });
                },
                else => try stack.push(allocator, .{ .iterator = Subtree.children(top.subtree, index), .subtree = top.subtree }),
            }
        }
    }

    pub fn printUnstructured(box_tree: BoxTree, writer: std.io.AnyWriter) !void {
        for (box_tree.blocks.subtrees.items) |subtree| {
            try writer.print("Subtree({}) size ({})\n", .{ @intFromEnum(subtree.id), subtree.blocks.len });

            const view = subtree.view();
            for (0..view.len) |i| {
                try printBlock(view, @intCast(i), writer);
            }

            try writer.writeAll("\n");
        }
    }

    fn printBlock(subtree: Subtree.View, index: Subtree.Size, writer: std.io.AnyWriter) !void {
        try writer.print("[{}, {}) ", .{ index, index + subtree.items(.skip)[index] });

        switch (subtree.items(.type)[index]) {
            .block => try writer.writeAll("block "),
            .ifc_container => |ifc_index| try writer.print("ifc_container({}) ", .{ifc_index}),
            .subtree_proxy => |subtree_id| {
                try writer.print("subtree_proxy({})\n", .{@intFromEnum(subtree_id)});
                return;
            },
        }

        if (subtree.items(.stacking_context)[index]) |sc_id| try writer.print("stacking_context({}) ", .{@intFromEnum(sc_id)});

        const bo = subtree.items(.box_offsets)[index];
        try writer.print("border_rect({}, {}, {}, {}) ", .{ bo.border_pos.x, bo.border_pos.y, bo.border_size.w, bo.border_size.h });
        try writer.print("content_rect({}, {}, {}, {})\n", .{ bo.content_pos.x, bo.content_pos.y, bo.content_size.w, bo.content_size.h });
    }
};
