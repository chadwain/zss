const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

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

pub const ZssFlowRelativeVector = struct {
    inline_dir: ZssUnit,
    block_dir: ZssUnit,
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
    border_start: ZssFlowRelativeVector,
    border_end: ZssFlowRelativeVector,
    content_start: ZssFlowRelativeVector,
    content_end: ZssFlowRelativeVector,
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

/// Contains information about a set of block boxes.
/// Block boxes form a hierarchy, and therefore a tree structure, which is represented here.
pub const BlockLevelUsedValues = struct {
    // A "used id" is an index into the following arrays.
    // To know how to use the "structure" field and the group of fields following it,
    // see the explanation in BoxTree. It works in exactly the same way.
    structure: []UsedId,
    box_offsets: []BoxOffsets,
    borders: []Borders,
    border_colors: []BorderColor,
    background1: []Background1,
    background2: []Background2,
    // End of the "used id" indexed arrays.

    /// Inline data that is the contents of a block box.
    inline_values: []InlineValues,

    pub const InlineValues = struct {
        values: *InlineLevelUsedValues,
        id_of_containing_block: UsedId,
    };

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.structure);
        allocator.free(self.box_offsets);
        allocator.free(self.borders);
        allocator.free(self.border_colors);
        allocator.free(self.background1);
        allocator.free(self.background2);
        for (self.inline_values) |*inl| {
            inl.values.deinit(allocator);
            allocator.destroy(inl.values);
        }
        allocator.free(self.inline_values);
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
    glyph_indeces: []hb.hb_codepoint_t,
    metrics: []Metrics,

    line_boxes: []LineBox,

    // zss is currently limited with what it can do with text. As a result,
    // font and font color will be the same for all glyphs, and
    // ascender and descender will be the same for all line boxes.
    font: *hb.hb_font_t,
    font_color_rgba: u32,
    ascender: ZssUnit,
    descender: ZssUnit,

    // A "used id" is an index into the following arrays.
    inline_start: []BoxProperties,
    inline_end: []BoxProperties,
    block_start: []BoxProperties,
    block_end: []BoxProperties,
    background1: []Background1,
    // End of the "used id" indexed arrays.

    const hb = @import("harfbuzz");

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
            /// Any other value of this enum should never appear in an end user's code.
            _,
        };

        /// Recovers the data contained within a glyph index.
        pub fn decode(encoded_glyph_index: hb.hb_codepoint_t) Special {
            return @bitCast(Special, encoded_glyph_index);
        }

        // End users should not concern themselves with anything below this comment.

        pub const LayoutInternalKind = extern enum(u16) {
            // The explanations for some of these are above.
            ZeroGlyphIndex = 1,
            BoxStart,
            BoxEnd,
            /// Represents a mandatory line break in the text.
            /// data has no meaning.
            LineBreak,
        };

        comptime {
            for (std.meta.fields(Kind)) |f| {
                std.debug.assert(std.mem.eql(u8, f.name, @tagName(@intToEnum(LayoutInternalKind, f.value))));
            }
        }

        pub fn encodeBoxStart(used_id: UsedId) hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .kind = .BoxStart, .data = used_id });
        }

        pub fn encodeBoxEnd(used_id: UsedId) hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .kind = .BoxEnd, .data = used_id });
        }

        pub fn encodeZeroGlyphIndex() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .kind = .ZeroGlyphIndex, .data = undefined });
        }

        pub fn encodeLineBreak() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .kind = @intToEnum(Kind, @enumToInt(LayoutInternalKind.LineBreak)), .data = undefined });
        }
    };

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.glyph_indeces);
        allocator.free(self.metrics);
        allocator.free(self.line_boxes);
        allocator.free(self.inline_start);
        allocator.free(self.inline_end);
        allocator.free(self.block_start);
        allocator.free(self.block_end);
        allocator.free(self.background1);
    }
};

/// The final result of layout.
pub const Document = struct {
    block_values: BlockLevelUsedValues,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.block_values.deinit(allocator);
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
