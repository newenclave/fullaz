# Use Components And Hierarchies

Each `.add("name", fullaz_db.component(...))` creates one separate component
in a compiled schema. Components share a transaction, but not their roots or
data.

## Choose A Component

| Need | Component |
| --- | --- |
| Sorted byte keys and range scans | `bpt` |
| Rectangle or box overlap queries | `rtree` |
| Take the smallest fixed-width priority key | `slotHeap` |
| Append and read one byte blob | `chainStore` |
| Edit bytes at offsets | `weightedSequence` |
| Store typed embedded components | `hierarchyStore` |

Use `bpt` for ordinary key/value records. Use `hierarchyStore` only when a
value must own another component with a durable type identity.

## B+ Tree And Blob

This small in-memory database stores users in a B+ tree and audit text in a
ChainStore.

```zig
const std = @import("std");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Schema = fullaz_db.Schema(.{ .page_id = u32 })
    .add("users", fullaz_db.bpt(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 1,
        .maximum_key_size = 32,
        .maximum_value_size = 128,
    }))
    .add("audit", fullaz_db.chainStore(.{}));
const Database = fullaz_db.MemoryDatabase(Schema);

pub fn main() !void {
    var database = try Database.init(std.heap.page_allocator, .{
        .page_size = 4096,
        .cache_frames = 32,
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    if (!try transaction.get("users").insert("ada", "Ada Lovelace")) {
        return error.UserAlreadyExists;
    }
    try transaction.get("audit").append("created ada\n");
    try transaction.commit();

    var found = (try database.getConst("users").find("ada")).?;
    defer found.deinit();
    const user = (try found.get()).?;
    std.debug.print("{s}\n", .{user.value});
}
```

The program prints:

```text
Ada Lovelace
```

`insert` returns `false` when the key already exists. `update` and `remove`
return `false` when the key is absent. An iterator owns a page pin, so call
`deinit` before a write, commit, or rollback.

`rtree` stores a bounding box and byte value for overlap queries. `slotHeap`
stores a fixed-width priority key and byte value. `chainStore` is for one blob.
`weightedSequence` is for editable byte sequences.

## Component Hierarchy

Use `hierarchyStore` when an entry must own a typed component. A normal B+ tree
stores plain byte values. A hierarchy B+ tree stores envelopes that hold raw
bytes or embedded child state.

This example creates an owner B+ tree named `files`. Its `root` entry owns an
embedded B+ tree named `folder`. The child tree then stores one raw note.

## Data Shape

`store` is the schema component. `files` is its named owner. Both the owner and
the `folder` child use a B+ tree, but they have different jobs.

```text
Database: MemoryDatabase(Schema)
|
`-- store: hierarchyStore
    |
    `-- files: owner B+ tree
        |
        `-- key "root"
            value: embedded envelope, type "folder"
            |
            `-- folder: embedded B+ tree
                |
                `-- key "note"
                    value: raw envelope, type "folder"
                    payload: "hello from a child"
```

The owner accepts type ID `1`, which is the `folder` type. The `folder` type
has no allowed child types in this example, so its entries can hold raw
`folder` envelopes but cannot embed another component.

```zig
const std = @import("std");
const fullaz_db = @import("fullaz-db");

fn compare(_: void, left: []const u8, right: []const u8) std.math.Order {
    return std.mem.order(u8, left, right);
}

const Folder = fullaz_db.bpt(.{
    .compare = compare,
    .CompareContext = void,
    .comparator_id = 1,
    .maximum_key_size = 32,
    .maximum_value_size = 96,
    .fixed_value_size = 96,
});

const Types = fullaz_db.Hierarchy(.{
    .registry_id = 1,
    .types = &.{.{
        .tag = "folder",
        .type_id = 1,
        .type_version = 1,
        .metadata_format_version = 1,
        .descriptor = Folder,
        .allowed_child_type_ids = &.{},
    }},
});

const Store = fullaz_db.hierarchyStore(Types, .{ .owners = &.{.{
    .tag = "files",
    .owner_id = 1,
    .descriptor = Folder,
    .allowed_type_ids = &.{1},
}} });
const Schema = fullaz_db.Schema(.{ .page_id = u32 }).add("store", Store);
const Database = fullaz_db.MemoryDatabase(Schema);

pub fn main() !void {
    var database = try Database.init(std.heap.page_allocator, .{
        .page_size = 1024,
        .components = .{ .store = .{ .owner_0 = .{} } },
    });
    defer database.deinit();

    var transaction = try database.begin();
    defer transaction.deinit();
    const files = transaction.get("store").owner("files");

    const root_value = try files.encodedEmbedded("folder");
    if (!try files.proxy().insert("root", root_value.data())) {
        return error.RootAlreadyExists;
    }

    const root_editor = (try files.proxy().openValueEditor("root")).?;
    var folder = try files.openChild(root_editor, "folder");
    defer folder.deinit();
    const note_value = try folder.encodedRaw("folder", "hello from a child");
    if (!try folder.proxy().insert("note", note_value.data())) {
        return error.NoteAlreadyExists;
    }
    try folder.finish();
    try transaction.commit();

    const files_const = database.getConst("store").owner("files");
    var folder_const = (try files_const.openEmbedded("root", "folder")).?;
    defer folder_const.deinit();
    var note = (try folder_const.proxy().find("note")).?;
    defer note.deinit();
    const envelope = try fullaz_db.value_envelope.readRaw(
        (try note.get()).?.value,
        Types.typeIdentityByTag("folder"),
    );
    std.debug.print("{s}\n", .{envelope.payload});
}
```

The program prints:

```text
hello from a child
```

`Hierarchy` lists durable child type IDs and allowed child relationships.
`hierarchyStore` lists named root owners and accepted types.

`encodedRaw(tag, bytes)` makes an envelope with ordinary bytes.
`encodedEmbedded(tag)` makes an envelope with an empty child component. Pass
`value.data()` to the native owner or child proxy.

Open a mutable child from a native value editor with `openChild`. Call
`finish()` for every successful child edit. Without it, `deinit()` invalidates
the parent edit and the transaction cannot commit. Close child iterators and
editors before `finish()`. Finish nested children from deepest to highest.

The `folder` type above has an empty `allowed_child_type_ids` list, so it is a
leaf. Add type ID `1` to that list to allow a folder to contain another folder.

Removing a hierarchy parent removes an ownership edge but does not immediately
free every child page. Use staged GC on a supported persistent typed database
when reclamation is needed.

[Previous: common errors](07-common-errors.md) | [fullaz-db documentation](../README.md)
