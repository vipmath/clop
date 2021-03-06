/*
 *  The MIT License (MIT)
 *  =====================
 *
 *  Copyright (c) 2015 Dmitri Makarov <dmakarov@alumni.stanford.edu>
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 */
module clop.rt.ndarray;

import std.exception;
version (LDC) import std.string;
else import std.format;

/**
 * NDArray is a multi-dimensional array.  The number of dimensions is
 * determined at the object construction.  The first dimension is the
 * most significant and slowest changing, the last dimensions is the
 * least significant and the fastest changing.
 * @example auto A = NDArray!float(8, 12);
 * A is a 2-dimensional array or matrix with 8 rows, 12 elements each.
 * To access an element of A at row 3, column 5 use the expression
 * A[3, 5].
 * Internally the data is placed in a 1-dimensional dynamic array of
 * size equal to the product of all dimensions.  In the example above,
 * A data are stored in an array of length 8 x 12 = 96.  The element
 * A[3, 5] accesses the element at index 3 * 12 + 5 = 41 in the
 * internal 1-dimensional data array.
 * For k dimensions N_{1}, N_{2}, ..., N_{k}, the size is
 * N_{1} * N_{2} * ... * N_{k}
 * and the internal index for element A[i_{1}, i_{2}, ..., i_{k}] is
 * i_{k} + N_{k} * (i_{k-1} + N_{k-1} * (i_{k-2} + ... + N_{2} * i_{1}))
 */
class NDArray(T)
{
  import derelict.opencl.cl;
  import clop.rt.ctx : cl_strerror;

  private
  {
    T[]      data;
    size_t[] dims;
    cl_mem   cl_buffer;           /// CL device buffer bound to this array.
    bool     cl_buffer_allocated; /// whether the buffer was created.
  }

  this(size_t[] dims...)
  {
    this.dims = new size_t[dims.length];
    size_t size = 1;
    foreach (i, d; dims)
    {
      this.dims[i] = d;
      size *= d;
    }
    data = new T[size];
  }

  ~this()
  {
    release_buffer();
  }

  @property
  cl_mem* get_buffer()
  {
    return &cl_buffer;
  }

  void create_buffer(cl_context context)
  {
    cl_int status;
    release_buffer();
    cl_buffer = clCreateBuffer(context, CL_MEM_READ_WRITE, T.sizeof * data.length, null, &status);
    assert(status == CL_SUCCESS, cl_strerror(status, "clCreateBuffer"));
    cl_buffer_allocated = true;
  }

  void push_buffer(cl_command_queue queue)
  {
    if (cl_buffer_allocated)
    {
      cl_int status;
      status = clEnqueueWriteBuffer(queue, cl_buffer, CL_TRUE, 0, T.sizeof * data.length, data.ptr, 0, null, null);
      assert(status == CL_SUCCESS, cl_strerror(status, "clEnqueueWriteBuffer"));
    }
  }

  void pull_buffer(cl_command_queue queue)
  {
    if (cl_buffer_allocated)
    {
      cl_int status;
      status = clEnqueueReadBuffer(queue, cl_buffer, CL_TRUE, 0, T.sizeof * data.length, data.ptr, 0, null, null);
      assert(status == CL_SUCCESS, cl_strerror(status, "clEnqueueWriteBuffer"));
    }
  }

  void release_buffer()
  {
    if (cl_buffer_allocated)
    {
      cl_int status = clReleaseMemObject(cl_buffer);
      assert(status == CL_SUCCESS, cl_strerror(status, "clReleaseMemObject"));
      cl_buffer_allocated = false;
    }
  }

  auto get_num_dimensions()
  {
    return dims.length;
  }

  auto get_dimensions()
  {
    return dims;
  }

  @property
  auto length()
  {
    return data.length;
  }

  @property
  auto ptr()
  {
    return data.ptr;
  }

  @property
  bool empty()
  {
    return data is null;
  }

  @property
  ref T front()
  {
    return data[0];
  }

  ref T[] opCast(U)() if (is (U == T[]))
  {
    return data;
  }

  T[] opIndex()
  {
    return data[];
  }

  T opIndex(size_t[] indices...)
  in
  {
    enforce(indices.length <= dims.length,
            format("Too many dimensions (%d) indexing %d-dimensional array.",
                   indices.length, dims.length));
  }
  body
  {
    return data[get_index(indices)];
  }

  void opIndexAssign(NDArray!T c)
  {
    data[] = c.data[];
  }

  void opIndexAssign(T c)
  {
    data[] = c;
  }

  void OpIndexAssign(T[] c)
  {
    data[] = c[];
  }

  void opIndexAssign(T c, size_t[] indices...)
  in
  {
    enforce(indices.length <= dims.length,
            format("Too many dimensions (%d) indexing %d-dimensional array.",
                   indices.length, dims.length));
  }
  body
  {
    data[get_index(indices)] = c;
  }

  void opIndexOpAssign(string op)(T c, size_t[] indices...)
  if (op == "+" || op == "-" || op == "*" || op == "/")
  in
  {
    enforce(indices.length <= dims.length,
            format("Too many dimensions (%d) indexing %d-dimensional array.",
                   indices.length, dims.length));
  }
  body
  {
    mixin ("data[get_index(indices)] " ~ op ~ "= c;");
  }

  private size_t get_index(size_t[] indices...)
  {
    size_t index = 0;
    size_t offset = 1;
    foreach_reverse (i, x; indices)
    {
      index += offset * x;
      offset *= dims[i];
    }
    return index;
  }

} // NDArray class

unittest
{
  auto a = new NDArray!int(16);
  assert(a.get_num_dimensions() == 1);
  assert(a.get_dimensions() == [16]);
  assert(a.length == 16);
  assert(!a.empty());
  a = new NDArray!int(8, 10);
  assert(a.get_num_dimensions() == 2);
  assert(a.get_dimensions() == [8, 10]);
  assert(a.length == 80);
  assert(!a.empty());
  a = new NDArray!int(2, 10, 5);
  assert(a.get_num_dimensions() == 3);
  assert(a.get_dimensions() == [2, 10, 5]);
  assert(a.length == 100);
  assert(!a.empty());
  a[1, 4, 4] = 37;
  assert(a[74] == 37 && a[1, 4, 4] == 37);
}
