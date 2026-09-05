# fullaz-db Documentation

These guides use the `fullaz` Zig package. That package exports both `fullaz`
and `fullaz-db` modules.

Start with [Build a database with `fullaz-db`](getting-started/README.md) if you
need package setup, schema design, transactions, persistence, and common
errors.

Choose one guide:

- [Static WAL](static-database-quickstart.md): one fixed schema and direct page IDs.
- [Virtual Static WAL](virtual-static-database-quickstart.md): one fixed schema with logical page IDs.
- [Dynamic Schema WAL](dynamic-database-quickstart.md): one typed schema with a durable component catalog.

More local guides:

- [Components and hierarchies](getting-started/08-components-and-hierarchy.md)
- [Reclaim unreachable pages](getting-started/09-garbage-collection.md)

Each quick start has two commands:

- `format` creates a new image and WAL. The supplied `FileBlock.create` and
  `FileLog.create` calls truncate existing paths, so use it only with explicit
  overwrite intent.
- `open` opens the existing image and WAL without formatting them.
