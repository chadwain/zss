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

subtrees: ArrayListUnmanaged(*Subtree) = .{},
initial_containing_block: BlockRef = undefined, // TODO: make this `?BlockRef`
ifcs: ArrayListUnmanaged(*InlineFormattingContext) = .{},
sct: StackingContextTree = .{},
element_to_generated_box: ElementHashMap(GeneratedBox) = .{},
background_images: BackgroundImages = .{},
allocator: Allocator,
debug: Debug = .{},

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
    for (box_tree.subtrees.items) |subtree| {
        subtree.deinit(box_tree.allocator);
        box_tree.allocator.destroy(subtree);
    }
    box_tree.subtrees.deinit(box_tree.allocator);
    for (box_tree.ifcs.items) |ctx| {
        ctx.deinit(box_tree.allocator);
        box_tree.allocator.destroy(ctx);
    }
    box_tree.ifcs.deinit(box_tree.allocator);
    for (box_tree.sct.view().items(.ifcs)) |*ifc_list| {
        ifc_list.deinit(box_tree.allocator);
    }
    box_tree.sct.deinit(box_tree.allocator);
    box_tree.element_to_generated_box.deinit(box_tree.allocator);
    box_tree.background_images.deinit(box_tree.allocator);
}

pub fn getIfc(box_tree: *const BoxTree, id: InlineFormattingContext.Id) *InlineFormattingContext {
    return box_tree.ifcs.items[@intFromEnum(id)];
}

pub fn getSubtree(box_tree: *const BoxTree, id: Subtree.Id) *Subtree {
    return box_tree.subtrees.items[@intFromEnum(id)];
}

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
    left: math.Color = .transparent,
    right: math.Color = .transparent,
    top: math.Color = .transparent,
    bottom: math.Color = .transparent,
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
    color: math.Color = .transparent,
    clip: BackgroundClip = .border,
};

pub const BlockBoxBackground = struct {
    color: math.Color = .transparent,
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
    ifc_container: InlineFormattingContext.Id,
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
        offset: math.Vector,
        box_offsets: BoxOffsets,
        borders: Borders,
        margins: Margins,
        insets: Insets,
        border_colors: BorderColor,
        background: BlockBoxBackground,
    });
    pub const View = List.Slice;

    fn deinit(subtree: *Subtree, allocator: Allocator) void {
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

    pub fn view(subtree: *const Subtree) View {
        return subtree.blocks.slice();
    }

    pub fn size(subtree: *const Subtree) Size {
        return @intCast(subtree.blocks.len);
    }
};

/// An inline formatting context is a sequence of line boxes.
/// Within each line box is a sequence of glyphs and other objects.
/// Every glyph is represented by a glyph index.
///
/// To represent objects other than glyphs, the glyph index 0 is reserved.
/// When a glyph index of 0 is found in a sequence of glyphs, it will always be succeeded by an encoded glyph,
/// which must be reinterpreted (use `@bitCast`) as a `Special`.
/// The `metrics` data for an encoded glyph is found together with the 0 glyph index.
pub const InlineFormattingContext = struct {
    id: Id,
    parent_block: BlockRef,

    glyphs: MultiArrayList(struct {
        index: GlyphIndex,
        metrics: Metrics,
    }) = .{},

    line_boxes: ArrayListUnmanaged(LineBox) = .{},

    font: zss.Fonts.Handle = .invalid,
    font_color: math.Color = undefined,
    ascender: math.Unit = undefined,
    /// This is a positive value.
    descender: math.Unit = undefined,

    inline_boxes: InlineBoxList = .{},

    pub const Size = u16;
    pub const Id = enum(u16) { _ };

    pub const InlineBoxList = MultiArrayList(struct {
        skip: Size,
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
        border_color: math.Color = .transparent,
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
        // TODO: Stop using usize
        elements: [2]usize,
        /// The inline box that starts this line box.
        // TODO: Make this non-optional
        inline_box: ?Size,
    };

    pub const Special = extern struct {
        kind: Kind,
        data: u16,

        // This must start at 1 to make the Special struct never have a bit representation of 0.
        pub const Kind = enum(u16) {
            /// Represents a glyph index of 0.
            /// data has no meaning.
            ZeroGlyphIndex = 1,
            /// Represents an inline box's start fragment.
            /// data is the index of the box.
            BoxStart,
            /// Represents an inline box's end fragment.
            /// data is the index of the box.
            BoxEnd,
            /// Represents an inline block.
            /// data is the index of the block box.
            InlineBlock,
            /// Any other value of this enum should never appear in an end user's code.
            _,
        };

        comptime {
            for (std.meta.fields(Kind)) |field| {
                assert(field.value != 0);
            }
        }

        /// Recovers the data contained within a glyph index.
        pub fn decode(encoded: GlyphIndex) Special {
            return @bitCast(encoded);
        }
    };

    fn deinit(ifc: *InlineFormattingContext, allocator: Allocator) void {
        ifc.glyphs.deinit(allocator);
        ifc.line_boxes.deinit(allocator);
        ifc.inline_boxes.deinit(allocator);
    }

    pub fn numInlineBoxes(ifc: *const InlineFormattingContext) Size {
        return @intCast(ifc.inline_boxes.len);
    }

    pub fn slice(ifc: *const InlineFormattingContext) Slice {
        return ifc.inline_boxes.slice();
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
    ifcs: ArrayListUnmanaged(InlineFormattingContext.Id),
};

pub const StackingContextTree = struct {
    list: List = .{},
    debug: StackingContextTree.Debug = .{},

    pub const Size = u16;
    pub const Id = enum(u16) { _ };
    const List = MultiArrayList(StackingContext);
    pub const View = List.Slice;

    fn deinit(sct: *StackingContextTree, allocator: Allocator) void {
        sct.list.deinit(allocator);
    }

    pub fn view(sct: *const StackingContextTree) View {
        return sct.list.slice();
    }

    pub const Debug = struct {
        pub fn print(debug: *const StackingContextTree.Debug, writer: std.io.AnyWriter, allocator: Allocator) !void {
            const sct: *const StackingContextTree = @alignCast(@fieldParentPtr("debug", debug));
            const Context = struct {
                view: View,
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
    };
};

/// The type of box(es) that an element generates.
pub const GeneratedBox = union(enum) {
    /// The element generated a single block box.
    block_ref: BlockRef,
    /// The element generated a single inline box.
    inline_box: struct { ifc_id: InlineFormattingContext.Id, index: InlineFormattingContext.Size },
    /// The element generated text.
    text: InlineFormattingContext.Id,
};

pub const BackgroundImages = struct {
    pub const Size = u32;
    pub const Handle = enum(Size) {
        invalid = 0,
        _,
    };

    const Slice = struct {
        begin: Size,
        end: Size,
    };

    slices: ArrayListUnmanaged(Slice) = .{},
    images: ArrayListUnmanaged(BackgroundImage) = .{},

    fn deinit(self: *BackgroundImages, allocator: Allocator) void {
        self.slices.deinit(allocator);
        self.images.deinit(allocator);
    }

    pub fn get(self: *const BackgroundImages, handle: Handle) ?[]const BackgroundImage {
        if (handle == .invalid) return null;
        const slice = self.slices.items[@intFromEnum(handle) - 1];
        return self.images.items[slice.begin..slice.end];
    }
};

pub const Debug = struct {
    pub fn print(debug: *const Debug, writer: std.io.AnyWriter, allocator: Allocator) !void {
        const box_tree: *const BoxTree = @alignCast(@fieldParentPtr("debug", debug));
        try box_tree.debug.printBlocks(writer, allocator);
        try writer.writeAll("\n");
        try box_tree.sct.debug.print(writer, allocator);
    }

    pub fn printBlocks(debug: *const Debug, writer: std.io.AnyWriter, allocator: Allocator) !void {
        const box_tree: *const BoxTree = @alignCast(@fieldParentPtr("debug", debug));
        var stack = zss.Stack(struct {
            iterator: Subtree.Iterator,
            view: Subtree.View,
        }){};
        defer stack.deinit(allocator);

        {
            const icb = box_tree.initial_containing_block;
            const view = box_tree.getSubtree(icb.subtree).view();
            try printBlock(view, icb.index, writer);
            stack.top = .{ .iterator = Subtree.children(view, icb.index), .view = view };
        }

        while (stack.top) |*top| {
            const index = top.iterator.next(top.view) orelse {
                _ = stack.pop();
                continue;
            };
            try writer.writeByteNTimes(' ', stack.len() * 4);
            try printBlock(top.view, index, writer);

            switch (top.view.items(.type)[index]) {
                .subtree_proxy => |subtree_id| {
                    const view = box_tree.getSubtree(subtree_id).view();
                    try writer.writeByteNTimes(' ', stack.len() * 4);
                    try writer.print("Subtree({}) size({})\n", .{ @intFromEnum(subtree_id), view.len });
                    try stack.push(allocator, .{ .iterator = Subtree.root(view), .view = view });
                },
                else => try stack.push(allocator, .{ .iterator = Subtree.children(top.view, index), .view = top.view }),
            }
        }
    }

    fn printBlock(subtree: Subtree.View, index: Subtree.Size, writer: std.io.AnyWriter) !void {
        try writer.print("[{}, {}) ", .{ index, index + subtree.items(.skip)[index] });

        switch (subtree.items(.type)[index]) {
            .block => try writer.writeAll("block "),
            .ifc_container => |ifc_index| try writer.print("ifc_container({}) ", .{ifc_index}),
            .subtree_proxy => |subtree_id| try writer.print("subtree_proxy({}) ", .{@intFromEnum(subtree_id)}),
        }

        if (subtree.items(.stacking_context)[index]) |sc_id| try writer.print("stacking_context({}) ", .{@intFromEnum(sc_id)});

        const offset = subtree.items(.offset)[index];
        const bo = subtree.items(.box_offsets)[index];
        try writer.print("offset({}, {}) ", .{ offset.x, offset.y });
        try writer.print("border_rect({}, {}, {}, {}) ", .{ bo.border_pos.x, bo.border_pos.y, bo.border_size.w, bo.border_size.h });
        try writer.print("content_rect({}, {}, {}, {})\n", .{ bo.content_pos.x, bo.content_pos.y, bo.content_size.w, bo.content_size.h });
    }
};
