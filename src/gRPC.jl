const _grpc = gRPCCURL()

"""
    grpc_init()

Initializes the global `gRPCCURL` state. This should be called once before making gRPC calls. There is no harm in calling this more than once (ie by different packages/dependencies)
"""
grpc_init() = open(_grpc)

"""
    grpc_shutdown()

Shuts down the global `gRPCCURL` state. This neatly cleans up all active connections and requests. Useful for calling during development with Revise.
"""
grpc_shutdown() = close(_grpc)

"""
    grpc_global_handle()

Returns the global `gRPCCURL` state which contains a libCURL multi handle. By default all gRPC functions use this multi in order to ensure that HTTP/2 multiplexing happens where possible.
"""
grpc_global_handle() = _grpc

struct gRPCClient{TRequest,SRequest,TResponse,SResponse}
    grpc::gRPCCURL
    host::String
    port::Int64
    path::String
    secure::Bool
    deadline::Float64
    keepalive::Float64
    max_send_message_length::Int64
    max_recieve_message_length::Int64

    function gRPCClient{TRequest,SRequest,TResponse,SResponse}(
        host,
        port,
        path;
        secure = false,
        grpc = grpc_global_handle(),
        deadline = 10,
        keepalive = 60,
        max_send_message_length = 4 * 1024 * 1024,
        max_recieve_message_length = 4 * 1024 * 1024,
    ) where {TRequest<:Any,SRequest,TResponse<:Any,SResponse}     
        new(
            grpc,
            host,
            port,
            path,
            secure,
            deadline,
            keepalive,
            max_send_message_length,
            max_recieve_message_length,
        )
    end

end

function url(client::gRPCClient)
    protocol = if client.secure
        "grpcs"
    else
        "grpc"
    end
    "$protocol://$(client.host):$(client.port)$(client.path)"
end


function grpc_encode_request_iobuffer(request, req_buf::IOBuffer; max_send_message_length=4*1024*1024)
    start_pos = position(req_buf)

    # Write compressed flag and length prefix
    write(req_buf, UInt8(0))
    write(req_buf, UInt32(0))

    # Serialize the protobuf
    e = ProtoEncoder(req_buf)
    sz = UInt32(encode(e, request))

    end_pos = position(req_buf)

    if req_buf.size - GRPC_HEADER_SIZE > max_send_message_length
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "request message larger than max_send_message_length: $(req_buf.size - GRPC_HEADER_SIZE) > $max_send_message_length",
            ),
        )
    end

    # Seek back to length prefix and update it with size of encoded protobuf
    seek(req_buf, start_pos+1)
    write(req_buf, hton(sz))

    # Seek back to the end 
    seek(req_buf, end_pos)

    req_buf
end


grpc_encode_request_iobuffer(
    request; 
    max_send_message_length=4*1024*1024
) = grpc_encode_request_iobuffer(
    request, 
    IOBuffer(); 
    max_send_message_length=max_send_message_length
)


const regex_grpc_status = r"grpc-status: ([0-9]+)"
const regex_grpc_message = Regex("grpc-message: (.*)", "s")

function grpc_finalize_request(req::gRPCRequest)
    wait(req)

    # Throw an exception for this request if we have one
    !isnothing(req.ex) && throw(req.ex)

    req.code == CURLE_OPERATION_TIMEDOUT &&
        throw(gRPCServiceCallException(GRPC_DEADLINE_EXCEEDED, "Deadline exceeded."))
    req.code != CURLE_OK &&
        throw(gRPCServiceCallException(GRPC_INTERNAL, nullstring(req.errbuf)))

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

    nothing
end


function grpc_async_await(req::gRPCRequest, TResponse)
    grpc_finalize_request(req)
    return decode(ProtoDecoder(req.response), TResponse)
end





