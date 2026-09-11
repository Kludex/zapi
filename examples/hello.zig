const std = @import("std");
const zapi = @import("zapi");

const User = struct {
    id: u64,
    email: []const u8,
};

const CreateUser = struct {
    email: []const u8,
};

fn hello(ctx: *zapi.Context) !struct { message: []const u8 } {
    _ = ctx;
    return .{ .message = "Hello from Zig" };
}

fn createUser(ctx: *zapi.Context, body: zapi.Body(CreateUser)) !User {
    _ = ctx;
    return .{ .id = 1, .email = body.value.email };
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var app = zapi.App.init(gpa.allocator(), .{
        .title = "Hello Zapi",
        .version = "0.1.0",
    });
    defer app.deinit();

    const router = zapi.Router.init(.{
        .routes = .{
            zapi.Route.get("/", hello, .{ .summary = "Hello world" }),
            zapi.Route.post("/users", createUser, .{
                .status = .created,
                .summary = "Create user",
                .tags = &.{"users"},
            }),
        },
    });

    try app.includeRouter(router);

    var response = try app.handle(zapi.Request.init(.GET, "/openapi.json"));
    defer response.deinit(gpa.allocator());
    std.debug.print("{s}\n", .{response.body.items});
}
