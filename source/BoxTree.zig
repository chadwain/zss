//! The result of layout.
const BoxTree = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const MultiArrayList = std.MultiArrayList;

const zss = @import("zss.zig");
const math = zss.math;
const Element = zss.ElementTree.Element;

blocks: BlockBoxTree = .{},
ifcs: ArrayListUnmanaged(*InlineFormattingContext) = .{},
stacking_contexts: StackingContextTree = .{},
element_to_generated_box: ElementHashMap(GeneratedBox) = .{},
background_images: BackgroundImages = .{},
allocator: Allocator,

fn ElementHashMap(comptime V: type) type {
    const Context = struct {
        pub fn eql(_: @This(), lhs: Element, rhs: Element) bool {
            return lhs.eql(rhs);
        }
        pub const hash = std.hash_map.getAutoHashFn(Element, @This());
    };
    return std.HashMapUnmanaged(Element, V, Context, std.hash_map.default_max_load_percentage);
}

pub fn deinit(box_tree: *BoxTree) void {
    box_tree.blocks.deinit(box_tree.allocator);
    for (box_tree.ifcs.items) |ctx| {
        ctx.deinit(box_tree.allocator);
        box_tree.allocator.destroy(ctx);
    }
    box_tree.ifcs.deinit(box_tree.allocator);
    for (box_tree.stacking_contexts.view().items(.ifcs)) |*ifc_list| {
        ifc_list.deinit(box_tree.allocator);
    }
    box_tree.stacking_contexts.deinit(box_tree.allocator);
    box_tree.element_to_generated_box.deinit(box_tree.allocator);
    box_tree.background_images.deinit(box_tree.allocator);
}

pub fn mapElementToBox(box_tree: *BoxTree, element: Element, generated_box: GeneratedBox) !void {
    try box_tree.element_to_generated_box.putNoClobber(box_tree.allocator, element, generated_box);
}

pub fn getIfc(box_tree: BoxTree, id: InlineFormattingContextId) *InlineFormattingContext {
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

pub fn print(box_tree: *const BoxTree, writer: std.io.AnyWriter, allocator: Allocator) !void {
    try box_tree.blocks.print(writer, allocator);
    try writer.writeAll("\n");
    try printStackingContextTree(&box_tree.stacking_contexts, writer, allocator);
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
    border_pos: math.Vector = .{ .x = 0, .y = 0 },
    /// The width and height of the border box.
    border_size: math.Size = .{ .w = 0, .h = 0 },
    /// The offset of the top-left corner of the content box, relative to
    /// the top-left corner of this block's border box.
    content_pos: math.Vector = .{ .x = 0, .y = 0 },
    /// The width and height of the content box.
    content_size: math.Size = .{ .w = 0, .h = 0 },
};

pub const Borders = struct {
    left: math.Unit = 0,
    right: math.Unit = 0,
    top: math.Unit = 0,
    bottom: math.Unit = 0,
};

pub const BorderColor = struct {
    left: Color = Color.transparent,
    right: Color = Color.transparent,
    top: Color = Color.transparent,
    bottom: Color = Color.transparent,
};

pub const Margins = struct {
    left: math.Unit = 0,
    right: math.Unit = 0,
    top: math.Unit = 0,
    bottom: math.Unit = 0,
};

pub const Insets = math.Vector;

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
    pub const Position = math.Vector;
    pub const Size = math.Size;
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
        stacking_context: ?StackingContextTree.Id,
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

    fn printBlock(subtree: Subtree.View, index: Subtree.Size, writer: std.io.AnyWriter) !void {
        try writer.print("[{}, {}) ", .{ index, index + subtree.items(.skip)[index] });

        switch (subtree.items(.type)[index]) {
            .block => try writer.writeAll("block "),
            .ifc_container => |ifc_index| try writer.print("ifc_container({}) ", .{ifc_index}),
            .subtree_proxy => |subtree_id| try writer.print("subtree_proxy({}) ", .{@intFromEnum(subtree_id)}),
        }

        if (subtree.items(.stacking_context)[index]) |sc_id| try writer.print("stacking_context({}) ", .{@intFromEnum(sc_id)});

        const bo = subtree.items(.box_offsets)[index];
        try writer.print("border_rect({}, {}, {}, {}) ", .{ bo.border_pos.x, bo.border_pos.y, bo.border_size.w, bo.border_size.h });
        try writer.print("content_rect({}, {}, {}, {})\n", .{ bo.content_pos.x, bo.content_pos.y, bo.content_size.w, bo.content_size.h });
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

    pub fn print(block_box_tree: *const BlockBoxTree, writer: std.io.AnyWriter, allocator: Allocator) !void {
        var stack = zss.Stack(struct {
            iterator: Subtree.Iterator,
            view: Subtree.View,
        }){};
        defer stack.deinit(allocator);

        {
            const icb = block_box_tree.initial_containing_block;
            const view = block_box_tree.subtree(icb.subtree).view();
            try Subtree.printBlock(view, icb.index, writer);
            stack.top = .{ .iterator = Subtree.children(view, icb.index), .view = view };
        }

        while (stack.top) |*top| {
            const index = top.iterator.next(top.view) orelse {
                _ = stack.pop();
                continue;
            };
            try writer.writeByteNTimes(' ', stack.len() * 4);
            try Subtree.printBlock(top.view, index, writer);

            switch (top.view.items(.type)[index]) {
                .subtree_proxy => |subtree_id| {
                    const view = block_box_tree.subtree(subtree_id).view();
                    try writer.writeByteNTimes(' ', stack.len() * 4);
                    try writer.print("Subtree({}) size({})\n", .{ @intFromEnum(subtree_id), view.len });
                    try stack.push(allocator, .{ .iterator = Subtree.root(view), .view = view });
                },
                else => try stack.push(allocator, .{ .iterator = Subtree.children(top.view, index), .view = top.view }),
            }
        }
    }

    pub fn printUnstructured(block_box_tree: *const BlockBoxTree, writer: std.io.AnyWriter) !void {
        for (block_box_tree.subtrees.items) |s| {
            try writer.print("Subtree({}) size({})\n", .{ @intFromEnum(s.id), s.blocks.len });

            const view = s.view();
            for (0..view.len) |i| {
                try Subtree.printBlock(view, @intCast(i), writer);
            }

            try writer.writeAll("\n");
        }
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
    ascender: math.Unit = undefined,
    descender: math.Unit = undefined,

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
        border: math.Unit = 0,
        padding: math.Unit = 0,
        border_color: Color = Color.transparent,
    };

    pub const Metrics = struct {
        offset: math.Unit,
        advance: math.Unit,
        width: math.Unit,
    };

    pub const MarginsInline = struct {
        start: math.Unit = 0,
        end: math.Unit = 0,
    };

    pub const LineBox = struct {
        /// The vertical distance from the top of the containing block to this line box's baseline.
        baseline: math.Unit,
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
    skip: StackingContextTree.Size,
    /// A unique identifier.
    id: StackingContextTree.Id,
    /// The z-index of this stacking context.
    z_index: ZIndex,
    /// The block box that created this stacking context.
    ref: BlockRef,
    /// The list of inline formatting contexts contained within this stacking context.
    ifcs: ArrayListUnmanaged(InlineFormattingContextId),
};

pub const StackingContextTree = struct {
    list: List = .{},

    pub const Size = u16;
    pub const Id = enum(u16) { _ };
    const List = MultiArrayList(StackingContext);
    pub const View = List.Slice;

    pub fn deinit(sct: *StackingContextTree, allocator: Allocator) void {
        sct.list.deinit(allocator);
    }

    pub fn view(sct: *const StackingContextTree) View {
        return sct.list.slice();
    }
};

pub fn printStackingContextTree(sct: *const StackingContextTree, writer: std.io.AnyWriter, allocator: Allocator) !void {
    const Size = StackingContextTree.Size;
    const Context = struct {
        view: StackingContextTree.View,
        writer: std.io.AnyWriter,
    };
    const callback = struct {
        fn f(ctx: Context, index: Size, depth: Size) !void {
            const item = ctx.view.get(index);
            try ctx.writer.writeByteNTimes(' ', depth * 4);
            try ctx.writer.print(
                "[{}, {}) id({}) z-index({}) ref({}) ifcs({any})\n",
                .{ index, index + item.skip, @intFromEnum(item.id), item.z_index, item.ref, item.ifcs.items },
            );
        }
    }.f;

    const context = Context{
        .view = sct.view(),
        .writer = writer,
    };
    try zss.debug.skipArrayIterate(Size, context.view.items(.skip), context, callback, allocator);
}

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
