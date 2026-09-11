//! Core HTTP values shared by requests, responses, routing, and adapters.
//! This module defines protocol values only. It does not allocate or perform I/O.

/// An HTTP request method supported by zapi.
pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
    HEAD,
    TRACE,
    CONNECT,

    /// Returns the uppercase wire representation.
    pub fn text(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .OPTIONS => "OPTIONS",
            .HEAD => "HEAD",
            .TRACE => "TRACE",
            .CONNECT => "CONNECT",
        };
    }

    /// Returns the lowercase OpenAPI operation name.
    pub fn openapiText(self: Method) []const u8 {
        return switch (self) {
            .GET => "get",
            .POST => "post",
            .PUT => "put",
            .PATCH => "patch",
            .DELETE => "delete",
            .OPTIONS => "options",
            .HEAD => "head",
            .TRACE => "trace",
            .CONNECT => "connect",
        };
    }

    /// Reports whether OpenAPI defines an operation for this method.
    pub fn supportsOpenApi(self: Method) bool {
        return switch (self) {
            .GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .HEAD, .TRACE => true,
            .CONNECT => false,
        };
    }
};

/// An HTTP response status, including extension status codes.
pub const Status = enum(u16) {
    continue_ = 100,
    switching_protocols = 101,
    processing = 102,
    early_hints = 103,
    ok = 200,
    created = 201,
    accepted = 202,
    non_authoritative_information = 203,
    no_content = 204,
    reset_content = 205,
    partial_content = 206,
    multi_status = 207,
    already_reported = 208,
    im_used = 226,
    multiple_choices = 300,
    moved_permanently = 301,
    found = 302,
    see_other = 303,
    not_modified = 304,
    use_proxy = 305,
    temporary_redirect = 307,
    permanent_redirect = 308,
    bad_request = 400,
    unauthorized = 401,
    payment_required = 402,
    forbidden = 403,
    not_found = 404,
    method_not_allowed = 405,
    not_acceptable = 406,
    proxy_authentication_required = 407,
    request_timeout = 408,
    conflict = 409,
    gone = 410,
    length_required = 411,
    precondition_failed = 412,
    payload_too_large = 413,
    uri_too_long = 414,
    unsupported_media_type = 415,
    requested_range_not_satisfiable = 416,
    expectation_failed = 417,
    im_a_teapot = 418,
    misdirected_request = 421,
    unprocessable_entity = 422,
    locked = 423,
    failed_dependency = 424,
    too_early = 425,
    upgrade_required = 426,
    precondition_required = 428,
    too_many_requests = 429,
    request_header_fields_too_large = 431,
    unavailable_for_legal_reasons = 451,
    internal_server_error = 500,
    not_implemented = 501,
    bad_gateway = 502,
    service_unavailable = 503,
    gateway_timeout = 504,
    http_version_not_supported = 505,
    variant_also_negotiates = 506,
    insufficient_storage = 507,
    loop_detected = 508,
    not_extended = 510,
    network_authentication_required = 511,
    _,

    /// Returns the numeric status code.
    pub fn code(self: Status) u16 {
        return @intFromEnum(self);
    }

    /// Creates a status from a standard or extension code.
    pub fn fromCode(value: u16) Status {
        return @enumFromInt(value);
    }

    /// Reports whether the status is in the 1xx range.
    pub fn isInformational(self: Status) bool {
        const status = self.code();
        return status >= 100 and status < 200;
    }

    /// Reports whether the status is in the 2xx range.
    pub fn isSuccess(self: Status) bool {
        const status = self.code();
        return status >= 200 and status < 300;
    }

    /// Reports whether the status is in the 3xx range.
    pub fn isRedirect(self: Status) bool {
        const status = self.code();
        return status >= 300 and status < 400;
    }

    /// Reports whether the status is in the 4xx range.
    pub fn isClientError(self: Status) bool {
        const status = self.code();
        return status >= 400 and status < 500;
    }

    /// Reports whether the status is in the 5xx range.
    pub fn isServerError(self: Status) bool {
        const status = self.code();
        return status >= 500 and status < 600;
    }

    /// Reports whether the status is a client or server error.
    pub fn isError(self: Status) bool {
        return self.isClientError() or self.isServerError();
    }

    /// Returns the standard reason phrase or a fallback for extension codes.
    pub fn reason(self: Status) []const u8 {
        return switch (self) {
            .continue_ => "Continue",
            .switching_protocols => "Switching Protocols",
            .processing => "Processing",
            .early_hints => "Early Hints",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multi_status => "Multi-Status",
            .already_reported => "Already Reported",
            .im_used => "IM Used",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .use_proxy => "Use Proxy",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .payload_too_large => "Payload Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .requested_range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a Teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_entity => "Unprocessable Entity",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",
            else => "Unknown Status",
        };
    }
};

/// A borrowed HTTP header name and value.
pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

/// Rejects header bytes that cannot be written safely to an HTTP message.
pub fn validateHeader(name: []const u8, value: []const u8) !void {
    if (name.len == 0) return error.InvalidHeader;
    for (name) |ch| {
        if (!isHeaderNameByte(ch)) return error.InvalidHeader;
    }
    for (value) |ch| {
        if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return error.InvalidHeader;
    }
}

fn isHeaderNameByte(ch: u8) bool {
    if (ch >= 'a' and ch <= 'z' or ch >= 'A' and ch <= 'Z' or ch >= '0' and ch <= '9') return true;
    return switch (ch) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
