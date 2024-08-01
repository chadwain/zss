const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zss = @import("zss");
const Ast = zss.syntax.Ast;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;

const hb = @import("mach-harfbuzz").c;

const Test = @import("Test.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var library: hb.FT_Library = undefined;
    if (hb.FT_Init_FreeType(&library) != 0) return error.FreeTypeError;
    defer _ = hb.FT_Done_FreeType(library);

    const font_name = try std.fs.path.joinZ(allocator, &.{ args[3], "NotoSans-Regular.ttf" });
    defer allocator.free(font_name);
    const font_size = 12;
    var face: hb.FT_Face = undefined;
    if (hb.FT_New_Face(library, font_name.ptr, 0, &face) != 0) return error.FreeTypeError;
    defer _ = hb.FT_Done_Face(face);
    if (hb.FT_Set_Char_Size(face, 0, font_size * 64, 96, 96) != 0) return error.FreeTypeError;

    const font = hb.hb_ft_font_create_referenced(face).?;
    hb.hb_ft_font_set_funcs(font);

    var fonts = zss.Fonts.init();
    defer fonts.deinit();
    const font_handle = fonts.setFont(.{ .handle = font });

    var images = zss.Images{};
    defer images.deinit(allocator);

    var storage = zss.values.Storage{ .allocator = allocator };
    defer storage.deinit();

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tests = try getAllTests(args, &arena, &fonts, font_handle, images.slice(), &storage);

    const category_fns = std.StaticStringMap(*const fn ([]const *Test) anyerror!void).initComptime(&.{
        .{ "check", @import("check.zig").run },
        .{ "memory", @import("memory.zig").run },
        .{ "opengl", @import("opengl.zig").run },
    });
    inline for (@import("build-options").test_categories) |category| {
        const runFn = comptime category_fns.get(category) orelse @compileError("TODO");
        try runFn(tests);
    }
}

fn getAllTests(
    args: []const []const u8,
    arena: *ArenaAllocator,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
    images: zss.Images.Slice,
    storage: *const zss.values.Storage,
) ![]*Test {
    const allocator = arena.allocator();

    const cwd = std.fs.cwd();
    var cases_dir = try cwd.openDir(args[1], .{ .iterate = true });
    defer cases_dir.close();

    var walker = try cases_dir.walk(allocator);
    defer walker.deinit();

    var ast_dir = try cwd.openDir(args[2], .{});
    defer ast_dir.close();

    var list = std.ArrayList(*Test).init(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zml")) continue;

        const name = try allocator.dupe(u8, entry.path[0 .. entry.path.len - ".zml".len]);

        const ast_file_name = try std.mem.concat(allocator, u8, &.{ entry.path, "-ast" });
        const in_file = try ast_dir.openFile(ast_file_name, .{});
        defer in_file.close();
        const reader = in_file.reader().any();
        const ast = try zss.syntax.Ast.debug.deserialize(reader, allocator);
        const source = try reader.readAllAlloc(allocator, 100_000);

        const t = try createTest(allocator, name, ast, source, fonts, font_handle, images, storage);
        try list.append(t);
    }

    return list.toOwnedSlice();
}

fn createTest(
    allocator: Allocator,
    name: []const u8,
    ast: Ast,
    source: []const u8,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
    images: zss.Images.Slice,
    storage: *const zss.values.Storage,
) !*Test {
    const t = try allocator.create(Test);
    errdefer allocator.destroy(t);

    t.* = .{
        .name = name,
        .fonts = fonts,
        .font_handle = font_handle,
        .images = images,
        .storage = storage,

        .element_tree = undefined,
        .root_element = undefined,
        .env = undefined,
    };

    t.element_tree = ElementTree.init(allocator);
    errdefer t.element_tree.deinit();

    t.env = zss.Environment.init(allocator);
    errdefer t.env.deinit();

    t.root_element = blk: {
        const slice = ast.slice();
        assert(slice.tag(0) == .zml_document);
        var seq = slice.children(0);
        if (seq.next(slice)) |zml_element| {
            assert(slice.tag(zml_element) == .zml_element);
            const token_source = try zss.syntax.tokenize.Source.init(.{ .data = source });
            break :blk try zss.zml.astToElementTree(&t.element_tree, &t.env, slice, zml_element, token_source, allocator);
        } else {
            break :blk Element.null_element;
        }
    };

    if (!t.root_element.eqlNull()) {
        const slice = t.element_tree.slice();
        const cv = slice.ptr(.cascaded_values, t.root_element);
        try cv.add(slice.arena, .color, .{ .color = .{ .rgba = 0xffffffff } });
    }

    return t;
}
