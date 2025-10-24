using gRPCClient2
using BenchmarkTools

grpc_init()

include("test/gen/test/test_pb.jl")

function workload_32_224_224_uint8(n)

    client = TestService_TestRPC_Client("localhost", 8001)
    reqs = Vector{gRPCRequest}()

    for i in 1:n
        send_sz = 32*224*224÷sizeof(UInt64)
        req = grpc_async_request(client, TestRequest(32, zeros(UInt64, send_sz)))
        push!(reqs, req)
    end

    for req in reqs
        grpc_async_await(req)
    end

end

function workload_smol(n)

    client = TestService_TestRPC_Client("localhost", 8001)

    reqs = Vector{gRPCRequest}()
    for i in 1:n
        req = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
        push!(reqs, req)
    end

    for req in reqs
        grpc_async_await(req)
    end
end 

function workload_streaming_request(n)
    client = TestService_TestClientStreamRPC_Client("localhost", 8001)
    requests_c = Channel{TestRequest}(100)

    @sync begin 
        req = grpc_async_request(client, requests_c)

        for i in 1:n 
            put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(requests_c)

        response = grpc_async_await(req)
    end    
end

function workload_streaming_bidirectional(n)
    client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)
    requests_c = Channel{TestRequest}(32)
    response_c = Channel{TestResponse}(32)

    @sync begin 
        req = grpc_async_request(client, requests_c, response_c)

        task_request = Threads.@spawn begin 
            for i in 1:n 
                put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
            end
            close(requests_c)
        end
        errormonitor(task_request)

        task_response = Threads.@spawn begin 
            for i in 1:n 
                take!(response_c)
            end
            close(response_c)
        end
        errormonitor(task_response)

        nothing
    end    
end


function stress_workload(f::Function, n)
    while true
        f(n)
    end
end

stress_workload_smol() = stress_workload(workload_smol, 1_000)
stress_workload_32_224_224_uint8() = stress_workload(workload_32_224_224_uint8, 100)
stress_workload_streaming_request() = stress_workload(workload_streaming_request, 32)

benchmark_workload_smol() = @benchmark workload_smol(1_000)
benchmark_workload_32_224_224_uint8() = @benchmark workload_32_224_224_uint8(100)
benchmark_workload_streaming_request() = @benchmark workload_streaming_request(100)
nothing
