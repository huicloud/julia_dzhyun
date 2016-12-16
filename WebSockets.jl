# This module implements the server side of the WebSockets protocol. Some
# things would need to be added to implement a WebSockets client, such as
# masking of sent frames.
#
# WebSockets expects to be used with HttpServer to provide the HttpServer
# for accepting the HTTP request that begins the opening handshake. WebSockets
# implements a subtype of the WebSocketInterface from HttpServer; this means
# that you can create a WebSocketsHandler and pass it into the constructor for
# an http server.
#
# Future improvements:
# 1. Logging of refused requests and closures due to bad behavior of client.
# 2. Better error handling (should we always be using "error"?)
# 3. Unit tests with an actual client -- to automatically test the examples.
# 4. Send close messages with status codes.
# 5. Allow users to receive control messages if they want to.

using Compat; import Compat.String
using URIParser

export WebSocket,
       write,
       read,
       close,
       send_ping,
       send_pong

const TCPSock = VERSION < v"0.4.0-dev" ? Base.TcpSocket : Base.TCPSocket
if VERSION < v"0.4.0-dev"
  init_socket(sock) = nothing
else
  init_socket(sock) = Base.buffer_writes(sock) # Buffer writes to socket till flush(sock)
end

# A WebSocket is a wrapper over a TcpSocket. It takes care of wrapping outgoing
# data in a frame and unwrapping (and concatenating) incoming data.
type WebSocket
  id::Int
  socket::TCPSock
  is_closed::Bool
  sent_close::Bool

  function WebSocket(id::Int,socket::TCPSock)
    init_socket(socket)
    new(id,socket, !isopen(socket), false)
  end

  function WebSocket(id::Int, remote::String)
    socket = ws_connect(remote)
    init_socket(socket)
    new(id,socket, !isopen(socket), false)
  end
end

# WebSocket Frames
#
#      0               1                   2                   3
#      0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
#     +-+-+-+-+-------+-+-------------+-------------------------------+
#     |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
#     |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
#     |N|V|V|V|       |S|             |   (if payload len==126/127)   |
#     | |1|2|3|       |K|             |                               |
#     +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
#     |     Extended payload length continued, if payload len == 127  |
#     + - - - - - - - - - - - - - - - +-------------------------------+
#     |                               |Masking-key, if MASK set to 1  |
#     +-------------------------------+-------------------------------+
#     | Masking-key (continued)       |          Payload Data         |
#     +-------------------------------- - - - - - - - - - - - - - - - +
#     :                     Payload Data continued ...                :
#     + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
#     |                     Payload Data continued ...                |
#     +---------------------------------------------------------------+
#


# Opcode values
#  *  %x0 denotes a continuation frame
const OPCODE_CONTINUATION = 0x00
#  *  %x1 denotes a text frame
const OPCODE_TEXT = 0x1
#  *  %x2 denotes a binary frame
const OPCODE_BINARY = 0x2
#  *  %x3-7 are reserved for further non-control frames
#
#  *  %x8 denotes a connection close
const OPCODE_CLOSE = 0x8
#  *  %x9 denotes a ping
const OPCODE_PING = 0x9
#  *  %xA denotes a pong
const OPCODE_PONG = 0xA
#  *  %xB-F are reserved for further control frames

# Write the raw frame to a bufffer
function write_fragment(io::IO, islast::Bool, data::Array{UInt8}, opcode)
  l = length(data)
  b1::UInt8 = (islast ? 0b1000_0000 : 0b0000_0000) | opcode

  maskkey = fill(UInt8(0), 4)

  # TODO: Do the mask xor thing??
  # 1. set bit 8 to 1,
  # 2. set a mask
  # 3. xor data with mask

  write(io, b1)
  if l <= 125
    write(io, @compat UInt8(l) | 0b1000_0000)
  elseif l <= typemax(UInt16)
    write(io, @compat UInt8(126))
    write(io, hton(@compat UInt16(l)))
  elseif l <= typemax(UInt64)
    write(io, @compat UInt8(127) | 0b1000_0000)
    write(io, hton(@compat UInt64(l)))
  else
    error("Attempted to send too much data for one websocket fragment\n")
  end

  write(io, maskkey)
  write(io, data)
end

# A version of send_fragment for text data.
function write_fragment(io::IO, islast::Bool, data::String, opcode)
  write_fragment(io, islast, data.data, opcode)
end

if VERSION < v"0.4.0-dev"
  function locked_write(io::IO, islast::Bool, data, opcode)
    buf = IOBuffer()
    write_fragment(buf, islast, data, opcode)
    write(io, takebuf_array(buf))
  end
else
  function locked_write(io::IO, islast::Bool, data, opcode)
    isa(io, TCPSock) && lock(io.lock)
    try
      write_fragment(io, islast, data, opcode)
    finally
      if isa(io, TCPSock)
        flush(io)
        unlock(io.lock)
      end
    end
  end
end


# Write text data; will be sent as one frame.
function Base.write(ws::WebSocket,data::String)
  if ws.is_closed
    @show ws
    error("Attempted write to closed WebSocket\n")
  end
  locked_write(ws.socket, true, data, OPCODE_TEXT)
end

# Write binary data; will be sent as one frmae.
function Base.write(ws::WebSocket, data::Array{UInt8})
  if ws.is_closed
    @show ws
    error("attempt to write to closed WebSocket\n")
  end
  locked_write(ws.socket, true, data, OPCODE_BINARY)
end

# Send a ping message, optionally with data.
function write_ping(io::IO, data = "")
  locked_write(io, true, data, OPCODE_PING)
end

send_ping(ws, data...) = write_ping(ws.socket, data...)

# Send a pong message, optionally with data.
function write_pong(io::IO, data = "")
  locked_write(io, true, data, OPCODE_PONG)
end

send_pong(ws, data...) = write_pong(ws.socket, data...)

# Send a close message.
function Base.close(ws::WebSocket)
    # Tell client to close connection
    locked_write(ws.socket, true, "", OPCODE_CLOSE)
    ws.is_closed = true

    # Wait till client responds with an OPCODE_CLOSE
    while true
      wsf = read_frame(ws.socket)
      # ALERT: stuff might get lost in ether here
      is_control_frame(wsf) || continue
      wsf.opcode == OPCODE_CLOSE || continue
      break
    end
    close(ws.socket)
end

# A WebSocket is closed if the underlying TCP socket closes, or if we send or
# receive a close message.
Base.isopen(ws::WebSocket) = !ws.is_closed && isopen(ws.socket)


# Represents one (received) message frame.
type WebSocketFragment
  is_last::Bool
  rsv1::Bool
  rsv2::Bool
  rsv3::Bool
  opcode::UInt8  # This is actually a UInt4 value.
  is_masked::Bool
  payload_len::UInt64
  maskkey::Vector{UInt8}  # This will be 4 bytes on frames from the client.
  data::Vector{UInt8}  # For text messages, this is a String.
end

# This constructor handles conversions from bytes to bools.
function WebSocketFragment(
   fin::UInt8
  ,rsv1::UInt8
  ,rsv2::UInt8
  ,rsv3::UInt8
  ,opcode::UInt8
  ,masked::UInt8
  ,payload_len::UInt64
  ,maskkey::Vector{UInt8}
  ,data::Vector{UInt8})

  WebSocketFragment(
      fin != 0
    , rsv1 != 0
    , rsv2 != 0
    , rsv3 != 0
    , opcode
    , masked != 0
    , payload_len
    , maskkey
    , data)
end

# Control frames have opcodes with the highest bit = 1.
is_control_frame(msg::WebSocketFragment) = (msg.opcode & 0b0000_1000) > 0

# Respond to pings, ignore pongs, respond to close.
function handle_control_frame(ws::WebSocket,wsf::WebSocketFragment)
  if wsf.opcode == OPCODE_CLOSE
    # Reply with an empty CLOSE frame
    locked_write(ws.socket, true, "", OPCODE_CLOSE)
    ws.is_closed = true
    wait(ws.socket.closenotify)
  elseif wsf.opcode == OPCODE_PING
    write_pong(ws.socket,wsf.data)
  elseif wsf.opcode == OPCODE_PONG
    # Nothing to do here; no reply is needed for a pong message.
  else  # %xB-F are reserved for further control frames
    error("Unknown opcode $(wsf.opcode)")
  end
end

# Read a frame: turn bytes from the websocket into a WebSocketFragment.
function read_frame(io::IO)
  a = read(io,UInt8)
  fin    = a & 0b1000_0000 >>> 7  # If fin, then is final fragment
  rsv1   = a & 0b0100_0000  # If not 0, fail.
  rsv2   = a & 0b0010_0000  # If not 0, fail.
  rsv3   = a & 0b0001_0000  # If not 0, fail.
  opcode = a & 0b0000_1111  # If not known code, fail.
  # TODO: add validation somewhere to ensure rsv, opcode, mask, etc are valid.

  b = read(io,UInt8)
  mask = b & 0b1000_0000 >>> 7  # If not 1, fail.

  maskkey = Array(UInt8,4)


  payload_len::UInt64 = b & 0b0111_1111
  if payload_len == 126
    payload_len = ntoh(read(io,UInt16))  # 2 bytes
  elseif payload_len == 127
    payload_len = ntoh(read(io,UInt64))  # 8 bytes
  end

  if mask == 1 
    maskkey = Array(UInt8,4)
    for i in 1:4
      maskkey[i] = read(io,UInt8)
    end
  end

  data = Array(UInt8, payload_len)
  for i in 1:payload_len
    d = read(io, UInt8)
    if mask == 1
      d = d $ maskkey[mod(i - 1, 4) + 1]
    end
    data[i] = d
  end

  return WebSocketFragment(fin,rsv1,rsv2,rsv3,opcode,mask,payload_len,maskkey,data)
end

# Read one non-control message from a WebSocket. Any control messages that are
# read will be handled by the handle_control_frame function. This function will
# not return until a full non-control message has been read. If the other side
# doesn't ever complete it's message, this function will never return. Only the
# data (contents/body/payload) of the message will be returned from this
# function.
function Base.read(ws::WebSocket)
  if ws.is_closed
    error("Attempt to read from closed WebSocket")
  end
  frame = read_frame(ws.socket)


  # Handle control (non-data) messages.
  if is_control_frame(frame)
    # Don't return control frames; they're not interesting to users.
    handle_control_frame(ws,frame)

    # Recurse to return the next data frame.
    return read(ws)
  end

  # Handle data message that uses multiple fragments.
  if !frame.is_last
    return vcat(frame.data, read(ws))
  end

  return frame.data
end


function ws_req(path::String, host::String)
    key = base64encode("julia@yundzh.com")

    req = """
GET $path HTTP/1.1
Upgrade: websocket
Connection: Upgrade
Host: $host
Sec-WebSocket-Key: $key
Sec-WebSocket-Version: 13

"""
    return req
end

function ws_connect(url)
    uri = URI(url)
    port::UInt16 = 80
    if uri.port > 0x0000
        port = uri.port
    end
    socket = connect(uri.host, port)
    req = ws_req(string(uri.path, "?", uri.query), uri.host)
    #print(req)
    write(socket, req)
    
    line = strip(readline(socket))
    code = split(line)[2]
    while length(line) > 0
        #println(line)
        line = strip(readline(socket))
    end
    #println()

    if code != "101"
        error("$url isn't a websockt url")
    end

    return socket
end
