import std/[tables,
            strutils,
            uri,
            sha1,
            parseutils]

import pkg/[chronos,
            chronicles,
            httputils,
            stew/byteutils,
            stew/endians2,
            stew/base64,
            eth/keys]

import ./random, ./http

  #[
  +---------------------------------------------------------------+
  |0                   1                   2                   3  |
  |0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1|
  +-+-+-+-+-------+-+-------------+-------------------------------+
  |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
  |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
  |N|V|V|V|       |S|             |   (if payload len==126/127)   |
  | |1|2|3|       |K|             |                               |
  +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
  |     Extended payload length continued, if payload len == 127  |
  + - - - - - - - - - - - - - - - +-------------------------------+
  |                               |Masking-key, if MASK set to 1  |
  +-------------------------------+-------------------------------+
  | Masking-key (continued)       |          Payload Data         |
  +-------------------------------- - - - - - - - - - - - - - - - +
  :                     Payload Data continued ...                :
  + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
  |                     Payload Data continued ...                |
  +---------------------------------------------------------------+
  ]#

const
  SHA1DigestSize* = 20
  WSHeaderSize* = 12
  WSDefaultVersion* = 13
  WSDefaultFrameSize* = 256 # bytes
  WSMaxMessageSize* = 1 shl 20 # 1mb

type
  ReadyState* {.pure.} = enum
    Connecting = 0 # The connection is not yet open.
    Open = 1       # The connection is open and ready to communicate.
    Closing = 2    # The connection is in the process of closing.
    Closed = 3     # The connection is closed or couldn't be opened.

  WebSocketError* = object of CatchableError
  WSMalformedHeaderError* = object of WebSocketError
  WSFailedUpgradeError* = object of WebSocketError
  WSVersionError* = object of WebSocketError
  WSProtoMismatchError* = object of WebSocketError
  WSMaskMismatchError* = object of WebSocketError
  WSHandshakeError* = object of WebSocketError
  WSOpcodeMismatchError* = object of WebSocketError
  WSRsvMismatchError* = object of WebSocketError
  WSWrongUriSchemeError* = object of WebSocketError
  WSMaxMessageSizeError* = object of WebSocketError
  WSClosedError* = object of WebSocketError
  WSSendError* = object of WebSocketError

  Base16Error* = object of CatchableError
    ## Base16 specific exception type

  HeaderFlag* {.size: sizeof(uint8).} = enum
    rsv3
    rsv2
    rsv1
    fin
  HeaderFlags = set[HeaderFlag]

  HttpCode* = enum
    Http101 = 101 # Switching Protocols

  Opcode* {.pure.} = enum
    ## 4 bits. Defines the interpretation of the "Payload data".
    Cont = 0x0   ## Denotes a continuation frame.
    Text = 0x1   ## Denotes a text frame.
    Binary = 0x2 ## Denotes a binary frame.
    # 3-7 are reserved for further non-control frames.
    Close = 0x8  ## Denotes a connection close.
    Ping = 0x9   ## Denotes a ping.
    Pong = 0xa   ## Denotes a pong.
    # B-F are reserved for further control frames.

  Frame = ref object
    fin: bool                 ## Indicates that this is the final fragment in a message.
    rsv1: bool                ## MUST be 0 unless negotiated that defines meanings
    rsv2: bool                ## MUST be 0
    rsv3: bool                ## MUST be 0
    opcode: Opcode            ## Defines the interpretation of the "Payload data".
    mask: bool                ## Defines whether the "Payload data" is masked.
    data: seq[byte]           ## Payload data
    maskKey: array[4, char]   ## Masking key
    length: uint64            ## Message size.
    consumed: uint64          ## how much has been consumed from the frame

  ControlCb* = proc(ws: WebSocket) {.gcsafe.}
  WebSocket* = ref object
    tcpSocket*: StreamTransport
    version*: int
    key*: string
    protocol*: string
    readyState*: ReadyState
    masked*: bool # send masked packets
    rng*: ref BrHmacDrbgContext
    frameSize: int
    frame: Frame
    onPing: ControlCb
    onPong: ControlCb

func remainder*(frame: Frame): uint64 =
  frame.length - frame.consumed

proc handshake*(
  ws: WebSocket,
  header: HttpRequestHeader,
  version = WSDefaultVersion) {.async.} =
  ## Handles the websocket handshake.
  ##

  discard parseSaturatedNatural(header["Sec-WebSocket-Version"], ws.version)
  if ws.version != version:
    raise newException(WSVersionError,
      "Websocket version not supported, Version: " &
      header["Sec-WebSocket-Version"])

  ws.key = header["Sec-WebSocket-Key"].strip()
  if header.contains("Sec-WebSocket-Protocol"):
    let wantProtocol = header["Sec-WebSocket-Protocol"].strip()
    if ws.protocol != wantProtocol:
      raise newException(WSProtoMismatchError,
        "Protocol mismatch (expected: " & ws.protocol & ", got: " &
        wantProtocol & ")")

  var acceptKey: string
  let sh = secureHash(ws.key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
  acceptKey = Base64.encode(hexToByteArray[SHA1DigestSize]($sh))

  var response = "HTTP/1.1 101 Web Socket Protocol Handshake" & CRLF
  response.add("Sec-WebSocket-Accept: " & acceptKey & CRLF)
  response.add("Connection: Upgrade" & CRLF)
  response.add("Upgrade: webSocket" & CRLF)

  if ws.protocol != "":
    response.add("Sec-WebSocket-Protocol: " & ws.protocol & CRLF)
  response.add CRLF

  let res = await ws.tcpSocket.write(response)
  if res != len(response):
    raise newException(WSSendError, "Failed to send handshake response to client")
  ws.readyState = ReadyState.Open

proc createServer*(
  header: HttpRequestHeader,
  transp: StreamTransport,
  protocol: string = "",
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil): Future[WebSocket] {.async.} =
  ## Creates a new socket from a request.
  ##

  if not header.contains("Sec-WebSocket-Version"):
    raise newException(WSHandshakeError, "Missing version header")

  var ws = WebSocket(
    tcpSocket: transp,
    protocol: protocol,
    masked: false,
    rng: newRng(),
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong)

  await ws.handshake(header)
  return ws

proc encodeFrame*(f: Frame): seq[byte] =
  ## Encodes a frame into a string buffer.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2

  var ret: seq[byte]
  var b0 = (f.opcode.uint8 and 0x0f) # 0th byte: opcodes and flags.
  if f.fin:
    b0 = b0 or 128'u8

  ret.add(b0)

  # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
  # 1st byte: payload len start and mask bit.
  var b1 = 0'u8

  if f.data.len <= 125:
    b1 = f.data.len.uint8
  elif f.data.len > 125 and f.data.len <= 0xffff:
    b1 = 126'u8
  else:
    b1 = 127'u8

  if f.mask:
    b1 = b1 or (1 shl 7)

  ret.add(uint8 b1)

  # Only need more bytes if data len is 7+16 bits, or 7+64 bits.
  if f.data.len > 125 and f.data.len <= 0xffff:
    # Data len is 7+16 bits.
    var len = f.data.len.uint16
    ret.add ((len shr 8) and 255).uint8
    ret.add (len and 255).uint8
  elif f.data.len > 0xffff:
    # Data len is 7+64 bits.
    var len = f.data.len.uint64
    ret.add(len.toBE().toBytesBE())

  var data = f.data

  if f.mask:
    # If we need to mask it generate random mask key and mask the data.
    for i in 0..<data.len:
      data[i] = (data[i].uint8 xor f.maskKey[i mod 4].uint8)
    # Write mask key next.
    ret.add(f.maskKey[0].uint8)
    ret.add(f.maskKey[1].uint8)
    ret.add(f.maskKey[2].uint8)
    ret.add(f.maskKey[3].uint8)

  # Write the data.
  ret.add(data)
  return ret

proc send*(
  ws: WebSocket,
  data: seq[byte] = @[],
  opcode = Opcode.Text): Future[void] {.async.} =
  ## Send a frame
  ##

  var maskKey: array[4, char]
  if ws.masked:
    maskKey = genMaskKey(ws.rng)

  if opcode notin {Opcode.Text, Opcode.Binary}:
    discard await ws.tcpSocket.write(encodeFrame(Frame(
        fin: true,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: opcode,
        mask: ws.masked,
        data: data, # allow sending data with close messages
        maskKey: maskKey)))

    return

  let maxSize = ws.frameSize
  # Send stuff in 1 megabyte chunks to prevent IOErrors.
  # This really large packets.
  var i = 0
  while i < data.len:
    let len = min(data.len, (maxSize + i))
    let inFrame = Frame(
        fin: if (i + len >= data.len): true else: false,
        rsv1: false,
        rsv2: false,
        rsv3: false,
        opcode: opcode,
        mask: ws.masked,
        data: data[i ..< len],
        maskKey: maskKey)

    discard await ws.tcpSocket.write(encodeFrame(inFrame))
    i += len

proc send*(ws: WebSocket, data: string): Future[void] =
  send(ws, toBytes(data), Opcode.Text)

proc handleControl*(ws: WebSocket, frame: Frame) {.async.} =
  ## handle control frames
  ##
  var data = newSeq[byte](frame.length)

  try:
    # Process control frame payload.
    if frame.opcode == Opcode.Ping:
      if not isNil(ws.onPing):
        ws.onPing(ws)

      await ws.send(data, Opcode.Pong)
    elif frame.opcode == Opcode.Pong:
      if not isNil(ws.onPong):
        ws.onPong(ws)

      discard
    elif frame.opcode == Opcode.Close:
      case ws.readyState:
      of ReadyState.Closing:
        # Finish close flow

        await ws.tcpSocket.closeWait()
        ws.readyState = ReadyState.Closed
      of ReadyState.Open:
        # Handle close flow

        # Read control frame payload.
        if frame.length > 0:
          # Read the data.
          await ws.tcpSocket.readExactly(addr data[0], int frame.length)
          frame.data = data

        await ws.send(data, Opcode.Close)
        ws.readyState = ReadyState.Closed
      else:
        raiseAssert("Invalid state during close!")
  except CatchableError as exc:
    trace "Exception handling control messages", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.tcpSocket.closeWait()

proc readFrame*(ws: WebSocket): Future[Frame] {.async.} =
  ## Gets a frame from the WebSocket.
  ## See https://tools.ietf.org/html/rfc6455#section-5.2
  ##

  try:
    while ws.readyState != ReadyState.Closed: # read until a data frame arrives
      # Grab the header.
      var header = newSeq[byte](2)
      await ws.tcpSocket.readExactly(addr header[0], 2)

      if header.len != 2:
        raise newException(WSMalformedHeaderError, "Invalid websocket header length")

      let b0 = header[0].uint8
      let b1 = header[1].uint8

      var frame = Frame()
      # Read the flags and fin from the header.

      var hf = cast[HeaderFlags](b0 shr 4)
      frame.fin = fin in hf
      frame.rsv1 = rsv1 in hf
      frame.rsv2 = rsv2 in hf
      frame.rsv3 = rsv3 in hf

      frame.opcode = (b0 and 0x0f).Opcode

      # If any of the rsv are set close the socket.
      if frame.rsv1 or frame.rsv2 or frame.rsv3:
        ws.readyState = ReadyState.Closed
        raise newException(WSRsvMismatchError, "WebSocket rsv mismatch")

      # Payload length can be 7 bits, 7+16 bits, or 7+64 bits.
      var finalLen: uint64 = 0

      let headerLen = uint(b1 and 0x7f)
      if headerLen == 0x7e:
        # Length must be 7+16 bits.
        var length = newSeq[byte](2)
        await ws.tcpSocket.readExactly(addr length[0], 2)
        finalLen = cast[ptr uint16](length[0].addr)[].toBE
      elif headerLen == 0x7f:
        # Length must be 7+64 bits.
        var length = newSeq[byte](8)
        await ws.tcpSocket.readExactly(addr length[0], 8)
        finalLen = cast[ptr uint64](length[0].addr)[].toBE
      else:
        # Length must be 7 bits.
        finalLen = headerLen
      frame.length = finalLen

      # Do we need to apply mask?
      frame.mask = (b1 and 0x80) == 0x80

      if ws.masked == frame.mask:
        # Server sends unmasked but accepts only masked.
        # Client sends masked but accepts only unmasked.
        raise newException(WSMaskMismatchError, "Socket mask mismatch")

      var maskKey = newSeq[byte](4)
      if frame.mask:
        # Read the mask.
        await ws.tcpSocket.readExactly(addr maskKey[0], 4)
        for i in 0..<maskKey.len:
          frame.maskKey[i] = cast[char](maskKey[i])

      # return the current frame if it's not one of the control frames
      if frame.opcode notin {Opcode.Text, Opcode.Cont, Opcode.Binary}:
        asyncSpawn ws.handleControl(frame) # process control frames
        continue

      return frame
  except CatchableError as exc:
    trace "Exception reading frame, dropping socket", exc = exc.msg
    ws.readyState = ReadyState.Closed
    await ws.tcpSocket.closeWait()
    raise exc

proc ping*(ws: WebSocket): Future[void] =
  ws.send(opcode = Opcode.Ping)

proc recv*(
  ws: WebSocket,
  data: pointer,
  size: int): Future[int] {.async.} =
  ## Attempts to read up to `size` bytes
  ##
  ## Will read as many frames as necesary
  ## to fill the buffer until either
  ## the message ends (frame.fin) or
  ## the buffer is full. If no data is on
  ## the pipe will await until at least
  ## one byte is available
  ##

  try:
    # we might have to read more
    # than one frame to fill the buffer
    if isNil(ws.frame) or # no previous frame
      (not isNil(ws.frame) and ws.frame.remainder() <= 0): # all has been consumed
      ws.frame = await ws.readFrame()

    var consumed = 0.uint64
    while consumed < size.uint64:
      let len = min(size, ws.frame.remainder().int)
      let read = await ws.tcpSocket.readOnce(data, len)
      consumed += read.uint64
      var castData = cast[ptr UncheckedArray[byte]](data)

      # unmask data using offset
      for i in 0 ..< read:
        let offset = ws.frame.consumed.int + i # offset is per frame as masks are per frame also
        castData[i] = (castData[offset].uint8 xor ws.frame.maskKey[offset mod 4].uint8)

      if ws.frame.fin:
        break

      ws.frame.consumed += consumed.uint64

    return consumed.int
  except CancelledError as exc:
    trace "Cancelling reading", exc = exc.msg
    raise exc
  except CatchableError as exc:
    trace "Exception reading frames", exc = exc.msg

proc recv*(
  ws: WebSocket,
  size = WSMaxMessageSize): Future[seq[byte]] {.async.} =
  ## Attempt to read a full message up to max `size`
  ## bytes in `frameSize` chunks.
  ##
  ## If no `fin` flag ever arrives it will await until
  ## either cancelled or the `fin` flag arrives.
  ##
  ## If message is larger than `size` a `WSMaxMessageSizeError`
  ## exception is thrown.
  ##
  ## In all other cases it awaits a full message.
  ##
  var res: seq[byte]
  try:
    while true:
      var buf = newSeq[byte](ws.frameSize)
      let read = await ws.recv(addr buf[0], buf.len)
      if read <= 0:
        break

      buf.setLen(read)
      if res.len + buf.len > size:
        raise newException(WSMaxMessageSizeError, "Max message size exceeded")

      res.add(buf)

      # we got the last frame in the sequence, exit
      if ws.frame.fin:
        break
  except WSMaxMessageSizeError as exc:
    raise exc
  except CancelledError as exc:
    trace "Cancelling reading", exc = exc.msg
    raise exc
  except CatchableError as exc:
    trace "Exception reading frames", exc = exc.msg

  return res

proc close*(ws: WebSocket, data: seq[byte] = @[]) {.async.} =
  ## Close the Socket, sends close packet.
  ##

  if ws.readyState != ReadyState.Open:
    return

  try:
    ws.readyState = ReadyState.Closing
    await ws.send(data, opcode = Opcode.Close)

    # read frames until closed
    while ws.readyState != ReadyState.Closed:
      discard await ws.recv()
  except CatchableError as exc:
    debug "Exception closing", exc = exc.msg

proc connect*(
  uri: Uri,
  protocols: seq[string] = @[],
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil): Future[WebSocket] {.async.} =
  ## create a new websockets client
  ##

  var key = Base64.encode(genWebSecKey(newRng()))
  var uri = uri
  case uri.scheme
  of "ws":
    uri.scheme = "http"
  else:
    raise newException(WSWrongUriSchemeError, "uri scheme has to be 'ws'")

  var headers = newHttpHeaders({
    "Connection": "Upgrade",
    "Upgrade": "websocket",
    "Cache-Control": "no-cache",
    "Sec-WebSocket-Version": $version,
    "Sec-WebSocket-Key": key
  })

  if protocols.len != 0:
    headers.table["Sec-WebSocket-Protocol"] = @[protocols.join(", ")]

  let client = newHttpClient(headers)
  var response = await client.request($uri, "GET", headers = headers)
  var header = response.parseResponse()
  if header.failed():
    # Header could not be parsed
    raise newException(WSMalformedHeaderError, "Malformed header received: " &
        $client.transp.remoteAddress())

  if header.code != ord(Http101):
    raise newException(WSFailedUpgradeError,
          "Server did not reply with a websocket upgrade: " &
          "Header code: " & $header.code &
          "Header reason: " & header.reason() &
          "Address: " & $client.transp.remoteAddress())

  # Client data should be masked.
  return WebSocket(
    tcpSocket: client.transp,
    readyState: Open,
    masked: true,
    rng: newRng(),
    frameSize: frameSize,
    onPing: onPing,
    onPong: onPong)

proc connect*(
  host: string,
  port: Port,
  path: string,
  protocols: seq[string] = @[],
  version = WSDefaultVersion,
  frameSize = WSDefaultFrameSize,
  onPing: ControlCb = nil,
  onPong: ControlCb = nil): Future[WebSocket] {.async.} =
  ## Create a new websockets client
  ## using a string path
  ##

  var uri = "ws://" & host & ":" & $port
  if path.startsWith("/"):
    uri.add path
  else:
    uri.add "/" & path

  return await connect(
    parseUri(uri),
    protocols,
    version,
    frameSize,
    onPing,
    onPong)
