const CURL_VERSION_STR = unsafe_string(curl_version())
let m = match(r"^libcurl/(\d+\.\d+\.\d+)\b", CURL_VERSION_STR)
    m !== nothing || error("unexpected CURL_VERSION_STR value")
    curl = m.captures[1]
    julia = "$(VERSION.major).$(VERSION.minor)"
    const global CURL_VERSION = VersionNumber(curl)
    const global USER_AGENT = "curl/$curl julia/$julia"
end


function write_callback(
    data::Ptr{Cchar},
    size::Csize_t,
    count::Csize_t,
    req_p::Ptr{Cvoid},
)::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest

        n = size * count
        buf = unsafe_wrap(Array, convert(Ptr{UInt8}, data), (n,))

        handled_n_bytes = try
            # Handles all of the response stream data 
            handle_write(req, buf)
        catch ex
            # Eat InvalidStateException raised on put! to closed channel
            !isa(ex, InvalidStateException) && rethrow(ex)
            n
        end

        # If there was an exception handle it 
        !isnothing(req.ex) && return typemax(Csize_t)

        # Check that we handled the correct number of bytes
        # If there was no exception in handle_write this should always match 
        if handled_n_bytes != n
            req.ex = gRPCServiceCallException(
                GRPC_INTERNAL,
                "Recieved $(n) bytes from curl but only handled $(handled_n_bytes)",
            )
            return typemax(Csize_t)
        end

        return handled_n_bytes
    catch err
        @async @error("write_callback: unexpected error", err = err, maxlog = 1_000)
        return typemax(Csize_t)
    end
end

function read_callback(
    data::Ptr{Cchar},
    size::Csize_t,
    count::Csize_t,
    req_p::Ptr{Cvoid},
)::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest

        buf_p = pointer(req.request.data) + req.request_ptr
        n_left = req.request.size - req.request_ptr

        n = size * count
        n_min = min(n, n_left)

        ccall(:memcpy, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Csize_t), data, buf_p, n_min)

        req.request_ptr += n_min

        if isstreaming_request(req) && n_min == 0
            # Keep sending until the channel is closed and empty
            if !isopen(req.request_c) && isempty(req.request_c)
                notify(req.curl_done_reading)
                return 0
            end

            seekstart(req.request)
            truncate(req.request, 0)
            req.request_ptr = 0

            # Safe to write more data to the request buffer again 
            notify(req.curl_done_reading)

            return CURL_READFUNC_PAUSE
        end

        return n_min
    catch err
        @async @error("read_callback: unexpected error", err = err, maxlog = 1_000)
        return CURL_READFUNC_ABORT
    end
end

const regex_grpc_status = r"grpc-status: ([0-9]+)"
const regex_grpc_message = Regex("grpc-message: (.*)", "s")


function header_callback(
    data::Ptr{Cchar},
    size::Csize_t,
    count::Csize_t,
    req_p::Ptr{Cvoid},
)::Csize_t
    try
        req = unsafe_pointer_to_objref(req_p)::gRPCRequest
        n = size * count

        header = unsafe_string(data, n)
        header = strip(header)

        if (m_grpc_status = match(regex_grpc_status, header)) !== nothing
            req.grpc_status = parse(UInt64, m_grpc_status.captures[1])
        elseif (m_grpc_message = match(regex_grpc_message, header)) !== nothing
            req.grpc_message = m_grpc_message.captures[1]
        end

        return n
    catch err
        @async @error("header_callback: unexpected error", err = err, maxlog = 1_000)
        return typemax(Csize_t)
    end
end



mutable struct gRPCRequest
    lock::ReentrantLock
    easy::Ptr{Cvoid}
    multi::Ptr{Cvoid}
    url::String
    request::IOBuffer
    response::IOBuffer
    # These are only used when the request or response is streaming
    request_c::Union{Nothing,Channel{IOBuffer}}
    response_c::Union{Nothing,Channel{IOBuffer}}
    code::CURLcode
    ready::Event
    errbuf::Vector{UInt8}
    headers::Vector{String}
    request_ptr::Int64
    max_send_message_length::Int64
    max_recieve_message_length::Int64
    ex::Union{Nothing,Exception}
    response_read_header::Bool
    response_compressed::Bool
    response_length::UInt32
    curl_done_reading::Event
    grpc_status::Int64
    grpc_message::String


    function gRPCRequest(
        grpc,
        url,
        request::IOBuffer,
        response::IOBuffer,
        request_c::Union{Nothing,Channel{IOBuffer}},
        response_c::Union{Nothing,Channel{IOBuffer}};
        deadline = 10,
        keepalive = 60,
        max_send_message_length = 4 * 1024 * 1024,
        max_recieve_message_length = 4 * 1024 * 1024,
    )

        # Reduce number of available requests by one or block if its currently zero
        acquire(grpc.sem)

        easy_handle = curl_easy_init()

        # curl_easy_setopt(easy_handle, CURLOPT_VERBOSE, UInt32(1))

        http_url = replace(url, "grpc://" => "http://")
        http_url = replace(http_url, "grpcs://" => "https://")

        curl_easy_setopt(easy_handle, CURLOPT_URL, http_url)
        curl_easy_setopt(easy_handle, CURLOPT_TIMEOUT, deadline)
        curl_easy_setopt(easy_handle, CURLOPT_PIPEWAIT, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_POST, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_CUSTOMREQUEST, "POST")

        if startswith(http_url, "http://")
            curl_easy_setopt(
                easy_handle,
                CURLOPT_HTTP_VERSION,
                CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE,
            )
        elseif startswith(http_url, "https://")
            curl_easy_setopt(easy_handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS)
        end

        function grpc_timeout_header_val(timeout::Real)
            if round(Int, timeout) == timeout
                timeout_secs = round(Int64, timeout)
                return "$(timeout_secs)S"
            end
            timeout *= 1000
            if round(Int, timeout) == timeout
                timeout_millisecs = round(Int64, timeout)
                return "$(timeout_millisecs)m"
            end
            timeout *= 1000
            if round(Int, timeout) == timeout
                timeout_microsecs = round(Int64, timeout)
                return "$(timeout_microsecs)u"
            end
            timeout *= 1000
            timeout_nanosecs = round(Int64, timeout)
            return "$(timeout_nanosecs)n"
        end

        headers = C_NULL
        headers = curl_slist_append(headers, "User-Agent: $(USER_AGENT)")
        headers = curl_slist_append(headers, "Content-Type: application/grpc+proto")
        headers = curl_slist_append(headers, "Content-Length:")
        headers = curl_slist_append(headers, "te: trailers")
        headers =
            curl_slist_append(headers, "grpc-timeout: $(grpc_timeout_header_val(deadline))")
        curl_easy_setopt(easy_handle, CURLOPT_HTTPHEADER, headers)

        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPALIVE, Clong(1))
        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPINTVL, keepalive)
        curl_easy_setopt(easy_handle, CURLOPT_TCP_KEEPIDLE, keepalive)

        req = new(
            grpc.lock,
            easy_handle,
            grpc.multi,
            http_url,
            request,
            response,
            request_c,
            response_c,
            UInt32(0),
            Event(),
            zeros(UInt8, CURL_ERROR_SIZE),
            Vector{String}(),
            0,
            max_send_message_length,
            max_recieve_message_length,
            nothing,
            false,
            false,
            0,
            Event(),
            GRPC_OK,
            "",
        )

        req_p = pointer_from_objref(req)
        curl_easy_setopt(easy_handle, CURLOPT_PRIVATE, req_p)

        errbuf_p = pointer(req.errbuf)
        curl_easy_setopt(easy_handle, CURLOPT_ERRORBUFFER, errbuf_p)

        write_cb =
            @cfunction(write_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
        curl_easy_setopt(easy_handle, CURLOPT_WRITEFUNCTION, write_cb)
        curl_easy_setopt(easy_handle, CURLOPT_WRITEDATA, req_p)

        read_cb =
            @cfunction(read_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))
        curl_easy_setopt(easy_handle, CURLOPT_READFUNCTION, read_cb)
        curl_easy_setopt(easy_handle, CURLOPT_READDATA, req_p)

        # set header callback
        header_cb =
            @cfunction(header_callback, Csize_t, (Ptr{Cchar}, Csize_t, Csize_t, Ptr{Cvoid}))


        curl_easy_setopt(easy_handle, CURLOPT_HEADERFUNCTION, header_cb)
        curl_easy_setopt(easy_handle, CURLOPT_HEADERDATA, req_p)
        curl_easy_setopt(easy_handle, CURLOPT_UPLOAD, true)

        # Start paused and able to write the request
        curl_easy_pause(easy_handle, CURLPAUSE_RECV)
        notify(req.curl_done_reading)

        lock(grpc.lock) do
            if !grpc.running
                curl_easy_cleanup(easy_handle)
                throw(
                    gRPCServiceCallException(
                        GRPC_FAILED_PRECONDITION,
                        "Tried to make a request when the provided grpc handle is shutdown",
                    ),
                )
            end

            push!(grpc.requests, req)
            curl_multi_add_handle(grpc.multi, easy_handle)
        end

        return req
    end
end

isstreaming_request(req::gRPCRequest) = !isnothing(req.request_c)
isstreaming_response(req::gRPCRequest) = !isnothing(req.response_c)

wait(req::gRPCRequest) = wait(req.ready)
reset(req::gRPCRequest) = reset(req.ready)


function handle_write(req::gRPCRequest, buf::Vector{UInt8})
    if !req.response_read_header
        header_bytes_left = GRPC_HEADER_SIZE - req.response.size

        if length(buf) < header_bytes_left
            # Not enough data yet to read the entire header
            return write(req.response, buf)
        else

            buf_header = buf[1:header_bytes_left]
            n = write(req.response, buf_header)

            # Read the header
            seekstart(req.response)
            req.response_compressed = read(req.response, UInt8) > 0
            req.response_length = ntoh(read(req.response, UInt32))

            if req.response_compressed
                req.ex = gRPCServiceCallException(
                    GRPC_UNIMPLEMENTED,
                    "Response was compressed but compression is not currently supported.",
                )
                return n
            elseif req.response_length > req.max_recieve_message_length
                req.ex = gRPCServiceCallException(
                    GRPC_RESOURCE_EXHAUSTED,
                    "length-prefix longer than max_recieve_message_length: $(req.response_length) > $(req.max_recieve_message_length)",
                )
                return n
            end

            req.response_read_header = true
            seekstart(req.response)
            truncate(req.response, 0)

            if (leftover_bytes = length(buf) - header_bytes_left) > 0
                # Handle the remaining data
                buf_leftover = unsafe_wrap(Array, pointer(buf) + n, (leftover_bytes,))
                n += handle_write(req, buf_leftover)
            end

            return n
        end
    end

    # Already read the header
    message_bytes_left = req.response_length - req.response.size

    # Not enough bytes to complete the message
    length(buf) < message_bytes_left && return write(req.response, buf)

    if isstreaming_response(req)
        # Write just enough to complete the message
        buf_complete = unsafe_wrap(Array, pointer(buf), (message_bytes_left,))
        n = write(req.response, buf_complete)

        # Response is done, put it in the channel so it can be returned back to the user
        seekstart(req.response)

        # Put the completed response protobuf buffer in the channel so it can be processed by the `grpc_async_stream_response` task
        put!(req.response_c, req.response)

        # There might be another response after this so reset these
        req.response = IOBuffer()
        req.response_read_header = false
        req.response_compressed = false
        req.response_length = 0

        # Handle the remaining data
        leftover_bytes = message_bytes_left - n

        if leftover_bytes > 0
            buf_leftover = unsafe_wrap(Array, pointer(buf) + n, (length(leftover_bytes),))
            n += handle_write(req, buf_leftover)
        end

        return n
    else
        # We only expect a single response for non-streaming RPC
        if length(buf) > message_bytes_left
            req.ex = gRPCServiceCallException(
                GRPC_RESOURCE_EXHAUSTED,
                "Response was longer than declared in length-prefix.",
            )
            return 0
        end

        n = write(req.response, buf)
        seekstart(req.response)

        notify(req.ready)

        return n
    end

end


function timer_callback(multi_h::Ptr{Cvoid}, timeout_ms::Clong, grpc_p::Ptr{Cvoid})::Cint
    try
        grpc = unsafe_pointer_to_objref(grpc_p)::gRPCCURL
        @assert multi_h == grpc.multi

        stoptimer!(grpc)

        if timeout_ms >= 0
            grpc.timer = Timer(timeout_ms / 1000) do timer
                lock(grpc.lock) do
                    !grpc.running && return
                    curl_multi_socket_action(
                        grpc.multi,
                        CURL_SOCKET_TIMEOUT,
                        0,
                        Ref{Cint}(),
                    )
                    check_multi_info(grpc)
                end
            end
        end

        return 0
    catch err
        @async @error("timer_callback: unexpected error", err = err, maxlog = 1_000)
        return -1
    end
end


mutable struct CURLWatcher
    sock::curl_socket_t
    fdw::FDWatcher
    ready::Event
    running::Bool


    function CURLWatcher(sock, fdw)
        event = Event()
        notify(event)
        new(sock, fdw, event, true)
    end
end

isreadable(w::CURLWatcher) = w.fdw.readable
iswritable(w::CURLWatcher) = w.fdw.writable
function close(w::CURLWatcher)
    w.running = false
    notify(w.ready)
    close(w.fdw)
end


function socket_callback(
    easy_h::Ptr{Cvoid},
    sock::curl_socket_t,
    action::Cint,
    grpc_p::Ptr{Cvoid},
    socket_p::Ptr{Cvoid},
)::Cint
    try
        if action ∉ (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT, CURL_POLL_REMOVE)
            @async @error("socket_callback: unexpected action", action, maxlog = 1_000)
            return -1
        end

        grpc = unsafe_pointer_to_objref(grpc_p)::gRPCCURL

        # Handle is being shutdown, give exclusive access of watchers to close()
        !grpc.running && return 0

        if action in (CURL_POLL_IN, CURL_POLL_OUT, CURL_POLL_INOUT)
            readable = action in (CURL_POLL_IN, CURL_POLL_INOUT)
            writable = action in (CURL_POLL_OUT, CURL_POLL_INOUT)

            watcher = nothing
            if sock in keys(grpc.watchers)

                # We already have a watcher for this sock
                watcher = grpc.watchers[sock]

                # Reset the ready event and trigger an EOFError
                reset(watcher.ready)
                close(watcher.fdw)

                # Update the FDWatcher with the new flags
                watcher.fdw = FDWatcher(OS_HANDLE(sock), readable, writable)

                # Start waiting on the socket with the new flags
                notify(watcher.ready)

                return 0
            end

            # Don't have a watcher, create one and start a task 
            watcher = CURLWatcher(sock, FDWatcher(OS_HANDLE(sock), readable, writable))
            grpc.watchers[sock] = watcher

            task = @async begin
                while watcher.running && grpc.running
                    # Watcher configuration might be changed, wait until its safe to wait on the watcher
                    wait(watcher.ready)

                    events = try
                        wait(watcher.fdw)
                    catch err
                        err isa EOFError && continue
                        err isa Base.IOError || rethrow()
                        FileWatching.FDEvent()
                    end

                    flags =
                        CURL_CSELECT_IN * isreadable(events) +
                        CURL_CSELECT_OUT * iswritable(events) +
                        CURL_CSELECT_ERR * (events.disconnect || events.timedout)

                    lock(grpc.lock) do
                        curl_multi_socket_action(grpc.multi, sock, flags, Ref{Cint}())
                        check_multi_info(grpc)
                    end
                end

                # If the multi handle was shutdown, return without doing any operations on it
                !grpc.running && return

                # When we shut down the watcher do the check_multi_info in this task to avoid creating a new one
                lock(grpc.lock) do
                    check_multi_info(grpc)
                end
            end
            @isdefined(errormonitor) && errormonitor(task)
        else
            # Shut down and cleanup the watcher for this socket
            watcher = grpc.watchers[sock]
            close(watcher)
            delete!(grpc.watchers, sock)
        end

        return 0
    catch err
        @async @error("socket_callback: unexpected error", err = err, maxlog = 1_000)
        return -1
    end
end


function grpc_multi_init(grpc)
    grpc.multi = curl_multi_init()

    grpc_p = pointer_from_objref(grpc)

    timer_cb = @cfunction(timer_callback, Cint, (Ptr{Cvoid}, Clong, Ptr{Cvoid}))
    curl_multi_setopt(grpc.multi, CURLMOPT_TIMERFUNCTION, timer_cb)
    curl_multi_setopt(grpc.multi, CURLMOPT_TIMERDATA, grpc_p)

    socket_cb = @cfunction(
        socket_callback,
        Cint,
        (Ptr{Cvoid}, curl_socket_t, Cint, Ptr{Cvoid}, Ptr{Cvoid})
    )
    curl_multi_setopt(grpc.multi, CURLMOPT_SOCKETFUNCTION, socket_cb)
    curl_multi_setopt(grpc.multi, CURLMOPT_SOCKETDATA, grpc_p)
end


mutable struct gRPCCURL
    multi::Ptr{Cvoid}
    lock::ReentrantLock
    timer::Union{Nothing,Timer}
    watchers::Dict{curl_socket_t,CURLWatcher}
    running::Bool
    requests::Vector{gRPCRequest}
    sem::Semaphore

    function gRPCCURL(max_streams = GRPC_MAX_STREAMS)
        grpc = new(
            Ptr{Cvoid}(0),
            ReentrantLock(),
            nothing,
            Dict{curl_socket_t,CURLWatcher}(),
            true,
            Vector{gRPCRequest}(),
            Semaphore(max_streams),
        )

        grpc_multi_init(grpc)

        finalizer((x) -> close(x), grpc)

        return grpc
    end
end

function close(grpc::gRPCCURL)
    # Lock free way to get exclusive access to grpc.watchers
    grpc.running = false
    sleep(0.25)

    lock(grpc.lock) do
        # Already closed
        if grpc.multi == Ptr{Cvoid}(0)
            return
        end

        # Cleanup easy handles
        while length(grpc.requests) > 0
            request = pop!(grpc.requests)
            curl_multi_remove_handle(grpc.multi, request.easy)
            curl_easy_cleanup(request.easy)
            # Unblock anything waiting on the request
            notify(request.ready)
        end

        # Cleanup watchers
        while length(grpc.watchers) > 0
            _, watcher = pop!(grpc.watchers)
            close(watcher)
        end

        curl_multi_cleanup(grpc.multi)
        grpc.multi = Ptr{Cvoid}(0)
    end

    nothing
end

function open(grpc::gRPCCURL)
    lock(grpc.lock) do
        if grpc.multi != Ptr{Cvoid}(0)
            return
        end

        # Guarantee that we start with a clean slate
        grpc.watchers = Dict{curl_socket_t,CURLWatcher}()
        grpc.requests = Vector{gRPCRequest}()
        grpc.timer = nothing
        grpc.sem = Semaphore(grpc.sem.sem_size)

        grpc.running = true
        grpc_multi_init(grpc)
    end

    nothing
end

struct CURLMsg
    msg::CURLMSG
    easy::Ptr{Cvoid}
    code::CURLcode
end

function check_multi_info(grpc::gRPCCURL)
    while true
        p = curl_multi_info_read(grpc.multi, Ref{Cint}())
        p == C_NULL && return
        message = unsafe_load(convert(Ptr{CURLMsg}, p))
        if message.msg == CURLMSG_DONE
            easy_handle = message.easy
            req_p_ref = Ref{Ptr{Cvoid}}()
            curl_easy_getinfo(easy_handle, CURLINFO_PRIVATE, req_p_ref)
            req = unsafe_pointer_to_objref(req_p_ref[])::gRPCRequest
            @assert easy_handle == req.easy
            req.code = message.code

            # Doing the cleanup here helps with lock contention
            curl_multi_remove_handle(req.multi, req.easy)
            curl_easy_cleanup(req.easy)

            grpc.requests = filter(x -> x !== req, grpc.requests)
            notify(req.ready)

            # Allow a new request now that this one is complete
            release(grpc.sem)
        else
            @async @error("curl_multi_info_read: unknown message", message, maxlog = 1_000)
        end
    end
end



function stoptimer!(grpc::gRPCCURL)
    t = grpc.timer
    if t !== nothing
        grpc.timer = nothing
        close(t)
    end
    nothing
end
