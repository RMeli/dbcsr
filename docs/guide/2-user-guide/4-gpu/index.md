title: GPUs

# CUDA/HIP backend and LIBSMM_ACC

Users interested to tune kernels for the CUDA/HIP backend, can take a look at the [Developer Guide](../../3-developer-guide/3-programming/2-accelerator-backend/2-libsmm_acc/3-tune.html). Following the guide, [tuned parameters](https://github.com/cp2k/dbcsr/tree/develop/src/acc/libsmm_acc/parameters) can be collected for the desired GPU and potentially submitted for the benefit of others.

# OpenCL Backend and OpenCL based LIBSMM

This section shows how to auto-tune a kernel for the OpenCL based LIBSMM library. The process builds a stand-alone driver program which is then driven by an [OpenTuner](https://opentuner.org/) based script guiding the auto-tuning of the desired kernel. The [Developer Guide](../../3-developer-guide/3-programming/2-accelerator-backend/4-opencl-libsmm.html) provides more information, e.g., about constraining execution time or parallelizing the tuning-process as well as how to select and tune an entire set of kernels.

For simplicity, the GNU Compiler is used to build the afore mentioned driver program, both DBCSR and LIBXSMM are Git-cloned into the same common directory, e.g., the user's `HOME` directory, and the driver is built for tuning double-precision kernels (DP).

```bash
cd ${HOME}
git clone https://github.com/hfp/libxsmm.git
cd libxsmm
make GNU=1 -j

cd ${HOME}
git clone https://github.com/cp2k/dbcsr.git
cd dbcsr/src/acc/opencl
make
```

Tuning the 23x23x23-kernel for example is the default case. However, to better illustrate the options, M, N, and K are given explicitly. The `tune_multiply.py` script can be used interactively for example, and terminated with CTRL-C which writes a JSON-file with tuned parameters (note a file `.tune_multiply-double-32x32x32.json` is quietly written every time a better set of parameter is found), and then aggregates all JSON-file in the directory into a CSV-file (`tune_multiply.csv`).

```bash
cd ${HOME}/dbcsr/src/acc/opencl/smm
./tune_multiply.py 23 23 23
```

The above process would also terminate at some point (based on OpenTuner's default) but can be constrained also by the number of steps (experiments), time to be spent, or a combination of both. Details can be found in the [Developer Guide](../../3-developer-guide/3-programming/2-accelerator-backend/4-opencl-libsmm.html).

Finally, suppose the 23x23x23-kernel was tuned for some time (e.g., 5-10 minutes), the found parameters can be incorporated into the backend. The aggregated parameters (`tune_multiply.csv`) are automatically embedded when rebuilding the library and driver.

```bash
cd ${HOME}/dbcsr/src/acc/opencl
make
```

Important kernels can be tuned further (beside of spending more time for tuning the kernel) by widening the set of tuned parameters (`--tuning-level` or `-a` with "0" denoting an unrestricted set of tunables).

```bash
cd ${HOME}/dbcsr/src/acc/opencl/smm
./tune_multiply.py 23 23 23 -a 0
```

Please note, to tune *further*, the previously found parameters should be embedded (rebuilding the driver) or specified at runtime (`OPENCL_LIBSMM_SMM_PARAMS=/path/to/tune_multiply.csv`).