# zss
zss is a library written in [Zig](https://ziglang.org/) which implements CSS layout on a document. Said document can then be drawn to the screen.

# License
## GPL-3.0-only
Copyright (C) 2020-2021 Chadwain Holness

zss is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this library.  If not, see <https://www.gnu.org/licenses/>.

# Project structure
- [source/layout](source/layout)
  - The main file here is [layout.zig](source/layout/layout.zig). It does all the heavy lifting of CSS document layout. Create a `BoxTree` data structure, and then call `doLayout`.
- [source/render](source/render)
  - Allows one to draw a document to graphical window via a rendering backend. At the moment, the only provided backend is [SDL2](source/render/sdl.zig).

# Building zss
zss is built using Zig 0.8.0, not master.

To do layout or run tests, you will need:
- harfbuzz
- freetype

To run the demo program, you must also have:
- sdl2
- sdl2-image

So on Debian, for example, you can do
```
sudo apt install libharfbuzz-dev libfreetype6-dev libsdl2-dev libsdl2-image-dev
```

Windows users currently must provide their own builds of these libraries.

After you've installed the dependencies, you can then run `zig build --help`.

# How to use zss
Assuming you've imported the library like this...
```zig
const zss = @import("zss");
```
...then the basic workflow is as follows:
1. Fill in a `zss.BoxTree` structure.
2. Call `zss.layout.doLayout`.
3. Draw the resulting document using the SDL2 rendering backend. Call `zss.render.sdl.renderDocument`.

[A demo program](demo/demo.zig) is provided as an actual example. It must be run from the project root directory.

## Using `BoxTree`
The box tree is the main interface into zss. It is where you specify the CSS properties for the elements of your document. It's much like writing a `.css` file. Here are a few short guides for using it properly.

### Specifying widths and heights
Use the `inline_size` and `block_size` fields to specify the widths and heights of block boxes, margin boxes, border boxes, and padding boxes.
The words "inline", "block", "start", and "end" indicate that these are flow relative properties.
If you're unfamiliar with CSS's flow relative properties, you can just assume that:
- "inline" means "x-axis"
- "block" means "y-axis"
- "start" means "left (inline) or top (block)"
- "end" means "right (inline) or bottom (block)"

So for example, this:
```zig
box_tree.inline_size[4].margin_start = .{ .px = 20 };
box_tree.inline_size[4].size = .{ .percentage = 0.7 };
box_tree.block_size[4].border_end = .{ .px = 50 };
box_tree.block_size[4].max_size = .{ .none = {} };
```
would be equivalent to setting the following properties for element at index 4:
```css
margin-left: 20px;
width: 70%;
border-bottom-width: 50px;
max-height: none;
```

### Adding text
All text in zss is Unicode text. To add text to your document, you must create a new element in the box tree to contain it.
Set the `display` of that element to `text` (using the `display` field), then set the text using the `latin1_text` field.
As the name suggests, only the first 256 Unicode codepoints, which contain Latin characters, can be used.
```zig
box_tree.display[1] = .{ .text = {} };
box_tree.latin1_text[1] = .{ .text = "Hello!" };
```

### Adding background images
zss does not specify the format of background images. Therefore background images are specified using abstract "background image objects" (see `BoxTree.Background.Image`).
These objects are specific to the rendering backend being used and don't need to be created manually.

For example, using the SDL2 backend, you can call `zss.render.sdl.textureAsBackgroundImageObject` to create an object.
```zig
const texture = SDL_CreateTexture(...);
const bg_img_object = textureAsBackgroundImageObject(texture);
box_tree.background[0].image = .{ .object = bg_img_object };
```

### Border colors
Specify border colors with the `border` field. The border color properties are flow relative, just like the widths and heights.
