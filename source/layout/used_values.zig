const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const ZssUnit = i32;

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

/// The offsets of various points of a block box, taken from the top-left
/// corner of the content box of its parent.
pub const BoxOffsets = struct {
    border_top_left: ZssVector,
    border_bottom_right: ZssVector,
    content_top_left: ZssVector,
    content_bottom_right: ZssVector,
};

/// Contains the used values of the properties 'border-top-width',
/// 'border-right-width', 'border-bottom-width', and 'border-left-width'.
pub const Borders = struct {
    top: ZssUnit = 0,
    right: ZssUnit = 0,
    bottom: ZssUnit = 0,
    left: ZssUnit = 0,
};

/// Contains the used values of the properties 'border-top-color',
/// 'border-right-color', 'border-bottom-color', and 'border-left-color'.
pub const BorderColor = struct {
    top_rgba: u32 = 0,
    right_rgba: u32 = 0,
    bottom_rgba: u32 = 0,
    left_rgba: u32 = 0,
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
    pub const Position = struct { horizontal: ZssUnit = 0, vertical: ZssUnit = 0 };
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

    pdfs_flat_tree: []UsedId,
    box_offsets: []BoxOffsets,
    borders: []Borders,
    border_colors: []BorderColor,
    background1: []Background1,
    background2: []Background2,
    //visual_effect: []VisualEffect,
    inline_values: []InlineValues,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.pdfs_flat_tree);
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

    //pub const BoxMeasures = struct {
    //    border: ZssUnit = 0,
    //    padding: ZssUnit = 0,
    //    border_color_rgba: u32 = 0,
    //};

    //pub const Heights = struct {
    //    above_baseline: ZssUnit,
    //    below_baseline: ZssUnit,
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

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.glyph_indeces);
        allocator.free(self.metrics);
        allocator.free(self.line_boxes);
    }

    pub fn dump(self: *const @This()) void {
        const p = std.debug.print;
        p("\n", .{});
        p("glyphs\n", .{});
        var i: usize = 0;
        while (i < self.glyph_indeces.len) : (i += 1) {
            const gi = self.glyph_indeces[i];
            if (gi == Special.glyph_index) {
                i += 1;
                p("{}\n", .{Special.decode(self.glyph_indeces[i])});
            } else {
                p("{x}\n", .{gi});
            }
        }
        p("\n", .{});
        p("metrics\n", .{});
        i = 0;
        while (i < self.metrics.len) : (i += 1) {
            const metrics = self.metrics[i];
            p("{}\n", .{metrics});
            if (self.glyph_indeces[i] == Special.glyph_index) {
                i += 1;
            }
        }
        p("\n", .{});
        p("line boxes\n", .{});
        for (self.line_boxes) |l| {
            p("{}\n", .{l});
        }
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
