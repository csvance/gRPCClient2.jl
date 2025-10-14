
from concurrent import futures
import logging

import numpy as np
import grpc
import test_pb2
import test_pb2_grpc

class TestServiceServicer(test_pb2_grpc.TestServiceServicer):
    def TestRPC(self, request: test_pb2.TestRequest, context):
        response_data = np.arange(request.test_response_sz, dtype=np.uint64)
        response_data[:] += 1

        return test_pb2.TestResponse(data=response_data)


def serve():
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=12))
    test_pb2_grpc.add_TestServiceServicer_to_server(
        TestServiceServicer(), server
    )
    server.add_insecure_port("[::]:8001")
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig()
    serve()