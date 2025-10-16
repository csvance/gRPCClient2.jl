const _grpc = gRPCCURL()

"""
    grpc_init()

Initializes the global gRPCCURL state. This should be called once before making gRPC calls. There is no harm in calling this more than once (ie by different packages/dependencies)
"""
grpc_init() = open(_grpc)

"""
    grpc_shutdown()

Shuts down the global gRPCCURL state. This neatly cleans up all active connections and requests. Useful for calling during development with Revise.
"""
grpc_shutdown() = close(_grpc)

"""
    grpc_global_handle()

Returns the global gRPCCURL state which contains a libCURL multi. By default all gRPC functions use this multi in order to ensure that HTTP/2 multiplexing happens where possible.
"""
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
        grpc = grpc_global_handle(),
        deadline = 10,
        keepalive = 60,
        max_send_message_length = 4 * 1024 * 1024,
        max_recieve_message_length = 4 * 1024 * 1024,
    ) where {TRequest<:Any,TResponse<:Any} = new(
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

function url(client::gRPCClient)
    protocol = if client.secure
        "grpcs"
    else
        "grpc"
    end
    "$protocol://$(client.host):$(client.port)$(client.path)"
end


function grpc_async_request(
    grpc::gRPCCURL,
    url::String,
    request;
    deadline = 10,
    keepalive = 60,
    max_send_message_length = 4 * 1024 * 1024,
    max_recieve_message_length = 4 * 1024 * 1024,
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
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "request message larger than max_send_message_length: $(req_buf.size - GRPC_HEADER_SIZE) > $max_send_message_length",
            ),
        )
    end

    # Seek back to length prefix and update it with size of encoded protobuf
    seek(req_buf, 1)
    write(req_buf, hton(sz))

    # Seek to start before initializing the request
    seek(req_buf, 0)

    # Create the request and register it with the libCURL multi handle in grpc
    gRPCRequest(
        grpc,
        url,
        req_buf;
        deadline = deadline,
        keepalive = keepalive,
        max_send_message_length = max_send_message_length,
        max_recieve_message_length = max_recieve_message_length,
    )
end


const regex_grpc_status = r"grpc-status: ([0-9]+)"
const regex_grpc_message = Regex("grpc-message: (.*)", "s")
nullstring(x::Vector{UInt8}) = String(x[1:findfirst(==(0), x)-1])

function grpc_async_await(req::gRPCRequest, TResponse)
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

    seek(req.response, 0)

    if (is_compressed = read(req.response, UInt8) > 0)
        throw(
            gRPCServiceCallException(
                GRPC_UNIMPLEMENTED,
                "Compression flag was set in recieved message but compression is not supported.",
            ),
        )
    end

    if (length_prefix = ntoh(read(req.response, UInt32))) !=
       req.response.size - GRPC_HEADER_SIZE
        throw(
            gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "effective response message size larger than declared prefix-length: $(length_prefix) > $(req.response.size - GRPC_HEADER_SIZE)",
            ),
        )
    end

    return decode(ProtoDecoder(req.response), TResponse)
end


"""
    grpc_async_request(client::gRPCClient{TRequest,TResponse}, request::TRequest) where {TRequest<:Any,TResponse<:Any}

Initiate an asynchronous gRPC request: send the request to the server and then immediately return a `gRPCRequest` object without waiting for the response. 
In order to wait on / retrieve the result once its ready, call `grpc_async_await`.
This is ideal when you need to send many requests in parallel and waiting on each response before sending the next request would things down.
"""
grpc_async_request(
    client::gRPCClient{TRequest,TResponse},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_request(
    client.grpc,
    url(client),
    request;
    deadline = client.deadline,
    keepalive = client.keepalive,
    max_send_message_length = client.max_send_message_length,
    max_recieve_message_length = client.max_recieve_message_length,
)


mutable struct gRPCAsyncChannelResponse{TResponse}
    index::Int64
    response::Union{Nothing, TResponse}
    ex::Union{Nothing, Exception}
end

"""
    grpc_async_request(client::gRPCClient{TRequest,TResponse}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}

Initiate an asynchronous gRPC request: send the request to the server and then immediately return. When the request is complete a background task will put the response in the provided channel.
This has the advantage over the request / await patern in that you can handle responses immediately after they are recieved in any order.

```
using gRPCClient2

grpc_init()
include("test/gen/test/test_pb.jl")

# Connect to the test server
client = TestService_TestRPC_Client("localhost", 8001)

N = 10

channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(N)

for (index, request) in enumerate([TestRequest(i, zeros(UInt64, i)) for i in 1:N])
     grpc_async_request(client, request, channel, index)
end

for i in 1:N
    cr = take!(channel)
    # Check if an exception was thrown, if so throw it here
    !isnothing(cr.ex) && throw(cr.ex)

    # If this does not hold true, then the requests and responses have gotten mixed up.
    @assert length(cr.response.data) == cr.index
end

```
"""
function grpc_async_request(
    client::gRPCClient{TRequest,TResponse},
    request::TRequest,
    channel::Channel{gRPCAsyncChannelResponse{TResponse}},
    index::Int64,
) where {TRequest<:Any,TResponse<:Any}

    request = grpc_async_request(
        client.grpc,
        url(client),
        request;
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    Threads.@spawn begin
        try
            response = grpc_async_await(client, request)
            put!(channel, gRPCAsyncChannelResponse{TResponse}(index, response, nothing))
        catch ex
            put!(channel, gRPCAsyncChannelResponse{TResponse}(index, nothing, ex))
        end
    end

    nothing
end


"""
    grpc_async_await(client::gRPCClient{TRequest,TResponse}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}

Wait for the request to complete and return the response when it is ready. Throws any exceptions that were encountered during handling of the request.
"""
grpc_async_await(
    client::gRPCClient{TRequest,TResponse},
    request::gRPCRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_await(request, TResponse)


"""
    grpc_sync_request(client::gRPCClient{TRequest,TResponse}, request::TRequest) where {TRequest<:Any,TResponse<:Any}

Do a synchronous gRPC request: send the request and wait for the response before returning it. 
Under the hood this just calls `grpc_async_request` and `grpc_async_await`
"""
grpc_sync_request(
    client::gRPCClient{TRequest,TResponse},
    request::TRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_await(
    grpc_async_request(
        client.grpc,
        url(client),
        request;
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    ),
    TResponse,
)
