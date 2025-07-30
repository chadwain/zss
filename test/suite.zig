const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const zss = @import("zss");
const Ast = zss.syntax.Ast;
const ElementTree = zss.ElementTree;
const Element = ElementTree.Element;
const TokenSource = zss.syntax.TokenSource;

const hb = @import("harfbuzz").c;

const Test = @import("Test.zig");

const Args = struct {
    test_cases_path: []const u8,
    resources_path: []const u8,
    output_path: []const u8,
    filters: []const []const u8,

    fn init(arena: *ArenaAllocator) !Args {
        const allocator = arena.allocator();
        const argv = try std.process.argsAlloc(allocator);
        var args = Args{
            .test_cases_path = argv[1],
            .resources_path = argv[2],
            .output_path = argv[3],
            .filters = undefined,
        };

        var filters = std.ArrayList([]const u8).init(allocator);
        const stderr = std.io.getStdErr();
        var i: usize = 4;
        while (i < argv.len) {
            const arg = argv[i];
            if (std.mem.eql(u8, arg, "--test-filter")) {
                i += 1;
                if (i == argv.len) {
                    stderr.writeAll("Missing argument after '--test-filter'\n") catch {};
                    std.process.exit(1);
                }
                try filters.append(argv[i]);
                i += 1;
            } else {
                stderr.writeAll("Unrecognized argument: ") catch {};
                stderr.writeAll(arg) catch {};
                stderr.writeAll("\n") catch {};
                std.process.exit(1);
            }
        }

        args.filters = try filters.toOwnedSlice();

        return args;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    const args = try Args.init(&arena);

    var library: hb.FT_Library = undefined;
    if (hb.FT_Init_FreeType(&library) != 0) return error.FreeTypeError;
    defer _ = hb.FT_Done_FreeType(library);

    const font_name = try std.fs.path.joinZ(allocator, &.{ args.resources_path, "NotoSans-Regular.ttf" });
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
    const font_handle = fonts.setFont(font);

    const tests = try getAllTests(args, &arena, &fonts, font_handle);

    const Category = enum { check, memory, opengl, print };
    inline for (@import("build-options").test_categories) |category| {
        const module = comptime switch (std.meta.stringToEnum(Category, category) orelse @compileError("unknown test category: " ++ category)) {
            .check => @import("check.zig"),
            .memory => @import("memory.zig"),
            .opengl => @import("opengl.zig"),
            .print => @import("print.zig"),
        };
        try module.run(tests, args.output_path);
    }
}

fn getAllTests(
    args: Args,
    arena: *ArenaAllocator,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
) ![]*Test {
    const allocator = arena.allocator();

    const cwd = std.fs.cwd();
    var cases_dir = try cwd.openDir(args.test_cases_path, .{ .iterate = true });
    defer cases_dir.close();

    var walker = try cases_dir.walk(allocator);
    defer walker.deinit();

    var list = std.ArrayList(*Test).init(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zml")) continue;
        if (args.filters.len > 0) {
            for (args.filters) |filter| {
                if (std.mem.indexOf(u8, entry.path, filter)) |_| break;
            } else continue;
        }

        const source = try cases_dir.readFileAlloc(allocator, entry.path, 100_000);
        const token_source = try TokenSource.init(source);
        const ast = blk: {
            var parser = zss.syntax.Parser.init(token_source, allocator);
            break :blk try parser.parseZmlDocument(allocator);
        };

        const name = try allocator.dupe(u8, entry.path[0 .. entry.path.len - ".zml".len]);

        const t = try createTest(allocator, name, ast, token_source, fonts, font_handle);
        try list.append(t);
    }

    return list.toOwnedSlice();
}

fn createTest(
    allocator: Allocator,
    name: []const u8,
    ast: Ast,
    token_source: TokenSource,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
) !*Test {
    const t = try allocator.create(Test);
    errdefer allocator.destroy(t);

    t.* = .{
        .name = name,
        .fonts = fonts,
        .font_handle = font_handle,

        .element_tree = undefined,
        .root_element = undefined,
        .env = undefined,
    };

    t.element_tree = ElementTree.init();
    errdefer t.element_tree.deinit(allocator);

    t.env = zss.Environment.init(allocator);
    errdefer t.env.deinit();

    t.root_element = blk: {
        assert(ast.tag(0) == .zml_document);
        var seq = ast.children(0);
        if (seq.nextSkipSpaces(ast)) |zml_element| {
            break :blk try zss.zml.astToElement(&t.element_tree, allocator, &t.env, ast, zml_element, token_source);
        } else {
            break :blk Element.null_element;
        }
    };

    if (!t.root_element.eqlNull()) {
        if (t.element_tree.category(t.root_element) == .normal) {
            const block = try t.env.decls.openBlock(t.env.allocator);
            const DeclaredValues = zss.property.groups.Tag.DeclaredValues;
            try t.env.decls.addValues(t.env.allocator, .normal, .{ .color = DeclaredValues(.color){
                .color = .{ .declared = .{ .rgba = 0xffffffff } },
            } });
            t.env.decls.closeBlock();
            try t.element_tree.updateCascadedValues(t.root_element, allocator, &t.env.decls, &.{.{ .block = block, .importance = .normal }});
        }
    }

    return t;
}
