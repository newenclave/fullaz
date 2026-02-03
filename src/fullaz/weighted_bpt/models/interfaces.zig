const std = @import("std");
const contracts = @import("../../contracts/contracts.zig");
const interfaces = @import("../../contracts/interfaces.zig");

const requiresFnSignature = interfaces.requiresFnSignature;
const requiresFnReturnsError = interfaces.requiresFnReturnsAnyError;
const requiresErrorDeclaration = interfaces.requiresErrorDeclaration;
const requiresTypeDeclaration = interfaces.requiresTypeDeclaration;
