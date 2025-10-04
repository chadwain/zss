const Test = @This();

const zss = @import("zss");

name: []const u8,
env: zss.Environment,
document: zss.zml.Document,
stylesheet: zss.Stylesheet,
images: *const zss.Images,
fonts: *const zss.Fonts,
font_handle: zss.Fonts.Handle,

width: u32 = 400,
height: u32 = 400,
