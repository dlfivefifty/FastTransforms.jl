struct SynthesisPlan{T, P1, P2}
    planθ::P1
    planφ::P2
    C::ColumnPermutation
    temp::Vector{T}
end

function plan_synthesis(A::Matrix{T}) where T<:fftwNumber
    m, n = size(A)
    x = FFTW.FakeArray(T, m)
    y = FFTW.FakeArray(T, n)
    planθ = FFTW.plan_r2r!(x, FFTW.REDFT01), FFTW.plan_r2r!(x, FFTW.RODFT01)
    planφ = FFTW.plan_r2r!(y, FFTW.HC2R)
    C = ColumnPermutation(vcat(1:2:n, 2:2:n))
    SynthesisPlan(planθ, planφ, C, zeros(T, n))
end

struct AnalysisPlan{T, P1, P2}
    planθ::P1
    planφ::P2
    C::ColumnPermutation
    temp::Vector{T}
end

function plan_analysis(A::Matrix{T}) where T<:fftwNumber
    m, n = size(A)
    x = FFTW.FakeArray(T, m)
    y = FFTW.FakeArray(T, n)
    planθ = FFTW.plan_r2r!(x, FFTW.REDFT10), FFTW.plan_r2r!(x, FFTW.RODFT10)
    planφ = FFTW.plan_r2r!(y, FFTW.R2HC)
    C = ColumnPermutation(vcat(1:2:n, 2:2:n))
    AnalysisPlan(planθ, planφ, C, zeros(T, n))
end

function Base.A_mul_B!(Y::Matrix{T}, P::SynthesisPlan{T}, X::Matrix{T}) where T
    M, N = size(X)

    # Column synthesis
    PCe = P.planθ[1]
    PCo = P.planθ[2]

    X[1] *= two(T)
    A_mul_B_col_J!(Y, PCe, X, 1)
    X[1] *= half(T)

    for J = 2:4:N
        A_mul_B_col_J!(Y, PCo, X, J)
        A_mul_B_col_J!(Y, PCo, X, J+1)
    end
    for J = 4:4:N
        X[1,J] *= two(T)
        X[1,J+1] *= two(T)
        A_mul_B_col_J!(Y, PCe, X, J)
        A_mul_B_col_J!(Y, PCe, X, J+1)
        X[1,J] *= half(T)
        X[1,J+1] *= half(T)
    end
    scale!(half(T), Y)

    # Row synthesis
    scale!(inv(sqrt(π)), Y)
    invsqrttwo = inv(sqrt(2))
    @inbounds for i = 1:M Y[i] *= invsqrttwo end

    temp = P.temp
    planφ = P.planφ
    C = P.C
    for I = 1:M
        copy_row_I!(temp, Y, I)
        row_synthesis!(planφ, C, temp)
        copy_row_I!(Y, temp, I)
    end
    Y
end

function Base.A_mul_B!(Y::Matrix{T}, P::AnalysisPlan{T}, X::Matrix{T}) where T
    M, N = size(X)

    # Row analysis
    temp = P.temp
    planφ = P.planφ
    C = P.C
    for I = 1:M
        copy_row_I!(temp, X, I)
        row_analysis!(planφ, C, temp)
        copy_row_I!(Y, temp, I)
    end

    # Column analysis
    PCe = P.planθ[1]
    PCo = P.planθ[2]

    A_mul_B_col_J!(Y, PCe, Y, 1)
    Y[1] *= half(T)
    for J = 2:4:N
        A_mul_B_col_J!(Y, PCo, Y, J)
        A_mul_B_col_J!(Y, PCo, Y, J+1)
    end
    for J = 4:4:N
        A_mul_B_col_J!(Y, PCe, Y, J)
        A_mul_B_col_J!(Y, PCe, Y, J+1)
        Y[1,J] *= half(T)
        Y[1,J+1] *= half(T)
    end
    scale!(sqrt(π)*inv(T(M)), Y)
    sqrttwo = sqrt(2)
    @inbounds for i = 1:M Y[i] *= sqrttwo end

    Y
end




function row_analysis!(P, C, vals::Vector{T}) where T
    n = length(vals)
    cfs = scale!(two(T)/n,P*vals)
    cfs[1] *= half(T)
    if iseven(n)
        cfs[n÷2+1] *= half(T)
    end

    negateeven!(reverseeven!(A_mul_B!(C, cfs)))
end

function row_synthesis!(P, C, cfs::Vector{T}) where T
    n = length(cfs)
    Ac_mul_B!(C, reverseeven!(negateeven!(cfs)))
    if iseven(n)
        cfs[n÷2+1] *= two(T)
    end
    cfs[1] *= two(T)
    P*scale!(half(T), cfs)
end

function copy_row_I!(temp::Vector, Y::Matrix, I::Int)
    M, N = size(Y)
    @inbounds @simd for j = 1:N
        temp[j] = Y[I+M*(j-1)]
    end
    temp
end

function copy_row_I!(Y::Matrix, temp::Vector, I::Int)
    M, N = size(Y)
    @inbounds @simd for j = 1:N
        Y[I+M*(j-1)] = temp[j]
    end
    Y
end


function reverseeven!(x::Vector)
    n = length(x)
    if iseven(n)
        @inbounds @simd for k=2:2:n÷2
            x[k], x[n+2-k] = x[n+2-k], x[k]
        end
    else
        @inbounds @simd for k=2:2:n÷2
            x[k], x[n+1-k] = x[n+1-k], x[k]
        end
    end
    x
end

function negateeven!(x::Vector)
    @inbounds @simd for k = 2:2:length(x)
        x[k] *= -1
    end
    x
end

function A_mul_B_col_J!(Y::Matrix{T}, P::r2rFFTWPlan{T}, X::Matrix{T}, J::Int) where T
    unsafe_execute_col_J!(P, X, Y, J)
    return Y
end

function unsafe_execute_col_J!(plan::r2rFFTWPlan{T}, X::Matrix{T}, Y::Matrix{T}, J::Int) where T<:fftwDouble
    M = size(X, 1)
    ccall((:fftw_execute_r2r, libfftw), Void, (PlanPtr, Ptr{T}, Ptr{T}), plan, pointer(X, M*(J-1)+1), pointer(Y, M*(J-1)+1))
end

function unsafe_execute_col_J!(plan::r2rFFTWPlan{T}, X::Matrix{T}, Y::Matrix{T}, J::Int) where T<:fftwSingle
    M = size(X, 1)
    ccall((:fftwf_execute_r2r, libfftwf), Void, (PlanPtr, Ptr{T}, Ptr{T}), plan, pointer(X, M*(J-1)+1), pointer(Y, M*(J-1)+1))
end
