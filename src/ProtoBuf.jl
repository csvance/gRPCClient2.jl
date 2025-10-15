#=
function codegen(io, t::ServiceType, ctx::Context)
    @info "ServiceType: $(safename(t))"

    @info t
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name 


    for rpc_t in t.rpcs
        if rpc_t.request_stream || rpc_t.response_stream
            println(io, "# Service $(safename(rpc_t)) uses streaming, not yet supported.")
            continue
        end

        rpc_path = "/$namespace.$service_name/$(rpc_t.name)"

        request_type = rpc_t.request_type.name
        response_type = rpc_t.response_type.name 

        # if rpc_t.package_namespace !== nothing 
        #     request_type = join([rpc_t.package_namespace, request_type], ".")
        #     response_type = join([rpc_t.package_namespace, response_type], ".")
        # end

        async_request_method = "$(service_name)_$(rpc_t.name)_async_request"
        async_await_method = "$(service_name)_$(rpc_t.name)_async_await"
        sync_await_method = "$(service_name)_$(rpc_t.name)_sync"

        println(io, "$async_request_method(grpc, url, request::$(request_type); deadline=10, keepalive=60) = grpc_unary_async_request(grpc, grpc_path_url(url, \"$rpc_path\"), request; deadline=deadline, keepalive=keepalive)")
        println(io, "$async_await_method(grpc, request) = grpc_unary_async_await(grpc, request, $response_type)")
        println(io, "$sync_await_method(grpc, url, request::$(request_type); deadline=10, keepalive=60) = $async_await_method(grpc, $async_request_method(grpc, url, request; deadline=deadline, keepalive=keepalive))")
    end

    
end
=#