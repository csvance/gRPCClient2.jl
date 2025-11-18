using gRPCClient2
using BenchmarkTools
using PrettyTables
using ProgressBars


grpc_init()

include("test/gen/test/test_pb.jl")

function workload_32_224_224_uint8(n)
    client = TestService_TestRPC_Client("localhost", 8001)

    reqs = Vector{gRPCRequest}()

    send_sz = 32*224*224÷sizeof(UInt64)
    # Pre-allocate this so we are measuring gRPC client performance without external allocations
    test_buf = zeros(UInt64, send_sz)

    for i in 1:n
        req = grpc_async_request(client, TestRequest(32, test_buf))
        push!(reqs, req)
    end
    for req in reqs
        grpc_async_await(req)
    end
end

function workload_smol(n)
    client = TestService_TestRPC_Client("localhost", 8001)

    # Since requests are lightweight, use async / await pattern to avoid creating an extra task per request
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
    requests_c = Channel{TestRequest}(16)

    @sync begin 
        req = grpc_async_request(client, requests_c)

        for i in 1:n 
            put!(requests_c, TestRequest(1, zeros(UInt64, 1)))
        end

        close(requests_c)

        response = grpc_async_await(req)
    end    

    nothing
end

function workload_streaming_response(n)
    client = TestService_TestServerStreamRPC_Client("localhost", 8001)
    response_c = Channel{TestResponse}(16)

    req = grpc_async_request(client, TestRequest(n, zeros(UInt64, 1)), response_c)

    for i in 1:n 
        take!(response_c)
    end
    close(response_c)

    nothing
end


function workload_streaming_bidirectional(n)
    client = TestService_TestBidirectionalStreamRPC_Client("localhost", 8001)
    requests_c = Channel{TestRequest}(16)
    response_c = Channel{TestResponse}(16)

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
stress_workload_streaming_request() = stress_workload(workload_streaming_request, 1_000)
stress_workload_streaming_response() = stress_workload(workload_streaming_response, 1_000)
stress_workload_streaming_bidirectional() = stress_workload(workload_streaming_bidirectional, 1_000)

benchmark_workload_smol() = @benchmark workload_smol(1_000)
benchmark_workload_32_224_224_uint8() = @benchmark workload_32_224_224_uint8(100)
benchmark_workload_streaming_request() = @benchmark workload_streaming_request(1_000)
benchmark_workload_streaming_response() = @benchmark workload_streaming_response(1_000)
benchmark_workload_streaming_bidirectional() = @benchmark workload_streaming_bidirectional(1_000)


function perform_benchmark(f, N)
    b = @benchmark $f($N)
    timing = sum(b.times) / 1e9
    timings_us = b.times ./ 1e3
    N_sample = length(b.times) * N
    mem = round(b.memory / (1024*1024), digits=2)

    return [f, N_sample, mem, b.allocs, 
        round(timing, digits=2), 
        round(Int, N_sample/timing), # Throughput
        round(Int, mean(timings_us) / N), # Avg duration
        round(std(timings_us) / N, digits=2), 
        round(Int, minimum(timings_us) / N), 
        round(Int, maximum(timings_us) / N)]
end

function benchmark_table()
    column_labels = [
        ["Benchmark", "N", "Memory", "Allocations", "Duration", "Throughput", "Avg duration",  "Std-dev", "Min", "Max"],
        ["",          "calls", "MiB", "",           "s",        "calls/s",    "μs",            "μs",      "μs",  "μs"]
    ]
    all_benchmarks = [
        (workload_smol, 1_000),
        (workload_32_224_224_uint8, 100),
        (workload_streaming_request, 1_000),
        (workload_streaming_response, 1_000),
        (workload_streaming_bidirectional, 1_000),
    ]

    all_results = [perform_benchmark(f, N) for (f, N) in ProgressBar(all_benchmarks)]
    
    pretty_table(
        permutedims(reduce(hcat, all_results));
        column_labels = column_labels,
        style         = TextTableStyle(first_line_column_label = crayon"yellow bold"),
        table_format  = TextTableFormat(borders = text_table_borders__unicode_rounded)
    )
end


nothing
