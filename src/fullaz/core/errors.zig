pub const EmptySet = error{};

pub const HandleError = error{
    InvalidHandle,
};

pub const IteratorError = error{
    InvalidIterator,
    EndOfIterator,
};

pub const PageError = error{
    InvalidId,
    BadType,
} || HandleError;

pub const NotFoundError = error{
    KeyNotFound,
    NodeNotFound,
    PageNotFound,
};

pub const CacheError = error{
    NoFreeFrames,
};

pub const IndexError = error{
    OutOfBounds,
};

pub const BufferError = error{
    BadLength,
    ReadOnly,
};

pub const SpaceError = error{
    BufferTooSmall,
    NotEnoughSpace,
};

pub const LayoutError = error{
    InconsistentLayout,
};

pub const SlotsError = IndexError || SpaceError || LayoutError;
pub const StaticVectorError = IndexError || SpaceError;

pub const OrderError = error{
    Unordered,
};

pub const BptError = error{
    ChildNotFoundInParent,
    NoParent,
    NodeFull,
    KeyTooLarge,
    ValueTooLarge,
    NotEnoughTemporaryBuffer,
    NotEnoughSpaceForUpdate,
};
