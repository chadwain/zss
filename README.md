# zss
zss is a [CSS](https://www.w3.org/Style/CSS/) layout engine and document renderer, written in [Zig](https://ziglang.org/).

# Project structure
- [source/values](source/values)
  - Contains CSS value and property definitions.
- [source/layout](source/layout)
  - The main file here is [layout.zig](source/layout/layout.zig). It does all the heavy lifting of CSS document layout.
- [source/render](source/render)
  - Allows one to draw a document to graphical window via a rendering backend. At the moment, the only provided backend is [SDL2](https://libsdl.org/).

# Building zss
To build zss, use the latest version of zig.

To do layout or run tests, you will need:
- harfbuzz
- freetype

To use the SDL2 rendering backend or run the demo program, you must also have:
- sdl2
- sdl2-image

So on Debian, for example, you can do
```
sudo apt install libharfbuzz-dev libfreetype6-dev libsdl2-dev libsdl2-image-dev
```

Windows users must provide their own builds of these libraries for now.

After you've installed the dependencies, you can then run `zig build --help` to see your options.

# How to use zss
Assuming you've imported the library like this...
```zig
const zss = @import("zss");
```
...then the basic workflow is as follows:
1. Create a `zss.ElementTree` structure.
2. Create a `zss.CascadedValueStore` structure.
3. Call `zss.layout.doLayout` to receive a `zss.used_values.BoxTree`.
4. Draw the resulting box tree using the SDL2 rendering backend by calling `zss.render.sdl.drawBoxTree`.

A [demo program](demo/demo.zig) is provided to show how one could use zss. To see it, run `zig build` then `zig-out/bin/demo`.
When you run it, make sure you are in the project root directory.

## Using `ElementTree`
Layout is the process of taking a tree of elements, with each element being associated with a set of CSS values, and producing the information necessary to draw them to the screen. In zss, creating these elements is done using `ElementTree`, and associating them with values is done using `CascadedValueStore`, which is covered in the next section.

Here is some example usage of the `ElementTree`.
```zig
var tree = zss.ElementTree{};
defer tree.deinit(allocator); // Free the memory used by this tree.
try tree.ensureTotalCapacity(allocator, 100); // Have enough memory for all the elements we want to create.

// The first element must be made with 'createRootAssumeCapacity'.
// If this ElementTree were representing an HTML document, this would be like the <html> or <body> element.
const root = tree.createRootAssumeCapacity();

// Subsequent elements can be created with 'appendChildAssumeCapacity',
// passing the parent element as an argument.
const first_child = tree.appendChildAssumeCapacity(root);
const second_child = tree.appendChildAssumeCapacity(root);
const grandchild = tree.appendChildAssumeCapacity(first_child);
```

The functions `createRootAssumeCapacity` and `appendChildAssumeCapacity` return `zss.ElementRef`, which is a handle that can be used to refer to the new element. This will be useful for associating CSS values to that element.

## Using `CascadedValueStore`
The `CascadedValueStore` maps each element in the `ElementTree` to its [cascaded values](https://www.w3.org/TR/css-cascade-4/#cascaded). The store contains many individual maps, whose keys are `zss.ElementRef` and values are a set of related CSS properties. You may look at [source/layout/CascadedValueStore.zig](source/layout/CascadedValueStore.zig) to see exactly which maps correspond to which properties.

Here are some short guides on using `CascadedValueStore`.

### Specifying widths and heights
The `content_width` and `content_height` fields can be used to set the size of content boxes, and the `horizontal_edges` and `vertical_edges` can be used to set the sizes of margin boxes, border boxes, and padding boxes.

```zig
// Creating our CascadedValueStore.
var cvs = CascadedValueStore{};
defer cvs.deinit(allocator);
try cvs.ensureTotalCapacity(allocator, 100);

// Assuming `my_element` was a ElementRef previously returned from an ElementTree.
cvs.content_width.setAssumeCapacity(my_element, .{ .size = .{ .percentage = 0.7 } });
cvs.horizontal_edges.setAssumeCapacity(my_element, .{ .margin_start = .{ .px = 20 } });
cvs.content_height.setAssumeCapacity(my_element, .{ .max_size = .none });
cvs.vertical_edges.setAssumeCapacity(my_element, .{ .border_end = .{ .px = 50 }, .margin_start = .auto });
```

In this code, we can see that each map takes in a value that corresponds to a certain set of CSS properties. We also see that multiple properties can be set within one line of code. When setting a property, you can write in as many or as few of the struct fields as you want. Any fields you leave out will be assigned the value `.undeclared`.

The above code would be roughly equivalent to the following CSS:
```css
#my_element {
    width: 70%;
    margin-left: 20px;
    max-height: none;
    border-bottom-width: 50px;
    margin-top: auto;
}
```

Note that within `horizontal_edges`, setting `margin_start` affects the 'margin-left' property, while within `vertical_edges`, it affects the 'margin-top' property. This is because both maps use the same value type, and the meaning of each field varies depending on what map is being used. In this case, "start/end" are in reference to the typical CSS usage of these words, where they mean "left/right" in some contexts and "top/bottom" in others. It is important to read [source/layout/CascadedValueStore.zig](source/layout/CascadedValueStore.zig) so that you always know which property a certain field corresponds to.

### Adding text
To add text to a document, you must create a "text node" in your element tree. A text node is any node which has its `display` property set to `.text`. Once you've done that, you can set its `text` property to the string it should contain. At the moment, only Latin characters are supported, but more support for Unicode is planned.

Example:
```zig
cvs.display.setAssumeCapacity(text_node, .{ .display = .text });
cvs.text.setAssumeCapacity(text_node, .{ .text = "Hello world!" });
```

Note that a text node must be a leaf node, i.e. it cannot have any children in the element tree.

### Fonts
Due to limitations in zss at the moment, it is only possible to define one font and font color for your entire document. This will be the case until more robust font handling is implemented.

Fonts are specified using Harfbuzz's `hb_font_t`. Once you have one of those, you may set the `font` and `color` properties on the root element to customize the font.

```zig
const hb_font = hb_font_create(...);

// `root` must be the root element of the ElementTree.
cvs.font.setAssumeCapacity(root, .{ .font = .{ .font = hb_font } });
cvs.color.setAssumeCapacity(root, .{ .color = .{ .rgba 0x336699ff } });
```

### The 'all' property
The 'all' property in CSS resets all of the properties of an element to one of [a few keywords](https://www.w3.org/TR/css-cascade-4/#all-shorthand). In zss, `all` sets the values of all of the undeclared properties of an element. A property is undeclared if it is set to `.undeclared`, or if its entry in the `CascadedValueStore` does not exist.

### Adding background images
zss supports background images, but does not care about the representation in memory of the image. Instead, background images are handled using an interface, whose name is `zss.values.BackgroundImage.Object`. By using interfaces, zss is not tied to a particular rendering backend, and can easily extract just the information about an image that it needs.

For example, when using the SDL2 rendering backend, you can use `zss.render.sdl.textureAsBackgroundImageObject` to wrap a `SDL_Texture` into an `Object`.
```zig
const texture = SDL_CreateTexture(...);
const bg_img_object = textureAsBackgroundImageObject(texture);
cvs.background2.setAssumeCapacity(my_element, .{ .image = .{ .object = bg_img_object } });
```

Other background-related properties can be set using the `background1` and `background2` fields of `CascadedValueStore`.
