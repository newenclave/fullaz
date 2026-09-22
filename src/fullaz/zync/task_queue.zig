pub fn TaskQueue(
    comptime SyncPolicyT: type,
    comptime StorageT: type,
) type {
    return struct {
        const Self = @This();

        pub const SyncPolicy = SyncPolicyT;
        pub const Storage = StorageT;
        pub const Task = Storage.Task;
        pub const Error = Storage.Error;

        sync: SyncPolicy,
        storage: Storage,

        pub fn init(sync: SyncPolicy, storage_policy: Storage.Policy) Self {
            return .{
                .sync = sync,
                .storage = .init(storage_policy),
            };
        }

        /// Requires exclusive access and no waiting threads.
        pub fn deinit(self: *Self) void {
            self.storage.deinit();
            self.* = undefined;
        }

        pub fn push(self: *Self, task: Task) Error!void {
            self.sync.lock();
            defer self.sync.unlock();

            try self.storage.push(task);
            self.sync.notifyOne();
        }

        /// Removes one task, or returns `null` without waiting for a producer.
        pub fn pop(self: *Self) ?Task {
            self.sync.lock();
            defer self.sync.unlock();

            return self.storage.pop();
        }

        /// Removes and returns the next task only when `predicate` accepts it.
        /// The predicate runs under the queue lock. It must not call queue methods
        /// or keep the task pointer after returning.
        pub fn popIf(
            self: *Self,
            ctx: anytype,
            predicate: fn (ctx: @TypeOf(ctx), task: *const Task) bool,
        ) ?Task {
            self.sync.lock();
            defer self.sync.unlock();

            const task = self.storage.peek() orelse return null;
            if (!predicate(ctx, &task)) {
                return null;
            }
            return self.storage.pop().?;
        }

        /// Copies the next task under the queue lock, then tests the snapshot
        /// after releasing the lock. References inside `Task` are not kept alive.
        pub fn testNext(
            self: *Self,
            ctx: anytype,
            predicate: fn (ctx: @TypeOf(ctx), task: *const Task) bool,
        ) bool {
            const next = blk: {
                self.sync.lock();
                defer self.sync.unlock();
                break :blk self.storage.peek();
            };
            const task = next orelse return false;
            return predicate(ctx, &task);
        }

        /// Waits until the queue is nonempty without reserving a task.
        pub fn wait(self: *Self) void {
            requireWaitSupport("wait");

            self.sync.lock();
            defer self.sync.unlock();

            while (self.storage.isEmpty()) {
                self.sync.wait();
            }
        }

        /// Waits until a task is available, then removes and returns it.
        pub fn waitPop(self: *Self) Task {
            requireWaitSupport("waitPop");

            self.sync.lock();
            defer self.sync.unlock();

            while (self.storage.isEmpty()) {
                self.sync.wait();
            }
            return self.storage.pop().?;
        }

        pub fn isEmpty(self: *Self) bool {
            self.sync.lock();
            defer self.sync.unlock();

            return self.storage.isEmpty();
        }

        fn requireWaitSupport(comptime operation: []const u8) void {
            if (comptime !SyncPolicy.supports_wait) {
                @compileError("zync.TaskQueue." ++ operation ++
                    " requires a synchronization policy with wait support");
            }
        }
    };
}
