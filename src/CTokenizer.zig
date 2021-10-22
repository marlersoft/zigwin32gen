const std = @import("std");

const CTokenizer = @This();

src: []const u8,
off: usize,

pub fn init(src: []const u8) CTokenizer {
    return .{
        .src = src,
        .off = 0,
    };
}

pub fn next(self: *CTokenizer) ?[]const u8 {
    self.off = scanWhitespaceAndComments(self.src, self.off);
    if (self.off == self.src.len)
        return null;

    const c = self.src[self.off];
    if (c == '#' or c == '(' or c == ')') {
        const result = self.src[self.off..self.off+1];
        self.off += 1;
        return result;
    }

    var it = std.mem.tokenize(u8, self.src[self.off..], " \t\r\n#()");
    var opt_token = it.next();
    if (opt_token) |token| {
        self.off += token.len;
        return token;
    }
    return null;
}


fn scanWhitespaceAndComments(src: []const u8, start_offset: usize) usize {
    var off = start_offset;

    while (true) {
       if (off == src.len)
           return src.len;
       if (src[off] == ' ' or
           src[off] == '\t' or
           src[off] == '\n' or
           src[off] == '\r') {
           off += 1;
       } else if (src[off] == '/') {
           off += 1;
           if (off == src.len)
               return src.len;
           if (src[off] == '/') {
               off = scanPastScalar(src, off + 1, '\n');
           } else if (src[off] == '*') {
               off = scanPast(src, off + 1, "*/");
           }
       } else {
           return off;
       }
    }
}

fn scanPastScalar(src: []const u8, start_offset: usize, to: u8) usize {
    var off = start_offset;
    while (off < src.len) : (off += 1) {
        if (src[off] == to)
            return off + 1;
    }
    return src.len;
}

fn scanPast(src: []const u8, start_offset: usize, to: []const u8) usize {
    var off = start_offset;
    while (off + to.len <= src.len) : (off += 1) {
        if (std.mem.eql(u8, src[off..off+to.len], to))
            return off + to.len;
    }
    return src.len;
}
