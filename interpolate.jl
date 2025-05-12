using Base.Threads
using Dates
using Printf

using HDF5
using Interpolations

"""
    _check_midwest24k_demand_data(D; check_type::Bool=true, check_size::Bool=true)
# Arguments
* `D::Dict`

# Keyword arguments
* `check_type::Bool=true`: whether to check value types
* `check_type::Bool=true`: whether to check value size

# Throws
An error is thrown if some data checks fail
"""
function _check_midwest24k_demand_data(D; check_type::Bool=true, check_size::Bool=true)

    MIDWEST24K_DEMAND_SCHEMA = Dict(
        "datetime" => Dict(
            "type" => Vector{String},
            "size" => (8784,),
        ),
        "pd" => Dict(
            "type" => Matrix{Float32},
            "size" => (8784, 11731),
        ),
        "qd" => Dict(
            "type" => Matrix{Float32},
            "size" => (8784, 11731),
        ),
    )

    for (k, s) in MIDWEST24K_DEMAND_SCHEMA
        haskey(D, k) || error("Missing key: $k")
        # check type
        v = D[k]
        (check_type && isa(v, s["type"])) || error(
            """Invalid value type for key $k:
            * Expected: $(s["type"])
            * Actual  : $(typeof(v))"""
        )
        (check_size && size(v) == s["size"]) || error(
            """Invalid size of data for key $k:
            * Expected: $(s["size"])
            * Actual  : $(size(v))"""
        )
    end

    return nothing
end

function _load_midwest24k_demand_2020_consolidated()
    fpath = joinpath(@__DIR__, "data", "midwest24k_demand_2020.h5")
    if !isfile(fpath)
        error("Missing file: ", abspath(normpath(fpath)))
    end

    D = h5read(joinpath(@__DIR__, "data", "midwest24k_demand_2020.h5"), "/")

    _check_midwest24k_demand_data(D)
    return D
end

function _load_midwest24k_demand_2020_monthly()
    # Check that all files exist
    fpaths = [
        joinpath(@__DIR__, "data", @sprintf("midwest24k_demand_2020-%02d.h5", mm))
        for mm in 1:12
    ]
    all(isfile.(fpaths)) || error("Some monthly h5 files are missing; please check that you cloned the repository correctly")
    
    # All files exist, let's load them and consolidate into a single dictionary
    ds = [h5read(fpath, "/") for fpath in fpaths]
    D = Dict(
        k => reduce(vcat, [d[k] for d in ds])
        for k in ["datetime", "pd", "qd"]
    )

    _check_midwest24k_demand_data(D)
    return D
end

"""
    load_midwest24k_demand_2020()

Load the Midwest24k 2020 demand time series data.

Returns a Dictionary with the following keys
* `datetime::Vector{String}`: Hourly time stamps
* `pd::Matrix{Float32}`: a 8785×4549 Matrix of hourly nodal active power demand
* `qd::Matrix{Float32}`: a 8785×4549 Matrix of hourly nodal reactive power demand
"""
function load_midwest24k_demand_2020()
    if isfile(joinpath(@__DIR__, "data", "midwest24k_demand_2020.h5"))
        return _load_midwest24k_demand_2020_consolidated()
    else
        return _load_midwest24k_demand_2020_monthly()
    end
end

"""
    interpolate_demand(D; time_period=Minute(5))

Interpolate active and reactive demand from hourly to `time_period` granularity.
The interpolation is done using cubic splines.

# Arguments
* `D::Dict`: dictionary containing 3 keys:
    * `datetime`: A vector of size `T` containing hourly time stamps.
        Assumed to be sorted and contiguous (i.e., no missing values)
    * `D["pd"]` is a Matrix{Float32} of size `T*L`, such that 
        D["pd"][t, i] is the active demand of load `i` at time step `t`.
    * `D["qd"]` is a Matrix{Float32} of size `T*L`, such that 
        D["qd"][t, i] is the active demand of load `i` at time step `t`.
* `time_period::TimePeriod`: the time period to use for interpolation.
    Must be an integer divider of one hour (e.g. 15min, 5min, 30s)

# Returns
* A dictionary with same keys as `D`, but with 5-min interpolated data
"""
function interpolate_demand(D; time_period::TimePeriod=Minute(5))
    # Ensure that time period is a divider of 1hr
    if !isinteger(Hour(1) / time_period)
        error(
            """Invalid time period for interpolation: $(time_period).
            Acceptable time periods must be an integer divider of 1 hour.
            For instance:
            * ✅: 30min, 15min, 30s
            * ❌: 2hr, 7min, 43s"""
        )
    end

    # Hourly data info
    dts_hrly = DateTime.(D["datetime"])
    (round.(dts_hrly, Hour(1)) == dts_hrly) || error("Raw time stamps must be on the hour")
    T_hrly = length(dts_hrly)
    pd_hrly = D["pd"]
    qd_hrly = D["qd"]
    L = size(pd_hrly, 2)  # number of loads

    # All field with `_itp` suffix indicate interpolated data
    dts_itp = collect(minimum(dts_hrly):time_period:maximum(dts_hrly))
    T_itp = length(dts_itp)
    # pre-allocate interpolated active/reactive demand
    pd_itp = zeros(Float32, T_itp, L)
    qd_itp = zeros(Float32, T_itp, L)

    # Now we do the actual interpolation
    # For numerical stability of the interpolation step,
    #   we define "1 unit of time" to be 1 hour.
    delta_x = (time_period / Hour(1))
    for (x_hrly, x_itp) in zip([pd_hrly, qd_hrly], [pd_itp, qd_itp])
        @threads for i in 1:L
            local itp = cubic_spline_interpolation(1:T_hrly, x_hrly[:, i])
            x_itp[:, i] .= itp.(collect(1:delta_x:T_hrly))
        end
    end

    D_itp = Dict(
        "datetime" => string.(dts_itp),
        "pd" => pd_itp,
        "qd" => qd_itp,
    )

    return D_itp
end

function main_interpolate()
    D = load_midwest24k_demand_2020()
    D_5min = interpolate_demand(D; time_period=Minute(10))

    # Save to h5 file
    if !isdir(joinpath(@__DIR__, "data", "interpolated"))
        @warn "Path `data/interpolated` does not exist; creating it"
        mkpath(joinpath(@__DIR__, "data", "interpolated"))
    end

    h5open(joinpath(@__DIR__, "data", "interpolated", "midwest24k_demand_2020_10min.h5"), "w") do fid
        for (k, v) in D_5min
            fid[k] = v
        end
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main_interpolate()
    exit(0)
end
