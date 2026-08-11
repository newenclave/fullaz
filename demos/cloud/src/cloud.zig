const std = @import("std");
const fullaz = @import("fullaz");

const constants = @import("constants.zig");
const point = @import("point.zig");
const scene = @import("scene.zig");
const storage_mod = @import("storage.zig");
const superblock = @import("superblock.zig");
const trait = @import("trait.zig");

const orthtree = fullaz.spatial.orthtree;

pub fn defaultCamera() superblock.Camera {
    return .{
        .yaw = constants.default_camera_yaw,
        .pitch = constants.default_camera_pitch,
        .distance = constants.default_camera_distance,
        .target = constants.worldCentre(),
    };
}

pub fn Cloud(comptime PageCacheType: type) type {
    const ManagerT = storage_mod.Manager(PageCacheType);
    const LocationAccessor = orthtree.models.paged.NodePageLocationAccessor(
        constants.PageId,
        u16,
        constants.endian,
    );
    const FsmModelT = fullaz.storage.fsm.models.paged.slab.Model(
        PageCacheType,
        ManagerT,
        storage_mod.NodeSizePolicy,
        LocationAccessor,
    );
    const FsmT = fullaz.storage.fsm.Fsm(FsmModelT);
    const ModelT = orthtree.models.PagedImpl(
        PageCacheType,
        ManagerT,
        FsmT,
        constants.Coord,
        constants.dims,
        trait.SplatTrait,
        constants.endian,
    );
    const TreeT = orthtree.tree.TreeImpl(ModelT);

    return struct {
        const Self = @This();

        pub const Manager = ManagerT;
        pub const FsmModel = FsmModelT;
        pub const Fsm = FsmT;
        pub const Model = ModelT;
        pub const Tree = TreeT;
        pub const Box = ModelT.Box;
        pub const Trait = ModelT.Trait;
        pub const NodeId = ModelT.NodeId;

        // Distinct from node_page_kind and entry_page_kind so a mistyped page
        // is caught rather than reinterpreted.
        pub const fsm_page_kind: u16 = 0x32;

        gpa: std.mem.Allocator,
        cache: *PageCacheType,
        // Model points at Manager and Fsm, Fsm points at FsmModel, and both
        // format and open return Self by value. Any of them stored inline would
        // dangle the moment that copy happens.
        manager: *Manager,
        fsm_model: *FsmModel,
        fsm: *Fsm,
        model: *Model,
        tree: Tree,

        spec: scene.Spec,
        next_point_id: u32,
        camera: superblock.Camera,
        detail_fraction: f64,

        const Wired = struct {
            manager: *Manager,
            fsm_model: *FsmModel,
            fsm: *Fsm,
            model: *Model,
        };

        fn wire(gpa: std.mem.Allocator, cache: *PageCacheType, state: Manager.State) !Wired {
            const manager = try gpa.create(Manager);
            errdefer gpa.destroy(manager);
            manager.* = Manager.init(cache, state);

            const fsm_model = try gpa.create(FsmModel);
            errdefer gpa.destroy(fsm_model);
            fsm_model.* = FsmModel.init(cache, manager, .{}, .{ .page_kind = fsm_page_kind });

            const fsm = try gpa.create(Fsm);
            errdefer gpa.destroy(fsm);
            fsm.* = Fsm.init(fsm_model);

            const model = try gpa.create(Model);
            errdefer gpa.destroy(model);
            model.* = try Model.init(cache, manager, fsm, constants.tree_settings);

            return .{ .manager = manager, .fsm_model = fsm_model, .fsm = fsm, .model = model };
        }

        pub fn format(
            gpa: std.mem.Allocator,
            cache: *PageCacheType,
            block_size: u32,
            spec: scene.Spec,
            initial_points: u32,
        ) !Self {
            {
                var handle = try cache.create();
                defer handle.deinit();
                if (try handle.pid() != constants.superblock_pid) {
                    return error.NotFreshDevice;
                }
                var view = superblock.View(false).init(try handle.dataMut());
                view.format(block_size, spec.seed, spec.cluster_count);
            }
            try cache.flush(constants.superblock_pid);

            const wired = try wire(gpa, cache, .{});
            var self = Self{
                .gpa = gpa,
                .cache = cache,
                .manager = wired.manager,
                .fsm_model = wired.fsm_model,
                .fsm = wired.fsm,
                .model = wired.model,
                .tree = Tree.init(wired.model),
                .spec = spec,
                .next_point_id = 0,
                .camera = defaultCamera(),
                .detail_fraction = constants.default_detail_fraction,
            };
            // Mandatory: without it the first insert makes the root a
            // point-sized box and the second fails growing a zero extent.
            try self.tree.initRootBounds(constants.rootBox());
            _ = try self.insertPoints(initial_points);
            // Frame the cloud, not the cube: the root aggregate already knows
            // where the points actually ended up.
            if (self.manager.root) |root_id| {
                var root = try self.model.accessor().loadNode(root_id);
                defer self.model.accessor().deinitNode(&root);
                if (trait.Splat.count(root.trait()) > 0) {
                    self.camera.target = trait.Splat.centroid(root.trait());
                }
            }
            return self;
        }

        pub fn open(gpa: std.mem.Allocator, cache: *PageCacheType, block_size: u32) !Self {
            // Validated before the model exists: a mismatched page reaches
            // readViewUnchecked, which is `catch unreachable`.
            const restored = blk: {
                var handle = try cache.fetch(constants.superblock_pid);
                defer handle.deinit();
                const view = superblock.View(true).init(try handle.data());
                try view.validate(block_size);
                break :blk .{
                    .state = Manager.State{
                        .root = view.getRoot(),
                        .entries_count = try view.getEntriesCount(),
                        .fsm_class_root = view.getFsmClassRoot(),
                    },
                    .spec = scene.Spec{
                        .seed = view.getSeed(),
                        .cluster_count = view.getClusterCount(),
                    },
                    .next_point_id = view.getNextPointId(),
                    .camera = view.getCamera(),
                    .detail_fraction = view.getDetailFraction(),
                };
            };

            const wired = try wire(gpa, cache, restored.state);
            // No initRootBounds here: the root already exists and the call
            // would return AlreadyInitialized.
            return Self{
                .gpa = gpa,
                .cache = cache,
                .manager = wired.manager,
                .fsm_model = wired.fsm_model,
                .fsm = wired.fsm,
                .model = wired.model,
                .tree = Tree.init(wired.model),
                .spec = restored.spec,
                .next_point_id = restored.next_point_id,
                .camera = restored.camera,
                .detail_fraction = restored.detail_fraction,
            };
        }

        pub fn deinit(self: *Self) void {
            self.model.deinit();
            self.gpa.destroy(self.model);
            // Fsm.deinit poisons rather than frees, so it must run before the
            // model it borrows from is gone and before FsmModel is released.
            self.fsm.deinit();
            self.gpa.destroy(self.fsm);
            self.fsm_model.deinit();
            self.gpa.destroy(self.fsm_model);
            self.gpa.destroy(self.manager);
        }

        pub fn save(self: *Self) !void {
            {
                var handle = try self.cache.fetch(constants.superblock_pid);
                defer handle.deinit();
                var view = superblock.View(false).init(try handle.dataMut());
                view.setRoot(self.manager.root);
                view.setEntriesCount(self.manager.entries_count);
                view.setFsmClassRoot(self.manager.fsm_class_root);
                view.setNextPointId(self.next_point_id);
                view.setCamera(self.camera);
                view.setDetailFraction(self.detail_fraction);
            }
            try self.cache.flushAll();
        }

        // next_point_id advances only after the whole batch, so a partial
        // failure leaves the generator resumable at a clean boundary.
        pub fn insertPoints(self: *Self, count: u32) !u32 {
            var added: u32 = 0;
            while (added < count) : (added += 1) {
                const sample = scene.sampleAt(self.spec, self.next_point_id + added);
                const bytes = sample.record.bytes();
                try self.tree.insert(point.boxFor(sample.position), &bytes);
            }
            self.next_point_id += count;
            return added;
        }

        pub fn pointCount(self: *Self) !usize {
            return self.model.getEntriesCount();
        }

        pub fn rootBounds(self: *const Self) !?Box {
            return self.tree.bounds();
        }

        pub fn imageBytes(self: *const Self) usize {
            return self.cache.device.blocksCount() * self.cache.pageSize();
        }
    };
}
