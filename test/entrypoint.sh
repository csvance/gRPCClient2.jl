#!/bin/bash

set -e

pushd /test/test/python 
# uv sync to ensure all Python dependencies are installed before starting tests in Julia
uv sync
nohup uv run grpc_test_server.py &
popd 

pushd /test

julia -t auto --project=.<<EOF

using Pkg
Pkg.instantiate()
Pkg.test()

EOF