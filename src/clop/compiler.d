/*
  The MIT License (MIT)
  =====================

  Copyright (c) 2015 Dmitri Makarov <dmakarov@alumni.stanford.edu>

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.
*/
module clop.compiler;

import std.container;
import std.conv;
import std.string;
import std.traits;

import clop.analysis;
import clop.grammar;
import clop.program;
import clop.structs;
import clop.symbol;
import clop.templates;
import clop.transform;

public import clop.runtime;

/++
 +  The CLOP compiler.
 +/
struct Compiler
{
  Box range;
  ParseTree AST;
  ParseTree KBT; // kernel body compound statement AST
  Program[] variants;
  Argument[] parameters;
  Symbol[string] symtable;
  Set!Transformation trans;

  string errors;
  string pattern;
  string external;
  string block_size;
  string source_file;
  size_t source_line;

  bool global_scope = false;
  bool eval_def     = false;
  bool internal     = false;
  bool use_shadow   = false;
  uint depth        = 0;

  this(string expr, string file, size_t line)
  {
    source_file = file;
    source_line = line;
    errors = "";
    external = "";
    range = Box();
    AST   = CLOP(expr);
    trans = Set!Transformation();
  }

  string generate_code()
  {
    debug(DEBUG_GRAMMAR)
    {
      debug_tree(AST);
    }
    else
    {
      analyze(AST);
      compute_intervals();
      collect_parameters();
      // before we generate optimized variants, we need to transform
      // the AST for a specific synchronization pattern.
      auto t = transform_by_pattern(KBT);
      apply_transformations(t);
      // FIXME! now we have the variants and we need to generate the
      // code that invokes variants one after another and reports
      // performance.
      auto kernel = variants[0].generate_code();
      auto params = set_params();
      auto unit = format(template_create_opencl_kernel, generate_kernel_name());
      unit ~= set_args("clop_opencl_kernel") ~ code_to_invoke_kernel() ~ code_to_read_data_from_device();
      //debug (DISABLE_PERMANENTLY)
      {
        unit ~= "\n// transformations <" ~ trans.toString ~ ">\n";
        unit ~= dump_arraytab();
        unit ~= dump_intervals();
        unit ~= dump_symtable();
      }
      auto diagnostics = format("pragma (msg, \"%s\");\n", errors);
      auto code = diagnostics ~ params ~ format(template_clop_unit, external, kernel, unit);
      return code;
    }
  }

  void analyze(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.TranslationUnit":
      {
        if (t.children[0].name == "CLOP.ExternalDeclarations")
        {
          auto x = t.children[0];
          external = "q{\n";
          foreach (m; x.matches)
          {
            external ~= " " ~ m;
          }
          external ~= "\n}";
          analyze(t.children[0]);
          analyze(t.children[1]);
        }
        else
        {
          analyze(t.children[0]);
        }
        break;
      }
    case "CLOP.KernelBlock":
      {
        uint i = 0;
        if (t.children[i].name == "CLOP.SyncPattern")
        {
          pattern = t.children[i++].matches[0];
        }
        if (t.children[$ - 1].name == "CLOP.Transformations")
        {
          analyze(t.children[$ - 1]);
        }
        analyze(t.children[i++]);
        global_scope = true;
        if (t.children[i].name == "CLOP.CompoundStatement")
        {
          KBT = t.children[i];
        }
        analyze(t.children[i]);
        break;
      }
    case "CLOP.ExternalDeclarations":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.ExternalDeclaration":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.FunctionDefinition":
      {
        // add function name to the symbol table
        analyze(t.children[1]);
        break;
      }
    case "CLOP.RangeDecl":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.RangeList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.RangeSpec":
      {
        auto s = t.matches[0];
        auto d = range.get_dimensionality();
        symtable[s] = Symbol(s, "int", t, true, false, [], [], "clop_local_index_" ~ s);
        range.intervals ~= [Interval(t.children[1], t.children[2])];
        range.symbols ~= [s];
        range.s2i[s] = d;
        bool saved_global_scope_value = global_scope;
        global_scope = true;
        analyze(t.children[1]);
        analyze(t.children[2]);
        global_scope = saved_global_scope_value;
        break;
      }
    case "CLOP.Transformations":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.TransList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.TransSpec":
      {
        if (t.matches.length > 3)
        {
          block_size = t.matches[$-2];
        }
        string[] params;
        if (t.children.length > 1)
          foreach (c; t.children[1].children)
            params ~= c.matches[0];
        trans.insert(Transformation(t.matches[0], params));
        break;
      }
    case "CLOP.Declaration":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.Declarator":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.TypeSpecifier":
      {
        break;
      }
    case "CLOP.StructSpecifier":
      {
        break;
      }
    case "CLOP.InitDeclaratorList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.InitDeclarator":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.InitializerList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.Initializer":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.ParameterList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.ParameterDeclaration":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.TypeName":
      {
        break;
      }
    case "CLOP.StatementList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.Statement":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.CompoundStatement":
      {
        t.children.length == 1 && analyze(t.children[0]);
        break;
      }
    case "CLOP.ExpressionStatement":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.ReturnStatement":
      {
        t.children.length == 1 && analyze(t.children[0]);
        break;
      }
    case "CLOP.PrimaryExpr":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.PostfixExpr":
      {
        analyze(t.children[0]);
        if (t.children.length == 1)
        {
          return;
        }
        analyze(t.children[1]);
        if (t.children[1].name != "CLOP.Expression" || t.children[0].children[0].name != "CLOP.Identifier")
        {
          return;
        }
        // this is an identifier
        auto symbol = t.children[0].children[0].matches[0];
        // analyze index expression
        if (!symtable[symbol].is_array)
        {
          symtable[symbol].is_array = true;
          if (can_transform_index_expression(t.children[1]))
          {
            symtable[symbol].shadow = generate_shared_memory_variable(symbol);
          }
        }
        eval_def ? symtable[symbol].defs : symtable[symbol].uses ~= t.children[1];
        break;
      }
    case "CLOP.ArgumentExprList":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.UnaryExpr":
    case "CLOP.IncrementExpr":
    case "CLOP.DecrementExpr":
      {
        analyze(t.children[0]);
        break;
      }
    case "CLOP.CastExpr":
    case "CLOP.MultiplicativeExpr":
    case "CLOP.AdditiveExpr":
    case "CLOP.ShiftExpr":
    case "CLOP.RelationalExpr":
    case "CLOP.EqualityExpr":
    case "CLOP.ANDExpr":
    case "CLOP.ExclusiveORExpr":
    case "CLOP.InclusiveORExpr":
    case "CLOP.LogicalANDExpr":
    case "CLOP.LogicalORExpr":
    case "CLOP.ConditionalExpr":
    case "CLOP.Expression":
      {
        foreach (c; t.children)
          analyze(c);
        break;
      }
    case "CLOP.AssignmentExpr":
      {
        if (t.children.length == 3)
        {
          eval_def = true;
          analyze(t.children[0]);
          eval_def = false;
          analyze(t.children[2]);
        }
        else
        {
          analyze(t.children[0]);
        }
        break;
      }
    case "CLOP.IdentifierList":
      {
        foreach (c; t.children)
        {
          analyze(c);
        }
        break;
      }
    case "CLOP.Identifier":
      {
        auto s = t.matches[0];
        if (s !in symtable)
        {
          symtable[s] = Symbol(s, "", t, !global_scope, false, [], [], null);
        }
        break;
      }
    default:
      {
        break;
      }
    }
  }

  ParseTree transform_by_pattern(ParseTree t)
  {
    if (pattern == "Antidiagonal")
    {
      return Antidiagonal(t);
    }
    errors ~= "CLOP: unknown syncronization pattern " ~ pattern ~ "\n";
    return t;
  }

  ParseTree Antidiagonal(ParseTree t)
  {
    if (t.children.length == 0 || t.name != "CLOP.CompoundStatement")
      return t;
    ParseTree newt = t.dup;
    ParseTree[] decl;
    auto thread_index = "tx";
    auto sync_diagonal = "diagonal";
    if (symtable.get(sync_diagonal, Symbol()) == Symbol())
    {
      symtable[sync_diagonal] = Symbol(sync_diagonal, "int", ParseTree(), false, false, [], [], null);
      parameters ~= [Argument(sync_diagonal, "int", "", "", "", true)];
    }
    decl ~= CLOP.decimateTree(CLOP.Declaration(format("int %s = get_global_id(0);", thread_index)));
    decl ~= CLOP.decimateTree(CLOP.Declaration(format("int %s = %s + 1;", range.symbols[0], thread_index)));
    decl ~= CLOP.decimateTree(CLOP.Declaration(format("int %s = %s - %s - 1;", range.symbols[1], sync_diagonal, thread_index)));
    auto max = range.intervals[0].get_max();
    decl ~= CLOP.decimateTree(CLOP.Statement(format("if (%s >= %s) {%s = %s - %s + %s + 1; %s = %s - %s - 1;}",
                                                    sync_diagonal, max,
                                                    range.symbols[0], sync_diagonal, max, thread_index,
                                                    range.symbols[1], max, thread_index)));
    newt.children[0].children = decl ~ newt.children[0].children;
    return newt;
  }

  void apply_transformations(ParseTree t)
  {
    foreach (p; trans)
      variants ~= Program(symtable, [p], t.dup, range, pattern);
  }

  /++
   + @FIXME this doesn't work when not entire index space is used in
   + index expressions.  A possible work-around to assume that arrays
   + indexes always start at 0 and if the lower bound of a computed
   + interval is greater than 0 it should be extended to 0.
   +/
  void compute_intervals()
  {
    foreach (k, v; symtable)
    {
      if (v.is_array && v.shadow != null)
      {
        auto uses = v.uses;
        auto box = range.map(uses[0]);
        foreach (u; uses[1 .. $])
        {
          auto newbox = range.map(u);
          foreach (i; 0 .. box.length)
            box[i] = interval_union(box[i], newbox[i]);
        }
        symtable[k].box = box;
      }
    }
  }

  void collect_parameters()
  {
    foreach (s, v; symtable)
      if (!v.is_local)
        parameters ~= [Argument(s, "", "", "")];
  }

  bool can_transform_index_expression(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP.ArrayIndex":
    case "CLOP.FunctionCall":
      return false;
    case "CLOP.ArgumentList":
      if (t.children.length == 1)
        return false;
      goto default;
    default:
      auto result = true;
      foreach (c; t.children)
        result = result && can_transform_index_expression(c);
      return result;
    }
  }

  string generate_kernel_name()
  {
    auto suffix = get_applied_transformations();
    return format("clop_kernel_main_%s_%s", pattern, suffix);
  }

  string get_applied_transformations()
  {
    return trans.toString();
  }

  string select_array_for_shared_memory()
  {
    return "F";
  }

  auto generate_shared_memory_variable(string v)
  {
    return v ~ "_in_shared_memory";
  }

  string generate_antidiagonal_range(ParseTree t)
  {
    auto s = "";
    auto num_dimensions = t.children.length;
    auto range_arg = new string[num_dimensions];
    auto shadowed = SList!string();

    foreach (v; symtable)
      if (v.is_array && v.shadow != null)
        shadowed.insert(v.name);

    auto r = Box([], []);
    auto g = Box([], []);
    string[3] bix;
    foreach (c, u; t.children)
    {
      auto v = u.matches[0];              // variable name in NDRange specification
      r.symbols ~= [v];
      r.s2i[v] = c;
      auto n = "0";
      auto x = block_size;
      r.intervals ~= [
                      Interval(
                               ParseTree("CLOP.IntegerLiteral", true, [n], "", 0, 0, []),
                               ParseTree("CLOP.IntegerLiteral", true, [x], "", 0, 0, [])
                              )
                      ];
      // n = range.intervals[c].min + b%d * block_size;
      // x = n + block_size;
      bix[c] = format("b%d", c);
      auto y = ParseTree("CLOP.Identifier", true, [bix[c]], "", 0, 0, []);
      auto w = ParseTree("CLOP.IntegerLiteral", true, [x], "", 0, 0, []);
      auto f = create_mul_expr(y, w, "*");
      auto a = create_add_expr(range.intervals[c].min, f, "+");
      g.intervals ~= [Interval(a, create_add_expr(a, w, "+"))];
      g.symbols ~= [v];
      g.s2i[v] = c;
    }

    if (true /*trans.contains("rectangular_blocking")*/)
    {
      auto iv = "iv";
      // block or work group id
      auto bid0 = "bid0";
      // thread or work item id
      auto tid0 = "tid0";
      // local index variables
      auto li0 = "li0";
      auto li1 = "li1";
      // size of local index space
      auto lsz0 = block_size;
      auto lsz1 = block_size;

      s ~= format("  int %s = get_group_id(0);\n", bid0);
      s ~= format("  int %s = get_local_id(0);\n", tid0);
      auto factor = false;
      foreach (c, u; t.children)
      {
        auto v = u.matches[0];        // variable name in NDRange specification
        auto o = factor ? "-" : "+";  // arithmetic operation
        factor = !factor;
        range_arg[c] = v;
        auto n = format("b%s0", v); // generated variable to pass the block index.
        s ~= format("  int b%d = %s %s %s;\n", c, n, o, bid0);
        parameters ~= [Argument(n, "int", "", "", "", true)];
      }

      auto recalculations = "";
      auto safeguards = "";

      foreach (v; shadowed)
      {
        auto uses = symtable[v].uses;
        Interval[3] local_box;
        Interval[3] global_box;
        foreach (i, c; uses[0].children)
        {
          local_box[i] = interval_apply(c, r);
          global_box[i] = interval_apply(c, g);
        }
        for (auto ii = 1; ii < uses.length; ++ii)
        {
          foreach (i, c; uses[ii].children)
          {
            local_box[i] = interval_union(local_box[i], interval_apply(c, r));
            global_box[i] = interval_union(global_box[i], interval_apply(c, g));
          }
        }
        // size of current array block
        auto bsz0 = local_box[0].get_size();
        auto bsz1 = local_box[1].get_size();
        // global index of current array
        auto gi0 = format("(%s) + (%s)", global_box[0].get_min(), li0);
        auto gi1 = format("(%s) + (%s)", global_box[1].get_min(), li1);
        // size of current global array
        auto gsz0 = symtable[v].box[0].get_max();
        // global memory array name
        auto gma = v;
        // shared memory array name
        auto sma = generate_shared_memory_variable(v);
        parameters ~= Argument(sma, "", "__local",format("(%s) * (%s)", bsz0, bsz1), gma);
        s ~= format(template_shared_memory_data_init,
                     li1, li1, bsz1, li1,
                     li0, li0, bsz0, li0, lsz0,
                     li0, tid0, bsz0,
                     sma, li1, bsz0, li0, tid0,
                     gma, gi1, gsz0, gi0, tid0);

        // margin size
        auto msz0 = bsz0 ~ "-" ~ lsz0;
        auto msz1 = bsz1 ~ "-" ~ lsz1;

        auto iv0 = v ~ "_" ~ generate_shared_memory_variable(range_arg[0]);
        auto iv1 = v ~ "_" ~ generate_shared_memory_variable(range_arg[1]);
        recalculations ~= format(template_shared_index_recalculation, iv0, msz0, tid0, iv, lsz0, iv, lsz0,  iv1, msz1, tid0, iv, lsz1, iv, lsz1);
        if (safeguards != "") safeguards ~= " && ";
        safeguards ~= format("(%s) < (%s) && (%s) >= (%s)", iv0, bsz0, iv1, msz1);
      }
      s ~= format(template_antidiagonal_loop_prefix, iv, iv, lsz1, lsz0, iv);
      s ~= format("    int %s = (%s) + tid0 + ((%s) < (%s) ?   0  : (%s) - (%s) + 1);\n", t.children[0].matches[0], g.intervals[0].get_min(), iv, lsz0, iv, lsz0);
      s ~= format("    int %s = (%s) - tid0 + ((%s) < (%s) ? (%s) : (%s)        - 1);\n", t.children[1].matches[0], g.intervals[1].get_min(), iv, lsz1, iv, lsz1);
      s ~= recalculations;
      s ~= format("\n    if (%s)\n", safeguards);
    }
    else
    {
      s ~= "  int tid0 = get_global_id(0);\n";
      for (auto c = 0; c < t.children.length; ++c)
      {
        ParseTree u = t.children[c];
        s ~= (internal)
             ? "  int " ~ u.matches[0] ~ " = c0 + tid0;\n"
             : "  int " ~ u.matches[0] ~ " = r0 - tid1;\n";
        internal = true;
      }
    }
    return s;
  }

  string finish_antidiagonal_range(ParseTree t)
  {
    auto s = "";
    auto shadowed = SList!string();

    foreach (v; symtable)
      if (v.is_array && v.shadow != null)
      {
        auto defs = v.defs;
        if (defs.length > 0)
          shadowed.insert(v.name);
      }

    if (true /*trans.contains("rectangular_blocking")*/)
    {
      s ~= template_antidiagonal_loop_suffix;
      string[3] bix;
      auto r = Box([], []);
      foreach (c, u; range.symbols)
      {
        bix[c] = format("b%d", c);
        r.symbols ~= [u];
        r.s2i[u] = c;
        auto n = "0";
        auto x = block_size;
        r.intervals ~= [
                        Interval(ParseTree("CLOP.IntegerLiteral", true, [n], "", 0, 0, []), ParseTree("CLOP.IntegerLiteral", true, [x], "", 0, 0, []))];
      }
      foreach (v; shadowed)
      {
        auto uses = symtable[v].uses;
        Interval[3] local_box;
        foreach (i, c; uses[0].children)
        {
          local_box[i] = interval_apply(c, r);
        }
        for (auto ii = 1; ii < uses.length; ++ii)
          foreach (i, c; uses[ii].children)
          {
            local_box[i] = interval_union(local_box[i], interval_apply(c, r));
          }
        // thread or work item id
        auto tid0 = "tid0";
        // local index variables
        auto li0 = "li0";
        auto li1 = "li1";
        // size of local index space
        auto lsz0 = block_size;
        auto lsz1 = block_size;
        // size of current array block
        auto bsz0 = local_box[0].get_size();
        auto bsz1 = local_box[1].get_size();
        // global index of current array
        auto gi0 = format("(%s) * (%s) + (%s)", bix[0], lsz0, li0);
        auto gi1 = format("(%s) * (%s) + (%s)", bix[1], lsz1, li1);
        // size of current global array
        auto gsz0 = symtable[v].box[0].get_max();
        // global memory array name
        auto gma = v;
        // shared memory array name
        auto sma = generate_shared_memory_variable(v);
        s ~= format(template_shared_memory_fini,
                     li1, li1, bsz1, li1,
                     li0, li0, bsz0, li0, lsz0,
                     li0, tid0, bsz0,
                     gma, gi1, gsz0, gi0, tid0,
                     sma, li1, bsz0, li0, tid0);
      }
    }
    return s;
  }

  string generate_horizontal_range(ParseTree t)
  {
    return "";
  }

  string finish_horizontal_range(ParseTree t)
  {
    return "";
  }

  string generate_stencil_range(ParseTree t)
  {
    return generate_ndrange(t);
  }

  string finish_stencil_range(ParseTree t)
  {
    return "";
  }

  string generate_ndrange(ParseTree t)
  {
    string s = "";
    ulong n = t.children.length;
    for (auto c = 0; c < n; ++c)
    {
      ParseTree u = t.children[c];
      string name = u.matches[0];
      symtable[name] = Symbol(name, "int", t, true);
      s ~= "  int " ~ name ~ " = get_global_id(" ~ ct_itoa(n - 1 - c) ~ ");\n";
    }
    return s;
  }

  string finish_ndrange(ParseTree t)
  {
    return "";
  }

  bool is_local(string sym)
  {
    return symtable.get(sym, Symbol()).is_local;
  }

  string set_params()
  {
    string result = "string param;\n";
    auto issued_declaration = false;
    foreach(p; parameters)
    {
      if (p.type == "")
      {
        if (p.back == "")
        {
          result ~= format("param = mixin(set_kernel_param!(typeof(%s))(\"%s\",\"%s\"));\n", p.name, p.name, p.back);
        }
        else
        {
          result ~= format("param = mixin(set_kernel_param!(typeof(%s))(\"%s\",\"%s\"));\n", p.back, p.name, p.back);
        }
      }
      else
      {
        result ~= format("param = \"%s %s\";\n", p.type, p.name);
      }
      if (issued_declaration)
      {
        result ~= "if (param != \"\") kernel_params ~= \", \" ~ param;\n";
      }
      else
      {
        result ~= "string kernel_params = param;\n";
        issued_declaration = true;
      }
    }
    return result;
  }

  string set_args(string kernel)
  {
    auto result = "";
    foreach(i, p; parameters)
    {
      if (!p.skip)
      {
        if (p.back == "")
        {
          result ~= format("mixin(set_kernel_arg!(typeof(%s))(\"%s\",\"%d\",\"%s\",\"\",\"\"));\n", p.name, kernel, i, p.name);
        }
        else
        {
          result ~= format("mixin(set_kernel_arg!(typeof(%s))(\"%s\",\"%d\",\"null\",\"%s\",\"%s\"));\n", p.back, kernel, i, p.back, p.size);
        }
      }
    }
    return result;
  }

  string code_to_read_data_from_device()
  {
    string result = "";
    foreach (k, v; symtable)
    {
      if (!v.is_local && v.type == "" && v.defs.length > 0)
      {
        result ~= "mixin(read_device_buffer!(typeof(" ~ k ~ "))(\"" ~ k ~ "\"));\n";
      }
    }
    return result;
  }

  string code_to_invoke_kernel()
  {
    debug (DEBUG_GRAMMAR)
    {
      return "";
    }
    else
    {
      auto gsz0 = range.intervals[0].get_max();
      auto bsz0 = block_size;
      auto bsz1 = block_size;
      auto name = "clop_opencl_kernel";
      auto n = 0;
      ulong argindex[2];
      foreach (i, p; parameters)
        if (p.skip)
          argindex[n++] = i;
      return format(template_antidiagonal_rectangular_blocks_invoke_kernel, gsz0, bsz0, bsz0, bsz0, name, argindex[0], name, argindex[1], name);
    }
  }

  string dump_symtable()
  {
    auto result = "// Symbol table:\n";
    foreach (s; symtable)
      result ~= format("// %s\n", s.toString());
    return result;
  }

  string dump_arraytab()
  {
    string result = "// Recognized the following array variables:\n";
    foreach (k, v; symtable)
    {
      if (v.is_array)
      {
        string s = "// defs " ~ ct_itoa(v.defs.length) ~ "\n";
        foreach (a; v.defs)
        {
          s ~= "// " ~ to!string(a.matches) ~ "\n";
          s ~= "// " ~ to!string(map!(p => p.toString())(range.map(a))) ~ "\n";
        }
        s ~= "// uses " ~ ct_itoa(v.uses.length) ~ "\n";
        foreach (a; v.uses)
        {
          s ~= "// " ~ to!string(a.matches) ~ "\n";
          s ~= "// " ~ to!string(map!(p => p.toString())(range.map(a))) ~ "\n";
        }
        result ~= "// " ~ k ~ ":\n" ~ s;
      }
    }
    return result;
  }

  string dump_intervals()
  {
    string result = "// The intervals:\n";
    foreach (k; 0 .. range.get_dimensionality())
    {
      result ~= "// " ~ range.symbols[k] ~ ": " ~ range.intervals[k].toString() ~ "\n";
    }
    return result;
  }

  string dump_parameters()
  {
    string result = "// The kernel arguments:\n";
    foreach (i, a; parameters)
    {
      result ~= "// " ~ a.name ~ " " ~ a.type ~ " " ~ a.qual ~ " " ~ a.size ~ "\n";
    }
    return result;
  }

  string debug_node(ParseTree t)
  {
    string s = "\n";
    string indent = "";
    foreach (x; 0 .. depth) indent ~= "  ";
    ++depth;
    foreach (i, c; t.children)
      s ~= indent ~ ct_itoa(i) ~ ": " ~ debug_tree(c) ~ "\n";
    --depth;
    string m = "";
    foreach (i, x; t.matches)
      m ~= " " ~ ct_itoa(i) ~ ":\"" ~ x ~ "\"";
    return format("<%s, input[%d,%d]:\"%s\" matches%s>%s%s</%s>", t.name, t.begin, t.end, t.input[t.begin .. t.end], m, s, indent, t.name);
  }

  string debug_leaf(ParseTree t)
  {
    return "<" ~ t.name ~ ">" ~ t.matches[0] ~ "</" ~ t.name ~ ">";
  }

  string debug_tree(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP":
    case "CLOP.TranslationUnit":
    case "CLOP.KernelBlock":
    case "CLOP.ExternalDeclarations":
    case "CLOP.ExternalDeclaration":
    case "CLOP.FunctionDefinition":
    case "CLOP.SyncPattern":
    case "CLOP.RangeDecl":
    case "CLOP.RangeList":
    case "CLOP.RangeSpec":
    case "CLOP.Transformations":
    case "CLOP.TransList":
    case "CLOP.TransSpec":
    case "CLOP.Declaration":
    case "CLOP.Declarator":
    case "CLOP.TypeSpecifier":
    case "CLOP.StructSpecifier":
    case "CLOP.StructDeclarationList":
    case "CLOP.StructDeclaration":
    case "CLOP.StructDeclaratorList":
    case "CLOP.StructDeclarator":
    case "CLOP.InitDeclaratorList":
    case "CLOP.InitDeclarator":
    case "CLOP.InitializerList":
    case "CLOP.Initializer":
    case "CLOP.ParameterList":
    case "CLOP.ParameterDeclaration":
    case "CLOP.TypeName":
    case "CLOP.StatementList":
    case "CLOP.Statement":
    case "CLOP.CompoundStatement":
    case "CLOP.ExpressionStatement":
    case "CLOP.IfStatement":
    case "CLOP.IterationStatement":
    case "CLOP.WhileStatement":
    case "CLOP.ForStatement":
    case "CLOP.ReturnStatement":
    case "CLOP.PrimaryExpr":
    case "CLOP.PostfixExpr":
    case "CLOP.ArgumentExprList":
    case "CLOP.UnaryExpr":
    case "CLOP.IncrementExpr":
    case "CLOP.DecrementExpr":
    case "CLOP.CastExpr":
    case "CLOP.MultiplicativeExpr":
    case "CLOP.AdditiveExpr":
    case "CLOP.ShiftExpr":
    case "CLOP.RelationalExpr":
    case "CLOP.EqualityExpr":
    case "CLOP.ANDExpr":
    case "CLOP.ExclusiveORExpr":
    case "CLOP.InclusiveORExpr":
    case "CLOP.LogicalANDExpr":
    case "CLOP.LogicalORExpr":
    case "CLOP.ConditionalExpr":
    case "CLOP.AssignmentExpr":
    case "CLOP.Expression":
    case "CLOP.IdentifierList":
        return debug_node(t);
    case "CLOP.MultiplicativeOperator":
    case "CLOP.AdditiveOperator":
    case "CLOP.ShiftOperator":
    case "CLOP.RelationalOperator":
    case "CLOP.EqualityOperator":
    case "CLOP.AssignmentOperator":
    case "CLOP.Identifier":
    case "CLOP.FloatLiteral":
    case "CLOP.IntegerLiteral":
        return debug_leaf(t);
    default: return t.name;
    }
  }

  /**
   * The very limited integer to string conversion works at compile-time.
   */
  string ct_itoa(T)(T x) if (is (T == byte) || is (T == ubyte)
                         ||  is (T == short) || is (T == ushort)
                         ||  is (T == int ) || is (T == uint )
                         ||  is (T == long) || is (T == ulong))
  {
    string s = "";
    string v = "";
    static if (is (T == byte) || is (T == short) || is (T == int) || is (T == long))
    {
      if (x < 0)
      {
        s = "-";
        x = -x;
      }
    }
    do
    {
      v = cast(char)('0' + (x % 10)) ~ v;
      x /= 10;
    } while (x > 0);
    return s ~ v;
  }

} // Compiler class

/+
 +  Free functions, not members of Compiler class.
 +/

string
set_kernel_param(T)(string name, string back)
{
  string code;
  static      if (is (T == bool  )) code = "\"uchar "  ~ name ~ "\"";
  else static if (is (T == char  )) code = "\"char "   ~ name ~ "\"";
  else static if (is (T == byte  )) code = "\"char "   ~ name ~ "\"";
  else static if (is (T == ubyte )) code = "\"uchar "  ~ name ~ "\"";
  else static if (is (T == short )) code = "\"short "  ~ name ~ "\"";
  else static if (is (T == ushort)) code = "\"ushort " ~ name ~ "\"";
  else static if (is (Unqual!(T) == int)) code = "\"int "    ~ name ~ "\"";
  else static if (is (T == uint  )) code = "\"uint "   ~ name ~ "\"";
  else static if (is (T == long  )) code = "\"long "   ~ name ~ "\"";
  else static if (is (T == ulong )) code = "\"ulong "  ~ name ~ "\"";
  else static if (is (T == float )) code = "\"float "  ~ name ~ "\"";
  else static if (is (T == double)) code = "\"double " ~ name ~ "\"";
  else static if (isDynamicArray!T || isStaticArray!T || __traits(isSame, TemplateOf!(T), NDArray))
  {
    auto qual = (back == "") ? "__global" : "__local";
    auto orig = (back == "") ? name : back;
    code = "\"" ~ qual ~ " \" ~ typeid(*" ~ orig ~ ".ptr).toString() ~ \"* " ~ name ~ "\"";
  }
  else
    code = "\"\"";
  return code;
}

string
set_kernel_arg(T)(string kernel, string arg, string name, string back, string size)
{
  string code;
  static      if (is (T == bool))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_char.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == char))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_char.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == byte))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_char.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == ubyte))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_uchar.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == short))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_short.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == ushort))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_ushort.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (Unqual!(T) == int))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_int.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == uint))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_uint.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == long))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_long.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == ulong))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_ulong.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == float))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_float.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (is (T == double))
    code = "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg  ~ ", cl_double.sizeof, &" ~ name ~ ");\n"
         ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  else static if (isDynamicArray!T || isStaticArray!T || __traits(isSame, TemplateOf!(T), NDArray))
  {
    code = (null == size || size == "")
           ?
           "cl_mem clop_opencl_device_buffer_" ~ name ~
           " = clCreateBuffer(runtime.context, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR, typeid(*"
           ~ name ~ ".ptr).tsize * " ~ name ~ ".length, " ~ name ~ ".ptr, &runtime.status);\n"
           ~ "assert(runtime.status == CL_SUCCESS, \"clCreateBuffer failed.\");\n"
           ~ "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg ~ ", cl_mem.sizeof, &clop_opencl_device_buffer_"
           ~ name ~ ");\nassert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");"
           :
           "runtime.status = clSetKernelArg(" ~ kernel ~ ", " ~ arg ~ ", " ~ size ~ " * typeid(*" ~ back ~ ".ptr).tsize, " ~ name ~ ");\n"
           ~ "assert(runtime.status == CL_SUCCESS, \"clSetKernelArg failed.\");";
  }
  else
    code = "";
  return "debug (DEBUG) writefln(\"%s\", q{" ~ code ~ "});\n" ~ code;
}

string
read_device_buffer(T)(string name)
{
  string code;
  static if (isDynamicArray!T || isStaticArray!T || __traits(isSame, TemplateOf!(T), NDArray))
    code = "runtime.status = clEnqueueReadBuffer(runtime.queue, clop_opencl_device_buffer_"
           ~ name ~ ", CL_TRUE, 0, typeid(*" ~ name ~ ".ptr).tsize * " ~ name ~ ".length, " ~ name ~
           ".ptr, 0, null, null);\nassert(runtime.status == CL_SUCCESS, \"clEnqueueReadBuffer failed.\");";
  else
    code = "";
  return "debug (DEBUG) writefln(\"%s\", q{" ~ code ~ "});\n" ~ code;
}

/**
 * Main entry point to the compiler.
 * \param expr a string containing the source code of a CLOP fragment
 *             to be compiled into OpenCL kernel and the supporting
 *             OpenCL API calls.
 * \return     a string containing the valid D source code to be mixed
 *             in the invoking application code.  This code includes
 *             the generated OpenCL kernel code and everything needed
 *             to invoke the kernel along with the data movements to
 *             and from the OpenCL device used to execute the kernel.
 */
string
compile(string expr, string file = __FILE__, size_t line = __LINE__)
{
  auto compiler = Compiler(expr, file, line);
  auto code = compiler.generate_code();
  //return "debug (DEBUG) writefln(\"CLOP MIXIN at %s:%s:\\n%sEND OF CLOP\", \"" ~ file ~ "\", " ~ to!string(line) ~ ", q{" ~ code ~ "});\n" ~ code;
  return "debug (DEBUG) writefln(\"CLOP MIXIN at %s:%s:\\n%sEND OF CLOP\", \"" ~ file ~ "\", " ~ to!string(line) ~ ", `" ~ code ~ "`);\n";
}
