const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const ZssUnit = i32;

///The number of ZssUnits contained wthin 1 screen pixel.
pub const unitsPerPixel = 4;

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

    image: ?*zss.box_tree.Background.Image.Object.Data = null,
    position: Position = .{},
    size: Size = .{},
    repeat: Repeat = .{},
    origin: Origin = .Padding,
};

///// Contains the used value of the properties 'overflow' and 'visibility'.
//pub const VisualEffect = struct {
//    overflow: enum { Visible, Hidden } = .Visible,
//    visibility: enum { Visible, Hidden } = .Visible,
//};

pub const UsedId = u16;

pub const BlockLevelUsedValues = struct {
    pub const InlineValues = struct {
        values: *InlineLevelUsedValues,
        id_of_containing_block: UsedId,
    };

    structure: []UsedId,
    box_offsets: []BoxOffsets,
    borders: []Borders,
    border_colors: []BorderColor,
    background1: []Background1,
    background2: []Background2,
    //visual_effect: []VisualEffect,
    inline_values: []InlineValues,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.structure);
        allocator.free(self.box_offsets);
        allocator.free(self.borders);
        allocator.free(self.border_colors);
        allocator.free(self.background1);
        allocator.free(self.background2);
        //allocator.free(self.visual_effect);
        for (self.inline_values) |*inl| {
            inl.values.deinit(allocator);
            allocator.destroy(inl.values);
        }
        allocator.free(self.inline_values);
    }
};

pub const InlineLevelUsedValues = struct {
    const hb = @import("harfbuzz");

    pub const BoxProperties = struct {
        border: ZssUnit = 0,
        padding: ZssUnit = 0,
        border_color_rgba: u32 = 0,
    };

    //pub const Heights = struct {
    //    ascender: ZssUnit,
    //    descender: ZssUnit,
    //};

    pub const LineBox = struct {
        baseline: ZssUnit,
        elements: [2]usize,
    };

    // NOTE may need to make sure this is never a valid glyph index when bitcasted
    // NOTE Not making this an extern struct keeps crashing compiler
    pub const Special = extern struct {
        pub const glyph_index = 0;
        pub const Meaning = extern enum(u16) { LiteralGlyphIndex, BoxStart, BoxEnd, _ };
        pub const LayoutInternalMeaning = extern enum(u16) { LiteralGlyphIndex, BoxStart, BoxEnd, LineBreak };

        comptime {
            for (std.meta.fields(Meaning)) |f| {
                std.debug.assert(std.mem.eql(u8, f.name, @tagName(@intToEnum(LayoutInternalMeaning, f.value))));
            }
        }

        meaning: Meaning,
        data: u16,

        pub fn decode(encoded_glyph_index: hb.hb_codepoint_t) Special {
            return @bitCast(Special, encoded_glyph_index);
        }

        pub fn encodeBoxStart(used_id: UsedId) hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = .BoxStart, .data = used_id });
        }

        pub fn encodeBoxEnd(used_id: UsedId) hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = .BoxEnd, .data = used_id });
        }

        pub fn encodeLiteralGlyphIndex() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = .LiteralGlyphIndex, .data = undefined });
        }

        pub fn encodeLineBreak() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = @intToEnum(Meaning, @enumToInt(LayoutInternalMeaning.LineBreak)), .data = undefined });
        }
    };

    pub const Metrics = struct {
        // NOTE It seems that offset is 0 almost all the time, maybe no need to record it.
        offset: ZssUnit,
        advance: ZssUnit,
        width: ZssUnit,
    };

    glyph_indeces: []hb.hb_codepoint_t,
    metrics: []Metrics,
    line_boxes: []LineBox,
    font: *hb.hb_font_t,
    font_color_rgba: u32,

    inline_start: []BoxProperties,
    inline_end: []BoxProperties,
    block_start: []BoxProperties,
    block_end: []BoxProperties,
    background1: []Background1,
    ascender: ZssUnit,
    descender: ZssUnit,

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
