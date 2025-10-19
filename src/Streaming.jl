function grpc_async_stream_request(req::gRPCRequest, channel::Channel{TRequest}) where {TRequest<:Any}
    try 
        reqs_ready = 0
        encode_buf = IOBuffer()

        while isnothing(req.ex)
            request = take!(channel)
            grpc_encode_request_iobuffer(request, encode_buf; max_send_message_length=req.max_send_message_length)
            reqs_ready += 1

            # Try to be smart about when we pass control to curl (we won't be able to encode protobufs during this time)
            if req.curl_done_reading.set && (isempty(channel) || reqs_ready >= 10 || encode_buf.size >= 8096)
                seekstart(encode_buf)

                # Wait for libCURL to not be reading anymore 
                wait(req.curl_done_reading)
                
                # Write all of the encoded protobufs to the request read buffer
                write(req.request, encode_buf)

                # Tell curl we have more to send
                curl_easy_pause(req.easy, CURLPAUSE_CONT)

                # Reset the encode buffer
                reqs_ready = 0
                seekstart(encode_buf)
                truncate(encode_buf, 0)
            end
        end
    catch ex
        close(channel)
        close(req)
            
        if isa(ex, InvalidStateException)

        elseif isa(ex, gRPCServiceCallException)
            if isnothing(req.ex) req.ex = ex end
        else 
            if isnothing(req.ex) req.ex = ex end
            @error "grpc_async_stream_request: unexpected exception" exception=ex
        end
    end

    nothing
end

function grpc_async_stream_response(req::gRPCRequest, channel::Channel{TResponse}) where {TResponse<:Any}
    try 
        while isnothing(req.ex)
            response_buf = take!(req.response_c)
            response = decode(ProtoDecoder(response_buf), TResponse)
            put!(channel, response)
        end
    catch ex
        close(channel)
        close(req)
            
        if isa(ex, InvalidStateException)

        elseif isa(ex, gRPCServiceCallException)
            if isnothing(req.ex) req.ex = ex end
        else 
            if isnothing(req.ex) req.ex = ex end
            @error "grpc_async_stream_response: unexpected exception" exception=ex
        end

    end

    nothing
end


function grpc_async_request(
    client::gRPCClient{TRequest,true,TResponse,false},
    request::Channel{TRequest},
) where {TRequest<:Any,TResponse<:Any} 

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        nothing;
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    request_task = Threads.@spawn grpc_async_stream_request(req, request)
    errormonitor(request_task)

    # response is not streaming so we use grpc_async_await on the returned request
    req
end

function grpc_async_request(
    client::gRPCClient{TRequest,false,TResponse,true},
    request::TRequest,
    response::Channel{TResponse},
) where {TRequest<:Any,TResponse<:Any}

    request_buf = grpc_encode_request_iobuffer(request; max_send_message_length=client.max_send_message_length)
    seekstart(request_buf)

    req = gRPCRequest(
        client.grpc,
        url(client),
        request_buf,
        IOBuffer(),
        nothing,
        Channel{IOBuffer}(16);
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    response_task = Threads.@spawn grpc_async_stream_response(req, response)
    errormonitor(response_task)

    nothing
end

function grpc_async_request(
    client::gRPCClient{TRequest,true,TResponse,true},
    request::Channel{TRequest},
    response::Channel{TResponse},
) where {TRequest<:Any,TResponse<:Any}

    req = gRPCRequest(
        client.grpc,
        url(client),
        IOBuffer(),
        IOBuffer(),
        Channel{IOBuffer}(16),
        Channel{IOBuffer}(16);
        deadline = client.deadline,
        keepalive = client.keepalive,
        max_send_message_length = client.max_send_message_length,
        max_recieve_message_length = client.max_recieve_message_length,
    )

    request_task = Threads.@spawn grpc_async_stream_request(req, request)
    errormonitor(request_task)

    response_task = Threads.@spawn grpc_async_stream_response(req, response)
    errormonitor(response_task)

    nothing
end



grpc_async_await(
    client::gRPCClient{TRequest,true,TResponse,false},
    request::gRPCRequest,
) where {TRequest<:Any,TResponse<:Any} = grpc_async_await(request, TResponse)

