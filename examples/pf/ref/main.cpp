// Other header files.
#include <algorithm>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "common.hpp"

using namespace std;

class Application {

  static const unsigned SEED = 1;
  static const unsigned HALO = 3;  // halo width along one direction when advancing to the next iteration

public:

  Application(int argc, char** argv) : outfile( NULL )
                                     , rows( 100 )
                                     , cols( 100000 )
                                     , height( 200 )
  {
    int ch;
    while ( ( ch = getopt( argc, argv, "d:o:p:" ) ) != -1 )
    {
      switch ( ch )
      {
      case 'd': sscanf( optarg, "%d", device );   break;
      case 'p': sscanf( optarg, "%d", platform ); break;
      case 'o': cfg->outfile = optarg;            break;
      default:  usage( argv );
      }
    }
    argc -= optind;
    argv += optind;
    if ( argc < 3 ) usage( argv );
    cfg->cols   = atoi( argv[0] );
    cfg->rows   = atoi( argv[1] );
    cfg->height = atoi( argv[2] );

    data = (int*) malloc( rows * cols * sizeof(int) );
    wall = (int**) malloc( rows * sizeof(int*) );
    result = (int*) malloc( cols * sizeof(int) );
    srandom( SEED );
    for ( int ii = 0; ii < rows; ++ii )
    { // wall[n] is set to be the nth row of the data array.
      wall[ii] = data + cols * ii;
      for ( int jj = 0; jj < cols; ++jj )
        wall[ii][jj] = random() % 10;
    }
  }

  string summary()
  {
    ss << "\"SEED='"   << SEED
       << "',HALO='"   << HALO
       << "',rows='"   << rows
       << "',cols='"   << cols
       << "',height='" << height
       << "',Output='" << ( outfile ? outfile : "(null)" )
       << "'\"";
    return ss.str();
  }

  /**
   *
   **/
  void run()
  {
    double t1 = gettime();
    size_t gwsize = cfg->rows * cfg->cols;
    size_t lwsize = cl->getWorkGroupSize( 0 );
    if ( lwsize == 0 )
    {
      fprintf( stderr, "ERROR: max work group size is zero!\n" );
      abort();
    }
    if ( lwsize > gwsize ) lwsize = gwsize;
    else
    {
      size_t nthreads = lwsize;
      for ( nthreads = lwsize; gwsize % nthreads != 0; --nthreads );    
      lwsize = nthreads;
    }
    double t2 = gettime();
    *prep += t2 - t1;
    cl_mem result_d[2];
    cl_mem wall_d = cl->createBuffer( CL_MEM_READ_ONLY  | CL_MEM_COPY_HOST_PTR, sizeof(int) * (gwsize - cfg->cols), cfg->data + cfg->cols );
    result_d[0]   = cl->createBuffer( CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, sizeof(int) * cfg->cols           , cfg->data             );
    result_d[1]   = cl->createBuffer( CL_MEM_READ_WRITE                       , sizeof(int) * cfg->cols           , NULL                  );

    int src = 0;
    for ( int height = 0 ; height < cfg->rows - 1; height += cfg->height )
    {
      int iteration = min( cfg->height, cfg->rows - height - 1 );
      int border = cfg->height * Config::HALO;
      int halo = Config::HALO;
      int dst = 1 - src;

      cl->setKernelArg( 0,  0, sizeof(int)   , &iteration );
      cl->setKernelArg( 0,  1, sizeof(cl_mem), &wall_d );
      cl->setKernelArg( 0,  2, sizeof(cl_mem), &result_d[src] );
      cl->setKernelArg( 0,  3, sizeof(cl_mem), &result_d[dst] );
      cl->setKernelArg( 0,  4, sizeof(int)   , &cfg->cols );
      cl->setKernelArg( 0,  5, sizeof(int)   , &cfg->rows );
      cl->setKernelArg( 0,  6, sizeof(int)   , &height );
      cl->setKernelArg( 0,  7, sizeof(int)   , &border );
      cl->setKernelArg( 0,  8, sizeof(int)   , &halo );
      cl->setKernelArg( 0,  9, sizeof(int) * lwsize, NULL );
      cl->setKernelArg( 0, 10, sizeof(int) * lwsize, NULL );

      cl->enqueueNDRangeKernel( 0, 1, NULL, &gwsize, &lwsize, 0, NULL, NULL );

      src = dst;
    }

    // Copy results back to host.
    // setup.queue           - command queue.
    // config.result[src]    - result on the device.
    // CL_TRUE               - blocking
    // 0                     - offset
    // sizeof(cl_int) * cols - size to copy
    // result                - pointer to the memory on the host
    // 0                     - number of events in wait list
    // NULL                  - event wait list
    // &event                - event object for profiling data access
    cl->enqueueReadBuffer( result_d[src], CL_TRUE, 0, sizeof(int) * cfg->cols, cfg->result, 0, NULL, NULL );

    cl->releaseMemObject( wall_d );
    cl->releaseMemObject( result_d[0] );
    cl->releaseMemObject( result_d[1] );

    t1 = gettime();
    if ( NULL != cfg->outfile )
    {
      FILE *fp = fopen( cfg->outfile, "w" );
      for ( int t = 0; t < cfg->cols; ++t )
        fprintf( fp, "%d %d\n", cfg->data[t], cfg->result[t] );
      fclose( fp );
    }
    t2 = gettime();
    *prep += t2 - t1;
  }

private:

  int **wall, *data, *result;
  int rows, cols, height;
  stringstream ss;

  void usage(const char* name)
  {
    cout << "Usage: " << name << " [-p <platform>] [-d <device>] [-o <outfile>] columns rows height\n"
         << "  columns:  minimum number of centers allowed\n"
         << "  rows:     maximum number of centers allowed\n"
         << "  height:   dimension of each data point\n";
  }

};

int main(int argc, char** argv)
{
  try
  {
    Application app(argc, argv);
    app.run();
  }
  catch (exception& e)
  {
    cerr << "pf: " << e.what() << endl;
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}

// Local Variables:
// company-c-headers-path-user: ("../../include")
// End:
