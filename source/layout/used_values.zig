const std = @import("std");
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

const zss = @import("../../zss.zig");

/// The fundamental unit of space used for all CSS layout computations in zss.
pub const CSSUnit = i32;

/// A floating point number usually between 0 and 1, but it can
/// exceed these values.
pub const Percentage = f32;

pub const Offset = struct {
    x: CSSUnit,
    y: CSSUnit,

    const Self = @This();
    pub fn add(lhs: Self, rhs: Self) Self {
        return Self{ .x = lhs.x + rhs.x, .y = lhs.y + rhs.y };
    }
};

pub const CSSSize = struct {
    w: CSSUnit,
    h: CSSUnit,
};

pub const CSSRect = struct {
    x: CSSUnit,
    y: CSSUnit,
    w: CSSUnit,
    h: CSSUnit,

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
    border_top_left: Offset,
    border_bottom_right: Offset,
    content_top_left: Offset,
    content_bottom_right: Offset,
};

/// Contains the used values of the properties 'border-top-width',
/// 'border-right-width', 'border-bottom-width', and 'border-left-width'.
pub const Borders = struct {
    top: CSSUnit = 0,
    right: CSSUnit = 0,
    bottom: CSSUnit = 0,
    left: CSSUnit = 0,
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
    pub const Position = struct { horizontal: CSSUnit = 0, vertical: CSSUnit = 0 };
    pub const Size = struct { width: CSSUnit = 0, height: CSSUnit = 0 };
    pub const Repeat = struct {
        pub const Style = enum { None, Repeat, Space, Round };
        x: Style = .None,
        y: Style = .None,
    };

    image: ?*zss.values.BackgroundImage.Data = null,
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

pub const BlockRenderingData = struct {
    pub const InlineData = struct {
        data: *InlineRenderingData,
        id_of_containing_block: UsedId,
    };

    pdfs_flat_tree: []UsedId,
    box_offsets: []BoxOffsets,
    borders: []Borders,
    border_colors: []BorderColor,
    background1: []Background1,
    background2: []Background2,
    //visual_effect: []VisualEffect,
    inline_data: []InlineData,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.pdfs_flat_tree);
        allocator.free(self.box_offsets);
        allocator.free(self.borders);
        allocator.free(self.border_colors);
        allocator.free(self.background1);
        allocator.free(self.background2);
        //allocator.free(self.visual_effect);
        for (self.inline_data) |*inl| {
            inl.data.deinit(allocator);
            allocator.destroy(inl.data);
        }
        allocator.free(self.inline_data);
    }
};

pub const InlineRenderingData = struct {
    const hb = @import("harfbuzz");

    //pub const BoxMeasures = struct {
    //    border: CSSUnit = 0,
    //    padding: CSSUnit = 0,
    //    border_color_rgba: u32 = 0,
    //};

    //pub const Heights = struct {
    //    above_baseline: CSSUnit,
    //    below_baseline: CSSUnit,
    //};

    pub const LineBox = struct {
        baseline: CSSUnit,
        elements: [2]usize,
    };

    // NOTE may need to make sure this is never a valid glyph index when bitcasted
    // NOTE Not making this an extern struct keeps crashing compiler
    pub const Special = extern struct {
        pub const glyph_index = 0xFFFF;
        pub const Meaning = extern enum(u16) { BoxStart, BoxEnd, LiteralFFFF, LineBreak };

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

        pub fn encodeLiteralFFFF() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = .LiteralFFFF, .data = undefined });
        }

        pub fn encodeLineBreak() hb.hb_codepoint_t {
            return @bitCast(hb.hb_codepoint_t, Special{ .meaning = .LineBreak, .data = undefined });
        }
    };

    pub const Position = struct {
        // NOTE It seems that offset is 0 almost all the time, maybe no need to record it.
        offset: CSSUnit,
        advance: CSSUnit,
        width: CSSUnit,
    };

    glyph_indeces: []hb.hb_codepoint_t,
    positions: []Position,
    line_boxes: []LineBox,
    font: *hb.hb_font_t,
    font_color_rgba: u32,

    pub fn deinit(self: *@This(), allocator: *Allocator) void {
        allocator.free(self.glyph_indeces);
        allocator.free(self.positions);
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
        p("positions\n", .{});
        i = 0;
        while (i < self.positions.len) : (i += 1) {
            const pos = self.positions[i];
            p("{}\n", .{pos});
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
    block_data: BlockRenderingData,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: *Allocator) void {
        self.block_data.deinit(allocator);
    }
};

test "CSSRect" {
    const r1 = CSSRect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const r2 = CSSRect{ .x = 3, .y = 5, .w = 17, .h = 4 };
    const r3 = CSSRect{ .x = 15, .y = 0, .w = 20, .h = 9 };
    const r4 = CSSRect{ .x = 20, .y = 1, .w = 10, .h = 0 };

    const intersect = CSSRect.intersect;
    try expect(std.meta.eql(intersect(r1, r2), CSSRect{ .x = 3, .y = 5, .w = 7, .h = 4 }));
    try expect(intersect(r1, r3).isEmpty());
    try expect(intersect(r1, r4).isEmpty());
    try expect(std.meta.eql(intersect(r2, r3), CSSRect{ .x = 15, .y = 5, .w = 5, .h = 4 }));
    try expect(intersect(r2, r4).isEmpty());
    try expect(intersect(r3, r4).isEmpty());
}
