const std = @import("std");
const atomic = @import("atomic.zig");

/// Synchronization policy for single-threaded callers, including WASM builds.
pub const NoSync = struct {
    pub const supports_wait = false;

    pub fn lock(_: *NoSync) void {}
    pub fn unlock(_: *NoSync) void {}
    pub fn notifyOne(_: *NoSync) void {}
    pub fn notifyAll(_: *NoSync) void {}
};

/// Synchronization policy that busy-waits without using `std.Io`.
pub const SpinSync = struct {
    pub const supports_wait = true;

    mutex: atomic.SpinLock = .init(),
    condition: atomic.CondVariable = .init(),

    pub fn init() SpinSync {
        return .{};
    }

    pub fn lock(self: *SpinSync) void {
        self.mutex.lock();
    }

    pub fn unlock(self: *SpinSync) void {
        self.mutex.unlock();
    }

    pub fn notifyOne(self: *SpinSync) void {
        self.condition.notifyOne();
    }

    pub fn notifyAll(self: *SpinSync) void {
        self.condition.notifyAll();
    }

    /// Must be called with this policy locked; it returns with the lock held.
    pub fn wait(self: *SpinSync) void {
        self.condition.wait(&self.mutex);
    }
};

/// Synchronization policy backed by Zig's I/O runtime.
pub const IoSync = struct {
    pub const supports_wait = true;

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,

    pub fn init(io: std.Io) IoSync {
        return .{ .io = io };
    }

    pub fn lock(self: *IoSync) void {
        self.mutex.lockUncancelable(self.io);
    }

    pub fn unlock(self: *IoSync) void {
        self.mutex.unlock(self.io);
    }

    pub fn notifyOne(self: *IoSync) void {
        self.condition.signal(self.io);
    }

    pub fn notifyAll(self: *IoSync) void {
        self.condition.broadcast(self.io);
    }

    /// Must be called with this policy locked; it returns with the lock held.
    pub fn wait(self: *IoSync) void {
        self.condition.waitUncancelable(self.io, &self.mutex);
    }
};
