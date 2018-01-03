module ConnectionPool

export getconnection, getparser, getrawstream, inactiveseconds

using ..IOExtras

import ..@debug, ..DEBUG_LEVEL, ..taskid, ..@require, ..precondition_error
import MbedTLS.SSLContext
import ..Connect: getconnection, getparser, getrawstream, inactiveseconds
import ..Parsers.Parser


const default_duplicate_limit = 8
const default_pipeline_limit = 16
const nolimit = typemax(Int)

const nobytes = view(UInt8[], 1:0)
const ByteView = typeof(nobytes)
byteview(bytes::ByteView) = bytes
byteview(bytes)::ByteView = view(bytes, 1:length(bytes))


function havelock(l)
    @assert l.reentrancy_cnt <= 1
    islocked(l) && l.locked_by == current_task()
end


"""
    Connection{T <: IO}

A `TCPSocket` or `SSLContext` connection to a HTTP `host` and `port`.

- `host::String`
- `port::String`
- `io::T`, the `TCPSocket` or `SSLContext.
- `excess::ByteView`, left over bytes read from the connection after
   the end of a response message. These bytes are probably the start of the
   next response message.
- `writecount`, number of Request Messages that have been written.
- `readcount`, number of Response Messages that have been read.
- `writelock`, busy writing a Request to `io`.
- `readlock`, busy reading a Response from `io`.
- `parser::Parser`, reuse a `Parser` when this `Connection` is reused.
"""

mutable struct Connection{T <: IO}
    host::String
    port::String
    pipeline_limit::Int
    peerport::UInt16
    localport::UInt16
    io::T
    excess::ByteView
    writebusy::Bool
    writecount::Int
    readcount::Int
    readlock::ReentrantLock
    timestamp::Float64
    parser::Parser
end

struct Transaction{T <: IO} <: IO
    c::Connection{T}
    sequence::Int
end


Connection{T}(host::AbstractString, port::AbstractString,
              pipeline_limit::Int, io::T) where T <: IO =
    Connection{T}(host, port, pipeline_limit,
                  peerport(io), localport(io), io, view(UInt8[], 1:0),
                  0, 0, 0, ReentrantLock(), 0, Parser())

function Transaction{T}(c::Connection{T}) where T <: IO
    r = Transaction{T}(c, c.writecount)
    startwrite(r)
    return r
end

getparser(t::Transaction) = t.c.parser


getrawstream(t::Transaction) = t.c.io


inactiveseconds(t::Transaction) = inactiveseconds(t.c)


function inactiveseconds(c::Connection)::Float64
    if !islocked(c.readlock)
        return Float64(0)
    end
    return time() - c.timestamp
end


Base.unsafe_write(t::Transaction, p::Ptr{UInt8}, n::UInt) =
    unsafe_write(t.c.io, p, n)

Base.isopen(t::Transaction) = isopen(t.c.io)

function Base.eof(t::Transaction)
    @require isreadable(t) || !isopen(t)
    if nb_available(t) > 0
        return false
    end                 ;@debug 3 "eof(::Transaction) -> eof($typeof(c.io)): $t"
    return eof(t.c.io)
end

Base.nb_available(t::Transaction) = nb_available(t.c)
Base.nb_available(c::Connection) =
    !isempty(c.excess) ? length(c.excess) : nb_available(c.io)

Base.isreadable(t::Transaction) = islocked(t.c.readlock) &&
                                  t.c.readcount == t.sequence

Base.iswritable(t::Transaction) = t.c.writebusy &&
                                  t.c.writecount == t.sequence


function Base.readavailable(t::Transaction)::ByteView
    @require isreadable(t)
    if !isempty(t.c.excess)
        bytes = t.c.excess
        @debug 3 "↩️  read $(length(bytes))-bytes from excess buffer."
        t.c.excess = nobytes
    else
        bytes = byteview(readavailable(t.c.io))
        @debug 3 "⬅️  read $(length(bytes))-bytes from $(typeof(t.c.io))"
    end
    t.c.timestamp = time()
    return bytes
end


"""
    unread!(::Transaction, bytes)

Push bytes back into a connection's `excess` buffer
(to be returned by the next read).
"""

function IOExtras.unread!(t::Transaction, bytes::ByteView)
    @require isreadable(t)
    t.c.excess = bytes
end


function IOExtras.startwrite(t::Transaction)
    @require !t.c.writebusy
    t.c.writebusy = true
end


"""
    closewrite(::Transaction)

Signal that an entire Request Message has been written to the `Transaction`.

Increment `writecount` and wait for pending reads to complete.
"""

function IOExtras.closewrite(t::Transaction)
    @require iswritable(t)

    t.c.writecount += 1                           ;@debug 2 "🗣  Write done: $t"
    t.c.writebusy = false
    notify(poolcondition)

    @assert !iswritable(t)
end


"""
    startread(::Transaction)

Wait for prior pending reads to complete, then lock the readlock.
"""

function IOExtras.startread(t::Transaction)
    @require !isreadable(t)

    t.c.timestamp = time()
    lock(t.c.readlock)
    while t.c.readcount != t.sequence
        unlock(t.c.readlock)
        yield()                           ;@debug 0 "⏳  Waiting to read:    $t"
        lock(t.c.readlock)
    end                                           ;@debug 1 "👁  Start read: $t"
    @assert isreadable(t)
    return
end

ensurereadable(t::Transaction) = if !isreadable(t) startread(t) end


"""
    closeread(::Transaction)

Signal that an entire Response Message has been read from the `Transaction`.

Increment `readcount` and wake up tasks waiting in `closewrite`.
"""

function IOExtras.closeread(t::Transaction)
    @require isreadable(t)
    t.c.readcount += 1
    unlock(t.c.readlock)                          ;@debug 2 "✉️  Read done:  $t"
    notify(poolcondition)
    @assert !isreadable(t)
    return
end

function Base.close(t::Transaction)
    close(t.c.io)                                 ;@debug 2 "🚫      Closed: $t"
    if iswritable(t)
        closewrite(t)
    end
    if isreadable(t)
        purge(t.c)
        closeread(t)
    end
    notify(poolcondition)
    return
end

Base.close(c::Connection) = Base.close(c.io)


"""
    purge(::Transaction)

Remove unread data from a `Transaction`.
"""

function purge(c::Connection)
    @require !isopen(c.io)
    while !eof(c.io)
        readavailable(c.io)
    end
    c.excess = nobytes
    @assert nb_available(c) == 0
end


"""
    pool

The `pool` is a collection of open `Connection`s.  The `request`
function calls `getconnection` to retrieve a connection from the
`pool`.  When the `request` function has written a Request Message
it calls `closewrite` to signal that the `Connection` can be reused
for writing (to send the next Request). When the `request` function
has read the Response Message it calls `closeread` to signal that
the `Connection` can be reused for reading.
"""

const pool = Vector{Connection}()
const poollock = ReentrantLock()
const poolcondition = Condition()

"""
    closeall()

Close all connections in `pool`.
"""

function closeall()

    lock(poollock)
    for c in pool
        close(c)
    end
    empty!(pool)
    unlock(poollock)
    return
end


"""
    findwritable(type, host, port) -> Vector{Connection}

Find `Connections` in the `pool` that are ready for writing.
"""

function findwritable(T::Type,
                      host::AbstractString,
                      port::AbstractString,
                      pipeline_limit::Int,
                      reuse_limit::Int)

    filter(c->(!c.writebusy &&
               typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               c.writecount < reuse_limit &&
               c.writecount - c.readcount < pipeline_limit + 1 &&
               isopen(c.io)), pool)
end


"""
    findoverused(type, host, port, reuse_limit) -> Vector{Connection}

Find `Connections` in the `pool` that are over the reuse limit
and have no more active readers.
"""

function findoverused(T::Type,
                      host::AbstractString,
                      port::AbstractString,
                      reuse_limit::Int)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.readcount >= reuse_limit &&
               !islocked(c.readlock) &&
               isopen(c.io)), pool)
end


"""
    findall(type, host, port) -> Vector{Connection}

Find all `Connections` in the `pool` for `host` and `port`.
"""

function findall(T::Type,
                 host::AbstractString,
                 port::AbstractString,
                 pipeline_limit::Int)

    filter(c->(typeof(c.io) == T &&
               c.host == host &&
               c.port == port &&
               c.pipeline_limit == pipeline_limit &&
               isopen(c.io)), pool)
end


"""
    purge()

Remove closed connections from `pool`.
"""
function purge()
    while (i = findfirst(x->!isopen(x.io) &&
           x.readcount >= x.writecount, pool)) > 0
        c = pool[i]
        purge(c)
        deleteat!(pool, i)                        ;@debug 1 "🗑  Deleted:    $c"
    end
end


"""
    getconnection(type, host, port) -> Connection

Find a reusable `Connection` in the `pool`,
or create a new `Connection` if required.
"""

function getconnection(::Type{Transaction{T}},
                       host::AbstractString,
                       port::AbstractString;
                       duplicate_limit=default_duplicate_limit,
                       pipeline_limit::Int = default_pipeline_limit,
                       reuse_limit::Int = nolimit,
                       kw...)::Transaction{T} where T <: IO

    while true

        lock(poollock)
        @assert poollock.reentrancy_cnt == 1
        try

            # Close connections that have reached the reuse limit...
            if reuse_limit != nolimit
                for c in findoverused(T, host, port, reuse_limit)
                    close(c)
                end
            end

            # Remove closed connections from `pool`...
            purge()

            # Try to find a connection with no active readers or writers...
            writable = findwritable(T, host, port, pipeline_limit, reuse_limit)
            idle = filter(c->!islocked(c.readlock), writable)
            if !isempty(idle)
                c = rand(idle)                     ;@debug 1 "♻️  Idle:       $c"
                return Transaction{T}(c)
            end

            # If there are not too many duplicates for this host,
            # create a new connection...
            busy = findall(T, host, port, pipeline_limit)
            if length(busy) < duplicate_limit
                io = getconnection(T, host, port; kw...)
                c = Connection{T}(host, port, pipeline_limit, io)
                push!(pool, c)                    ;@debug 1 "🔗  New:        $c"
                return Transaction{T}(c)
            end

            # Share a connection that has active readers...
            if !isempty(writable)
                c = rand(writable)                 ;@debug 1 "⇆  Shared:     $c"
                return Transaction{T}(c)
            end

        finally
            unlock(poollock)
        end

        # Wait for `closewrite` or `close` to signal that a connection is ready.
        wait(poolcondition)
    end
end


function Base.show(io::IO, c::Connection)
    nwaiting = nb_available(tcpsocket(c.io))
    print(
        io,
        tcpstatus(c), " ",
        lpad(c.writecount,3),"↑", c.writebusy ? "🔒  " : "   ",
        lpad(c.readcount,3), "↓", islocked(c.readlock) ? "🔒   " : "    ",
        c.host, ":",
        c.port != "" ? c.port : Int(c.peerport), ":", Int(c.localport),
        ", ≣", c.pipeline_limit,
        length(c.excess) > 0 ? ", $(length(c.excess))-byte excess" : "",
        inactiveseconds(c) > 5 ?
            ", inactive $(round(inactiveseconds(c),1))s" : "",
        nwaiting > 0 ? ", $nwaiting bytes waiting" : "",
        DEBUG_LEVEL > 0 ? ", $(Base._fd(tcpsocket(c.io)))" : "",
        DEBUG_LEVEL > 0 &&
        islocked(c.readlock) ?  ", read task: $(taskid(c.readlock))" : "")
end

Base.show(io::IO, t::Transaction) = print(io, "T$(t.sequence) ", t.c)


function tcpstatus(c::Connection)
    s = Base.uv_status_string(tcpsocket(c.io))
        if s == "connecting" return "🔜🔗"
    elseif s == "open"       return "🔗 "
    elseif s == "active"     return "🔁 "
    elseif s == "paused"     return "⏸ "
    elseif s == "closing"    return "🔜💀"
    elseif s == "closed"     return "💀 "
    else
        return s
    end
end

function showpool(io::IO)
    lock(poollock)
    println(io, "ConnectionPool[")
    for c in pool
        println(io, "   $c")
    end
    println("]\n")
    unlock(poollock)
end

end # module ConnectionPool