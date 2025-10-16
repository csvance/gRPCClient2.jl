
from concurrent import futures
import logging

import numpy as np
import grpc
import test_pb2
import test_pb2_grpc
import sys

class TestServiceServicer(test_pb2_grpc.TestServiceServicer):
    def __init__(self, public: bool = False):
        self.public = public

    def TestRPC(self, request: test_pb2.TestRequest, context):

        if not self.public:
            # For testing
            response_data = np.arange(request.test_response_sz, dtype=np.uint64)
            response_data[:] += 1
        else:
            # For precompile
            response_data = np.arange(1, dtype=np.uint64)
            response_data[:] += 1

        return test_pb2.TestResponse(data=response_data)


def serve(public: bool = False):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=12))
    test_pb2_grpc.add_TestServiceServicer_to_server(
        TestServiceServicer(public=public), server
    )
    server.add_insecure_port("[::]:8001")
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig()
    serve(public=sys.argv[1] == 'public')