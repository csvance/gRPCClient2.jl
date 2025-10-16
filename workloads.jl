using gRPCClient2
using BenchmarkTools

grpc_init()

include("test/gen/test/test_pb.jl")

function workload_32_224_224_uint8(n)

    client = TestService_TestRPC_Client("localhost", 8001)
    channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(16)

    @sync begin
        task_request = Threads.@spawn begin 
            for i in 1:n
                send_sz = 32*224*224÷sizeof(UInt64)
                grpc_async_request(client, TestRequest(32, zeros(UInt64, send_sz)), channel, 0)
            end
        end
        errormonitor(task_request)

        task_response = Threads.@spawn begin 
            for i in 1:n
                response = take!(channel)
            end
        end
        errormonitor(task_response)
    end
end

function workload_smol(n)

    client = TestService_TestRPC_Client("localhost", 8001)
    channel = Channel{gRPCAsyncChannelResponse{TestResponse}}(16)

    @sync begin
        task_request = Threads.@spawn begin 
            for i in 1:n
                grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)), channel, 0)
            end
        end
        errormonitor(task_request)

        task_response = Threads.@spawn begin 
            for i in 1:n
                response = take!(channel)
            end
        end
        errormonitor(task_response)
    end
end 


function stress_workload(f::Function, n)
    while true
        f(n)
    end
end

stress_workload_smol() = stress_workload(workload_smol, 1_000)
stress_workload_32_224_224_uint8() = stress_workload(workload_32_224_224_uint8, 100)

benchmark_workload_smol() = @benchmark workload_smol(1_000)
benchmark_workload_32_224_224_uint8() = @benchmark workload_32_224_224_uint8(100)

nothing
