# PGLearn Texas7k data sources

This repository contains raw data for the [PGLearn Texas7k dataset](https://huggingface.co/datasets/PGLearn/PGLearn-Texas7k).

The original Matpower and time series data files are part of the [Texas A&M University Electric Grid Datasets](https://electricgrids.engr.tamu.edu/),
    namely the [6716-bus Texas synthetic grid](https://electricgrids.engr.tamu.edu/texas7k/).
If you use this dataset in your work, please cite the appropriate papers.

## Installation instructions

1. Make sure you have julia installed
2. Instantiate the current environment
    ```bash
    julia --project=. -e 'using Pkg; Pkg.instantiate()'
    ```

## Quick start

### Processing

Data processing is not required if you cloned the repository.

This code is included for reproducibility.
1. Download raw demand data files from TAMU (see [here]((https://electricgrids.engr.tamu.edu/texas-am-perform-cases/)))
2. Copy the following files into the `data/` folder
    * `Midwest24k_20220923.m`
    * `MISOSPP2020MWtimeseries.csv`
    * `MISOSPP2020MVARtimeseries.csv`
3. Rename matpower file
    ```bash
    mv data/Midwest24k_20220923.m data/Midwest24k_TAMU_20220923.m
    ```
3. Execute the data processing script
    ```bash
    julia --project=. process.jl
    ```


### Interpolation

It is recommended to execute this script with multiple threads
```bash
julia --project=. --threads=4 interpolate.jl
```

By default, the demand data is interpolated down to 5-min granularity.
While the underlying code supports other granularities (see `interpolate_demand` function in `interpolate.jl`), this functionality is not exposed from the command line.
Please open an issue if you'd like to request this feature.
