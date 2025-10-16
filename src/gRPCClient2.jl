module gRPCClient2

using PrecompileTools: @setup_workload, @compile_workload    # this is a small dependency

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

const GRPC_OK = 0
const GRPC_CANCELLED = 1
const GRPC_UNKNOWN = 2
const GRPC_INVALID_ARGUMENT = 3
const GRPC_DEADLINE_EXCEEDED = 4
const GRPC_NOT_FOUND = 5
const GRPC_ALREADY_EXISTS = 6
const GRPC_PERMISSION_DENIED = 7
const GRPC_RESOURCE_EXHAUSTED = 8
const GRPC_FAILED_PRECONDITION = 9
const GRPC_ABORTED = 10
const GRPC_OUT_OF_RANGE = 11
const GRPC_UNIMPLEMENTED = 12
const GRPC_INTERNAL = 13
const GRPC_UNAVAILABLE = 14
const GRPC_DATA_LOSS = 15
const GRPC_UNAUTHENTICATED = 16

const GRPC_CODE_TABLE = Dict{Int64, String}(
    0 => "OK",
    1 => "CANCELLED",
    2 => "UNKNOWN",
    3 => "INVALID_ARGUMENT",
    4 => "DEADLINE_EXCEEDED",
    5 => "NOT_FOUND",
    6 => "ALREADY_EXISTS",
    7 => "PERMISSION_DENIED",
    8 => "RESOURCE_EXHAUSTED",
    9 => "FAILED_PRECONDITION",
    10 => "ABORTED",
    11 => "OUT_OF_RANGE",
    12 => "UNIMPLEMENTED",
    13 => "INTERNAL",
    14 => "UNAVAILABLE",
    15 => "DATA_LOSS",
    16 => "UNAUTHENTICATED",
)

function Base.showerror(io::IO, e::gRPCServiceCallException)
    print(io, "gRPCServiceCallException($(GRPC_CODE_TABLE[e.grpc_status])($(e.grpc_status)), \"$(e.message)\")")
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

@setup_workload begin
    @compile_workload begin

    include("../test/gen/test/test_pb.jl")

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

    # We don't have a Julia gRPC server so call my Linode's public gRPC endpoint
    client = TestService_TestRPC_Client("172.238.177.88", 8001)

    # Sync API
    test_response = grpc_unary_sync(client, TestRequest(1, Vector{UInt64}()))

    # Async API
    request = grpc_unary_async_request(client, TestRequest(1, Vector{UInt64}()))
    response = grpc_unary_async_await(client, request)

    end
end



end
