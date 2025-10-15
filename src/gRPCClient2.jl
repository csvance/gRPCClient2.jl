module gRPCClient2

using LibCURL
using Base.Threads
using ProtoBuf
using FileWatching
using Base: OS_HANDLE

import Base.wait,
    Base.reset, Base.notify, Base.isreadable, Base.iswritable, Base.close, Base.open
import ProtoBuf.CodeGenerators.ServiceType,
    ProtoBuf.CodeGenerators.RPCType,
    ProtoBuf.CodeGenerators.Context,
    ProtoBuf.CodeGenerators.codegen,
    ProtoBuf.CodeGenerators.safename

abstract type gRPCException <: Exception end

struct gRPCServiceCallException <: gRPCException
    grpc_status::Int
    message::String
end

include("Curl.jl")
include("gRPC.jl")
include("ProtoBuf.jl")

export grpc_init
export grpc_shutdown
export grpc_global_handle

export grpc_unary_async_request
export grpc_unary_async_await
export grpc_unary_sync

export gRPCCURL
export gRPCRequest
export gRPCClient

export open
export close

export gRPCException
export gRPCServiceCallException

end
