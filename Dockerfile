FROM julia:1.12-trixie

# Need curl to install uv
RUN apt-get update
RUN apt-get install -y curl 

# Install uv so we can easily install dependencies for the gRPC test server
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
# Add uv to PATH
ENV PATH=$PATH:/root/.local/bin

# Copy all needed files
RUN mkdir -p /test
COPY Manifest.toml /test 
COPY Project.toml /test 
ADD src /test/src
RUN mkdir -p /test/test

ADD test/gen /test/test/gen
ADD test/proto /test/test/proto
ADD test/python /test/test/python
COPY test/runtests.jl /test/test/
COPY test/entrypoint.sh /test/test/

ENTRYPOINT /test/test/entrypoint.sh
