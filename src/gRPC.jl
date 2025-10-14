GRPC_OK	= 0
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


function grpc_unary_async_request(grpc, url, request; deadline=10, keepalive=60)
    # Create single buffer that contains the post data for the gRPC request
    req_buf = IOBuffer()

    # Write compressed flag and length prefix
    write(req_buf, UInt8(0))
    write(req_buf, UInt32(0))

    # Serialize the protobuf
    e = ProtoEncoder(req_buf)
    sz = UInt32(encode(e, request))

    # Seek back to length prefix and update it with size of encoded protobuf
    seek(req_buf, 1)
    write(req_buf, ntoh(sz))

    # Seek to start before initializing the request
    seek(req_buf, 0)
    
    # Create the request and register it with the libCURL multi handle in grpc
    gRPCRequest(grpc, url, req_buf; deadline=deadline, keepalive=keepalive)
end

function grpc_unary_async_await(grpc, req, TResponse)
    try
        wait(req)

        req.code == CURLE_OPERATION_TIMEDOUT && throw(gRPCServiceCallException(DEADLINE_EXCEEDED, "Deadline exceeded."))
        req.code != CURLE_OK && throw(gRPCServiceCallException(GRPC_INTERNAL, "libCURL returned easy request code $(req.code)"))

        seek(req.response, 0)

        is_compressed = read(req.response, UInt8) > 0
        # TODO: raise some sort of "NotImplementedException" if compressed is set
        length_prefix = ntoh(read(req.response, UInt32))
        # TODO: validate length 

        return decode(ProtoDecoder(req.response), TResponse)
    catch ex 
        @error ex
    finally
        lock(grpc.lock) do
            curl_multi_remove_handle(req.multi, req.easy)
        end
    end
end


function grpc_unary_sync(grpc, url, request, TResponse; deadline=10, keepalive=60)
    grpc_unary_async_await(
        grpc, 
        grpc_unary_async_request(grpc, url, request; deadline=deadline, keepalive=keepalive),
        TResponse
    )
end
