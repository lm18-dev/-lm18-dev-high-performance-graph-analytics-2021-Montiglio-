// Copyright (c) 2020, 2021, NECSTLab, Politecnico di Milano. All rights reserved.

// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
//  * Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//  * Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//  * Neither the name of NECSTLab nor the names of its
//    contributors may be used to endorse or promote products derived
//    from this software without specific prior written permission.
//  * Neither the name of Politecnico di Milano nor the names of its
//    contributors may be used to endorse or promote products derived
//    from this software without specific prior written permission.

// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
// CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
// EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
// PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
// PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
// OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#include <sstream>
#include "personalized_pagerank.cuh"
# include <stdio.h>
# include <stdlib.h>
# include <cuda_runtime.h>
#include "cublas_v2.h"


namespace chrono = std::chrono;
using clock_type = chrono::high_resolution_clock;

//////////////////////////////
//////////////////////////////


__global__ void gpu_axpb_personalized(double alpha, double *x, double beta,
const int personalization_vertex, double *result, const int N ) {

  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  double one_minus_alpha = 1 - alpha;

  while (tid < N) {
    result[tid] = alpha * x[tid] + beta + ((personalization_vertex == tid) ? one_minus_alpha : 0.0);
    tid += blockDim.x * gridDim.x;
  }

}


__global__ void gpu_euclidean_distance(const double *x, const double *y, const int N, double * result) {

  __shared__ float cache[128]; // 128 is the number of threads per block fixed in the kernel launch

  int tid = threadIdx.x + blockIdx.x * blockDim.x;
  int cacheIndex = threadIdx.x;

  float temp = 0;

  while (tid < N) {

    temp += (x[tid] - y[tid])*(x[tid] - y[tid]);
    tid += blockDim.x * gridDim.x;

  }


  cache[cacheIndex] = temp;


  __syncthreads();

  int i = blockDim.x/2;

  while (i != 0) {

    if (cacheIndex < i){

      cache[cacheIndex] += cache[cacheIndex + i];

    }

    __syncthreads();
    i /= 2;
  }

  if (cacheIndex == 0)
  result[blockIdx.x] = std::sqrt(cache[0]);


}

//////////////////////////////
//////////////////////////////


// CPU Utility functions;


// Read the input graph and initialize it;
void PersonalizedPageRank::initialize_graph() {
    // Read the graph from an MTX file;
    int num_rows = 0;
    int num_columns = 0;
    read_mtx(graph_file_path.c_str(), &x, &y, &val,
        &num_rows, &num_columns, &E, // Store the number of vertices (row and columns must be the same value), and edges;
        true,                        // If true, read edges TRANSPOSED, i.e. edge (2, 3) is loaded as (3, 2). We set this true as it simplifies the PPR computation;
        false,                       // If true, read the third column of the matrix file. If false, set all values to 1 (this is what you want when reading a graph topology);
        debug,
        false,                       // MTX files use indices starting from 1. If for whatever reason your MTX files uses indices that start from 0, set zero_indexed_file=true;
        true                         // If true, sort the edges in (x, y) order. If you have a sorted MTX file, turn this to false to make loading faster;
    );
    if (num_rows != num_columns) {
        if (debug) std::cout << "error, the matrix is not squared, rows=" << num_rows << ", columns=" << num_columns << std::endl;
        exit(-1);
    } else {
        V = num_rows;
    }
    if (debug) std::cout << "loaded graph, |V|=" << V << ", |E|=" << E << std::endl;

    // Compute the dangling vector. A vertex is not dangling if it has at least 1 outgoing edge;
    dangling.resize(V);
    std::fill(dangling.begin(), dangling.end(), 1);  // Initially assume all vertices to be dangling;
    for (int i = 0; i < E; i++) {
        // Ignore self-loops, a vertex is still dangling if it has only self-loops;
        if (x[i] != y[i]) dangling[y[i]] = 0;
    }
    // Initialize the CPU PageRank vector;
    pr.resize(V);
    pr_golden.resize(V);
    // Initialize the value vector of the graph (1 / outdegree of each vertex).
    // Count how many edges start in each vertex (here, the source vertex is y as the matrix is transposed);
    int *outdegree = (int *) calloc(V, sizeof(int));
    for (int i = 0; i < E; i++) {
        outdegree[y[i]]++;
    }
    // Divide each edge value by the outdegree of the source vertex;
    for (int i = 0; i < E; i++) {
        val[i] = 1.0 / outdegree[y[i]];
    }
    free(outdegree);
}

//////////////////////////////
//////////////////////////////

// Allocate data on the CPU and GPU;
void PersonalizedPageRank::alloc() {
    // Load the input graph and preprocess it;
    initialize_graph();


    pr_tmp_gpu = (double *) malloc(sizeof(double) * V);



    // Allocate any GPU data here;
    // TODO!

    cudaMalloc( (void**)&x_dot_gpu, V * sizeof(double) );
    cudaMalloc( (void**)&pr_gpu, V * sizeof(double) );
    cudaMalloc( (void**)&result_dot_gpu, V * sizeof(double) );


    cudaMalloc( (void**)&x_axpb_gpu, V * sizeof(double) );
    cudaMalloc( (void**)&result_axpb_gpu, V * sizeof(double) );


    cudaMalloc( (void**)&result_eudiff_gpu,  sizeof(double) );



}

// Initialize data;
void PersonalizedPageRank::init() {
    // Do any additional CPU or GPU setup here;
    // TODO!


   cudaMemcpy( x_dot_gpu, dangling.data(), V * sizeof(double),
   cudaMemcpyHostToDevice );




}


// Reset the state of the computation after every iteration.
// Reset the result, and transfer data to the GPU if necessary;
void PersonalizedPageRank::reset() {
   // Reset the PageRank vector (uniform initialization, 1 / V for each vertex);
   std::fill(pr.begin(), pr.end(), 1.0 / V);
   // Generate a new personalization vertex for this iteration;
   personalization_vertex = rand() % V;
   if (debug) std::cout << "personalization vertex=" << personalization_vertex << std::endl;

   cudaMemcpy( pr_gpu, pr.data(), V * sizeof(double),
   cudaMemcpyHostToDevice );
   // Do any GPU reset here, and also transfer data to the GPU;
   // TODO!
}






void PersonalizedPageRank::execute(int iter) {
    // Do the GPU computation here, and also transfer results to the CPU;
    //TODO! (and save the GPU PPR values into the "pr" array)

    bool converged = false;
    cublasStatus_t stat1;
    cublasStatus_t stat2;
    //int count;
    double * err = (double *) malloc(sizeof(double));

    iter = 0;


    //
    //
    // cudaGetDeviceCount( &count );
    // printf("Numero gpu %o", count);
    //


    dangling_factor_gpu = (double *) malloc(sizeof(double) * V);



    stat1 = cublasCreate(handle_pointer);

    //
    // cublasCreate(handle_pointer);
    // if (stat1 == CUBLAS_STATUS_NOT_INITIALIZED) {
    //
    //     printf ("CUBLAS not initialized \n");
    // }else{
    //
    //   printf ("CUBLAS initialized \n");
    // }


    while (!converged && iter < max_iterations) {

        memset(pr_tmp_gpu, 0, sizeof(double) * V);

        spmv_coo_cpu(x.data(), y.data(), val.data(), pr.data(), pr_tmp_gpu, E);

        //cublasSetPointerMode(handle_dot, CUBLAS_POINTER_MODE_DEVICE);
        //cublasSetPointerMode(handle_dot, CUBLAS_POINTER_MODE_HOST);

        //cublasDdot(handle, V, x_dot_gpu, 1, pr_gpu, 1, result_dot_gpu);


        stat2 = cublasDdot(handle, V, x_dot_gpu, 1, pr_gpu, 1, dangling_factor_gpu);


        //cudaMemcpy( dangling_factor_gpu, result_dot_gpu, V * sizeof(double),
        //cudaMemcpyDeviceToHost );

        //if (stat2 != CUBLAS_STATUS_SUCCESS) {

            //printf ("CUBLAS calculation failed\n");

        //}else{

            //printf ("CUBLAS calculation sucess\n");

        //}


        cudaMemcpy( x_axpb_gpu, pr_tmp_gpu, V * sizeof(double),
        cudaMemcpyHostToDevice );

         gpu_axpb_personalized<<<num_blocks, block_size>>>(alpha, x_axpb_gpu, alpha * *dangling_factor_gpu / V, personalization_vertex, result_axpb_gpu, V);


        //
        //
        // cudaDeviceSynchronize();
        //
        // cudaError_t cuda_error1 = cudaGetLastError();
        //
        //
        // if (cuda_error1 != cudaSuccess){
        //    printf("Error1: ");
        //    printf(" %s\n", cudaGetErrorString(cuda_error1));
        // }
        // else{
        //    printf("Success1\n" );
        // }


        cudaMemcpy(  pr_tmp_gpu, result_axpb_gpu,  V * sizeof(double),
        cudaMemcpyDeviceToHost );

        // printf("GPU axpb result vector\n");
        // //for (int i = 0; i < std::min(20, V); i++) {
        // for (int i = V-20; i < V; i++) {
        //     printf("%f\n",(pr_tmp_gpu)[i] );
        // }

        //*err = euclidean_distance_gpu(pr.data(), pr_tmp_gpu, V);

        //printf(" err cpu calculation: %f\n", *err );


        gpu_euclidean_distance<<<num_blocks, 128>>>(pr_gpu, result_axpb_gpu, V, result_eudiff_gpu);

        //cudaDeviceSynchronize();

        // cudaError_t cuda_error2 = cudaGetLastError();
        //
        //
        // if (cuda_error2 != cudaSuccess){
        //    printf("Error2: ");
        //    printf(" %s\n", cudaGetErrorString(cuda_error2));
        // }
        // else{
        //    printf("Success2\n" );
        // }

        cudaMemcpy(  err, result_eudiff_gpu,   sizeof(double),
        cudaMemcpyDeviceToHost );

        // printf(" err gpu calculation: %f\n", *err );

        converged = *err <= convergence_threshold;

        // Update the PageRank vector
        memcpy(pr.data(), pr_tmp_gpu, sizeof(double) * V);
        cudaMemcpy( pr_gpu, pr_tmp_gpu, V * sizeof(double),
        cudaMemcpyHostToDevice );

        iter++;
    }


}

void PersonalizedPageRank::cpu_validation(int iter) {

    // Reset the CPU PageRank vector (uniform initialization, 1 / V for each vertex);
    std::fill(pr_golden.begin(), pr_golden.end(), 1.0 / V);

    // Do Personalized PageRank on CPU;
    auto start_tmp = clock_type::now();
    personalized_pagerank_cpu(x.data(), y.data(), val.data(), V, E, pr_golden.data(), dangling.data(), personalization_vertex, alpha, 1e-6, 100);
    auto end_tmp = clock_type::now();
    auto exec_time = chrono::duration_cast<chrono::microseconds>(end_tmp - start_tmp).count();
    std::cout << "exec time CPU=" << double(exec_time) / 1000 << " ms" << std::endl;

    // Obtain the vertices with highest PPR value;
    std::vector<std::pair<int, double>> sorted_pr_tuples = sort_pr(pr.data(), V);
    std::vector<std::pair<int, double>> sorted_pr_golden_tuples = sort_pr(pr_golden.data(), V);

    // Check how many of the correct top-20 PPR vertices are retrieved by the GPU;
    std::unordered_set<int> top_pr_indices;
    std::unordered_set<int> top_pr_golden_indices;
    int old_precision = std::cout.precision();
    std::cout.precision(4);
    int topk = std::min(V, topk_vertices);
    for (int i = 0; i < topk; i++) {
        int pr_id_gpu = sorted_pr_tuples[i].first;
        int pr_id_cpu = sorted_pr_golden_tuples[i].first;
        top_pr_indices.insert(pr_id_gpu);
        top_pr_golden_indices.insert(pr_id_cpu);
        if (debug) {
            double pr_val_gpu = sorted_pr_tuples[i].second;
            double pr_val_cpu = sorted_pr_golden_tuples[i].second;
            if (pr_id_gpu != pr_id_cpu) {
                std::cout << "* error in rank! (" << i << ") correct=" << pr_id_cpu << " (val=" << pr_val_cpu << "), found=" << pr_id_gpu << " (val=" << pr_val_gpu << ")" << std::endl;
            } else if (std::abs(sorted_pr_tuples[i].second - sorted_pr_golden_tuples[i].second) > 1e-6) {
                std::cout << "* error in value! (" << i << ") correct=" << pr_id_cpu << " (val=" << pr_val_cpu << "), found=" << pr_id_gpu << " (val=" << pr_val_gpu << ")" << std::endl;
            }
        }
    }
    std::cout.precision(old_precision);
    // Set intersection to find correctly retrieved vertices;
    std::vector<int> correctly_retrieved_vertices;
    set_intersection(top_pr_indices.begin(), top_pr_indices.end(), top_pr_golden_indices.begin(), top_pr_golden_indices.end(), std::back_inserter(correctly_retrieved_vertices));
    precision = double(correctly_retrieved_vertices.size()) / topk;
    if (debug) std::cout << "correctly retrived top-" << topk << " vertices=" << correctly_retrieved_vertices.size() << " (" << 100 * precision << "%)" << std::endl;
}

std::string PersonalizedPageRank::print_result(bool short_form) {
    if (short_form) {
        return std::to_string(precision);
    } else {
        // Print the first few PageRank values (not sorted);
        std::ostringstream out;
        out.precision(3);
        out << "[";
        for (int i = 0; i < std::min(20, V); i++) {
            out << pr[i] << ", ";
        }
        out << "...]";
        return out.str();
    }
}

void PersonalizedPageRank::clean() {
    // Delete any GPU data or additional CPU data;
    // TODO!


    free(pr_tmp_gpu);

    cudaFree( x_dot_gpu );
    cudaFree( pr_gpu );
    cudaFree( result_dot_gpu );
    cudaFree( x_axpb_gpu );
    cudaFree( result_axpb_gpu );
    cudaFree(result_eudiff_gpu );

    cublasDestroy(handle);
    cublasDestroy(handle_dot);




}
