const std = @import("std");
const tt = std.testing;

pub fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    return std.mem.containsAtLeast(u8, haystack, 1, needle);
}

test "contains slice" {
    try tt.expect(!contains("something", ""));
    try tt.expect(contains("something", "some"));
    try tt.expect(!contains("something", "no"));
}

pub fn trimStart(slice: []const u8) []const u8 {
    var index: usize = 0;
    for (slice) |char| {
        if (!std.ascii.isWhitespace(char)) break;
        index += 1;
    }
    return slice[index..];
}

test "trim start" {
    try tt.expectEqualStrings("", trimStart(""));
    try tt.expectEqualStrings("", trimStart("   "));
    try tt.expectEqualStrings("a", trimStart("   a"));
    try tt.expectEqualStrings("a", trimStart("\n\t\ra"));
}
