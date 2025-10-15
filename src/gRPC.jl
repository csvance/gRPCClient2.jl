GRPC_OK = 0
GRPC_CANCELLED = 1
GRPC_UNKNOWN = 2
GRPC_INVALID_ARGUMENT = 3
GRPC_DEADLINE_EXCEEDED = 4
GRPC_NOT_FOUND = 5
GRPC_ALREADY_EXISTS = 6
GRPC_PERMISSION_DENIED = 7
GRPC_RESOURCE_EXHAUSTED = 8
GRPC_FAILED_PRECONDITION = 9
GRPC_ABORTED = 10
GRPC_INTERNAL = 13
GRPC_UNAVAILABLE = 14
GRPC_DATA_LOSS = 15
GRPC_UNAUTHENTICATED = 16


const _grpc = gRPCCURL()

grpc_init() = open(_grpc)
grpc_shutdown() = close(_grpc)
grpc_global_handle() = _grpc


struct gRPCClient{TRequest,TResponse}
    grpc::gRPCCURL
    host::String
    port::Int64
    path::String
    secure::Bool
    deadline::Float64
    keepalive::Float64
    max_send_message_length::Int64
    max_recieve_message_length::Int64

    gRPCClient{TRequest,TResponse}(
        host,
        port,
        path;
        secure = false,
        grpc = _grpc,
        deadline = 10,
        keepalive = 60,
        max_send_message_length = 4*1024*1024,
        max_recieve_message_length = 4*1024*1024,
    ) where {TRequest<:Any,TResponse<:Any} =
        new(grpc, host, port, path, secure, deadline, keepalive, max_send_message_length, max_recieve_message_length)
end

function url(client::gRPCClient)
    protocol = if client.secure
        "grpcs"
    else
        "grpc"
    end
    "$protocol://$(client.host):$(client.port)$(client.path)"
end


function grpc_unary_async_request(
    grpc::gRPCCURL,
    url,
    request;
    deadline = 10,
    keepalive = 60,
    max_send_message_length = 4*1024*1024,
    max_recieve_message_length = 4*1024*1024
)
    # Create single buffer that contains the post data for the gRPC request
    req_buf = IOBuffer()

    # Write compressed flag and length prefix
    write(req_buf, UInt8(0))
    write(req_buf, UInt32(0))

    # Serialize the protobuf
    e = ProtoEncoder(req_buf)
    sz = UInt32(encode(e, request))

    if req_buf.size - GRPC_HEADER_SIZE > max_send_message_length
        throw(gRPCServiceCallException(
            GRPC_RESOURCE_EXHAUSTED, 
            "request message larger than max_send_message_length: $(req_buf.size - GRPC_HEADER_SIZE) > $max_send_message_length")
        )
    end

    # Seek back to length prefix and update it with size of encoded protobuf
    seek(req_buf, 1)
    write(req_buf, ntoh(sz))

    # Seek to start before initializing the request
    seek(req_buf, 0)

    # Create the request and register it with the libCURL multi handle in grpc
    gRPCRequest(
        grpc, url, req_buf; 
        deadline = deadline, 
        keepalive = keepalive, 
        max_send_message_length=max_send_message_length, 
        max_recieve_message_length=max_recieve_message_length
    )
end


const regex_grpc_status = r"grpc-status: ([0-9]+)"
const regex_grpc_message = Regex("grpc-message: (.*)", "s")

function grpc_unary_async_await(grpc::gRPCCURL, req, TResponse)
    wait(req)

    # Throw an exception for this request if we have one
    !isnothing(req.ex) && throw(req.ex)
        
    req.code == CURLE_OPERATION_TIMEDOUT &&
        throw(gRPCServiceCallException(GRPC_DEADLINE_EXCEEDED, "Deadline exceeded."))
    req.code != CURLE_OK && throw(
        gRPCServiceCallException(
            GRPC_INTERNAL,
            "libCURL returned easy request code $(req.code)",
        ),
    )

    grpc_status = GRPC_OK
    grpc_message = ""

    for header in req.headers
        header = strip(header)

        if (m_grpc_status = match(regex_grpc_status, header)) !== nothing
            grpc_status = parse(UInt64, m_grpc_status.captures[1])
        elseif (m_grpc_message = match(regex_grpc_message, header)) !== nothing
            grpc_message = m_grpc_message.captures[1]
        end
    end

    grpc_status != GRPC_OK && throw(gRPCServiceCallException(grpc_status, grpc_message))

    seek(req.response, 0)

    is_compressed = read(req.response, UInt8) > 0
    # TODO: raise some sort of "NotImplementedException" if compressed is set
    length_prefix = ntoh(read(req.response, UInt32))
    # TODO: validate length 

    return decode(ProtoDecoder(req.response), TResponse)
end


grpc_unary_async_request(
    client::gRPCClient{TRequest,TResponse},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_unary_async_request(
    client.grpc,
    url(client),
    request;
    deadline = client.deadline,
    keepalive = client.keepalive,
    max_send_message_length = client.max_send_message_length,
    max_recieve_message_length = client.max_recieve_message_length
)

grpc_unary_async_await(
    client::gRPCClient{TRequest,TResponse},
    request::gRPCRequest,
) where {TRequest<:Any,TResponse<:Any} =
    grpc_unary_async_await(client.grpc, request, TResponse)

grpc_unary_sync(
    client::gRPCClient{TRequest,TResponse},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_unary_async_await(
    client.grpc,
    grpc_unary_async_request(
        client.grpc,
        url(client),
        request;
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length
    ),
    TResponse,
)
