const std = @import("std");

/// A small non-reentrant lock that busy-waits instead of parking the thread.
pub const SpinLock = struct {
    const Self = @This();

    locked: std.atomic.Value(bool) = .init(false),

    pub fn init() Self {
        return .{};
    }

    pub fn lock(self: *Self) void {
        while (true) {
            if (self.locked.cmpxchgWeak(
                false,
                true,
                .acquire,
                .monotonic,
            ) == null) {
                return;
            }

            while (self.locked.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *Self) void {
        self.locked.store(false, .release);
    }
};

/// A condition variable that busy-waits instead of parking the thread.
pub const CondVariable = struct {
    const Self = @This();

    const Waiter = struct {
        notified: std.atomic.Value(bool) = .init(false),
        next: ?*Waiter = null,
    };

    waiters_lock: SpinLock = .init(),
    waiters: ?*Waiter = null,

    pub fn init() Self {
        return .{};
    }

    /// Must be called with `lock` held; returns with it held again.
    pub fn wait(self: *Self, lock: *SpinLock) void {
        var waiter: Waiter = .{};

        self.waiters_lock.lock();
        waiter.next = self.waiters;
        self.waiters = &waiter;
        self.waiters_lock.unlock();

        lock.unlock();
        while (!waiter.notified.load(.acquire)) {
            std.atomic.spinLoopHint();
        }
        lock.lock();
    }

    pub fn notifyOne(self: *Self) void {
        const waiter = waiter: {
            self.waiters_lock.lock();
            defer self.waiters_lock.unlock();

            const waiter = self.waiters orelse return;
            self.waiters = waiter.next;
            break :waiter waiter;
        };

        waiter.notified.store(true, .release);
    }

    pub fn notifyAll(self: *Self) void {
        var waiter = waiters: {
            self.waiters_lock.lock();
            defer self.waiters_lock.unlock();

            const waiters = self.waiters;
            self.waiters = null;
            break :waiters waiters;
        };

        while (waiter) |current| {
            const next = current.next;
            current.notified.store(true, .release);
            waiter = next;
        }
    }
};
