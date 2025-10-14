module gRPCClient2

using LibCURL
using Base.Threads
using ProtoBuf
using FileWatching
using Base: OS_HANDLE

import Base.wait, Base.reset, Base.notify, Base.isreadable, Base.iswritable

abstract type gRPCException <: Exception end

struct gRPCServiceCallException <: gRPCException
    grpc_status::Int
    message::String
end

include("Curl.jl")
include("gRPC.jl")

export grpc_unary_async_request
export grpc_unary_async_await
export grpc_unary_sync

export gRPCCURL
export gRPCRequest

end
