# gRPCClient2.jl

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability. It borrows some elements from [gRPCClient.jl](https://github.com/JuliaComputing/gRPCClient.jl) and [Downloads.jl](https://github.com/JuliaLang/Downloads.jl) but diverges in that it directly interfaces with a custom libCURL backend specifically tailored for gRPC performance.

## Usage

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

## Status

Currently the repo is in an rough state but multithreading works without deadlocks and things are running reasonably fast.

## TODO

- [x] Define formal interface for sync / async requests
- [x] Refactor codebase, breaking things down into multiple files
- [x] Propper handling of gRPC response headers / trailers
- [ ] Performance analysis (type stability, allocations, multithreading, lock contention) and further optimizations
- [ ] Write tests
- [x] Write usage basic documentation
- [ ] Static docs website style full documentation 
- [ ] Client stub generation in ProtoBuf.jl
- [ ] Support compression
- [ ] Add support for streaming RPC

Support is eventually planned for streaming RPC but its not a priority. Pull requests for this will be accepted only if it does not impact unary RPC performance at all.
