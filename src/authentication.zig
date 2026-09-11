//! Authentication values recognized by endpoint parameter inference.
//! This module defines credentials and OpenAPI metadata markers. It does not authenticate requests.

const std = @import("std");

/// Credentials from an HTTP Bearer authorization header.
pub const BearerAuth = struct {
    token: []const u8,
};

/// One OAuth2 scope advertised through OpenAPI.
pub const OAuth2Scope = struct {
    name: []const u8,
    description: []const u8 = "",
};

/// Creates an OAuth2 password bearer credential type.
pub fn OAuth2PasswordBearer(comptime options: anytype) type {
    return struct {
        pub const zapi_oauth2_password_bearer = true;
        pub const zapi_scheme_name = if (@hasField(@TypeOf(options), "scheme_name"))
            options.scheme_name
        else
            "OAuth2PasswordBearer";
        pub const zapi_token_url = options.token_url;
        pub const zapi_scopes = if (@hasField(@TypeOf(options), "scopes")) options.scopes else &[_]OAuth2Scope{};

        token: []const u8,
    };
}

/// Creates an OAuth2 authorization code bearer credential type.
pub fn OAuth2AuthorizationCodeBearer(comptime options: anytype) type {
    return struct {
        pub const zapi_oauth2_authorization_code_bearer = true;
        pub const zapi_scheme_name = if (@hasField(@TypeOf(options), "scheme_name"))
            options.scheme_name
        else
            "OAuth2AuthorizationCodeBearer";
        pub const zapi_authorization_url = options.authorization_url;
        pub const zapi_token_url = options.token_url;
        pub const zapi_scopes = if (@hasField(@TypeOf(options), "scopes")) options.scopes else &[_]OAuth2Scope{};

        token: []const u8,
    };
}

/// Creates an OAuth2 client credentials bearer credential type.
pub fn OAuth2ClientCredentialsBearer(comptime options: anytype) type {
    return struct {
        pub const zapi_oauth2_client_credentials_bearer = true;
        pub const zapi_scheme_name = if (@hasField(@TypeOf(options), "scheme_name"))
            options.scheme_name
        else
            "OAuth2ClientCredentialsBearer";
        pub const zapi_token_url = options.token_url;
        pub const zapi_scopes = if (@hasField(@TypeOf(options), "scopes")) options.scopes else &[_]OAuth2Scope{};

        token: []const u8,
    };
}

/// Creates an OAuth2 implicit bearer credential type.
pub fn OAuth2ImplicitBearer(comptime options: anytype) type {
    return struct {
        pub const zapi_oauth2_implicit_bearer = true;
        pub const zapi_scheme_name = if (@hasField(@TypeOf(options), "scheme_name"))
            options.scheme_name
        else
            "OAuth2ImplicitBearer";
        pub const zapi_authorization_url = options.authorization_url;
        pub const zapi_scopes = if (@hasField(@TypeOf(options), "scopes")) options.scopes else &[_]OAuth2Scope{};

        token: []const u8,
    };
}

/// Credentials from an HTTP Basic authorization header.
pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *BasicAuth) void {
        if (self.arena) |*arena| arena.deinit();
    }
};

/// The request location of an API key.
pub const ApiKeyLocation = enum {
    header,
    query,
    cookie,

    pub fn openapiText(self: ApiKeyLocation) []const u8 {
        return switch (self) {
            .header => "header",
            .query => "query",
            .cookie => "cookie",
        };
    }
};

/// Creates a header API key credential type.
pub fn ApiKeyHeader(comptime name: []const u8) type {
    return ApiKey(.header, name);
}

/// Creates a query-string API key credential type.
pub fn ApiKeyQuery(comptime name: []const u8) type {
    return ApiKey(.query, name);
}

/// Creates a cookie API key credential type.
pub fn ApiKeyCookie(comptime name: []const u8) type {
    return ApiKey(.cookie, name);
}

fn ApiKey(comptime location: ApiKeyLocation, comptime name: []const u8) type {
    return struct {
        const Self = @This();
        pub const zapi_api_key_location = location;
        pub const zapi_api_key_name = name;

        key: []const u8,
        arena: ?std.heap.ArenaAllocator = null,

        pub fn deinit(self: *Self) void {
            if (self.arena) |*arena| arena.deinit();
        }
    };
}
