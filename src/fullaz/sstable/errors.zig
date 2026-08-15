pub const EntryMetadata = error{
    InvalidMetadata,
};

pub const Footer = error{
    BufferTooSmall,
    BadMagic,
    BadVersion,
    BadHeaderSize,
    BadFooterSize,
    BadChecksum,
    BadSettings,
    BadRegion,
    BadTrailer,
};

pub const DataPage = error{
    BadMagic,
    BadVersion,
    BadHeaderSize,
    BadPageSize,
    BadBlockCount,
    BadBlockRecord,
    Unordered,
};

pub const Writer = error{
    EmptyTable,
    Finished,
    EntryCountMismatch,
    DuplicateKey,
    UnorderedKey,
    KeyTooLarge,
    ValueTooLarge,
    DataPageTooSmall,
    CountOverflow,
};

pub const Reader = error{
    ComparatorMismatch,
    BadFileSize,
    BadIndex,
    BadData,
    BadScratch,
};

pub const IndexStorage = error{};

pub const IndexLogBlock = error{
    BadData,
    InvalidId,
    ReadOnly,
};

pub const Merger = error{
    NoInputs,
    InvalidEstimate,
    ComparatorMismatch,
    OutputKeyTooSmall,
    OutputValueTooSmall,
    CountOverflow,
    UnorderedKey,
    EmptyOutput,
};
