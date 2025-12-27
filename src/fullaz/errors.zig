pub const BufferError = error{
    BufferTooSmall,
    BadLength,
};

pub const Common = error{
    IndexOutOfBounds,
    ReadOnly,
};
