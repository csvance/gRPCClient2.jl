# gRPCClient2.jl

[![CI](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml)

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability.

**Note that the package is in a pre-release state and external interfaces / API are unstable.**

## Usage

Code generation integration with ProtoBuf.jl is not complete yet but the following lower level syntax can be used:

```julia
using gRPCClient2

grpc_init()

# This will eventually be created by ProtoBuf code generation
TestService_TestRPC_Client(host, port; secure=false, deadline=10, keepalive=60) = gRPCClient{TestRequest, TestResponse}(host, port, "/test.TestService/TestRPC"; secure=secure, deadline=deadline, keepalive=keepalive)

# Create a client 
client = TestService_TestRPC_Client("localhost", 8001)

# Sync API
test_response = grpc_unary_sync(client, TestRequest(1))

# Async API
requests = Vector{gRPCRequest}()
for i in 1:10
    push!(
        requests, 
        grpc_unary_async_request(client, TestRequest(1))
    )
end

for request in requests
    response = grpc_unary_async_await(client, request)
end
```