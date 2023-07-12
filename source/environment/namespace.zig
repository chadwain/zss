pub const NamespaceId = struct {
    value: Value,

    pub const Value = u8;
    pub const none = NamespaceId{ .value = 0 };
    pub const any = NamespaceId{ .value = 255 };
};
