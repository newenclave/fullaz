const std = @import("std");

// pub fn StateHolder(comptime StateLeaseT: type) type {
//     return struct {
//         const Self = @This();
//         fn stateCast(_: *const Self, lease: *const StateLeaseT) StateError!*const StateImpl {
//             const data = try lease.data();
//             if (data.len != @sizeOf(StateImpl)) {
//                 return error.BadData;
//             }
//             return @ptrCast(data.ptr);
//         }

//         fn stateCastMut(_: *const Self, lease: *StateLeaseT) StateError!*StateImpl {
//             const data = try lease.dataMut();
//             if (data.len != @sizeOf(StateImpl)) {
//                 return error.BadData;
//             }
//             return @ptrCast(data.ptr);
//         }
//     };
// }
