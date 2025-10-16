# gRPCClient2.jl

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability.

## Features

- Unary RPC (non streaming)
- HTTP/2 connection multiplexing
- Synchronous and asynchronous interfaces
- Thread safe
- SSL/TLS

The client is missing a few features which will be added over time:

- OAuth2
- Compression
- Streaming RPC

## Getting Started

### Test gRPC Server

All examples in the documentation are run against a test server written in Python. You can run it by doing the following:

```bash
# Install uv package manager (https://docs.astral.sh/uv/#installation)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Change directory to the python test server project
cd test/python

# Run the test server
uv run grpc_test_server.py

```

### Code Generation

gRPCClient2.jl integrates with ProtoBuf.jl to automatically generate Julia client stubs for calling gRPC. 

```
using ProtoBuf
using gRPCClient2

# Creates Julia bindings for the messages and RPC defined in test.proto
protojl("proto/test.proto", ".", "gen")
```

### Making Requests with gRPCClient2.jl

```julia
using gRPCClient2

# Include the generated bindings
include("test/gen/test/test_pb.jl")

# Create a client bound to a specific RPC
client = TestService_TestRPC_Client("localhost", 8001)

# Make a syncronous request and get back a TestResponse
response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))
@info response

# Make some async requests and await their TestResponse
requests = Vector{gRPCRequest}()
for i in 1:10
    push!(
        requests, 
        grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
    )
end

for request in requests
    response = grpc_async_await(client, request)
    @info response
end
```

## Package Initialization / Shutdown

```@docs
grpc_init()
grpc_shutdown()
grpc_global_handle()
```

## Request Functions

```@docs
grpc_sync_request(client::gRPCClient{TRequest,TResponse}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCClient{TRequest,TResponse}, request::TRequest) where {TRequest<:Any,TResponse<:Any}
grpc_async_await(client::gRPCClient{TRequest,TResponse}, request::gRPCRequest) where {TRequest<:Any,TResponse<:Any}
grpc_async_request(client::gRPCClient{TRequest,TResponse}, request::TRequest, channel::Channel{gRPCAsyncChannelResponse{TResponse}}, index::Int64) where {TRequest<:Any,TResponse<:Any}
```