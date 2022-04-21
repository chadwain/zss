const zss = @import("../../zss.zig");
const ReferencedSkipTree = zss.ReferencedSkipTree;

pub const ElementTree = ReferencedSkipTree(u16, u16, struct {});
