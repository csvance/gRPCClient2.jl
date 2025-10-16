# gRPCClient2.jl

[![CI](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml)

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability.

**Note that the package is in a pre-release state and external interfaces / API are unstable.**

## Usage

```julia
using gRPCClient2

include("test/gen/test/test_pb.jl")

# Initialize the gRPC package - grpc_shutdown() does the opposite for use with Revise.
grpc_init()

# Create a client from the generated client stub
client = TestService_TestRPC_Client("172.238.177.88", 8001)

# Sync API
test_response = grpc_sync_request(client, TestRequest(1, zeros(UInt64, 1)))

# Async API
requests = Vector{gRPCRequest}()
for i in 1:10
    push!(
        requests, 
        grpc_async_request(client, TestRequest(1, zeros(UInt64, 1)))
    )
end

for request in requests
    response = grpc_async_await(client, request)
end
```