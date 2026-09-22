const fullaz = @import("fullaz");

pub const GcRunner = struct {
    const Self = @This();

    pub const State = enum(u32) {
        idle,
        marking,
        ready_to_sweep,
        sweeping,
        cancelling,
        complete,
        failed,
    };

    pub const EventKind = enum(u32) {
        restored,
        scheduled,
        started,
        progressed,
        ready_to_sweep,
        completed,
        cancelled,
        failed,
    };

    pub const Event = struct {
        kind: EventKind,
        state: State,
        page_budget: usize,
        completed_steps: usize,
    };

    pub const RequestError = error{
        InvalidPageBudget,
        InvalidState,
        WorkPending,
    };

    const Task = enum {
        start_mark,
        step_mark,
        step_sweep,
        cancel,
    };
    const TaskStorage = fullaz.zync.queue_storage.Storage(Task).Fixed(1);
    const TaskQueue = fullaz.zync.TaskQueue(fullaz.zync.policies.NoSync, TaskStorage);
    const Observer = fullaz.zync.ObserverImpl(
        fullaz.zync.policies.NoSync,
        fullaz.zync.storage.Fixed(2),
        Event,
        u32,
    );

    queue: TaskQueue,
    observer: Observer,
    state_: State = .idle,
    cycle_active: bool = false,
    page_budget: usize = 0,
    completed_steps: usize = 0,

    pub fn init() Self {
        return .{
            .queue = .init(.{}, .{}),
            .observer = .init(.{}, .{}),
        };
    }

    pub fn deinit(self: *Self) void {
        self.observer.deinit();
        self.queue.deinit();
        self.* = undefined;
    }

    pub fn subscribe(
        self: *Self,
        callback: Observer.Fn,
        context: ?*anyopaque,
    ) Observer.Error!Observer.Id {
        return self.observer.subscribe(callback, context);
    }

    pub fn unsubscribe(self: *Self, id: Observer.Id) ?Observer.UnsubscribeResult {
        return self.observer.unsubscribe(id);
    }

    pub fn state(self: *const Self) State {
        return self.state_;
    }

    pub fn stepCount(self: *const Self) usize {
        return self.completed_steps;
    }

    pub fn hasPendingWork(self: *Self) bool {
        return !self.queue.isEmpty();
    }

    pub fn blocksDatabaseReplacement(self: *const Self) bool {
        return switch (self.state_) {
            .idle, .complete => false,
            else => true,
        };
    }

    /// Restores visible runtime state from durable database state without
    /// scheduling work. The user must explicitly continue the restored phase.
    pub fn restore(self: *Self, phase: fullaz.gc.Phase) void {
        self.clearPendingWork();
        self.page_budget = 0;
        self.completed_steps = 0;
        self.cycle_active = phase != .idle;
        self.state_ = switch (phase) {
            .idle => .idle,
            .preparing, .marking => .marking,
            .sweeping => .ready_to_sweep,
        };
        self.emit(.restored);
    }

    pub fn requestMark(self: *Self, page_budget: usize) RequestError!void {
        try validatePageBudget(page_budget);
        if (!self.queue.isEmpty()) {
            return error.WorkPending;
        }

        const task: Task = switch (self.state_) {
            .idle, .complete => task: {
                self.cycle_active = false;
                self.completed_steps = 0;
                break :task .start_mark;
            },
            .marking => task: {
                if (!self.cycle_active) {
                    return error.InvalidState;
                }
                break :task .step_mark;
            },
            else => return error.InvalidState,
        };

        self.page_budget = page_budget;
        self.state_ = .marking;
        self.queue.push(task) catch unreachable;
        self.emit(.scheduled);
    }

    pub fn requestSweep(self: *Self, page_budget: usize) RequestError!void {
        try validatePageBudget(page_budget);
        if (!self.queue.isEmpty()) {
            return error.WorkPending;
        }
        if (self.state_ != .ready_to_sweep or !self.cycle_active) {
            return error.InvalidState;
        }

        self.page_budget = page_budget;
        self.state_ = .sweeping;
        self.queue.push(.step_sweep) catch unreachable;
        self.emit(.scheduled);
    }

    /// Cancels queued startup immediately. An active durable cycle is cancelled
    /// by the next pump so every database mutation still has one clear boundary.
    pub fn requestCancel(self: *Self) void {
        if (!self.cycle_active) {
            self.clearPendingWork();
            if (self.state_ != .idle) {
                self.state_ = .idle;
                self.emit(.cancelled);
            }
            return;
        }
        if (self.state_ == .cancelling) {
            return;
        }

        self.clearPendingWork();
        self.state_ = .cancelling;
        self.queue.push(.cancel) catch unreachable;
        self.emit(.scheduled);
    }

    /// Executes at most one queued GC mutation. It may also read the durable
    /// phase after that mutation. Returns `false` when no work was pending.
    pub fn pump(self: *Self, database: anytype) !bool {
        const task = self.queue.pop() orelse return false;
        self.execute(database, task) catch |err| {
            self.state_ = .failed;
            self.emit(.failed);
            return err;
        };
        return true;
    }

    fn execute(self: *Self, database: anytype, task: Task) !void {
        switch (task) {
            .start_mark => {
                try database.startGarbageCollection();
                self.cycle_active = true;
                const phase = try database.garbageCollectionPhase();
                if (phase != .preparing and phase != .marking) {
                    return error.UnexpectedGarbageCollectionPhase;
                }
                self.queue.push(.step_mark) catch unreachable;
                self.emit(.started);
            },
            .step_mark => {
                const status = try database.stepGarbageCollection(self.page_budget);
                self.completed_steps += 1;
                if (status == .complete) {
                    self.finish();
                    return;
                }

                switch (try database.garbageCollectionPhase()) {
                    .preparing, .marking => {
                        self.queue.push(.step_mark) catch unreachable;
                        self.emit(.progressed);
                    },
                    .sweeping => {
                        self.state_ = .ready_to_sweep;
                        self.emit(.ready_to_sweep);
                    },
                    .idle => return error.UnexpectedGarbageCollectionPhase,
                }
            },
            .step_sweep => {
                const status = try database.stepGarbageCollection(self.page_budget);
                self.completed_steps += 1;
                if (status == .complete) {
                    self.finish();
                    return;
                }
                if (try database.garbageCollectionPhase() != .sweeping) {
                    return error.UnexpectedGarbageCollectionPhase;
                }
                self.queue.push(.step_sweep) catch unreachable;
                self.emit(.progressed);
            },
            .cancel => {
                try database.cancelGarbageCollection();
                self.cycle_active = false;
                self.state_ = .idle;
                self.emit(.cancelled);
            },
        }
    }

    fn finish(self: *Self) void {
        self.cycle_active = false;
        self.state_ = .complete;
        self.emit(.completed);
    }

    fn clearPendingWork(self: *Self) void {
        while (self.queue.pop() != null) {}
    }

    fn emit(self: *Self, kind: EventKind) void {
        self.observer.notify(&.{
            .kind = kind,
            .state = self.state_,
            .page_budget = self.page_budget,
            .completed_steps = self.completed_steps,
        }) catch unreachable;
    }

    fn validatePageBudget(page_budget: usize) RequestError!void {
        switch (page_budget) {
            1, 8, 32 => {},
            else => return error.InvalidPageBudget,
        }
    }
};
