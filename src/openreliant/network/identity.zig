//! OpenReliant game identities for direct IP, using the pinned transport's certificate format.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Ed25519 = std.crypto.sign.Ed25519;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Writer = Io.Writer;

pub const PublicKey = Ed25519.PublicKey;
const KeyPair = Ed25519.KeyPair;
pub const host_name = "host";
pub const seed_file = "server.key";
const Seed = [KeyPair.seed_length]u8;
const lease_seconds = 24 * std.time.s_per_hour;
pub const renew_after_us = lease_seconds * std.time.us_per_s / 2;
const clock_skew = std.time.s_per_min;

fn newKey(io: Io) !KeyPair {
    var seed: Seed = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try io.randomSecure(&seed);
    return KeyPair.generateDeterministic(seed);
}

fn readSeed(io: Io, directory: Io.Dir, seed: *Seed) !void {
    const file = try directory.openFile(io, seed_file, .{ .allow_directory = false, .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != seed.len) return error.InvalidServerKey;
    if (builtin.os.tag != .windows and stat.permissions.toMode() & 0o077 != 0)
        return error.InsecureServerKeyPermissions;
    if (try file.readPositionalAll(io, seed, 0) != seed.len) return error.InvalidServerKey;
}

/// Publish a complete seed once. Two launchers starting together both use the published key.
fn serverKey(io: Io, directory: Io.Dir) !KeyPair {
    var seed: Seed = undefined;
    defer std.crypto.secureZero(u8, &seed);
    readSeed(io, directory, &seed) catch |err| switch (err) {
        error.FileNotFound => {
            try io.randomSecure(&seed);
            var file = try directory.createFileAtomic(io, seed_file, .{
                .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
            });
            defer file.deinit(io);
            try file.file.writeStreamingAll(io, &seed);
            try file.file.sync(io);
            file.link(io) catch |link_error| switch (link_error) {
                error.PathAlreadyExists => try readSeed(io, directory, &seed),
                else => return link_error,
            };
        },
        else => return err,
    };
    return KeyPair.generateDeterministic(seed);
}

fn fingerprint(key: PublicKey) [Sha256.digest_length]u8 {
    var hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&key.toBytes(), &hash, .{});
    return hash;
}

const ssh_header = "\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20";
const ssh_key_size = std.base64.standard.Encoder.calcSize(ssh_header.len + PublicKey.encoded_length);
pub fn openSshKey(key: PublicKey) ["ssh-ed25519 ".len + ssh_key_size]u8 {
    const prefix = "ssh-ed25519 ";
    const blob = ssh_header.* ++ key.toBytes();
    var line: [prefix.len + ssh_key_size]u8 = undefined;
    line[0..prefix.len].* = prefix.*;
    _ = std.base64.standard.Encoder.encode(line[prefix.len..], &blob);
    return line;
}

pub const Invite = struct {
    address: Io.net.IpAddress,
    key: PublicKey,

    pub const prefix = "orl1:";
    pub const max_address = 64;
    const key_length = std.base64.url_safe_no_pad.Encoder.calcSize(PublicKey.encoded_length);

    pub fn hasAddress(address: Io.net.IpAddress) bool {
        return switch (address) {
            inline .ip4, .ip6 => |ip| !std.mem.allEqual(u8, &ip.bytes, 0),
        };
    }

    pub fn parse(text: []const u8) !Invite {
        const value = std.mem.cutPrefix(u8, text, prefix) orelse return error.InvalidInvite;
        const sep = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidInvite;
        const key_text = value[sep + 1 ..];
        if (sep > max_address or key_text.len != key_length) return error.InvalidInvite;
        const address = Io.net.IpAddress.parseLiteral(value[0..sep]) catch return error.InvalidInvite;
        if (address.getPort() == 0 or !hasAddress(address)) return error.InvalidInvite;
        var key: [PublicKey.encoded_length]u8 = undefined;
        std.base64.url_safe_no_pad.Decoder.decode(&key, key_text) catch return error.InvalidInvite;
        return .{ .address = address, .key = PublicKey.fromBytes(key) catch return error.InvalidInvite };
    }

    pub fn format(invite: Invite, out: *Writer) Writer.Error!void {
        var text: [key_length]u8 = undefined;
        const key_text = std.base64.url_safe_no_pad.Encoder.encode(&text, &invite.key.toBytes());
        try out.print(prefix ++ "{f}/{s}", .{ invite.address, key_text });
    }
};

// Field numbers from steamnetworkingsockets_messages_certs.proto. Only the fields this issuer
// sets are encoded here. GameNetworkingSockets reads them and checks the signature.
const CertField = enum(u5) { key_type = 1, key_data = 2, time_created = 8, time_expiry = 9, app_ids = 10, identity_string = 12 };
const SignedField = enum(u5) { private_key_data = 1, cert = 4, ca_key_id = 5, ca_signature = 6 };
const FieldType = enum(u3) { varint = 0, fixed64 = 1, bytes = 2, fixed32 = 5 };

fn field(out: *Writer, tag: anytype, kind: FieldType) Writer.Error!void {
    try out.writeByte(@as(u8, @backingInt(tag)) << 3 | @backingInt(kind));
}

fn bytesField(out: *Writer, tag: anytype, data: []const u8) Writer.Error!void {
    try field(out, tag, .bytes);
    try out.writeLeb128(data.len);
    try out.writeAll(data);
}

pub const Certificate = struct {
    bytes: [216]u8 = undefined,
    len: usize,

    pub fn slice(cert: *const Certificate) []const u8 {
        return cert.bytes[0..cert.len];
    }

    pub fn wipe(cert: *Certificate) void {
        std.crypto.secureZero(u8, &cert.bytes);
    }
};

pub const Server = struct {
    issuer: KeyPair,
    leaf: KeyPair,

    pub fn load(io: Io, directory: Io.Dir) !Server {
        var issuer = try serverKey(io, directory);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&issuer));
        return .{ .issuer = issuer, .leaf = try newKey(io) };
    }

    pub fn hostCertificate(server: *const Server, io: Io) !Certificate {
        const now = Io.Clock.real.now(io).toSeconds();
        if (now < clock_skew or now > std.math.maxInt(u32) - lease_seconds) return error.InvalidCertificateTime;

        var certificate: [96]u8 = undefined;
        var out = Writer.fixed(&certificate);
        try field(&out, CertField.key_type, .varint);
        try out.writeByte(1); // ED25519
        try bytesField(&out, CertField.key_data, &server.leaf.public_key.toBytes());
        try field(&out, CertField.time_created, .fixed32);
        try out.writeInt(u32, @intCast(now - clock_skew), .little);
        try field(&out, CertField.time_expiry, .fixed32);
        try out.writeInt(u32, @intCast(now + lease_seconds), .little);
        try field(&out, CertField.app_ids, .varint);
        try out.writeByte(0); // The standalone transport uses app ID zero.
        try bytesField(&out, CertField.identity_string, "str:" ++ host_name);
        const inner = out.buffered();

        var signed: Certificate = .{ .len = 0 };
        var envelope = Writer.fixed(&signed.bytes);
        try bytesField(&envelope, SignedField.cert, inner);
        try field(&envelope, SignedField.ca_key_id, .fixed64);
        const key_id = fingerprint(server.issuer.public_key)[0..@sizeOf(u64)].*;
        try envelope.writeAll(&key_id);
        try bytesField(&envelope, SignedField.ca_signature, &(try server.issuer.sign(inner, null)).toBytes());
        var seed = server.leaf.secret_key.seed();
        defer std.crypto.secureZero(u8, &seed);
        try bytesField(&envelope, SignedField.private_key_data, &seed);
        signed.len = envelope.buffered().len;
        return signed;
    }

    pub fn wipe(server: *Server) void {
        std.crypto.secureZero(u8, std.mem.asBytes(server));
    }
};

test "IP invites contain the same key for IPv4 and IPv6" {
    const seed: Seed = @splat(1);
    const key = (try KeyPair.generateDeterministic(seed)).public_key;
    for ([_][]const u8{ "127.0.0.1:27020", "[::1]:27020" }) |address| {
        const invite: Invite = .{ .address = try Io.net.IpAddress.parseLiteral(address), .key = key };
        var text: [128]u8 = undefined;
        const formatted = try std.fmt.bufPrint(&text, "{f}", .{invite});
        const parsed = try Invite.parse(formatted);
        try std.testing.expect(parsed.address.eql(&invite.address));
        try std.testing.expectEqual(key.toBytes(), parsed.key.toBytes());
        try std.testing.expectError(error.InvalidInvite, Invite.parse(formatted[0 .. formatted.len - 1]));
    }
    try std.testing.expectError(error.InvalidInvite, Invite.parse("orl1:example.com:27020/invalid"));
}
