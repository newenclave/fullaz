# Build A Database With `fullaz-db`

This guide builds a small typed database from an empty Zig project. It does not
require knowledge of page caches, WAL records, or file formats.

`fullaz-db` is a storage library, not SQL. Your program compiles the schema and
the component names.

## Read In Order

1. [Create a Zig project](00-project-setup.md)
2. [Design a schema from components](01-pages-schemas-and-components.md)
3. [Learn the Zig concepts used here](02-zig-concepts-used-by-fullaz-db.md)
4. [Build an in-memory database](03-first-memory-database.md)
5. [Choose a backend](04-choosing-a-backend.md)
6. [Use transactions and borrowed results](05-transactions-ownership-and-lifetimes.md)
7. [Prepare persistent storage](06-persistence-and-recovery.md)
8. [Diagnose common errors](07-common-errors.md)
9. [Use components and hierarchies](08-components-and-hierarchy.md)

## Persistent Quick Starts

- [Static WAL](../static-database-quickstart.md) is the normal typed durable database.
- [Virtual Static WAL](../virtual-static-database-quickstart.md) separates logical and physical page IDs.
- [Dynamic Schema WAL](../dynamic-database-quickstart.md) stores typed component metadata in a catalog. It needs careful manual pairing of its image and WAL.

The last chapter has a component chooser, a small B+ tree and blob example,
and a typed hierarchy example. Writing a component binding is outside this
local getting-started guide.

[fullaz-db documentation](../README.md)
