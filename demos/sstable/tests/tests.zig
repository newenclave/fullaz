const sstable = @import("sstable");

test "SSTable demo exports its dictionary" {
    _ = sstable.dictionary.Dictionary;
}
