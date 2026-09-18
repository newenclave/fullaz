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
