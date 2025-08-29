const Test = @This();

const zss = @import("zss");
const Element = zss.ElementTree.Element;
const Environment = zss.Environment;
const Fonts = zss.Fonts;

name: []const u8,
env: Environment,
document: zss.zml.Document,
stylesheet: zss.Stylesheet,
author_cascade_node: zss.cascade.Node,
ua_cascade_node: zss.cascade.Node,
fonts: *const Fonts,
font_handle: Fonts.Handle,

width: u32 = 400,
height: u32 = 400,
