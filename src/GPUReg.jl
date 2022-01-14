import CUDA: cu
import Yao.YaoArrayRegister: _measure, measure, measure!, measure_collapseto!, measure_remove!
import Yao.YaoBase: batch_normalize!
import Yao.YaoBlocks: BlockedBasis, nblocks, subblock
import Yao: expect

export cpu, cu, GPUReg

cu(reg::ArrayReg{B}) where B = ArrayReg{B}(CuArray(reg.state))
cpu(reg::ArrayReg{B}) where B = ArrayReg{B}(collect(reg.state))
const GPUReg{B, T, MT} = ArrayReg{B, T, MT} where MT<:CuArray

function batch_normalize!(s::DenseCuArray, p::Real=2)
    p!=2 && throw(ArgumentError("p must be 2!"))
    s./=norm2(s, dims=1)
    s
end

@inline function tri2ij(l::Int)
    i = ceil(Int, sqrt(2*l+0.25)-0.5)
    j = l-i*(i-1)÷2
    i+1,j
end

############### MEASURE ##################
function measure(::ComputationalBasis, reg::GPUReg{1}, ::AllLocs; rng::AbstractRNG=Random.GLOBAL_RNG, nshots::Int=1)
    _measure(rng, reg |> probs |> Vector, nshots)
end

# TODO: optimize the batch dimension using parallel sampling
function measure(::ComputationalBasis, reg::GPUReg{B}, ::AllLocs; rng::AbstractRNG=Random.GLOBAL_RNG, nshots::Int=1) where B
    regm = reg |> rank3
    pl = dropdims(mapreduce(abs2, +, regm, dims=2), dims=2)
    _measure(rng, pl |> Matrix, nshots)
end

function measure!(::RemoveMeasured, ::ComputationalBasis, reg::GPUReg{B}, ::AllLocs; rng::AbstractRNG=Random.GLOBAL_RNG) where B
    regm = reg |> rank3
    nregm = similar(regm, 1<<nremain(reg), B)
    pl = dropdims(mapreduce(abs2, +, regm, dims=2), dims=2)
    pl_cpu = pl |> Matrix
    res_cpu = map(ib->_measure(rng, view(pl_cpu, :, ib), 1)[], 1:B)
    res = CuArray(res_cpu)
    CI = Base.CartesianIndices(nregm)
    @inline function kernel(ctx, nregm, regm, res, pl)
        state = @linearidx nregm
        @inbounds i,j = CI[state].I
        @inbounds r = Int(res[j])+1
        @inbounds nregm[i,j] = regm[r,i,j]/CUDA.sqrt(pl[r, j])
        return
    end
    gpu_call(kernel, nregm, regm, res, pl)
    reg.state = reshape(nregm,1,:)
    B == 1 ? Array(res)[] : res
end

function measure!(::NoPostProcess, ::ComputationalBasis, reg::GPUReg{B, T}, ::AllLocs; rng::AbstractRNG=Random.GLOBAL_RNG) where {B, T}
    regm = reg |> rank3
    pl = dropdims(mapreduce(abs2, +, regm, dims=2), dims=2)
    pl_cpu = pl |> Matrix
    res_cpu = map(ib->_measure(rng, view(pl_cpu, :, ib), 1)[], 1:B)
    res = CuArray(res_cpu)
    CI = Base.CartesianIndices(regm)

    @inline function kernel(ctx, regm, res, pl)
        state = @linearidx regm
        @inbounds k,i,j = CI[state].I
        @inbounds rind = Int(res[j]) + 1
        @inbounds regm[k,i,j] = k==rind ? regm[k,i,j]/CUDA.sqrt(pl[k, j]) : T(0)
        return
    end
    gpu_call(kernel, regm, res, pl)
    B == 1 ? Array(res)[] : res
end

function YaoBase.measure!(
    ::NoPostProcess,
    bb::BlockedBasis,
    reg::GPUReg{B,T},
    ::AllLocs;
    rng::AbstractRNG = Random.GLOBAL_RNG,
) where {B,T}
    state = @inbounds (reg|>rank3)[bb.perm, :, :]  # permute to make eigen values sorted
    pl = dropdims(mapreduce(abs2, +, state, dims=2), dims=2)
    pl_cpu = pl |> Matrix
    pl_block = zeros(eltype(pl), nblocks(bb), B)
    @inbounds for ib = 1:B
        for i = 1:nblocks(bb)
            for k in subblock(bb, i)
                pl_block[i, ib] += pl_cpu[k, ib]
            end
        end
    end
    # perform measurements on CPU
    res_cpu = Vector{Int}(undef, B)
    @inbounds @views for ib = 1:B
        ires = sample(rng, 1:nblocks(bb), Weights(pl_block[:, ib]))
        # notice ires is `BitStr` type, can be use as indices directly.
        range = subblock(bb, ires)
        state[range, :, ib] ./= sqrt(pl_block[ires, ib])
        state[1:range.start-1, :, ib] .= zero(T)
        state[range.stop+1:size(state, 1), :, ib] .= zero(T)
        res_cpu[ib] = ires
    end
    # undo permute and assign back
    _state = reshape(state, 1 << nactive(reg), :)
    rstate = reshape(reg.state, 1 << nactive(reg), :)
    @inbounds rstate[bb.perm, :] .= _state
    return B == 1 ? bb.values[res_cpu[]] : CuArray(bb.values[res_cpu])
end

function measure!(rst::ResetTo, ::ComputationalBasis, reg::GPUReg{B, T}, ::AllLocs; rng::AbstractRNG=Random.GLOBAL_RNG) where {B, T}
    regm = reg |> rank3
    pl = dropdims(mapreduce(abs2, +, regm, dims=2), dims=2)
    pl_cpu = pl |> Matrix
    res_cpu = map(ib->_measure(rng, view(pl_cpu, :, ib), 1)[], 1:B)
    res = CuArray(res_cpu)
    CI = Base.CartesianIndices(regm)

    @inline function kernel(ctx, regm, res, pl, val)
        state = @linearidx regm
        @inbounds k,i,j = CI[state].I
        @inbounds rind = Int(res[j]) + 1
        @inbounds k==val+1 && (regm[k,i,j] = regm[rind,i,j]/CUDA.sqrt(pl[rind, j]))
        CUDA.sync_threads()
        @inbounds k!=val+1 && (regm[k,i,j] = 0)
        return
    end

    gpu_call(kernel, regm, res, pl, rst.x)
    B == 1 ? Array(res)[] : res
end

import Yao.YaoArrayRegister: insert_qubits!, join
function YaoBase.batched_kron(A::DenseCuArray{T1}, B::DenseCuArray{T2}) where {T1 ,T2}
    res = CUDA.zeros(promote_type(T1,T2), size(A,1)*size(B, 1), size(A,2)*size(B,2), size(A, 3))
    CI = Base.CartesianIndices(res)
    @inline function kernel(ctx, res, A, B)
        state = @linearidx res
        @inbounds i,j,b = CI[state].I
        i_A, i_B = divrem((i-1), size(B,1))
        j_A, j_B = divrem((j-1), size(B,2))
        @inbounds res[state] = A[i_A+1, j_A+1, b]*B[i_B+1, j_B+1, b]
        return
    end

    gpu_call(kernel, res, A, B)
    res
end

"""
    YaoBase.batched_kron!(C::CuArray, A, B)

Performs batched Kronecker products in-place on the GPU.
The results are stored in 'C', overwriting the existing values of 'C'.
"""
function YaoBase.batched_kron!(C::CuArray{T3, 3}, A::DenseCuArray, B::DenseCuArray) where {T1 ,T2, T3}
    @boundscheck (size(C) == (size(A,1)*size(B,1), size(A,2)*size(B,2), size(A,3))) || throw(DimensionMismatch())
    @boundscheck (size(A,3) == size(B,3) == size(C,3)) || throw(DimensionMismatch())
    CI = Base.CartesianIndices(C)
    @inline function kernel(ctx, C, A, B)
        state = @linearidx C
        @inbounds i,j,b = CI[state].I
        i_A, i_B = divrem((i-1), size(B,1))
        j_A, j_B = divrem((j-1), size(B,2))
        @inbounds C[state] = A[i_A+1, j_A+1, b]*B[i_B+1, j_B+1, b]
        return
    end

    gpu_call(kernel, C, A, B)
    C
end

function join(reg1::GPUReg{B}, reg2::GPUReg{B}) where {B}
    s1 = reg1 |> rank3
    s2 = reg2 |> rank3
    state = YaoBase.batched_kron(s1, s2)
    ArrayReg{B}(copy(reshape(state, size(state, 1), :)))
end

export insert_qubits!
function insert_qubits!(reg::GPUReg{B}, loc::Int; nqubits::Int=1) where B
    na = nactive(reg)
    focus!(reg, 1:loc-1)
    reg2 = join(zero_state(nqubits; nbatch=B) |> cu, reg) |> relax! |> focus!((1:na+nqubits)...)
    reg.state = reg2.state
    reg
end

#=
for FUNC in [:measure!, :measure!]
    @eval function $FUNC(rng::AbstractRNG, op::AbstractBlock, reg::GPUReg, al::AllLocs; kwargs...) where B
        E, V = eigen!(mat(op) |> Matrix)
        ei = Eigen(E|>cu, V|>cu)
        $FUNC(rng::AbstractRNG, ei, reg, al; kwargs...)
    end
end
=#
