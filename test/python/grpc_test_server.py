import time
from concurrent import futures
import logging
import os
import sys

import numpy as np
import grpc
import test_pb2
import test_pb2_grpc

# --- IMPORTANT ASSUMPTION ---
# This implementation assumes that `test.proto` has been updated to include
# `StressTestRequest` and `StressTestResponse` message definitions, and that
# `test_pb2.py` and `test_pb2_grpc.py` have been regenerated.
# The assumed message structures are:
#
# message StressTestRequest {
#   int32 payload_size = 1;        // Size of payload in bytes for each message
#   int32 num_messages = 2;        // For server streaming: how many messages to send
#   int32 processing_delay_ms = 3; // Server-side artificial delay per message (ms)
#   bool  return_data = 4;         // Whether to actually return the payload or just an empty response
# }
#
# message StressTestResponse {
#   bytes payload = 1;
#   int64 sequence_num = 2;                   // Sequence number of the message in a stream
#   int32 server_processing_time_ms = 3;      // Actual server processing time for this message/stream
#   int32 client_stream_msg_count = 4;        // For client stream aggregation
#   int64 client_stream_total_payload_size = 5; // For client stream aggregation
# }
#
# These new RPC methods are added to the existing `TestServiceServicer`.


# Helper to generate a payload of given size for stress tests
def _generate_payload(size: int) -> bytes:
    if size <= 0:
        return b""
    # Generate a simple, repeatable byte sequence for the payload.
    return b'a' * size

class TestServiceServicer(test_pb2_grpc.TestServiceServicer):
    def __init__(self, public: bool = False):
        self.public = public
        self.log = logging.getLogger(self.__class__.__name__)
        if public:
            # In public mode, restrict original RPC responses to small size regardless of request
            self.max_response_data_size = 1
        else:
            # In test mode, allow larger responses for original RPCs
            self.max_response_data_size = 4 * 1024 * 1024 // 8 # 4MB in uint64 elements

    def _get_response_data(self, requested_size: int) -> np.ndarray:
        """
        Helper to generate numpy array response data for original RPCs,
        respecting public mode size limits.
        """
        if self.public:
            actual_size = self.max_response_data_size
        else:
            actual_size = min(requested_size, self.max_response_data_size)
        
        if actual_size <= 0:
            return np.array([], dtype=np.uint64)

        response_data = np.arange(actual_size, dtype=np.uint64)
        response_data[:] += 1 # Fill with some simple value
        return response_data

    # --- Original RPC Implementations (Refactored) ---

    def TestRPC(self, request: test_pb2.TestRequest, context):
        self.log.debug(f"TestRPC received request with test_response_sz={request.test_response_sz}")
        response_data = self._get_response_data(request.test_response_sz)
        return test_pb2.TestResponse(data=response_data)

    def TestClientStreamRPC(self, request_iterator, context):
        total_size = 0
        message_count = 0
        for request in request_iterator:
            message_count += 1
            # For this existing RPC, we interpret test_response_sz as a contributor to total size
            total_size += request.test_response_sz 
        
        self.log.debug(f"TestClientStreamRPC received {message_count} messages, total_size_sum={total_size}")
        response_data = self._get_response_data(total_size)
        return test_pb2.TestResponse(data=response_data)

    def TestServerStreamRPC(self, request, context):
        self.log.debug(f"TestServerStreamRPC received request with test_response_sz={request.test_response_sz}")
        # For this existing RPC, we interpret test_response_sz as the number of messages to send
        num_messages_to_send = request.test_response_sz
        if self.public:
            num_messages_to_send = min(num_messages_to_send, 10) # Arbitrary limit for public mode
        
        for i in range(1, int(num_messages_to_send) + 1):
            # Send responses with increasing sizes based on original logic
            response_data = self._get_response_data(i) 
            yield test_pb2.TestResponse(data=response_data)
        self.log.debug(f"TestServerStreamRPC sent {num_messages_to_send} messages.")


    def TestBidirectionalStreamRPC(self, request_iterator, context):
        message_count = 0
        for request in request_iterator:
            message_count += 1
            self.log.debug(f"TestBidirectionalStreamRPC received message {message_count} with size {request.test_response_sz}")
            response_data = self._get_response_data(request.test_response_sz)
            yield test_pb2.TestResponse(data=response_data)
        self.log.debug(f"TestBidirectionalStreamRPC completed. Sent {message_count} responses.")

    # --- New Stress Test RPC Implementations ---

    def StressTestBidiStream(self, request_iterator, context):
        """
        Bidirectional streaming RPC for stress testing.
        Client streams `StressTestRequest`s, server streams `StressTestResponse`s.
        """
        message_count = 0
        for request in request_iterator:
            message_count += 1
            start_time = time.perf_counter()

            payload_size = request.payload_size
            delay_ms = request.processing_delay_ms
            return_data = getattr(request, 'return_data', True)

            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)

            payload = _generate_payload(payload_size) if return_data else b""
            server_processing_time_ms = int((time.perf_counter() - start_time) * 1000)

            self.log.debug(
                f"StressTestBidiStream: received msg {message_count}, "
                f"payload_size={payload_size}, delay={delay_ms}ms, "
                f"server_time={server_processing_time_ms}ms"
            )
            yield test_pb2.StressTestResponse(
                payload=payload,
                sequence_num=message_count,
                server_processing_time_ms=server_processing_time_ms
            )
        self.log.info(f"StressTestBidiStream completed. Processed {message_count} messages.")

    def StressTestClientStream(self, request_iterator, context):
        """
        Client-streaming RPC for stress testing.
        Client streams `StressTestRequest`s, server sends a single aggregated `StressTestResponse`.
        """
        message_count = 0
        total_payload_size = 0
        start_time = time.perf_counter()

        for request in request_iterator:
            message_count += 1
            # Aggregate the size specified by the client, not an actual payload.
            total_payload_size += request.payload_size
            self.log.debug(f"StressTestClientStream: received msg {message_count}, current total size: {total_payload_size}")

        server_processing_time_ms = int((time.perf_counter() - start_time) * 1000)
        self.log.info(
            f"StressTestClientStream completed. Received {message_count} messages, "
            f"total payload size: {total_payload_size} bytes, "
            f"total server time: {server_processing_time_ms}ms"
        )
        return test_pb2.StressTestResponse(
            client_stream_msg_count=message_count,
            client_stream_total_payload_size=total_payload_size,
            server_processing_time_ms=server_processing_time_ms
        )

    def StressTestServerStream(self, request, context):
        """
        Server-streaming RPC for stress testing.
        Client sends a single `StressTestRequest`, server streams back `num_messages` responses.
        """
        num_messages = request.num_messages
        payload_size = request.payload_size
        delay_ms = request.processing_delay_ms
        return_data = getattr(request, 'return_data', True)

        self.log.info(
            f"StressTestServerStream starting. Will send {num_messages} messages "
            f"with payload_size={payload_size} and delay={delay_ms}ms."
        )

        for i in range(num_messages):
            start_time = time.perf_counter()
            
            if delay_ms > 0:
                time.sleep(delay_ms / 1000.0)

            payload = _generate_payload(payload_size) if return_data else b""
            server_processing_time_ms = int((time.perf_counter() - start_time) * 1000)

            yield test_pb2.StressTestResponse(
                payload=payload,
                sequence_num=i + 1,
                server_processing_time_ms=server_processing_time_ms
            )

        self.log.info(f"StressTestServerStream completed. Sent {num_messages} messages.")

def serve(public: bool = False):
    # Using more workers can help with I/O-bound tasks and concurrency, 
    # especially when using time.sleep() which blocks a worker thread.
    num_workers = int(os.environ.get('GRPC_SERVER_WORKERS', '12'))
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=num_workers))
    test_pb2_grpc.add_TestServiceServicer_to_server(
        TestServiceServicer(public=public), server
    )
    if public:
        bind_address = "[::]:8001"
        logging.info("Listening on %s in public mode" % bind_address)
        logging.info("(len(response.data) will always be 1 for original RPCs)")
        server.add_insecure_port(bind_address)
    else:
        bind_address = "127.0.0.1:8001"
        logging.info("Listening on %s in test mode" % bind_address)
        server.add_insecure_port(bind_address)

    logging.info(f"Server started with {num_workers} worker threads.")
    server.start()
    server.wait_for_termination()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    serve(public=len(sys.argv) > 1 and sys.argv[1] == 'public')