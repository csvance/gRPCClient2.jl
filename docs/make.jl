using Documenter
using gRPCClient2

makedocs(
    sitename = "gRPCClient2",
    format = Documenter.HTML(),
    modules = [gRPCClient2]
)

# Documenter can also automatically deploy documentation to gh-pages.
# See "Hosting Documentation" and deploydocs() in the Documenter manual
# for more information.
deploydocs(
    repo = "github.com/csvance/gRPCClient2.jl.git"
)
