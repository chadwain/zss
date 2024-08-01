const Test = @This();

const zss = @import("zss");
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const Environment = zss.Environment;
const Fonts = zss.Fonts;

name: []const u8,
element_tree: ElementTree,
root_element: Element,
env: Environment,
fonts: *const Fonts,
font_handle: Fonts.Handle,
images: zss.Images.Slice,
storage: *const zss.values.Storage,

width: u32 = 400,
height: u32 = 400,

pub fn deinit(t: *Test) void {
    t.element_tree.deinit();
    t.env.deinit();
}
