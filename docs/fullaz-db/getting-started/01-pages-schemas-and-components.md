# Design A Schema From Components

A `fullaz-db` schema is a compile-time list of structures in one database. Each
`.add` creates one separately rooted component.

| Need | Component |
| --- | --- |
| Sorted key/value records and range scans | B+ tree |
| Rectangles or geographic bounds | R-tree |
| Read the smallest priority key first | SlotHeap |
| One appendable byte blob | ChainStore |
| Insert and remove bytes in a sequence | WeightedSequence |

See [Use components and hierarchies](08-components-and-hierarchy.md) for a
short description and runnable B+ tree and blob example.

## A Multi-Component Schema

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
    .add("places", fullaz_db.rtree(.{
        .Coord = f32,
        .dimensions = 2,
        .maximum_entries = 8,
        .maximum_value_size = 32,
    }))
    .add("jobs", fullaz_db.slotHeap(.{
        .compare = compare,
        .CompareContext = void,
        .comparator_id = 2,
        .maximum_key_size = 8,
        .maximum_value_size = 128,
    }))
    .add("audit", fullaz_db.chainStore(.{}))
    .add("document", fullaz_db.weightedSequence(.{
        .maximum_chunk_size = 256,
    }));
```

The declaration is a type. Use it to create a database type:

```zig
const Database = fullaz_db.MemoryDatabase(Schema);
```

## Names And IDs

Component names are compile-time values:

```zig
const users = transaction.get("users");
_ = users;
```

`transaction.get(name_from_request)` does not work. Model user-created tables
as records inside a component instead.

Use a fixed-width page ID such as `u32`. Do not use `usize` or `isize` because
their width changes between targets.

`comparator_id` is a durable version of the whole ordering rule. Give a new ID
to any changed comparator or ordering-related context, then migrate or rebuild
the component. The comparator must give a deterministic total order for stored
keys.

`SlotHeap.maximum_key_size` is currently an exact key width. Every key passed
to `push` must have exactly that many bytes.

Static and virtual-static databases require ordered components with
`CompareContext = void`. Other backends can support a context but may need it
in component initialization options.

Use [components and hierarchies](08-components-and-hierarchy.md) when an entry
must own a typed child component.

[Previous: project setup](00-project-setup.md) | [Next: Zig concepts](02-zig-concepts-used-by-fullaz-db.md)
