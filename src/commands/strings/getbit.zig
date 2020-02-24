// GETBIT key offset

pub const GETBIT = struct {
    key: []const u8,
    offset: usize,

    pub fn init(key: []const u8, offset: usize) GETBIT {
        return .{ .key = key, .offset = offset };
    }

    pub fn validate(self: Self) !void {
        if (self.key.len == 0) return error.EmptyKeyName;
    }

    pub const RedisCommand = struct {
        pub fn serialize(self: GETBIT, comptime rootSerializer: type, msg: var) !void {
            return rootSerializer.serializeCommand(msg, .{ "GETBIT", self.key, self.offset });
        }
    };
};

test "basic usage" {
    const cmd = GETBIT.init("lol", 100);
}

test "serializer" {
    const std = @import("std");
    const serializer = @import("../../serializer.zig").CommandSerializer;

    var correctBuf: [1000]u8 = undefined;
    var correctMsg = std.io.SliceOutStream.init(correctBuf[0..]);

    var testBuf: [1000]u8 = undefined;
    var testMsg = std.io.SliceOutStream.init(testBuf[0..]);

    {
        correctMsg.reset();
        testMsg.reset();

        try serializer.serializeCommand(
            &testMsg.stream,
            GETBIT.init("mykey", 100),
        );
        try serializer.serializeCommand(
            &correctMsg.stream,
            .{ "GETBIT", "mykey", 100 },
        );

        std.testing.expectEqualSlices(u8, correctMsg.getWritten(), testMsg.getWritten());
    }
}