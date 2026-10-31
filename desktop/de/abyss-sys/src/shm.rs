//! Shared memory a Wayland buffer draws into (Window.swift's ShmBuffer):
//! an anonymous file, mapped, and cairo over it.

use crate::{cairo_surface_t, Surface, FORMAT_ARGB32};
use std::os::fd::{AsRawFd, OwnedFd};

unsafe extern "C" {
    fn cairo_image_surface_create_for_data(data: *mut u8, format: i32, w: i32, h: i32, stride: i32) -> *mut cairo_surface_t;
}

/// `len` bytes of shared memory, mapped read-write.
pub struct ShmMemory {
    ptr: *mut u8,
    len: usize,
}

impl ShmMemory {
    /// The mapping and its file (to hand the compositor, then close).
    pub fn new(len: usize) -> Option<(ShmMemory, OwnedFd)> {
        let fd = crate::wlc::create_shm(len)?;
        let p = unsafe { libc::mmap(std::ptr::null_mut(), len, libc::PROT_READ | libc::PROT_WRITE, libc::MAP_SHARED, fd.as_raw_fd(), 0) };
        if p == libc::MAP_FAILED {
            return None;
        }
        Some((ShmMemory { ptr: p as *mut u8, len }, fd))
    }

    pub fn len(&self) -> usize {
        self.len
    }
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    pub fn bytes(&self) -> &[u8] {
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    /// Draw into it: `f` gets an ARGB32 cairo surface over the memory.
    /// False when `width`×`height` at `stride` does not fit.
    pub fn draw(&mut self, width: i32, height: i32, stride: i32, f: impl FnOnce(&Surface)) -> bool {
        if width <= 0 || height <= 0 || stride < width * 4 || stride as usize * height as usize > self.len {
            return false;
        }
        let cs = Surface(unsafe { cairo_image_surface_create_for_data(self.ptr, FORMAT_ARGB32, width, height, stride) });
        f(&cs);
        cs.flush();
        true
    }
}

impl Drop for ShmMemory {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.ptr as *mut libc::c_void, self.len) };
    }
}
