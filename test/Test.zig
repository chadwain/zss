const Test = @This();

const zss = @import("zss");
const Element = zss.ElementTree.Element;
const Environment = zss.Environment;
const Fonts = zss.Fonts;

name: []const u8,
root_element: Element,
env: Environment,
fonts: *const Fonts,
font_handle: Fonts.Handle,

width: u32 = 400,
height: u32 = 400,
