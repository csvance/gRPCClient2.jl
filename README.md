# gRPCClient2.jl

[![CI](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml)

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability.

**Note that the package is in a pre-release state and external interfaces / API are unstable.**

## Usage

Code generation integration with ProtoBuf.jl is not complete yet but the following lower level syntax can be used:

```julia
using gRPCClient2

const grpc = gRPCCURL()

# Sync
test_response = grpc_unary_sync(grpc, "grpc://localhost:50051/test.TestService/TestRPC", TestRequest(1), TestResponse)

# Async
requests = Vector{gRPCRequest}()
for i in 1:10
    push!(
        requests, 
        grpc_unary_async_request(grpc, "grpc://localhost:50051/test.TestService/TestRPC", TestRequest(1))
    )
end

for request in requests
    response::TestResponse = grpc_unary_async_await(grpc, request, TestResponse)
end
```

Once code generation support is finished, it will look something like this:

```julia
TestService_TestRPC_async_request(grpc, url, request::TestRequest; deadline=10, keepalive=60) = grpc_unary_async_request(grpc, grpc_path_url(url, "/test.TestService/TestRPC"), request; deadline=deadline, keepalive=keepalive)
TestService_TestRPC_async_await(grpc, request) = grpc_unary_async_await(grpc, request, TestResponse)
TestService_TestRPC_sync(grpc, url, request::TestRequest; deadline=10, keepalive=60) = TestService_TestRPC_async_await(grpc, TestService_TestRPC_async_request(grpc, url, request; deadline=deadline, keepalive=keepalive))

grpc = gRPCCURL()

request = TestService_TestRPC_async_request(grpc, "grpc://localhost:8001", TestRequest(1))
response = TestService_TestRPC_async_await(grpc, request)
```