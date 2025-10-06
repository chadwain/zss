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
const zigimg = @import("zigimg");

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

        var filters = std.ArrayList([]const u8).empty;
        var stderr = std.fs.File.stderr().writer(&.{});
        var i: usize = 4;
        while (i < argv.len) {
            const arg = argv[i];
            if (std.mem.eql(u8, arg, "--test-filter")) {
                i += 1;
                if (i == argv.len) {
                    stderr.interface.writeAll("Missing argument after '--test-filter'\n") catch {};
                    stderr.interface.flush() catch {};
                    std.process.exit(1);
                }
                try filters.append(allocator, argv[i]);
                i += 1;
            } else {
                stderr.interface.print("Unrecognized argument: {s}\n", .{arg}) catch {};
                stderr.interface.flush() catch {};
                std.process.exit(1);
            }
        }

        args.filters = filters.items;

        return args;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);

    var arena = ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const args = try Args.init(&arena);

    var library: hb.FT_Library = undefined;
    if (hb.FT_Init_FreeType(&library) != 0) return error.FreeTypeError;
    defer _ = hb.FT_Done_FreeType(library);

    const font_name = try std.fs.path.joinZ(arena.allocator(), &.{ args.resources_path, "NotoSans-Regular.ttf" });
    const font_size = 12;
    var face: hb.FT_Face = undefined;
    if (hb.FT_New_Face(library, font_name.ptr, 0, &face) != 0) return error.FreeTypeError;
    defer _ = hb.FT_Done_Face(face);
    if (hb.FT_Set_Char_Size(face, 0, font_size * 64, 96, 96) != 0) return error.FreeTypeError;

    const font = hb.hb_ft_font_create_referenced(face).?;
    hb.hb_ft_font_set_funcs(font);

    var images = zss.Images.init();
    defer images.deinit(arena.allocator());

    var fonts = zss.Fonts.init();
    defer fonts.deinit();
    const font_handle = fonts.setFont(font);

    const tests = try getAllTests(args, &arena, &images, &fonts, font_handle);

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
    images: *zss.Images,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
) ![]*Test {
    const allocator = arena.allocator();

    const cwd = std.fs.cwd();

    var cases_dir = try cwd.openDir(args.test_cases_path, .{ .iterate = true });
    defer cases_dir.close();

    var loader = try ResourceLoader.init(args);
    defer loader.deinit();

    const ua_stylesheet = blk: {
        const token_source = try zss.syntax.TokenSource.init(@embedFile("ua-stylesheet.css"));
        var parser = zss.syntax.Parser.init(token_source, allocator);
        const ast, const rule_list = try parser.parseCssStylesheet(allocator);
        break :blk UaStylesheet{ .ast = ast, .rule_list = rule_list, .token_source = token_source };
    };

    var walker = try cases_dir.walk(allocator);
    defer walker.deinit();

    var list = std.ArrayList(*Test).empty;

    while (try walker.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zml")) continue;
        if (args.filters.len > 0) {
            for (args.filters) |filter| {
                if (std.mem.indexOf(u8, entry.path, filter)) |_| break;
            } else continue;
        }

        const source = try cases_dir.readFileAlloc(allocator, entry.path, 100_000);
        const token_source = try TokenSource.init(source);
        const ast, const zml_document_index = blk: {
            var parser = zss.syntax.Parser.init(token_source, allocator);
            break :blk try parser.parseZmlDocument(allocator);
        };

        const name = try allocator.dupe(u8, entry.path[0 .. entry.path.len - ".zml".len]);

        const t = try createTest(arena, name, ast, token_source, zml_document_index, images, fonts, font_handle, &loader, ua_stylesheet);
        try list.append(allocator, t);
    }

    return list.items;
}

const UaStylesheet = struct {
    ast: zss.syntax.Ast,
    rule_list: zss.syntax.Ast.Index,
    token_source: zss.syntax.TokenSource,
};

fn createTest(
    arena: *ArenaAllocator,
    name: []const u8,
    ast: Ast,
    token_source: TokenSource,
    zml_document_index: Ast.Index,
    images: *zss.Images,
    fonts: *const zss.Fonts,
    font_handle: zss.Fonts.Handle,
    loader: *ResourceLoader,
    ua_stylesheet: UaStylesheet,
) !*Test {
    const allocator = arena.allocator();

    const t = try allocator.create(Test);
    t.* = .{
        .name = name,
        .images = images,
        .fonts = fonts,
        .font_handle = font_handle,

        .document = undefined,
        .stylesheet = undefined,
    };

    t.document = try zss.zml.createDocument(allocator, ast, token_source, zml_document_index);
    t.stylesheet = try zss.Stylesheet.create(allocator, ua_stylesheet.ast, ua_stylesheet.rule_list, ua_stylesheet.token_source, &t.document.env);

    const cascade_list = zss.cascade.List{
        .author = &.{&.{ .leaf = &t.document.cascade_source }},
        .user_agent = &.{&.{ .leaf = &t.stylesheet.cascade_source }},
    };
    try zss.cascade.run(&cascade_list, &t.document.env, allocator);

    try loader.loadResourcesFromUrls(arena, t, images, token_source);

    return t;
}

const ResourceLoader = struct {
    res_dir: std.fs.Dir,
    /// maps image URLs to image handles
    seen_images: std.StringHashMapUnmanaged(zss.Images.Handle),

    fn init(args: Args) !ResourceLoader {
        const res_dir = try std.fs.cwd().openDir(args.resources_path, .{});
        return .{
            .res_dir = res_dir,
            .seen_images = .empty,
        };
    }

    fn deinit(loader: *ResourceLoader) void {
        loader.res_dir.close();
    }

    fn loadResourcesFromUrls(
        loader: *ResourceLoader,
        arena: *ArenaAllocator,
        t: *Test,
        images: *zss.Images,
        token_source: TokenSource,
    ) !void {
        const allocator = arena.allocator();
        for (0..t.document.urls.len) |index| {
            const url = t.document.urls.get(index);
            const string = switch (url.src_loc) {
                .url_token => |location| try token_source.copyUrl(location, .{ .allocator = allocator }),
                .string_token => |location| try token_source.copyString(location, .{ .allocator = allocator }),
            };

            switch (url.type) {
                .background_image => {
                    const gop = try loader.seen_images.getOrPut(allocator, string);
                    if (gop.found_existing) {
                        try t.document.env.linkUrlToImage(url.id, gop.value_ptr.*);
                        continue;
                    }

                    const file = try loader.res_dir.openFile(string, .{ .mode = .read_only });
                    defer file.close();

                    var read_buffer: [4096]u8 = undefined;
                    const zigimg_image = try zigimg.Image.fromFile(allocator, file, &read_buffer);
                    const zss_image = try images.addImage(allocator, .{
                        .dimensions = .{
                            .width_px = @intCast(zigimg_image.width),
                            .height_px = @intCast(zigimg_image.height),
                        },
                        .format = switch (zigimg_image.pixelFormat()) {
                            .rgba32 => .rgba,
                            else => return error.UnsupportedPixelFormat,
                        },
                        .data = zigimg_image.rawBytes(),
                    });

                    gop.value_ptr.* = zss_image;
                    try t.document.env.linkUrlToImage(url.id, zss_image);
                },
            }
        }
    }
};
