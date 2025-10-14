# gRPCClient2.jl

gRPCClient2.jl aims to be a production grade gRPC client emphasizing performance and reliability. It borrows some elements from [gRPCClient.jl](https://github.com/JuliaComputing/gRPCClient.jl) and [Downloads.jl](https://github.com/JuliaLang/Downloads.jl) but diverges in that it directly interfaces with a custom libCURL backend specifically tailored for gRPC performance.

## Status

Currently the repo is in an rough state but multithreading works without deadlocks and things are running reasonably fast.

## TODO

- [ ] Define formal interface for sync / async requests
- [ ] Refactor codebase, breaking things down into multiple files
- [ ] Performance analysis (type stability, allocations, multithreading) and further optimizations
- [ ] Write tests
- [ ] Write usage basic documentation
- [ ] Add support for streaming RPC

Support is eventually planned for streaming RPC but its not a priority. Pull requests for this will be accepted only if it does not impact unary RPC performance at all.