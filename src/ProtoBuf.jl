
#=
function codegen(io, t::ServiceType, ctx::Context)
    namespace = join(ctx.proto_file.preamble.namespace, ".")
    service_name = t.name 


    for rpc in t.rpcs
        @info rpc
        if rpc.request_stream || rpc.response_stream
            println(io, "# Service $(safename(rpc)) uses streaming, not yet supported.")
            continue
        end

        rpc_path = "/$namespace.$service_name/$(rpc.name)"

        request_type = rpc.request_type.name
        response_type = rpc.response_type.name 

        if rpc.request_type.package_namespace !== nothing 
            request_type = join([rpc.package_namespace, request_type], ".")
        end
        if rpc.response_type.package_namespace !== nothing 
            response_type = join([rpc.package_namespace, response_type], ".")
        end

        println(io, "$(service_name)_$(rpc.name)_Client(host, port; secure=false, grpc=grpc_global_handle(), deadline=10, keepalive=60) = gRPCClient{$request_type, $response_type}(host, port, \"$rpc_path\"; grpc=grpc, secure=secure, deadline=deadline, keepalive=keepalive)")
    end
end
=#
