using Test 
using ProtoBuf 
using gRPCClient2

# protobuf and service definitions for our tests
include("gen/test/test_pb.jl")

@testset "gRPCClient2.jl" begin
    # Initialize the global gRPCCURL structure
    grpc_init()

    client = TestService_TestRPC_Client("localhost", 8001)

    @testset "@async varying request/response" begin
        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_async_request(client, TestRequest(i, zeros(UInt64, i)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == i

            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    end

    @testset "@async small request/response" begin 
        requests = Vector{gRPCRequest}()
        for i in 1:1000
            request = grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
            push!(requests, request)
        end 

        for (i, request) in enumerate(requests)
            response = grpc_async_await(client, request)
            @test length(response.data) == 1
            @test response.data[1] == 1
        end
    end 

    @testset "Threads.@spawn small request/response" begin
        responses = [TestResponse(Vector{UInt64}()) for _ in 1:1000]

        @sync Threads.@threads for i in 1:1000
            response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
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
            response = grpc_sync_request(client, TestRequest(i, zeros(UInt64, i)))
            responses[i] = response
        end 

        for (i, response) in enumerate(responses)
            @test length(response.data) == i
            for (di, dv) in enumerate(response.data)
                @test di == dv
            end
        end
    end

    @testset "Max Message Size" begin 
        # Create a client with much more restictive max message lengths
        client_ms = TestService_TestRPC_Client("localhost", 8001; max_send_message_length=1024, max_recieve_message_length=1024)

        # Send too much 
        @test_throws gRPCServiceCallException grpc_sync_request(client_ms, TestRequest(1, zeros(UInt64, 1024)))
        # Receive too much
        @test_throws gRPCServiceCallException grpc_sync_request(client_ms, TestRequest(1024, zeros(UInt64, 1)))
    end

end