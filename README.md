# zss
zss is a [CSS](https://www.w3.org/Style/CSS/) layout engine and document renderer, written in [Zig](https://ziglang.org/).

# Building zss
To build zss, simply run `zig build --help` to see your options.

zss uses unstable (master) versions of Zig. Using a fairly recent version of the Zig compiler (0.13 or later) is recommended.

# Standards Implemented
In general, zss tries to implement the standards contained in [CSS Snapshot 2023](https://www.w3.org/TR/css-2023/).

| Module | Level | Progress |
| ------ | ----- | ----- |
| CSS Level 2 | 2.2 | Partial |
| Syntax | 3 | Partial |
| Selectors | 3 | Partial |
| Cascading and Inheritance | 4 | Partial |
| Backgrounds and Borders | 3 | Partial |
| Values and Units | 3 | Partial |
| Namespaces | 3 | Partial |

# License
zss is licensed under the GNU General Public License, version 3 only. Copyright (C) 2020-2024 Chadwain Holness.

A copy of this license can be found in [LICENSE](LICENSE).
