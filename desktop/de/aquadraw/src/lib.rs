//! AquaDraw in Rust (RUST.md R5, begun as R0's spike): the draw-list
//! interpreter, ported from DrawList.swift, with the parts of Text.swift,
//! Drawing.swift and ThemeLoader.swift it reaches. Themes are not ported
//! yet: a colour token or `@metric` is a parse error until they are.

pub mod color;
pub mod drawlist;
pub mod runner;
pub mod scene;
pub mod text;
