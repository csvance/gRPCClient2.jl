using Test 
using ProtoBuf 
using gRPCClient2

# request / response protobuf for our test RPC
include("gen/test/test_pb.jl")


@testset "gRPCClient2.jl" begin
    # Initialize the global gRPCCURL structure
    grpc_init()

    # This would normally be created by bindings
    TestService_TestRPC_Client(host, port; secure=false, deadline=10, keepalive=60) = gRPCClient{TestRequest, TestResponse}(host, port, "/test.TestService/TestRPC"; secure=secure, deadline=deadline, keepalive=keepalive)
    client = TestService_TestRPC_Client("localhost", 8001)

    @testset "@async varying request/response" begin
        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_unary_async_request(client, TestRequest(i, zeros(UInt64, i)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_unary_async_await(client, request)
            @test length(response.data) == i

            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    end

    @testset "@async small request/response" begin 
        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_unary_async_request(client, TestRequest(1, zeros(UInt64, 1)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_unary_async_await(client, request)
            @test length(response.data) == 1
            @test response.data[1] == 1
        end
    end 

    @testset "Threads.@spawn small request/response" begin
        responses = [TestResponse(Vector{UInt64}()) for _ in 1:1000]

        @sync Threads.@threads for i in 1:1000
            response = grpc_unary_sync(client, TestRequest(1, zeros(UInt64, 1)))
            responses[i] = response
        end 

        for (i, response) in enumerate(responses)
            @test length(response.data) == 1
            @test response.data[1] == 1
        end
    end

    @testset "Threads.@spawn varying request/response" begin
        responses = [TestResponse(Vector{UInt64}()) for _ in 1:1000]

        @sync Threads.@threads for i in 1:1000
            response = grpc_unary_sync(client, TestRequest(i, zeros(UInt64, i)))
            responses[i] = response
        end 

        for (i, response) in enumerate(responses)
            @test length(response.data) == i
            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    end

end