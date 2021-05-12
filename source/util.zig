const zss = @import("../zss.zig");
usingnamespace zss.types;
const used_values = zss.used_values;

pub fn getThreeBoxes(offset: used_values.Offset, box_offsets: used_values.BoxOffsets, borders: used_values.Borders) ThreeBoxes {
    const border_x = offset.x + box_offsets.border_top_left.x;
    const border_y = offset.y + box_offsets.border_top_left.y;
    const border_w = box_offsets.border_bottom_right.x - box_offsets.border_top_left.x;
    const border_h = box_offsets.border_bottom_right.y - box_offsets.border_top_left.y;

    return ThreeBoxes{
        .border = CSSRect{
            .x = border_x,
            .y = border_y,
            .w = border_w,
            .h = border_h,
        },
        .padding = CSSRect{
            .x = border_x + borders.left,
            .y = border_y + borders.top,
            .w = border_w - borders.left - borders.right,
            .h = border_h - borders.top - borders.bottom,
        },
        .content = CSSRect{
            .x = offset.x + box_offsets.content_top_left.x,
            .y = offset.y + box_offsets.content_top_left.y,
            .w = box_offsets.content_bottom_right.x - box_offsets.content_top_left.x,
            .h = box_offsets.content_bottom_right.y - box_offsets.content_top_left.y,
        },
    };
}

pub fn divCeil(comptime T: type, a: T, b: T) T {
    return @divFloor(a, b) + @boolToInt(@mod(a, b) != 0);
}

pub fn roundUp(comptime T: type, a: T, comptime multiple: comptime_int) T {
    const mod = @mod(a, multiple);
    return a + (multiple - mod) * @boolToInt(mod != 0);
}

test "roundUp" {
    const expect = @import("std").testing.expect;
    try expect(roundUp(usize, 0, 4) == 0);
    try expect(roundUp(usize, 1, 4) == 4);
    try expect(roundUp(usize, 3, 4) == 4);
    try expect(roundUp(usize, 62, 7) == 63);
}

pub const PdfsFlatTreeIterator = struct {
    items: []const u16,
    current: u16,
    index: u16,

    const Self = @This();

    pub fn init(items: []const u16, index: u16) Self {
        return Self{
            .items = items,
            .current = 0,
            .index = index,
        };
    }

    pub fn next(self: *Self) ?u16 {
        if (self.index < self.current) return null;
        while (self.index >= self.current + self.items[self.current]) {
            self.current += self.items[self.current];
        }
        defer self.current += 1;
        return self.current;
    }
};
