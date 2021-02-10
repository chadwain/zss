// This file is a part of zss.
// Copyright (C) 2020-2021 Chadwain Holness
//
// This library is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this library.  If not, see <https://www.gnu.org/licenses/>.

/// An integral, indivisible unit of space which is the basis for all CSS layout
/// computations.
pub const CSSUnit = i32;

/// Contains the used value of the 'width' and 'height' properties.
pub const Dimension = struct {
    width: CSSUnit = 0,
    height: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-top-width',
/// 'border-right-width', 'border-bottom-width', and 'border-left-width'.
pub const Borders = struct {
    top: CSSUnit = 0,
    right: CSSUnit = 0,
    bottom: CSSUnit = 0,
    left: CSSUnit = 0,
};

/// Contains the used values of the properties 'padding-top',
/// 'padding-right', 'padding-bottom', and 'padding-left'.
pub const Padding = struct {
    top: CSSUnit = 0,
    right: CSSUnit = 0,
    bottom: CSSUnit = 0,
    left: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-left', and
/// 'margin-right'.
pub const MarginLeftRight = struct {
    left: CSSUnit = 0,
    right: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-top', and
/// 'margin-bottom'.
pub const MarginTopBottom = struct {
    top: CSSUnit = 0,
    bottom: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-left',
/// 'margin-right', 'border-left-width', 'border-right-width',
/// 'padding-left', and 'padding-right'.
pub const MarginBorderPaddingLeftRight = struct {
    margin_left: CSSUnit = 0,
    margin_right: CSSUnit = 0,
    border_left: CSSUnit = 0,
    border_right: CSSUnit = 0,
    padding_left: CSSUnit = 0,
    padding_right: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-top',
/// 'margin-bottom', 'border-top-width', 'border-bottom-width',
/// 'padding-top', and 'padding-bottom'.
pub const MarginBorderPaddingTopBottom = struct {
    margin_top: CSSUnit = 0,
    margin_bottom: CSSUnit = 0,
    border_top: CSSUnit = 0,
    border_bottom: CSSUnit = 0,
    padding_top: CSSUnit = 0,
    padding_bottom: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-top-color',
/// 'border-right-color', 'border-bottom-color', and 'border-left-color'.
pub const BorderColor = struct {
    top_rgba: u32 = 0,
    right_rgba: u32 = 0,
    bottom_rgba: u32 = 0,
    left_rgba: u32 = 0,
};

/// Contains the used value of the 'background-color' property.
pub const BackgroundColor = struct {
    rgba: u32 = 0,
};

pub const Percentage = f32;

pub const BackgroundImage = struct {
    data: ?usize = null,
    origin: enum { Padding, Border, Content } = .Padding,
    clip: enum { Padding, Border, Content } = .Border,
    position: struct { horizontal: Percentage, vertical: Percentage } = .{ .horizontal = 0, .vertical = 0 },
};

/// Contains the used value of the properties 'overflow' and 'visibility'.
pub const VisualEffect = struct {
    overflow: enum { Visible, Hidden } = .Visible,
    visibility: enum { Visible, Hidden } = .Visible,
};
