using Dates
using Printf

using CSV
using DataFrames
using HDF5
using JSON
using PowerModels
PowerModels.silence()

function extract_load_time_series()

    # load active & reactive power dataset
    df_pd = CSV.read(joinpath(@__DIR__, "data", "MISOSPP2020MWtimeseries.csv"), DataFrame, header=2)
    df_qd = CSV.read(joinpath(@__DIR__, "data", "MISOSPP2020MVARtimeseries.csv"), DataFrame, header=2)
    # df_qd = df_qd[1:8760, :]  # trim excess rows in reactive load  data

    # Rename dataframe columns
    rename!(df_pd, Dict(s => prod(split(s)[2:3]) for s in names(df_pd)[6:end]))
    rename!(df_qd, Dict(s => prod(split(s)[2:3]) for s in names(df_qd)[6:end]))

    # Extract time stamps
    for df in [df_pd, df_qd]
        df.datetime = [
            DateTime(d * " " * t, "m/d/y HH:MM:SS p") for (d, t) in zip(df.Date, df.Time)
        ]
    end

    # The original PD data skipped Feb 29th in the time stamps :(
    # To fix it, we need to shift every datetime back by 24 hours, starting March 1st
    # for (i, dt) in enumerate(df_pd.datetime)
    #     if dt > DateTime(2020, 02, 28, 23, 59)
    #         df_pd.datetime[i] -= Hour(24)
    #     end
    # end

    # Make sure everything is sorted
    sort!(df_pd, :datetime)
    sort!(df_qd, :datetime)
    df_pd.datetime == df_qd.datetime || error("Time stamps do not match for active/reactive load")

    # Now, build active/reactivetime series per bus
    PD = Dict{Int,Vector{Float64}}()
    QD = Dict{Int,Vector{Float64}}()
    for c in names(df_pd)[6:end-1]
        i = parse(Int, split(c, "#")[1])  # Bus ID
        if haskey(PD, i)
            PD[i] .+= df_pd[!, c]
        else
            PD[i] = copy(df_pd[!, c])
        end
    end
    for c in names(df_qd)[6:end-1]
        i = parse(Int, split(c, "#")[1])  # Bus ID
        if haskey(QD, i)
            QD[i] .+= df_qd[!, c]
        else
            QD[i] = copy(df_qd[!, c])
        end
    end

    keys(PD) == keys(QD) || error("Active/reactive load keys not matching")

    return PD, QD
end

function process_generator_costs!(network)
    # Convert all the PWL curves to linear cost curves
    for (g, gen) in network["gen"]
        if gen["model"] == 2
            # Cost function is already polynomial
            continue
        end
        gen["model"] == 1 || error("Unsupported generator cost model for generator $g: $(gen["model"])")

        # Convert PWL cost curve to linear cost function
        c = gen["cost"]
        c1 = (c[end] - c[2]) / (c[end-1] - c[1])  # linear term
        c0 = c[2] - c[1] * c1  # constant term

        gen["model"] = 2
        gen["cost"] = [0.0, c1, c0]
    end

    return nothing
end

function main_midwest24k()
    network = PowerModels.parse_matpower(joinpath(@__DIR__, "data", "Midwest24k_TAMU_20220923.m"))
    process_generator_costs!(network)

    # Get active/reactive load time series
    PD, QD = extract_load_time_series()

    # Add loads for buses that are not covered
    bus2load = Dict{Int,Int}()
    load2bus = Dict{Int,Int}()
    for (_, load) in network["load"]
        i = load["load_bus"]
        l = load["index"]
        if haskey(bus2load, i)
            error("Multiple loads at bus $i")
        end
        bus2load[i] = l
        load2bus[l] = i
    end
    for (i, pd) in PD
        haskey(bus2load, i) && continue

        # Create a new load
        num_loads = length(network["load"])
        l = num_loads + 1
        network["load"]["$l"] = Dict(
            "source_id" => ["bus", i],
            "load_bus" => i,
            "status" => 1,
            "pd" => 0.0,
            "qd" => 0.0,
            "index" => l
        )
        bus2load[i] = l
        load2bus[l] = i
    end

    # Tensorize active/reactive load
    T = 8784  # 366 * 24 hours, hardcoded
    L = length(network["load"])
    pd = zeros(Float32, T, L)
    qd = zeros(Float32, T, L)
    for l in 1:L
        i = load2bus[l]
        pd[:, l] .= PD[i]
        qd[:, l] .= QD[i]
    end

    dts = collect(DateTime(2020, 01, 01, 00, 00):Hour(1):DateTime(2020, 12, 31, 23, 00,))
    demand_data = Dict(
        "datetime" => string.(dts),
        "pd" => pd,
        "qd" => qd,
    )

    # Finally, convert network data to basic format
    network_basic = make_basic_network(network)

    return network_basic, demand_data
end

if abspath(PROGRAM_FILE) == @__FILE__
    network_basic, demand_data = main_midwest24k()

    # Save network to JSON
    println("Exporting network data (JSON format)")
    open(joinpath(@__DIR__, "data", "Midwest24k_20220923_case.json"), "w") do io
        JSON.print(io, network_basic)
    end

    # Save load data to HDF5 file; one file per month to keep small files
    println("Exporting load data (one H5 file per month)")
    dts = DateTime.(demand_data["datetime"])
    months = month.(dts)
    for mm in 1:12
        Ts = (months .== mm)
        h5open(joinpath(@__DIR__, "data", @sprintf("midwest24k_demand_2020-%02d.h5", mm)), "w") do fid
            fid["datetime"] = demand_data["datetime"][Ts]
            fid["pd"] = demand_data["pd"][Ts, :]
            fid["qd"] = demand_data["qd"][Ts, :]
        end
    end
    # Also export a single h5 file (for local use)
    println("Exporting load data (consolidate H5 file)")
    h5open(joinpath(@__DIR__, "data", "midwest24k_demand_2020.h5"), "w") do fid
        fid["datetime"] = demand_data["datetime"]
        fid["pd"] = demand_data["pd"]
        fid["qd"] = demand_data["qd"]
    end

    exit(0)
end