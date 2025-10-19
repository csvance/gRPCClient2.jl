isfull(ch::Channel) = begin
    if ch.sz_max === 0
        isready(ch)
    else
        length(ch.data) ≥ ch.sz_max
    end
end

nullstring(x::Vector{UInt8}) = String(x[1:findfirst(==(0), x)-1])
