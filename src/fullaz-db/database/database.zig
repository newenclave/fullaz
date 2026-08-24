const dynamic = @import("dynamic/dynamic.zig");
const schema = @import("dynamic/schema.zig");
const memory = @import("memory.zig");
const static = @import("static/static.zig");
const superblock = @import("static/superblock.zig");
const wal = @import("static/wal.zig");

pub const MemoryDatabase = memory.MemoryDatabase;
pub const StaticDatabase = static.StaticDatabase;
pub const StaticDatabaseWithWal = wal.StaticDatabaseWithWal;
pub const DynamicDatabase = dynamic.DynamicDatabase;
pub const DynamicDatabaseWithWal = dynamic.DynamicDatabaseWithWal;
pub const DynamicSchemaDatabase = schema.DynamicSchemaDatabase;
pub const DynamicSchemaDatabaseWithWal = schema.DynamicSchemaDatabaseWithWal;
pub const StaticSuperblock = superblock.StaticSuperblock;
