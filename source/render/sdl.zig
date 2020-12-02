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

pub const sdl = @cImport({
    @cInclude("SDL2/SDL.h");
});

const block = @import("sdl/block.zig");
pub const renderBlockFormattingContext = block.renderBlockFormattingContext;

const @"inline" = @import("sdl/inline.zig");
pub const renderInlineFormattingContext = @"inline".renderInlineFormattingContext;
