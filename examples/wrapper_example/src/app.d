module clop.examples.wrapper_example;

import std.stdio;
import std.container.array;
import std.algorithm.mutation;

import derelict.opencl.cl;


import clop.rt.clid.context;
import clop.rt.clid.clerror;
import clop.rt.clid.settings;
import clop.rt.clid.imemory;
import clop.rt.clid.memory;
import clop.rt.clid.program;
import clop.rt.clid.kernel;
import clop.rt.clid.arglist;
import clop.rt.clid.makememory;
import clop.rt.clid.matrix;



void RunClidMatrixExample()
{
	auto mat = new Matrix!double(4, 4);
	mat.fill(2);
	mat.scale(2);
	mat.subtract(-2);
	mat.describe();

	auto mat2 = new Matrix!double(4, 3);
	mat2.fill(4);
	auto result = mat * mat2;
	result.describe();
}

class BasicMatrix(T) {
	public {
		this(int rows, int cols)
		{
			this.rows = rows;
			this.cols = cols;
			this.data = new T[rows*cols];
		}

		int size() { return rows*cols; }
		int rows, cols;
		T[] data;
	}
}

void RunBasicMatrixExample1()
{

	string path = "./examples/wrapper_example/src/matrix_program.cl";
	Program program = new Program();
	bool ok = program.load(path);
	assert(ok);
	if(!ok) return;

	BasicMatrix!double mat = new BasicMatrix!cl_double(2, 10);
	fill(mat.data, 1.5);

	Kernel scale = program.createKernel("Scale");
	scale.setGlobalWorkSize(mat.size());

	scale.call(mat.data, int(mat.size()), 2.0);

	//writeln(mat.data);

}

void RunBasicMatrixExample2()
{
	string path = "./examples/wrapper_example/src/matrix_program.cl";
	Program program = new Program();
	bool ok = program.load(path);
	assert(ok);
	if(!ok) return;

	BasicMatrix!cl_double mat = new BasicMatrix!cl_double(2, 10);
	fill(mat.data, 1);

	Kernel scale = program.createKernel("Scale");
	scale.setGlobalWorkSize(mat.size());

	Kernel subtract = program.createKernel("Subtract");
	subtract.setGlobalWorkSize(mat.size());

	ArgList args = new ArgList();
	args.arg(0, MakeMemory(mat.data));
	args.arg(1, MakeNumber!cl_int(mat.size()));
	args.arg(2, MakeNumber!cl_double(2));

	scale.call(args);
	args.arg(2, MakeNumber!cl_double(-1));
	subtract.call(args);

	args.updateHost();
	//writeln(mat.data);
}


int main(string[] args)
{
	//Settings.Instance().setUseGPU();
	Settings.Instance().setUseCPU();
	RunBasicMatrixExample1();
	RunBasicMatrixExample2();
	RunClidMatrixExample();
	return 0;
}
