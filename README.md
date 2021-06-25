# zss
zss is a library written in [Zig](https://ziglang.org/) which provides tools for laying out a document according to CSS layout rules. Said document can then be drawn to the screen.

## License
### GPL-3.0-only
Copyright (C) 2020-2021 Chadwain Holness

zss is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.

This library is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this library.  If not, see <https://www.gnu.org/licenses/>.

## How to use zss
The basic workflow is as follows:
1. Fill in a `BoxTree` structure
2. Call `zss.layout.doLayout`
3. Draw the document using a rendering backend of your choice (except there's only 1 backend right now).

[See the demo program](demo/demo1.zig) for an actual example.
