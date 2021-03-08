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

const values = @import("values.zig");

fn withDefaults(comptime T: type) type {
    const Defaults = values.mergeUnions(values.Initial, values.mergeUnions(values.Inherit, values.Unset));
    return values.mergeUnions(T, Defaults);
}

fn withNone(comptime T: type) type {
    return values.mergeUnions(T, values.None);
}

fn withAuto(comptime T: type) type {
    return values.mergeUnions(T, values.Auto);
}

fn withPercentage(comptime T: type) type {
    return values.mergeUnions(T, values.Percentage);
}

pub const BoxSize = struct {
    pub const PaddingValue = withDefaults(values.LengthPercentage);
    pub const BorderValue = withDefaults(values.LineWidth);
    pub const MarginValue = withDefaults(withAuto(values.LengthPercentage));

    margin_top: MarginValue,
    margin_right: MarginValue,
    margin_bottom: MarginValue,
    margin_left: MarginValue,
    border_top_width: BorderValue,
    border_right_width: BorderValue,
    border_bottom_width: BorderValue,
    border_left_width: BorderValue,
    padding_top: PaddingValue,
    padding_right: PaddingValue,
    padding_bottom: PaddingValue,
    padding_left: PaddingValue,
};

pub const ContentSize = struct {
    pub const MinValue = withDefaults(values.LengthPercentage);
    pub const MaxValue = withDefaults(withNone(values.LengthPercentage));
    pub const Dimension = withDefaults(withAuto(values.LengthPercentage));

    min_width: MinValue,
    min_height: MinValue,
    max_width: MaxValue,
    max_height: MaxValue,
    width: Dimension,
    height: Dimension,
};

pub const LogicalSize = struct {
    pub const Size = withDefaults(withAuto(values.LengthPercentage));
    pub const MinValue = withDefaults(values.LengthPercentage);
    pub const MaxValue = withDefaults(withNone(values.LengthPercentage));
    pub const BorderValue = withDefaults(values.LineWidth);
    pub const PaddingValue = withDefaults(values.LengthPercentage);
    pub const MarginValue = withDefaults(withAuto(values.LengthPercentage));

    size: Size,
    min_size: MinValue,
    max_size: MaxValue,
    border_start_width: BorderValue,
    border_end_width: BorderValue,
    padding_start: PaddingValue,
    padding_end: PaddingValue,
    margin_start: MarginValue,
    margin_end: MarginValue,
};

pub const Display = withNone(union(enum) {
    pub const InnerOuter = struct {
        inner: values.DisplayInner,
        outer: values.DisplayOuter,
    };

    inner_outer: InnerOuter,
});
