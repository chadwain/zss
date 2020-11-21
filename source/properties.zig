// This file is a part of zss.
// Copyright (C) 2020 Chadwain Holness
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

/// Contains the used value of the 'width' property.
pub const Width = struct {
    width: CSSUnit = 0,
};

/// Contains the used value of the 'height' property.
pub const Height = struct {
    height: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-left-width',
/// 'border-right-width', 'padding-left', and 'padding-right'.
pub const BorderPaddingLeftRight = struct {
    border_left: CSSUnit = 0,
    border_right: CSSUnit = 0,
    padding_left: CSSUnit = 0,
    padding_right: CSSUnit = 0,
};

/// Contains the used values of the properties 'border-top-width',
/// 'border-bottom-width', 'padding-top', and 'padding-bottom'.
pub const BorderPaddingTopBottom = struct {
    border_top: CSSUnit = 0,
    border_bottom: CSSUnit = 0,
    padding_top: CSSUnit = 0,
    padding_bottom: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-left', and
/// 'margin-right'.
pub const MarginLeftRight = struct {
    margin_left: CSSUnit = 0,
    margin_right: CSSUnit = 0,
};

/// Contains the used values of the properties 'margin-top', and
/// 'margin-bottom'.
pub const MarginTopBottom = struct {
    margin_top: CSSUnit = 0,
    margin_bottom: CSSUnit = 0,
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
