# gRPCClient2.jl

[![CI](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/csvance/gRPCClient2.jl/actions/workflows/ci.yml)

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability.

**Note that the package is in a pre-release state and external interfaces / API are unstable.**

## Usage

Code generation integration with ProtoBuf.jl is not complete yet but the following lower level syntax can be used:

```julia
using gRPCClient2

# Initialize the gRPC package - grpc_shutdown() does the opposite for use with Revise.
grpc_init()

# Client stubs like this will be automatically created by ProtoBuf code generation in the near future
TestService_TestRPC_Client(
	host, port;
	secure=false,
	grpc=grpc_global_handle(),
	deadline=10,
	keepalive=60,
    max_send_message_length = 4*1024*1024,
    max_recieve_message_length = 4*1024*1024,
) = gRPCClient{TestRequest, TestResponse}(
	host, port, "/test.TestService/TestRPC";
	secure=secure,
	grpc=grpc,
	deadline=deadline,
	keepalive=keepalive,
    max_send_message_length = max_send_message_length,
    max_recieve_message_length = max_recieve_message_length,
)

# Create a client from the generated client stub
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