# Choose A Backend

Choose the factory before creating the database. Typed factories share `Schema`,
`begin`, `get`, `getConst`, and component APIs, but have different durability
and initialization rules.

| Factory | Use it for | Important consequence |
| --- | --- | --- |
| `MemoryDatabase(Schema)` | Tests and short-lived data | Pages disappear at `deinit`. |
| `StaticDatabase(Schema, Device)` | Controlled images without a WAL | It has a dirty marker, but no atomic recovery or guaranteed torn-commit detection. |
| `StaticDatabaseWithWal(Schema, Device, Log)` | Normal durable typed applications | Keep the identity-bound image and WAL together. |
| `VirtualStaticDatabaseWithWal(Schema, Device, Log)` | Stable logical page IDs | It uses a different format and identity-bound WAL. |
| `VirtualStaticDatabaseWithCow(Schema, Device)` | Experimental WAL-free virtual storage | Append-only pages and alternating superblocks; do not choose it as a first backend. |
| `DynamicDatabase(Device)` | Raw catalog tooling | The caller maintains catalog and component invariants. |
| `DynamicDatabaseWithWal(Device, Log)` | Advanced raw catalog tooling | Its image and WAL pairing is not identity-checked. |
| `DynamicSchemaDatabase(Schema, Device)` | Typed catalog-backed storage without WAL | It has durable catalog metadata but no atomic recovery. |
| `DynamicSchemaDatabaseWithWal(Schema, Device, Log)` | Advanced typed catalog-backed storage | Its image and WAL pairing is not identity-checked. |

## Normal Choice

1. Use `MemoryDatabase` while designing and testing.
2. Use `StaticDatabaseWithWal` for a normal persistent typed application.
3. Use `VirtualStaticDatabaseWithWal` only when stable logical page IDs matter.
4. Use Dynamic factories only when their catalog model is required and your
   application controls the image and WAL pair carefully.

Dynamic schema databases are not SQL `CREATE TABLE`. Their typed component
names still come from the compiled `Schema`.

[Previous: memory database](03-first-memory-database.md) | [Next: transactions](05-transactions-ownership-and-lifetimes.md)
