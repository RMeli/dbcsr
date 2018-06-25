/*****************************************************************************
 *  CP2K: A general program to perform molecular dynamics simulations        *
 *  Copyright (C) 2000 - 2017  CP2K developers group                         *
 *****************************************************************************/

#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>
#include "libcusmm_benchmark.h"
#include "libcusmm.h"

//===========================================================================
// Allocate memory and cuda events
void libcusmm_benchmark_init(libcusmm_benchmark_t** handle, bool tune_mode,
                             int max_m, int max_n, int max_k){

    libcusmm_benchmark_t* h = (libcusmm_benchmark_t*) malloc(sizeof(libcusmm_benchmark_t));
    *handle = h;

    h-> tune_mode = tune_mode;

    if(h->tune_mode){
       h->n_a = 10000;
       h->n_b = 10000;
       h->n_c = 1000;
       h->n_stack = 16005;
//       h->n_a = 100;
//       h->n_b = 100;
//       h->n_c = 10;
//       h->n_stack = 18;
    }else{
       h->n_a = 100;
       h->n_b = 100;
       h->n_c = 10;
       h->n_stack = 100;
    }

    h->max_m = max_m;
    h->max_n = max_n;
    h->max_k = max_k;

    h->mat_a = (double*) malloc(h->n_a * max_m * max_k * sizeof(double));
    h->mat_b = (double*) malloc(h->n_b * max_k * max_n * sizeof(double));
    h->mat_c = (double*) malloc(h->n_c * max_m * max_n * sizeof(double));
    h->stack = (int*) malloc(h->n_stack * 3 * sizeof(int));

    cudaMalloc(&h->d_mat_a, h->n_a * max_m * max_k * sizeof(double));
    cudaMalloc(&h->d_mat_b, h->n_b * max_k * max_n * sizeof(double));
    cudaMalloc(&h->d_mat_c, h->n_c * max_m * max_n * sizeof(double));
    cudaMalloc(&h->d_stack, h->n_stack * 3 * sizeof(int));

    cudaEventCreate(&h->t_start);
    cudaEventCreate(&h->t_stop);

    cudaError_t cudaError = cudaGetLastError();
    if (cudaError != cudaSuccess){
      printf("libcusmm_benchmark_init: %s\n", cudaGetErrorString(cudaError));
      exit(1);
    }
}


//===========================================================================
// Free memory and cuda events
void libcusmm_benchmark_finalize(libcusmm_benchmark_t* handle){
    cudaEventDestroy(handle->t_stop);
    cudaEventDestroy(handle->t_start);
    cudaFree(handle->d_stack);
    cudaFree(handle->d_mat_c);
    cudaFree(handle->d_mat_b);
    cudaFree(handle->d_mat_a);
    free(handle->stack);
    free(handle->mat_c);
    free(handle->mat_b);
    free(handle->mat_a);
    free(handle);
    cudaError_t cudaError = cudaGetLastError();
    if (cudaError != cudaSuccess){
      printf("libcusmm_benchmark_init: %s\n", cudaGetErrorString(cudaError));
      exit(1);
    }
}


//===========================================================================
//Removes special symbols so that the output is usefull for awk and gnuplot.
static void clean_string(char* str_in, char* str_out){
    for(int i=0; i<1000 ; i++){
        if(str_in[i] == '=' || str_in[i] == ',' || str_in[i] == '(' || str_in[i] == ')'){
            str_out[i] = ' ';
         }else{
             str_out[i] = str_in[i];
         }
         if(str_in[i] == 0)
             break;
    }
}


//===========================================================================
int libcusmm_benchmark(libcusmm_benchmark_t* h,
                       int mat_m, int mat_n, int mat_k,
                       int nkernels, KernelLauncher* launchers, char ** kernel_descr){

 if(mat_m > h->max_m || mat_n > h->max_n || mat_k > h->max_k){
     printf("libcusmm_benchmark: got handle with too few resources");
     exit(1);
 }

 int n_iter = 1;
 int n_warm = 1;
 if(h->tune_mode){ // for larger matrices few iteration give enough statistics
//     n_iter = max(3, 1250/(mat_m * mat_n * mat_k));
     n_iter = max(3, 12500/(mat_m * mat_n * mat_k));
     n_warm = min(3, n_iter);
 }

 const int stream = 0;

 int error_counter = 0;
 int best_kernel = -1;
 double best_gflops = 0.0;
 double sumCPU, sumGPU;
 float t_duration;
 char descr[1000], msg_prefix[100]="";
 cudaError_t cudaError;

 memset(h->mat_c, 0, h->n_c * mat_m * mat_n * sizeof(double));
 matInit(h->mat_a, h->n_a, mat_m, mat_k, 42);
 matInit(h->mat_b, h->n_b, mat_k, mat_n, 24);

 if(h->tune_mode)
     printf("Initializing ...\n");
 stackInit(h->stack, h->n_stack, h->n_c, h->mat_c, h->n_a, h->mat_a, h->n_b, h->mat_b, mat_m, mat_n, mat_k);

 // Actually, we would have to calculate the stack n_iter times.
 // We cheat by simply scaling the results of a single stack calulcation.
 stackCalc(h->stack, h->n_stack, h->mat_c, h->mat_a, h->mat_b, mat_m, mat_n, mat_k);
 for(int i=0 ; i < h->n_c*mat_m*mat_n ; i++)
     h->mat_c[i] *= n_iter;

 sumCPU =  checkSum(h->mat_c, h->n_c, mat_m, mat_n);

 cudaMemcpy(h->d_mat_a, h->mat_a, h->n_a * mat_m * mat_k * sizeof(double), cudaMemcpyHostToDevice);
 cudaMemcpy(h->d_mat_b, h->mat_b, h->n_b * mat_k * mat_n * sizeof(double), cudaMemcpyHostToDevice);
 cudaMemcpy(h->d_stack, h->stack, h->n_stack * 3 * sizeof(int), cudaMemcpyHostToDevice);
 //d_mat_c get's zeroed after warmup run

 for(int ikern=0; ikern < nkernels; ikern++){
    //warmup run (more often if n_iter is small)
    for(int i=0; i<n_warm; i++)
        launchers[ikern](h->d_stack, h->n_stack, (CUstream) stream, mat_m, mat_n, mat_k, h->d_mat_a, h->d_mat_b, h->d_mat_c);
    cudaMemset(h->d_mat_c, 0, h->n_c * mat_m * mat_n * sizeof(double));

    cudaEventRecord(h->t_start, (cudaStream_t) stream);

    for(int i=0; i<n_iter; i++)
        launchers[ikern](h->d_stack, h->n_stack, (CUstream) stream, mat_m, mat_n, mat_k, h->d_mat_a, h->d_mat_b, h->d_mat_c);

    cudaEventRecord(h->t_stop, (cudaStream_t) stream);
    cudaEventSynchronize(h->t_stop);
    cudaEventElapsedTime(&t_duration, h->t_start, h->t_stop);

    cudaMemcpy(h->mat_c, h->d_mat_c, h->n_c * mat_m * mat_n * sizeof(double), cudaMemcpyDeviceToHost);

    clean_string(kernel_descr[ikern], descr);

    if(h->tune_mode)
        sprintf(msg_prefix, "params %d / %d",ikern+1, nkernels);

    cudaError = cudaGetLastError();
    if (cudaError != cudaSuccess){
      printf("%sERROR %s cuda_error: %s\n", msg_prefix, descr, cudaGetErrorString(cudaError));
      error_counter++;
      continue;
    }

    sumGPU =  checkSum(h->mat_c, h->n_c, mat_m, mat_n);
    if(sumGPU != sumCPU){
        printf("%sERROR %s checksum_diff: %g\n",msg_prefix, descr, sumGPU-sumCPU);
        error_counter++;
        continue;
    }

    if(h->tune_mode){
       double gflops = ((double) n_iter * h->n_stack * mat_m * mat_n * mat_k * 2 / (1e9))/(t_duration * 1e-3);
       printf("%sOK %s GFlop/s %g\n", msg_prefix, descr, gflops);
       if(best_gflops < gflops){
           best_gflops = gflops;
           best_kernel = ikern;
       }
    }else{
       printf("%sOK %s\n", msg_prefix, descr);
    }
 }

 if(h->tune_mode){
    printf("\n\n");
    if(best_kernel > -1){
        printf("WINNER: %d %s , # %g GFlop/s \n", best_kernel+1, kernel_descr[best_kernel], best_gflops);
    }else{
       printf("WINNER: None\n");
    }
    printf("Number of errors: %d\n", error_counter);
    cudaDeviceReset();
 }

 // cleanup
 return(error_counter);
}

//EOF
