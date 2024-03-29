const std = @import("std");
const builtin = @import("builtin");
const zlaap = @import("zlaap");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// A single namespace unit. Can fit 5 or 6 characters of a limited character set.
pub const Namespace = struct {
    /// The most significant bit determines which character encoding is used.
    bits: u31,

    /// Alphabetic encoding encodes exactly 6 characters matching [a-z _.-].
    /// Alphanumeric encoding encodes 1 to 5 characters matching [a-z0-9 _.-].
    pub const Encoding = enum(u1) {
        alphabetic = 0,
        alphanumeric = 1,
    };

    /// Return which encoding is used by this namespace.
    pub fn encoding(self: Namespace) Encoding {
        const alphanumeric = self.bits & (0b1 << 30) != 0;
        return @intToEnum(Encoding, @boolToInt(alphanumeric));
    }

    /// Encode up to 6 characters from the given slice, returning an error if
    /// any of the bytes are not part of the valid character set. Caller asserts
    /// that the input slice has at least one character in it.
    pub fn encode(input: []const u8) error{InvalidEncoding}!Namespace {
        var slice = input;
        return (try encodeNext(&slice)) orelse error.InvalidEncoding;
    }

    /// Encode up to 6 characters from the given slice, returning null if the
    /// slice is empty, or an error if any of the bytes are not part of the
    /// valid character set. The input slice will be updated automatically,
    /// allowing this function to be called repeatedly in a `while` loop.
    pub fn encodeNext(input: *[]const u8) error{InvalidEncoding}!?Namespace {
        // Initialize the slice of characters we are to encode.
        var slice = switch (input.len) {
            0 => return null,
            1...5 => input.*,
            else => input.*[0..6],
        };

        // Encode each character in the input string.
        var alphanumeric = slice.len < 6;
        var buf = [_]u8{0} ** 6;
        for (slice) |c, i| switch (c) {
            // Encode alphabetic characters into the range 1...26.
            'A'...'Z' => buf[i] = c - 'A' + 1,
            'a'...'z' => buf[i] = c - 'a' + 1,

            // Encode numeric characters into the range 31...40.
            '0'...'9' => {
                buf[i] = c - '0' + 31;
                alphanumeric = true;
            },

            // Encode special characters into the range 27...30.
            ' ' => buf[i] = 27,
            '_' => buf[i] = 28,
            '-' => buf[i] = 29,
            '.' => buf[i] = 30,

            // Return an error if the character doesn't fit in this encoding.
            else => return error.InvalidEncoding,
        };

        // Pack the encoded characters into an unsigned 31 bit integer.
        if (alphanumeric) {
            var bits: u32 = buf[0];
            for (buf[1..5]) |c| {
                bits <<= 6;
                bits |= c;
            }
            bits |= 0b1 << 30;
            input.* = input.*[std.math.min(5, slice.len)..];
            return Namespace{ .bits = @intCast(u31, bits) };
        } else {
            var bits: u32 = buf[0];
            for (buf[1..6]) |c| {
                bits <<= 5;
                bits |= c;
            }
            input.* = input.*[6..];
            return Namespace{ .bits = @intCast(u31, bits) };
        }
    }

    /// Decode a namespace into the target slice. Return an error if the bits
    /// could not have possibly been generated by this encoder.
    pub fn decode(
        self: Namespace,
        output: *[6]u8,
    ) error{InvalidEncoding}![]u8 {
        if (self.encoding() == .alphanumeric) {
            var i: usize = 5;
            var bits = @truncate(u30, self.bits);
            while (@truncate(u6, bits) == 0) {
                if (i == 1)
                    return error.InvalidEncoding;
                i -= 1;
                bits >>= 6;
            }
            const result = output[0..i];
            while (i > 0) {
                i -= 1;
                result[i] = switch (@truncate(u6, bits)) {
                    1...26 => |x| @as(u8, x - 1) + 'a',
                    31...40 => |x| @as(u8, x - 31) + '0',
                    27 => ' ',
                    28 => '_',
                    29 => '-',
                    30 => '.',
                    else => return error.InvalidEncoding,
                };
                bits >>= 6;
            }
            return result;
        } else {
            var bits = @intCast(u30, self.bits);
            var i: usize = 6;
            while (i > 0) {
                i -= 1;
                output[i] = switch (@truncate(u5, bits)) {
                    1...26 => |x| @as(u8, x - 1) + 'a',
                    27 => ' ',
                    28 => '_',
                    29 => '-',
                    30 => '.',
                    else => return error.InvalidEncoding,
                };
                bits >>= 5;
            }
            return output;
        }
    }

    /// Create a TextView into the Namespace. The iteration functionality of
    /// a TextView is unlikely to be useful, but the TextView also implements
    /// formatting APIs, making it trivial to use `std.log` and `writer.print`.
    pub fn textView(self: *const Namespace) TextView(true) {
        const as_array: *const [1]Namespace = self;
        return .{
            .items = as_array,
            .buf = undefined,
        };
    }

    /// Format the namespace value into a translation string.
    /// Best used via 'printer' APIs such as `writer.print` and `std.log`.
    pub fn format(
        self: Namespace,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("%{}$s", .{self.bits});
    }

    /// Parse a translation string back into a namespace. The provided slice must
    /// have exactly one translation string. Use `parseNext` for more flexibility.
    pub fn parse(string: []const u8) error{InvalidEncoding}!Namespace {
        return parseInternal(Mode.one, string);
    }

    /// Read a translation string into a namespace, then advance the
    /// pointer past the text. Returns null if the string is empty.
    pub fn parseNext(string: *[]const u8) error{InvalidEncoding}!?Namespace {
        return parseInternal(Mode.next, string);
    }

    /// Read a translation strings into a namespace, ignoring any characters that
    /// are clearly not translation strings. Returns null if the string is empty.
    pub fn parseLossy(string: *[]const u8) error{InvalidEncoding}!?Namespace {
        return parseInternal(Mode.lossy, string);
    }

    /// Underlying implementation for `parse`, `parseNext`, and `parseLossy`.
    const Mode = enum { one, next, lossy };
    fn parseInternal(
        comptime mode: Mode,
        string: if (mode == .one) []const u8 else *[]const u8,
    ) error{InvalidEncoding}!(if (mode == .one) Namespace else ?Namespace) {
        var slice = if (mode == .one) string else string.*;
        outer: while (slice.len >= 4) : (slice = slice[1..]) {
            // Each translation string starts with a `%` character.
            if (slice[0] != '%') {
                if (mode == .lossy) continue :outer;
                return error.InvalidEncoding;
            }

            // Initialize our bits value by reading the first digit.
            var bits: u31 = switch (slice[1]) {
                '1'...'9' => |x| @intCast(u31, x - '0'),
                else => if (mode == .lossy) continue :outer else break :outer,
            };

            // Parse the rest of the translation string into the namespace.
            slice = slice[2..];
            while (slice.len > 0) : (slice = slice[1..]) {
                switch (slice[0]) {
                    '0'...'9' => |x| {
                        // We treat integer overflow as a hard error even in lossy mode.
                        // It's clear even in lossy mode that this is supposed to be a
                        // translation string, but the integer was too large. This is an
                        // error we need to report instead silently ignoring.
                        const n = @intCast(u31, x - '0');
                        bits = std.math.mul(u31, bits, 10) catch break;
                        bits = std.math.add(u31, bits, n) catch break;
                    },
                    '$' => {
                        // `.one` is for exact matches, so we reject any trailing characters
                        // in that mode. In other modes, trailing characters are irrelevant.
                        const badlen = if (mode == .one)
                            slice.len != 2
                        else
                            slice.len < 2;

                        // Toss out this translation string if it's missing the `s` or is
                        // an incorrect length for the selected mode.
                        if (badlen or slice[1] != 's') {
                            if (mode != .lossy) break;
                            continue :outer;
                        }

                        // Update the slice we're iterating and return the namespace unit.
                        if (mode != .one)
                            string.* = slice[2..];
                        return Namespace{ .bits = bits };
                    },
                    else => {
                        if (mode != .lossy) break;
                        continue :outer;
                    },
                }
            }
            return error.InvalidEncoding;
        }

        // This codepath is reached if no value was found. Each mode handles this
        // case differently (this is, in fact, why the modes exist).
        switch (mode) {
            .lossy => string.* = slice[slice.len..],
            .next => if (string.len > 0) return error.InvalidEncoding,
            .one => return error.InvalidEncoding,
        }
        return null;
    }
};

/// A string of namespace units; used as an intermediary between raw text and
/// series of translation strings. Convenient for conversion between raw argument
/// strings provided by the OS and useful values that can be formatted or decoded.
pub const NamespaceString = struct {
    /// Iteration and modification of this field is permitted.
    items: []Namespace,

    /// ArrayList used in the initialization process.
    const List = std.ArrayListUnmanaged(Namespace);

    /// Create a NamespaceString by parsing a string formed of characters
    /// conforming to the regex [A-Za-z0-9 _.-]. This function will allocate
    /// memory (likely a smaller amount than the input string consumes).
    /// Caller is responsible for calling `deinit` to deallocate the string.
    pub fn encodeAll(
        allocator: Allocator,
        string: []const u8,
    ) error{ OutOfMemory, InvalidEncoding }!NamespaceString {
        // Initialize a buffer with the capacity to hold the full namespace string.
        const capacity = std.math.divCeil(usize, string.len, 5) catch unreachable;
        var buf = try List.initCapacity(allocator, capacity);
        errdefer buf.deinit(allocator);

        // Convert the text we were passed into a namespace string.
        var slice = string;
        while (try Namespace.encodeNext(&slice)) |n|
            buf.appendAssumeCapacity(n);
        return NamespaceString{ .items = buf.toOwnedSlice(allocator) };
    }

    /// Create a NamespaceString by parsing a string formed of translated strings
    /// obtained by previously formatting a Namespace or NamespaceString. This then
    /// facilitates the retrieval of the original text used to create the namespace.
    /// Caller is responsible for calling `deinit` to deallocate the string.
    pub fn parseAll(
        allocator: Allocator,
        string: []const u8,
    ) error{ OutOfMemory, InvalidEncoding }!NamespaceString {
        return parseInternal(allocator, string, Namespace.parseNext);
    }

    /// Create a NamespaceString by parsing a string formed of translated strings
    /// obtained by previously formatting a Namespace or NamespaceString. Any
    /// characters that are clearly not part of a translation string are ignored.
    /// Caller is responsible for calling `deinit` to deallocate the string.
    pub fn parseLossy(
        allocator: Allocator,
        string: []const u8,
    ) error{ OutOfMemory, InvalidEncoding }!NamespaceString {
        return parseInternal(allocator, string, Namespace.parseLossy);
    }

    /// Underlying implementation for `parseAll` and `parseLossy`.
    fn parseInternal(
        allocator: Allocator,
        string: []const u8,
        comptime next: anytype,
    ) error{ OutOfMemory, InvalidEncoding }!NamespaceString {
        // Initialize a buffer to hold the decoded namepsace string.
        var buf = List{};
        errdefer buf.deinit(allocator);

        // Convert the translation strings we were passed into a namespace string.
        var slice = string;
        while (try next(&slice)) |n|
            try buf.append(allocator, n);
        return NamespaceString{ .items = buf.toOwnedSlice(allocator) };
    }

    /// Free memory allocated by `fromText` or `fromTranslationString`.
    pub fn deinit(self: NamespaceString, allocator: Allocator) void {
        allocator.free(self.items);
    }

    /// Create a TextView into the NamespaceString. TextViews serve as iterators
    /// over decoded fragments of the NamespaceString, but they also implement
    /// the formatting APIs, making conversion into textual form very simple.
    ///
    /// If `strict` is true, `.next()` and `.format()` will return an error upon
    /// encountering a value that is impossible to `.decode()`. If `strict` is
    /// false, any such values will simply be skipped. A value of false is useful
    /// to skip over "real" substitution strings such as `%1$s`; instead only
    /// printing the subsitution strings that form an encoded namespace.
    pub fn textView(self: NamespaceString, comptime strict: bool) TextView(strict) {
        return .{
            .items = self.items,
            .buf = undefined,
        };
    }

    /// Format the namespace string into a series of translation strings.
    /// Best used via 'printer' APIs such as `writer.print` and `std.log`.
    pub fn format(
        self: NamespaceString,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        for (self.items) |item|
            try writer.print("%{}$s", .{item.bits});
    }
};

/// An iterator over a series of namespaces in decoded text form. Strings returned
/// via iteration will be short (between 1 and 6 characters). To make this type a
/// bit more useful, it also implements the stdlib formatting API, meaning that
/// utilities like `std.log`, `writer.print`, and `bufPrint` all work on TextView.
///
/// To create a TextView, call `textView` on a Namespace or NamespaceString. The
/// TextView does not allocate or own memory; its lifetime is tied to the Namespace
/// or NamespaceString used to construct it. This allows convenient usage such as:
///
/// ```
/// std.log.info("{}", .{namespace.textView(true)});
/// ```
pub fn TextView(comptime strict: bool) type {
    return struct {
        /// The set of namespace strings to iterate over.
        items: []const Namespace,

        /// Temporary buffer for the decoded text.
        buf: [6]u8,

        /// In strict mode, errors are propagated through the writer and iterator.
        /// Otherwise, iteration simply skips them; this is useful for skipping the
        /// initial `%1$s` commonly seen in practical usage of the namespace trick.
        const Next = if (strict) error{InvalidEncoding}!?[]u8 else ?[]u8;
        const Next2 = if (strict) Next else error{}!Next;

        /// Decode the text of the next namespace string, or return null if no namespace
        /// strings remain to decode. The return value is only valid until a subsequent
        /// call to `next`. Use `allocator.dupe` to save the text for longer.
        pub fn next(self: *@This()) Next {
            while (self.items.len > 0) {
                defer self.items = self.items[1..];
                return self.items[0].decode(&self.buf) catch |err| {
                    if (strict) return err else continue;
                };
            } else return null;
        }

        /// Format the namespace string into its original, textual form.
        /// Best used via "printer" APIs such as `writer.print` and `std.log`.
        pub fn format(
            self: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            _ = fmt;
            var copy = self;
            while (try @as(Next2, copy.next())) |text|
                try writer.writeAll(text);
        }
    };
}

const Arguments = struct {
    state: State,

    fn init(allocator: Allocator) !Arguments {
        return Arguments{ .state = try State.init(allocator) };
    }

    fn next(self: *Arguments) ?[]const u8 {
        if (builtin.os.tag == .windows) {
            if (self.state.iterator.decodeNext(.wtf8, self.state.buf[self.state.buf_idx..]) catch unreachable) |result| {
                self.state.buf_idx += result.len;
                return result;
            } else return null;
        }
        return self.state.iterator.next() orelse return null;
    }

    const State = switch (builtin.os.tag) {
        .windows => struct {
            iterator: zlaap.WindowsArgIterator,
            buf_idx: usize = 0,
            buf: [98304]u8 = undefined,

            fn init(_: Allocator) !@This() {
                return @This(){ .iterator = zlaap.WindowsArgIterator.init() };
            }
        },
        .wasi => struct {
            iterator: zlaap.ArgvIterator,
            buf: zlaap.WasiArgs,

            fn init(allocator: Allocator) !@This() {
                var buf = zlaap.WasiArgs{};
                const iterator = try buf.iterator(allocator);
                return @This(){
                    .iterator = iterator,
                    .buf = buf,
                };
            }
        },
        else => struct {
            iterator: zlaap.ArgvIterator,

            fn init(_: Allocator) !@This() {
                return @This(){ .iterator = zlaap.ArgvIterator.init() };
            }
        },
    };
};

fn printUsage(exe: []const u8, status: u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\transpace - Minecraft Translate Namespace Encoder
        \\
        \\Usage: {s} [options] [string]
        \\Options:
        \\  -h, --help     Print this help and exit
        \\  -V, --version  Print the version number and exit
        \\  --encode       Encode namespace into translation string
        \\  --decode       Decode translation string into namespace
        \\
    , .{exe});
    std.process.exit(status);
}

fn behaviorAlreadySet(exe: []const u8, behavior: []const u8) void {
    std.log.err(
        \\behavior already set to `{s}`
        \\See `{s} --help` for detailed usage information
    , .{ behavior, exe });
    std.process.exit(1);
}

pub fn main() !void {
    var arena = ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    // Initialize argv iterator and retrieve executable name.
    var argv = try Arguments.init(allocator);
    const exe = argv.next() orelse "transpace";

    // Process the list of command line arguments.
    var end_mark = false;
    var args: usize = 0;
    var string: []const u8 = undefined;
    var behavior: ?enum { encode, decode } = null;
    var any_args_exist: bool = false;
    while (argv.next()) |arg| {
        any_args_exist = true;
        if (!end_mark and std.mem.startsWith(u8, arg, "-")) {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try printUsage(exe, 0);
            } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
                const stdout = std.io.getStdOut();
                try stdout.writeAll("0.2.0\n");
                std.process.exit(0);
            } else if (std.mem.eql(u8, arg, "--encode")) {
                if (behavior) |b| {
                    behaviorAlreadySet(exe, @tagName(b));
                } else behavior = .encode;
            } else if (std.mem.eql(u8, arg, "--decode")) {
                if (behavior) |b| {
                    behaviorAlreadySet(exe, @tagName(b));
                } else behavior = .decode;
            } else if (std.mem.eql(u8, arg, "--")) {
                end_mark = true;
            } else {
                std.log.err(
                    \\unknown option: {s}
                    \\See `{s} --help` for detailed usage information
                , .{ arg, exe });
                std.process.exit(1);
            }
        } else {
            string = arg;
            args += 1;
        }
    } else if (!any_args_exist) try printUsage(exe, 1);

    // Validate the passed arguments.
    if (args != 1) {
        std.log.err(
            \\expected 1 positional argument, found {}
            \\See `{s} --help` for detailed usage information
        , .{ args, exe });
        std.process.exit(1);
    }
    if (string.len == 0)
        std.process.exit(0);
    if (behavior == null) {
        behavior = if (string[0] != '%') .encode else .decode;
    }

    // Perform the requested operation.
    switch (behavior.?) {
        .encode => {
            // Encode the provided string into a translation namespace.
            const namespace = NamespaceString.encodeAll(allocator, string) catch |err| switch (err) {
                error.InvalidEncoding => {
                    std.log.err(
                        \\namespace contains characters outside of [A-Za-z0-9 _.-]
                        \\See `{s} --help` for detailed usage information
                    , .{exe});
                    std.process.exit(1);
                },
                else => return err,
            };
            defer namespace.deinit(allocator);

            // Print the namespaced translation string.
            const stdout = std.io.getStdOut().writer();
            try stdout.print("%1$s{}\n", .{namespace});
        },
        .decode => {
            // Decode the translation string into a translation namespace.
            const namespace = NamespaceString.parseLossy(allocator, string) catch |err| switch (err) {
                error.InvalidEncoding => {
                    std.log.err(
                        \\translation string contains too large of an integer
                        \\See `{s} --help` for detailed usage information
                    , .{exe});
                    std.process.exit(1);
                },
                else => return err,
            };
            defer namespace.deinit(allocator);

            // Print the initial text used to create the translation namespace.
            const stdout = std.io.getStdOut().writer();
            try stdout.print("{}\n", .{namespace.textView(false)});
        },
    }
}
