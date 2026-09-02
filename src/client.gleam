//// An HTTP/1 and HTTP/2 client.
////
//// A client owns a pool of connections. Build one with `new`, adjust it with
//// the builder functions, then start it with `start` or `supervised`.
////
//// ```gleam
//// pub fn main() {
////   let pool_name = process.new_name("http_client")
////   let assert Ok(started) = client.new() |> client.start(name: pool_name)
////   let pool = started.data
//// 
////   let assert Ok(request) = request.to("https://gleam.run")
////
////   let assert Ok(response) =
////     request.set_body(request, client.Empty)
////     |> client.send(using: pool)
////
////   response.status
////   // -> 200
//// }
//// ```
////
//// `send` reads the whole body into memory and releases the connection. 
//// `stream` returns once the response head has arrived and leaves the body on 
//// the connection for `read_body` or `read_body_chunk`. `discard_body` and
//// `cancel_body` release the connection without reading the rest.
////
//// `dispatch` and `dispatch_stream` take a `Builder` in place of a running pool
//// and give the request a connection of its own.

import client/internal/connection
import client/internal/pool
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process.{type Name}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/uri.{type Uri}

/// A handle on a running connection pool.
pub opaque type Client {
  Client(pool: process.Subject(pool.Message))
}

/// Get a handle on a pool running under a supervision tree.
///
/// # Examples
///
/// ```gleam
/// let client = client.from_name(pool_name)
/// ```
pub fn from_name(pool_name: Name(pool.Message)) -> Client {
  todo
}

/// The configuration of a client.
///
/// Create one with `new`, adjust it with the builder functions, then give it
/// to `start`, `supervised`, `dispatch` or `dispatch_stream`.
pub opaque type Builder {
  Builder(
    address_family: AddressFamily,
    proxy: Option(Proxy),
    protocols: Protocols,
    verification: Verification,
    client_certificate: Option(ClientCertificate),
    redirects: Redirects,
    default_headers: List(#(String, String)),
    max_response_body: Int,
    timeouts: Timeouts,
    pool: PoolOptions,
    http1: Http1Options,
    http2: Http2Options,
  )
}

type AddressFamily {
  AnyAddressFamily
  IpV4Only
  IpV6Only
}

/// Create a new client configuration.
///
/// By default the connections are made to whichever IP family answers first,
/// HTTP/2 and HTTP/1 are offered over ALPN, certificates are checked against
/// the operating system's trust store and redirects are not followed.
///
/// # Examples
///
/// ```gleam
/// let pool_name = process.new_name("http_client")
/// let assert Ok(started) = client.new() |> client.start(name: pool_name)
/// ```
pub fn new() -> Builder {
  Builder(
    address_family: AnyAddressFamily,
    proxy: None,
    protocols: Http2ThenHttp1,
    verification: SystemCertificates,
    client_certificate: None,
    redirects: Never,
    default_headers: [],
    max_response_body: 8_388_608,
    timeouts: default_timeouts(),
    pool: default_pool_options(),
    http1: default_http1_options(),
    http2: default_http2_options(),
  )
}

/// Resolve host names to IPv4 addresses only.
///
/// Replaces a previous `ipv6_only`.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.ipv4_only
/// ```
pub fn ipv4_only(builder: Builder) -> Builder {
  Builder(..builder, address_family: IpV4Only)
}

/// Resolve host names to IPv6 addresses only.
///
/// Replaces a previous `ipv4_only`.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.ipv6_only
/// ```
pub fn ipv6_only(builder: Builder) -> Builder {
  Builder(..builder, address_family: IpV6Only)
}

/// Reach every origin through an HTTP proxy. Requests to a Unix domain socket
/// ignore it.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_proxy(client.HttpProxy(
///   host: "proxy.internal",
///   port: 8080,
///   headers: [],
/// ))
/// ```
pub fn with_proxy(builder: Builder, proxy: Proxy) -> Builder {
  Builder(..builder, proxy: Some(proxy))
}

/// Set which versions of HTTP the client speaks. Defaults to `Http2ThenHttp1`.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.with_protocols(client.Http1Only)
/// ```
pub fn with_protocols(builder: Builder, protocols: Protocols) -> Builder {
  Builder(..builder, protocols:)
}

/// Set how a server's certificate is checked. Defaults to `SystemCertificates`.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_verification(client.CaCertFile("/etc/ssl/internal.pem"))
/// ```
pub fn with_verification(
  builder: Builder,
  verification: Verification,
) -> Builder {
  Builder(..builder, verification:)
}

/// Present a certificate to servers asking for mutual TLS. None is presented
/// by default.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_client_certificate(client.Disk(
///   cert: "/etc/ssl/client.pem",
///   key: "/etc/ssl/client.key",
/// ))
/// ```
pub fn with_client_certificate(
  builder: Builder,
  certificate: ClientCertificate,
) -> Builder {
  Builder(..builder, client_certificate: Some(certificate))
}

/// Set whether redirect responses are followed. Defaults to `Never`.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.with_redirects(client.Follow(limit: 5))
/// ```
pub fn with_redirects(builder: Builder, redirects: Redirects) -> Builder {
  Builder(..builder, redirects:)
}

/// Set headers added to every request that does not already carry them. None
/// are added by default.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_default_headers([#("user-agent", "acme/1.0")])
/// ```
pub fn with_default_headers(
  builder: Builder,
  headers: List(#(String, String)),
) -> Builder {
  Builder(..builder, default_headers: headers)
}

/// Set how much of a response body `send` and `dispatch` will hold in memory.
/// Defaults to 8 MiB. A larger body comes back as `BodyTooLarge`.
///
/// `stream` and `dispatch_stream` take their limit from `read_body` and
/// `read_body_chunk` instead.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.with_max_response_body(bytes: 65_536)
/// ```
pub fn with_max_response_body(builder: Builder, bytes bytes: Int) -> Builder {
  Builder(..builder, max_response_body: bytes)
}

/// Set how long each stage of a request may take.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_timeouts(
///   Timeouts(..client.default_timeouts(), response_headers: 2000),
/// )
/// ```
pub fn with_timeouts(builder: Builder, timeouts: Timeouts) -> Builder {
  Builder(..builder, timeouts:)
}

/// Set how many connections the pool holds and how long it holds them for. Does
/// nothing to a request made with `dispatch` or `dispatch_stream`.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_pool(PoolOptions(..client.default_pool_options(), max_connections: 32))
/// ```
pub fn with_pool(builder: Builder, options: PoolOptions) -> Builder {
  Builder(..builder, pool: options)
}

/// Set the limits applied to every HTTP/1 connection.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_http1(Http1Options(..client.default_http1_options(), max_headers: 50))
/// ```
pub fn with_http1(builder: Builder, options: Http1Options) -> Builder {
  Builder(..builder, http1: options)
}

/// Set the limits applied to every HTTP/2 connection.
///
/// # Examples
///
/// ```gleam
/// client.new()
/// |> client.with_http2(Http2Options(..client.default_http2_options(), ping_interval: Some(30_000)))
/// ```
pub fn with_http2(builder: Builder, options: Http2Options) -> Builder {
  Builder(..builder, http2: options)
}

/// Start the connection pool.
///
/// No connection is opened until a request needs one. Use `supervised` to put
/// the pool under a supervision tree instead.
///
/// # Examples
///
/// ```gleam
/// let pool_name = process.new_name("http_client")
/// let assert Ok(started) = client.new() |> client.start(name: pool_name)
/// started.data
/// ```
pub fn start(
  builder: Builder,
  name pool_name: Name(pool.Message),
) -> Result(actor.Started(Client), actor.StartError) {
  todo
}

/// Create a child specification for the connection pool.
///
/// # Examples
///
/// ```gleam
/// client.new() |> client.supervised(name: pool_name)
/// ```
pub fn supervised(
  builder: Builder,
  name pool_name: Name(pool.Message),
) -> supervision.ChildSpecification(Client) {
  fn() { start(builder, pool_name) }
  |> supervision.supervisor
}

/// A version of HTTP as reported by `protocol`.
pub type Protocol {
  Http1
  Http2
}

/// Which versions of HTTP a client speaks given to `with_protocols`.
///
/// Over TLS the choice is offered by ALPN and the server picks. Over cleartext
/// the preferred version is spoken with prior knowledge.
pub type Protocols {
  /// Offer HTTP/2 falling back to HTTP/1.
  Http2ThenHttp1
  /// Speak HTTP/1 only.
  Http1Only
  /// Speak HTTP/2 only over cleartext as well as over TLS.
  Http2Only
}

/// A proxy to reach every origin through given to `with_proxy`.
pub type Proxy {
  /// An HTTP proxy. Cleartext requests are sent to it directly. TLS requests
  /// are tunnelled through it with `CONNECT` and handshake with the origin.
  HttpProxy(
    host: String,
    port: Int,
    /// Headers sent on the `CONNECT` such as `proxy-authorization`.
    headers: List(#(String, String)),
  )
}

/// How a server's certificate is checked given to `with_verification`.
pub type Verification {
  /// Check the certificate against the operating system's trust store and
  /// check that it was issued for the host being connected to.
  SystemCertificates
  /// Check the certificate against the certificate authorities in a PEM file.
  CaCertFile(path: String)
  /// Check the certificate against in-memory DER-encoded certificate 
  /// authorities.
  CaCertData(certs: List(BitArray))
  /// Accept any certificate.
  ///
  /// Both the signature check and the host name check are turned off, leaving
  /// every request and response readable and rewritable by anyone able to sit
  /// between the client and the server.
  Insecure
}

/// The source of the certificate and key presented to servers asking for
/// mutual TLS given to `with_client_certificate`.
pub type ClientCertificate {
  /// Paths to PEM-encoded certificate and key files on disk.
  Disk(cert: String, key: String)
  /// In-memory PEM-encoded certificate and key.
  Pem(cert: BitArray, key: BitArray)
  /// In-memory DER-encoded certificate and key.
  Der(cert: BitArray, key: BitArray, key_type: TlsKeyType)
}

/// The type of a DER-encoded private key needed by the `Der` variant of
/// `ClientCertificate`.
pub type TlsKeyType {
  /// Traditional RSA key.
  RsaPrivateKey
  /// Elliptic curve key.
  EcPrivateKey
  /// DSA key.
  DsaPrivateKey
  /// PKCS#8 key.
  PrivateKeyInfo
}

/// Whether redirect responses are followed given to `with_redirects`.
pub type Redirects {
  /// Hand the 3xx response back as it arrived.
  Never
  /// Follow up to `limit` redirects then fail with `TooManyRedirects`. A limit 
  /// below one behaves as `Never`.
  ///
  /// A 303 becomes a `GET` with no body, as does a 301 or 302 answering a
  /// `POST`. `authorization` and `cookie` headers are dropped on a hop to
  /// another origin. A redirect answering a `Streaming` or `File` body is
  /// handed back rather than followed.
  Follow(limit: Int)
}

/// How long each stage of a request may take in milliseconds.
///
/// Build one by updating `default_timeouts` so you only update the ones you
/// care about. A value outside the range a field accepts is replaced with the
/// default and logged as a warning when the client starts.
///
/// # Examples
///
/// ```gleam
/// Timeouts(..client.default_timeouts(), response_headers: 2000)
/// ```
pub type Timeouts {
  Timeouts(
    /// How long the pool waits for a free connection.
    checkout: Int,
    /// How long a single connection attempt waits. Each address a host resolves 
    /// to gets this long.
    connect: Int,
    /// How long the TLS handshake and the HTTP/2 settings exchange after it
    /// may take.
    handshake: Int,
    /// How long a single write of the request may take.
    request_write: Int,
    /// How long the client waits for the response head.
    response_headers: Int,
    /// How long a single read of a response body waits.
    body_read: Int,
    // TODO: move it as a separate value.
    /// A ceiling over every stage above. `None` leaves each stage to its own
    /// timeout.
    total: Option(Int),
  )
}

/// Get the default timeouts to be adjusted and given to `with_timeouts`.
///
/// # Examples
///
/// ```gleam
/// client.default_timeouts().connect
/// // -> 5000
/// ```
pub fn default_timeouts() -> Timeouts {
  todo
}

/// How many connections the pool holds and how long it holds them for. An
/// origin is a scheme, host and port.
///
/// Build one by updating `default_pool_options` so you only state the ones you
/// care about. A value outside the range a field accepts is replaced with the
/// default and logged as a warning when the client starts.
///
/// # Examples
///
/// ```gleam
/// PoolOptions(..client.default_pool_options(), max_connections: 32)
/// ```
pub type PoolOptions {
  PoolOptions(
    /// The most HTTP/1 connections open at once to one origin. HTTP/2 uses one
    /// connection per origin, capped by `max_concurrent_streams` of
    /// `Http2Options`.
    max_connections: Int,
    /// The most connections to one origin kept open with nothing to do.
    max_idle_connections: Int,
    /// How long a connection may sit doing nothing before it is closed.
    idle_timeout: Int,
    /// How long a connection may be used for before it is retired. `None`
    /// keeps it for as long as it works.
    max_lifetime: Option(Int),
    /// How much of an unread body `discard_body` will drain. A larger body
    /// closes the connection instead.
    auto_drain_limit: Int,
    /// How much of that drain is read at a time.
    auto_drain_chunk_bytes: Int,
  )
}

/// Get the default pool sizes and lifetimes to be adjusted and given to
/// `with_pool`.
///
/// # Examples
///
/// ```gleam
/// client.default_pool_options().max_connections
/// // -> 16
/// ```
pub fn default_pool_options() -> PoolOptions {
  todo
}

/// The limits applied to every HTTP/1 connection. Sizes are in bytes and
/// timeouts in milliseconds.
///
/// Build one by updating `default_http1_options` so you only state the ones
/// you care about. A value outside the range a field accepts is replaced with
/// the default and logged as a warning when the client starts.
///
/// # Examples
///
/// ```gleam
/// Http1Options(..client.default_http1_options(), max_headers: 50)
/// ```
pub type Http1Options {
  Http1Options(
    /// The longest status line accepted.
    max_status_line: Int,
    /// The longest single header line accepted.
    max_header_line: Int,
    /// The most header fields a response may carry.
    max_headers: Int,
    /// The longest chunk size line accepted in a chunked body.
    max_chunk_size_line: Int,
    /// The most 1xx responses, such as `103 Early Hints`, read and passed over
    /// before the real response.
    max_interim_responses: Int,
    // TODO: ???
    /// How long a request carrying `expect: 100-continue` waits for the
    /// server's go-ahead before sending its body anyway.
    expect_continue_timeout: Int,
  )
}

/// Get the default HTTP/1 limits to be adjusted and given to `with_http1`.
///
/// # Examples
///
/// ```gleam
/// client.default_http1_options().max_headers
/// // -> 100
/// ```
pub fn default_http1_options() -> Http1Options {
  todo
}

/// The limits applied to every HTTP/2 connection. Sizes are in bytes and
/// timeouts in milliseconds.
///
/// Build one by updating `default_http2_options` so you only state the ones
/// you care about. A value outside the range a field accepts is replaced with
/// the default and logged as a warning when the client starts.
///
/// # Examples
///
/// ```gleam
/// Http2Options(..client.default_http2_options(), ping_interval: Some(30_000))
/// ```
pub type Http2Options {
  Http2Options(
    /// The most streams in flight on one connection. `None` uses as many as
    /// the server allows. The server's `SETTINGS_MAX_CONCURRENT_STREAMS` is a
    /// ceiling over this.
    max_concurrent_streams: Option(Int),
    /// How much response body a stream may have in flight before the client
    /// allows more. Must be within 0 and 2147483647.
    initial_window_size: Int,
    /// The largest frame the client accepts. Must be within 16384 and
    /// 16777215.
    max_frame_size: Int,
    /// The largest header list the client accepts. `None` leaves it unlimited.
    max_header_list_size: Option(Int),
    /// How much HPACK dynamic table the client keeps for decoding.
    header_table_size: Int,
    /// The most CONTINUATION frames one header sequence may span.
    max_continuation_frames: Int,
    /// The most bytes of HEADERS and CONTINUATION one header block may total,
    /// counted before it is decoded.
    max_header_block_bytes: Int,
    /// The level a receive window is topped up at.
    receive_window_low_water_mark: Int,
    /// The level a receive window is topped up to.
    receive_window_high_water_mark: Int,
    /// How often an idle pooled connection is sent a PING. `None` sends none.
    ping_interval: Option(Int),
    /// How long a ping waits for its answer before the connection is closed.
    ping_timeout: Int,
    /// How long the streams in flight are given to finish after the server has
    /// sent GOAWAY.
    drain_timeout: Int,
  )
}

/// Get the default HTTP/2 limits to be adjusted and given to `with_http2`.
///
/// # Examples
///
/// ```gleam
/// client.default_http2_options().max_frame_size
/// // -> 16_384
/// ```
pub fn default_http2_options() -> Http2Options {
  todo
}

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

/// The body of a request.
pub type Body {
  /// Binary data held as a `BytesTree`. Use `bytes_tree.from_bit_array` to
  /// convert a `BitArray`.
  Bytes(BytesTree)
  /// Unicode text sent as UTF-8.
  Text(String)
  /// No body.
  Empty
  /// The contents of a file created with the `file` function.
  File(connection.File)
  /// A body written a chunk at a time created with the `streaming` function.
  Streaming(connection.Streaming)
}

/// The reason a file could not be prepared by the `file` function.
pub type FileError {
  /// There is nothing at the given path.
  NotFound
  /// The path is a directory.
  IsDirectory
  /// The client is not permitted to read the file.
  AccessDenied
  /// The file could not be opened or measured for a reason the client does not
  /// name.
  UnknownFileError
  /// The offset is negative or past the end of the file.
  InvalidOffset
  /// The limit is negative.
  InvalidLimit
}

/// Create a request body from a file on the disc.
///
/// The offset and limit are in bytes and send a range of the file. `None`
/// starts at the beginning and runs to the end. The file is measured here and
/// opened when the request is sent.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(body) =
///   client.file("/tmp/report.pdf", offset: None, limit: None)
///
/// request.set_header(request, "content-type", "application/pdf")
/// |> request.set_body(body)
/// ```
pub fn file(
  path: String,
  offset offset: Option(Int),
  limit limit: Option(Int),
) -> Result(Body, FileError) {
  todo
}

/// A handle for writing the body of a streamed request given to the handler
/// by `streaming`.
pub type BodyWriter =
  connection.BodyWriter

// TODO: think about this one callback vs selector thingie
/// Create a request body written a chunk at a time.
///
/// The handler is given a writer and must end the body with `finish_chunk` or
/// `finish_body`.
///
/// # Examples
///
/// ```gleam
/// request.set_body(
///   request,
///   client.streaming(fn(writer) {
///     use writer <- result.try(client.send_chunk(writer, <<"Hello, ":utf8>>))
///     client.finish_chunk(writer, <<"Joe!":utf8>>)
///   }),
/// )
/// ```
pub fn streaming(handler: fn(BodyWriter) -> Result(Nil, SendError)) -> Body {
  todo
}

/// Send one chunk of a streamed request body. The writer is handed back for
/// the next call.
///
/// # Examples
///
/// ```gleam
/// use writer <- result.try(client.send_chunk(writer, <<"Hello, ":utf8>>))
/// ```
pub fn send_chunk(
  writer: BodyWriter,
  chunk: BitArray,
) -> Result(BodyWriter, SendError) {
  todo
}

/// Send the last chunk of a streamed request body and end the body.
///
/// # Examples
///
/// ```gleam
/// client.finish_chunk(writer, <<"Joe!":utf8>>)
/// ```
pub fn finish_chunk(
  writer: BodyWriter,
  chunk: BitArray,
  // TODO: replace Nil 
) -> Result(Nil, SendError) {
  todo
}

/// End a streamed request body without sending any more data.
///
/// # Examples
///
/// ```gleam
/// client.finish_body(writer)
/// ```
pub fn finish_body(writer: BodyWriter) -> Result(Nil, SendError) {
  todo
}

/// Send a request to a Unix domain socket instead of to a host and port.
///
/// `localhost` is sent as the `host` header and as the HTTP/2 `:authority` 
/// pseudo-header unless the request carries a host header of its own.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(request) = request.to("http://localhost/containers/json")
///
/// client.unix(request, path: "/var/run/docker.sock")
/// |> request.set_body(client.Empty)
/// |> client.send(using: client)
/// ```
pub fn unix(request: Request(a), path path: String) -> Request(a) {
  request.set_host(request, path)
}

/// The connection a response arrived on.
///
/// This is the body of the response given back by `stream` and
/// `dispatch_stream`. Pass it to `read_body` or `read_body_chunk` to read the
/// response body or to `discard_body` or `cancel_body` to get rid of it.
pub type Connection =
  connection.Connection

/// Send a request and read the whole response into memory.
///
/// The body is limited to `max_response_body` of the client's configuration and
/// the connection is released once it has been read. Trailer fields are appended
/// to the response's headers.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(request) = request.to("https://gleam.run")
///
/// let assert Ok(response) =
///   request.set_body(request, client.Empty)
///   |> client.send(using: client)
///
/// bit_array.to_string(response.body)
/// // -> Ok("<!DOCTYPE html>...")
/// ```
pub fn send(
  request: Request(Body),
  using client: Client,
) -> Result(Response(BitArray), SendError) {
  todo
}

/// Send a request and wait for the response head.
///
/// The body is left on the connection for `read_body` or `read_body_chunk`. A
/// response that is dropped without being read holds its connection until
/// `idle_timeout` reclaims it.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(request) = request.to("https://gleam.run")
///
/// use response <- result.try(
///   request.set_body(request, client.Empty)
///   |> client.stream(using: client),
/// )
/// ```
pub fn stream(
  request: Request(Body),
  using client: Client,
) -> Result(Response(Connection), SendError) {
  todo
}

/// Send a request over a connection of its own outside a pool and read the
/// whole response into memory.
///
/// The connection is closed once the response has been read. Every call pays
/// for a name lookup, a connection and a TLS handshake.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(request) = request.to("https://gleam.run")
///
/// let assert Ok(response) =
///   request.set_body(request, client.Empty)
///   |> client.dispatch(using: client.new())
/// ```
pub fn dispatch(
  request: Request(Body),
  using builder: Builder,
) -> Result(Response(BitArray), SendError) {
  todo
}

/// Send a request over a connection of its own outside a pool and wait for the
/// response head.
///
/// The connection belongs to the calling process and is closed once the body
/// has been read. Responses are read back as they are from `stream`.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(request) = request.to("https://gleam.run/large.iso")
///
/// use response <- result.try(
///   request.set_body(request, client.Empty)
///   |> client.dispatch_stream(using: client.new()),
/// )
/// ```
pub fn dispatch_stream(
  request: Request(Body),
  using builder: Builder,
) -> Result(Response(Connection), SendError) {
  todo
}

/// The version of HTTP that carried a response.
///
/// # Examples
///
/// ```gleam
/// client.protocol(response)
/// // -> client.Http2
/// ```
pub fn protocol(response: Response(Connection)) -> Protocol {
  todo
}

/// The reason a response body could not be read.
pub type BodyError {
  /// The body is larger than the limit that was given.
  BodyTooLarge
  /// The body could not be read to the end. The connection dropped, the read
  /// timed out or the chunked framing was malformed.
  InvalidBody
}

/// Read the whole response body into memory up to `limit` bytes, then release
/// the connection.
///
/// Trailer fields are appended to the response's headers. Use `read_body_chunk` 
/// for a body too large to hold in memory.
///
/// # Examples
///
/// ```gleam
/// let assert Ok(response) = client.read_body(response, limit: 1_048_576)
///
/// bit_array.to_string(response.body)
/// // -> Ok("Hello, Joe!")
/// ```
pub fn read_body(
  response: Response(Connection),
  limit limit: Int,
) -> Result(Response(BitArray), BodyError) {
  todo
}

/// The result of a single call to `read_body_chunk`.
pub type ReadEvent {
  /// A piece of the body with the response to pass to the next call.
  Chunk(data: BitArray, response: Response(Connection))
  /// The end of the body. The connection has been released and trailer fields
  /// have been appended to the response's headers.
  Done(response: Response(Nil))
}

/// Read the response body a chunk at a time, taking up to `max_chunk_bytes`
/// per call and refusing a body larger than `limit` bytes in total.
///
/// Each `Chunk` carries the response to use for the next call. Keep going
/// until `Done` or stop early with `cancel_body`.
///
/// # Examples
///
/// ```gleam
/// fn count(response: response.Response(client.Connection), total: Int) -> Int {
///   case client.read_body_chunk(response, max_chunk_bytes: 4096, limit: 10_000_000) {
///     Ok(client.Chunk(data:, response:)) ->
///       count(response, total + bit_array.byte_size(data))
///     Ok(client.Done(_response)) -> total
///     Error(_body_error) -> total
///   }
/// }
/// ```
pub fn read_body_chunk(
  response: Response(Connection),
  max_chunk_bytes max_chunk_bytes: Int,
  limit limit: Int,
) -> Result(ReadEvent, BodyError) {
  todo
}

/// Read and throw away the rest of a response body then release the connection.
///
/// A body with more than `auto_drain_limit` of `PoolOptions` left in it closes
/// the connection instead.
///
/// # Examples
///
/// ```gleam
/// client.discard_body(response)
/// ```
pub fn discard_body(response: Response(Connection)) -> Nil {
  todo
}

/// Give up on a response part way through its body.
///
/// On HTTP/2 the stream is reset and the connection carries on. On HTTP/1 the
/// connection is closed. Use `discard_body` where the rest of the body is
/// small enough to be worth reading.
///
/// # Examples
///
/// ```gleam
/// client.cancel_body(response)
/// ```
pub fn cancel_body(response: Response(Connection)) -> Nil {
  todo
}

/// The reason a request did not come back with a response.
pub type SendError {
  /// The host name could not be resolved.
  ResolutionFailed(host: String)
  /// Nothing is listening at the address which is a host and port or a socket
  /// path.
  ConnectionRefused(address: String)
  /// The connection attempt ran past `connect` of `Timeouts`.
  ConnectTimedOut(address: String)
  /// The server's certificate or the client's own was not accepted.
  TlsFailed(reason: TlsError)
  /// No connection came free within `checkout` of `Timeouts`.
  PoolTimedOut
  /// Writing the request ran past `request_write` of `Timeouts`.
  RequestTimedOut
  /// The response head did not arrive within `response_headers` of `Timeouts`.
  ResponseTimedOut
  /// The request ran past `total` of `Timeouts`.
  TotalTimedOut
  /// The server closed the connection before answering.
  ConnectionClosed
  /// The server cancelled this HTTP/2 stream. A `RefusedStream` code means the
  /// request was never started.
  StreamReset(code: ErrorCode)
  /// The server sent GOAWAY and this stream was above the last one it will
  /// answer, which means the request was never started.
  ServerGoingAway(code: ErrorCode)
  /// The server sent something that is not valid HTTP.
  MalformedResponse(reason: ProtocolError)
  /// The server answered with a version of HTTP that `with_protocols` rules
  /// out.
  UnexpectedProtocol(protocol: Protocol)
  /// More redirects were followed than `Follow` allows ending at `last`.
  TooManyRedirects(last: Uri)
  /// A redirect pointed somewhere the client will not follow such as a scheme
  /// other than HTTP or HTTPS, or a `location` that is not a URI.
  InvalidRedirect(location: String)
  /// The file behind a `File` body could not be read when the request was
  /// sent.
  FileFailed(reason: FileError)
  /// The response head arrived but `send` or `dispatch` could not read the body.
  BodyFailed(reason: BodyError)
  /// The socket refused the read or the write.
  SocketError(reason: SocketReason)
}

/// The reason a TLS connection was refused carried by the `TlsFailed` variant
/// of `SendError`.
pub type TlsError {
  /// The certificate was issued for another host.
  HostnameMismatch
  /// The certificate is not signed by anything the client trusts.
  UnknownCertificateAuthority
  /// The certificate is past its expiry date or is not valid yet.
  CertificateExpired
  /// The certificate has been revoked by the authority that issued it.
  CertificateRevoked
  /// The server asked for a client certificate and none was configured.
  NoClientCertificate
  /// The server took none of the versions of HTTP offered over ALPN.
  NoCommonProtocol
  /// The handshake failed for a reason the client does not classify.
  HandshakeFailed(reason: String)
}

/// What was wrong with a response that is not valid HTTP carried by the
/// `MalformedResponse` variant of `SendError`.
pub type ProtocolError {
  /// HTTP/1: the status line is not a status line, or names a version the
  /// client does not speak.
  InvalidStatusLine
  /// HTTP/1: a header line has no colon, or a name or value holding bytes a
  /// header may not.
  InvalidHeaderLine
  /// HTTP/1: the status line is longer than `max_status_line` allows.
  StatusLineTooLong
  /// HTTP/1: a header line is longer than `max_header_line` allows.
  HeaderLineTooLong
  /// HTTP/1: the response carries more headers than `max_headers` allows.
  TooManyHeaders
  /// HTTP/1: a chunk size line is longer than `max_chunk_size_line` allows.
  ChunkSizeLineTooLong
  /// HTTP/1: a chunked body has a malformed size line or is missing its
  /// terminator.
  InvalidChunkedBody
  /// HTTP/1: more 1xx responses arrived in a row than `max_interim_responses`
  /// allows.
  TooManyInterimResponses
  /// HTTP/1: the framing headers contradict each other such as a
  /// `content-length` alongside a `transfer-encoding: chunked`.
  ConflictingFraming
  /// HTTP/2: a frame's length, flags or stream do not make sense.
  InvalidFrame
  /// HTTP/2: a frame arrived that its stream's state does not allow.
  UnexpectedFrame
  /// HTTP/2: the response has no `:status`, carries a pseudo-header a response
  /// may not, or carries one after an ordinary header.
  InvalidPseudoHeaders
  /// HTTP/2: a header block is longer than `max_header_block_bytes` or spans
  /// more CONTINUATION frames than `max_continuation_frames` allows.
  HeaderBlockTooLarge
  /// HTTP/2: a header block could not be decoded.
  HeaderDecodingFailed
  /// HTTP/2: the server sent more data than its flow control window allows.
  FlowControlViolation
  /// HTTP/2: the server sent a PUSH_PROMISE though the client advertised
  /// `SETTINGS_ENABLE_PUSH` of 0.
  ServerPushed
}

/// An HTTP/2 error code as defined by RFC 7540. Carried by the `StreamReset`
/// and `ServerGoingAway` variants of `SendError`.
pub type ErrorCode {
  NoError
  ProtocolViolation
  InternalError
  FlowControlError
  SettingsTimeout
  StreamClosed
  FrameSizeError
  RefusedStream
  Cancel
  CompressionError
  ConnectError
  EnhanceYourCalm
  InadequateSecurity
  Http11Required
  /// A code RFC 7540 does not define, treated as an `InternalError`.
  UnknownErrorCode(Int)
}

/// What the socket said when it refused a read or a write carried by the
/// `SocketError` variant of `SendError`.
pub type SocketReason {
  /// The kernel has no socket buffer space or memory left.
  OutOfBuffers
  /// The node is at its file descriptor limit or the whole host is.
  TooManyOpenFiles
  /// The interface the connection runs over is down.
  NetworkDown
  /// There is no route to the server's network.
  NetworkUnreachable
  /// The server's network is reachable but the server's host is not.
  HostUnreachable
  /// The write is larger than the socket will send in one piece.
  MessageTooLarge
  /// The socket refused the operation on permission grounds.
  PermissionDenied
  /// The operation would have blocked and the socket is not willing to.
  WouldBlock
  /// A signal arrived mid operation. Nothing was sent.
  Interrupted
  /// The socket does not support the operation as it was made.
  NotSupported
  /// The operation failed below the socket, in the network stack or in the
  /// device.
  IoError
  /// The socket reported something the client does not classify.
  UnknownReason
}

/// Describe a `SendError` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// client.send_error_to_string(client.PoolTimedOut)
/// // -> "no connection came free in time"
/// ```
pub fn send_error_to_string(error: SendError) -> String {
  todo
}

/// Describe a `TlsError` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// client.tls_error_to_string(client.HostnameMismatch)
/// // -> "the certificate was issued for another host"
/// ```
pub fn tls_error_to_string(error: TlsError) -> String {
  todo
}

/// Describe a `ProtocolError` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// client.protocol_error_to_string(client.ServerPushed)
/// // -> "the server pushed a stream that was not asked for"
/// ```
pub fn protocol_error_to_string(error: ProtocolError) -> String {
  todo
}

/// Describe a `SocketReason` in a form that reads inside a log line.
///
/// # Examples
///
/// ```gleam
/// client.socket_reason_to_string(client.NetworkDown)
/// // -> "the network is down"
/// ```
pub fn socket_reason_to_string(reason: SocketReason) -> String {
  todo
}
