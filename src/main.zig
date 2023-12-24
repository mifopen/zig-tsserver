const std = @import("std");

fn Request(comptime Args: type) type {
    return struct {
        seq: u32,
        type: MessageType,
        command: Command,
        arguments: Args,
    };
}

const StatusRequest = Request(void);

const OpenArgs = struct {
    file: []const u8,
};

const OpenRequest = Request(OpenArgs);

const ReferencesArgs = struct {
    file: []const u8,
    line: u32,
    offset: u32,
};

const ReferencesRequest = Request(ReferencesArgs);

fn Response(comptime Body: type) type {
    return struct {
        seq: u32,
        type: MessageType,
        command: Command,
        message: ?[]const u8 = null,
        request_seq: u32,
        success: bool,
        body: ?Body = null,
    };
}

const StatusResponseBody = struct {
    version: []const u8,
};

const Location = struct {
    line: u32,
    offset: u32,
};

const ReferencesResponseItem = struct {
    file: []const u8,
    start: Location,
    end: Location,
    contextStart: ?Location = null,
    contextEnd: ?Location = null,
    lineText: ?[]const u8 = null,
    isWriteAccess: bool,
    isDefinition: ?bool = null,
};

const ReferencesResponseBody = struct {
    refs: []const ReferencesResponseItem,
    symbolName: []const u8,
    symbolStartOffset: u32,
    symbolDisplayString: []const u8,
};

const MessageType = enum {
    request,
    response,
    event,
};

const Command = enum {
    status,
    open,
    references,
};

const TSServer = struct {
    allocator: std.mem.Allocator,
    p: std.ChildProcess,
    project_path: []const u8,

    pub fn status(self: @This()) !StatusResponseBody {
        const req = StatusRequest{
            // TODO track seq automatically
            .seq = 0,
            .type = .request,
            .command = .status,
            .arguments = {},
        };
        const writer = self.p.stdin.?.writer();
        try std.json.stringify(req, .{}, writer);
        try writer.writeByte('\n');
        var r = self.p.stdout.?.reader();
        try r.skipUntilDelimiterOrEof('\n');
        try r.skipUntilDelimiterOrEof('\n');
        var al = std.ArrayList(u8).init(self.allocator);
        const al_writer = al.writer();
        try r.streamUntilDelimiter(al_writer, '\n', null);
        const parsed = try std.json.parseFromSlice(
            Response(StatusResponseBody),
            self.allocator,
            al.items,
            .{},
        );
        return parsed.value.body.?;
    }

    pub fn open(self: @This(), file_name: []const u8) !void {
        const req = OpenRequest{
            .seq = 0,
            .type = .request,
            .command = .open,
            .arguments = .{
                .file = try std.fs.path.join(self.allocator, &.{ self.project_path, file_name }),
            },
        };
        const writer = self.p.stdin.?.writer();
        try std.json.stringify(req, .{}, writer);
        try writer.writeByte('\n');

        var r = self.p.stdout.?.reader();
        // 4 events
        var i: u32 = 0;
        while (i < 12) : (i += 1) {
            try r.skipUntilDelimiterOrEof('\n');
        }
    }

    pub fn references(self: @This(), file_name: []const u8, line: u32, offset: u32) !ReferencesResponseBody {
        const req = ReferencesRequest{
            .seq = 0,
            .type = .request,
            .command = .references,
            .arguments = .{
                .file = try std.fs.path.join(self.allocator, &.{ self.project_path, file_name }),
                .line = line,
                .offset = offset,
            },
        };
        const writer = self.p.stdin.?.writer();
        try std.json.stringify(req, .{}, writer);
        try writer.writeByte('\n');

        var r = self.p.stdout.?.reader();
        try r.skipUntilDelimiterOrEof('\n');
        try r.skipUntilDelimiterOrEof('\n');
        var al = std.ArrayList(u8).init(self.allocator);
        const al_writer = al.writer();
        try r.streamUntilDelimiter(al_writer, '\n', null);
        const parsed = try std.json.parseFromSlice(
            Response(ReferencesResponseBody),
            self.allocator,
            al.items,
            .{},
        );
        return parsed.value.body.?;
    }
};

pub fn init(allocator: std.mem.Allocator, project_path: []const u8) !TSServer {
    var p = std.ChildProcess.init(
        &[_][]const u8{ "bun", "./node_modules/typescript/lib/tsserver.js" },
        allocator,
    );
    p.cwd = project_path;
    p.stdin_behavior = .Pipe;
    p.stdout_behavior = .Pipe;
    try p.spawn();
    const r = p.stdout.?.reader();
    try r.skipUntilDelimiterOrEof('\n');
    try r.skipUntilDelimiterOrEof('\n');
    try r.skipUntilDelimiterOrEof('\n');
    return .{
        .p = p,
        .allocator = allocator,
        .project_path = project_path,
    };
}

// TODO
// Close = "close",
// Configure = "configure",
// Definition = "definition",
// DefinitionAndBoundSpan = "definitionAndBoundSpan",
// Exit = "exit",
// FileReferences = "fileReferences",
// References = "references",
// Reload = "reload",
// FindSourceDefinition = "findSourceDefinition",
// TypeDefinition = "typeDefinition",
// ProjectInfo = "projectInfo",
// UpdateOpen = "updateOpen",

// TODO I just can't
// var alloc = std.testing.allocator;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = gpa.allocator();
const path = "/Users/mif/Documents/GitHub/zig-tsserver/ts_test";

test "status" {
    var tsserver = try init(alloc, path);
    const status = try tsserver.status();
    try std.testing.expectEqualDeep(
        StatusResponseBody{ .version = "5.2.2" },
        status,
    );
}

test "references" {
    var tsserver = try init(alloc, path);
    try tsserver.open("someFile.ts");
    const references = try tsserver.references("someFile.ts", 1, 7);
    try std.testing.expectEqualDeep(ReferencesResponseBody{
        .symbolName = "a",
        .symbolDisplayString = "const a: 1",
        .symbolStartOffset = 7,
        .refs = &.{
            ReferencesResponseItem{
                .lineText = "const a = 1;",
                .start = Location{ .line = 1, .offset = 7 },
                .end = Location{ .line = 1, .offset = 8 },
                .contextStart = Location{ .line = 1, .offset = 1 },
                .contextEnd = Location{ .line = 1, .offset = 13 },
                .isDefinition = true,
                .isWriteAccess = true,
                .file = try std.fs.path.join(alloc, &.{ path, "someFile.ts" }),
            },
            ReferencesResponseItem{
                .lineText = "console.log(a);",
                .start = Location{ .line = 3, .offset = 13 },
                .end = Location{ .line = 3, .offset = 14 },
                .contextStart = null,
                .contextEnd = null,
                .isDefinition = false,
                .isWriteAccess = false,
                .file = try std.fs.path.join(alloc, &.{ path, "someFile.ts" }),
            },
        },
    }, references);
}
