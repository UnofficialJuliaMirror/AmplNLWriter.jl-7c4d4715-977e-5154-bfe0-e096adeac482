module AmplNLWriter

using MathProgBase
importall MathProgBase.SolverInterface

include("nl_linearity.jl")
include("nl_params.jl")
include("nl_convert.jl")

export AmplNLSolver, BonminNLSolver, CouenneNLSolver, IpoptNLSolver,
       getsolvername, getsolveresult, getsolveresultnum, getsolvemessage,
       getsolveexitcode

immutable AmplNLSolver <: AbstractMathProgSolver
    solver_command::AbstractString
    options::Dict{ASCIIString, Any}

    function AmplNLSolver(solver_command,
                          options=Dict{ASCIIString, Any}())
        new(solver_command, options)
    end
end

osl = isdir(Pkg.dir("CoinOptServices"))
ipt = isdir(Pkg.dir("Ipopt"))

if osl; import CoinOptServices; end
if ipt; import Ipopt; end

function BonminNLSolver(options::Dict{ASCIIString,}=Dict{ASCIIString, Any}())
    osl || error("CoinOptServices not installed. Please run\n",
                 "Pkg.add(\"CoinOptServices\")")
    AmplNLSolver(CoinOptServices.bonmin, options)
end

function CouenneNLSolver(options::Dict{ASCIIString,}=Dict{ASCIIString, Any}())
    osl || error("CoinOptServices not installed. Please run\n",
                 "Pkg.add(\"CoinOptServices\")")
    AmplNLSolver(CoinOptServices.couenne, options)
end

function IpoptNLSolver(options::Dict{ASCIIString,}=Dict{ASCIIString, Any}())
    ipt || error("Ipopt not installed. Please run\nPkg.add(\"Ipopt\")")
    AmplNLSolver(Ipopt.amplexe, options)
end

getsolvername(s::AmplNLSolver) = basename(s.solver_command)

type AmplNLMathProgModel <: AbstractMathProgModel
    options::Dict{ASCIIString, Any}

    solver_command::AbstractString

    x_l::Vector{Float64}
    x_u::Vector{Float64}
    g_l::Vector{Float64}
    g_u::Vector{Float64}

    nvar::Int
    ncon::Int

    obj
    constrs::Array{Any}

    lin_constrs::Array{Dict{Int, Float64}}
    lin_obj::Dict{Int, Float64}

    r_codes::Vector{Int}
    j_counts::Vector{Int}

    vartypes::Vector{Symbol}
    varlinearities_con::Vector{Symbol}
    varlinearities_obj::Vector{Symbol}
    conlinearities::Vector{Symbol}
    objlinearity::Symbol

    v_index_map::Dict{Int, Int}
    v_index_map_rev::Dict{Int, Int}
    c_index_map::Dict{Int, Int}
    c_index_map_rev::Dict{Int, Int}

    sense::Symbol

    x_0::Vector{Float64}

    probfile::AbstractString
    solfile::AbstractString

    objval::Float64
    solution::Vector{Float64}

    status::Symbol
    solve_exitcode::Int
    solve_result_num::Int
    solve_result::AbstractString
    solve_message::AbstractString

    d::AbstractNLPEvaluator

    function AmplNLMathProgModel(solver_command::AbstractString,
                                 options::Dict{ASCIIString, Any})
        new(options,
            solver_command,
            zeros(0),
            zeros(0),
            zeros(0),
            zeros(0),
            0,
            0,
            :(0),
            [],
            Dict{Int, Float64}[],
            Dict{Int, Float64}(),
            Int[],
            Int[],
            Symbol[],
            Symbol[],
            Symbol[],
            Symbol[],
            :Lin,
            Dict{Int, Int}(),
            Dict{Int, Int}(),
            Dict{Int, Int}(),
            Dict{Int, Int}(),
            :Min,
            zeros(0),
            "",
            "",
            NaN,
            zeros(0),
            :NotSolved,
            -1,
            -1,
            "?",
            "")
    end
end

include("nl_write.jl")

MathProgBase.model(s::AmplNLSolver) = AmplNLMathProgModel(s.solver_command,
                                                          s.options)

function MathProgBase.loadnonlinearproblem!(m::AmplNLMathProgModel,
    nvar, ncon, x_l, x_u, g_l, g_u, sense, d::MathProgBase.AbstractNLPEvaluator)

    m.nvar, m.ncon = nvar, ncon
    loadcommon!(m, x_l, x_u, g_l, g_u, sense)

    m.d = d
    MathProgBase.initialize(m.d, [:ExprGraph])

    # Process constraints
    m.constrs = map(1:m.ncon) do i
        c = MathProgBase.constr_expr(m.d, i)

        # Remove relations and bounds from constraint expressions
        @assert c.head == :comparison
        if length(c.args) == 3
            # Single relation constraint: expr rel bound
            m.r_codes[i] = relation_to_nl[c.args[2]]
            if c.args[2] == [:<=, :(==)]
                m.g_u[i] = c.args[3]
            end
            if c.args[2] in [:>=, :(==)]
                m.g_l[i] = c.args[3]
            end
            c = c.args[1]
        else
            # Double relation constraint: bound <= expr <= bound
            m.r_codes[i] = relation_to_nl[:multiple]
            m.g_u[i] = c.args[5]
            m.g_l[i] = c.args[1]
            c = c.args[3]
        end

        # Convert non-linear expression to non-linear, linear and constant
        c, constant, m.conlinearities[i] = process_expression!(
            c, m.lin_constrs[i], m.varlinearities_con)

        # Update bounds on constraint
        m.g_l[i] -= constant
        m.g_u[i] -= constant

        # Update jacobian counts using the linear constraint variables
        for j in keys(m.lin_constrs[i])
            m.j_counts[j] += 1
        end
        c
    end

    # Process objective
    m.obj = MathProgBase.obj_expr(m.d)
    if length(m.obj.args) < 2
        m.obj = nothing
    else
        # Convert non-linear expression to non-linear, linear and constant
        m.obj, constant, m.objlinearity = process_expression!(
            m.obj, m.lin_obj, m.varlinearities_obj)

        # Add constant back into non-linear expression
        if constant != 0
            m.obj = add_constant(m.obj, constant)
        end
    end
    m
end

function MathProgBase.loadproblem!(m::AmplNLMathProgModel, A, x_l, x_u, c, g_l,
                                   g_u, sense)
    m.ncon, m.nvar = size(A)

    loadcommon!(m, x_l, x_u, g_l, g_u, sense)

    # Load A into the linear constraints
    load_A!(m, A)
    m.constrs = zeros(m.ncon)  # Dummy constraint expression trees

    # Load c
    for (index, val) in enumerate(c)
        m.lin_obj[index] = val
    end
    m.obj = 0  # Dummy objective expression tree

    # Process variables bounds
    for j = 1:m.ncon
        lower = m.g_l[j]
        upper = m.g_u[j]
        if lower == -Inf
            if upper == Inf
                error("Neither lower nor upper bound on constraint $j")
            else
                m.r_codes[j] = 1
            end
        else
            if lower == upper
                m.r_codes[j] = 4
            elseif upper == Inf
                m.r_codes[j] = 2
            else
                m.r_codes[j] = 0
            end
        end
    end
    m
end

function load_A!(m::AmplNLMathProgModel, A::SparseMatrixCSC{Float64})
    @assert (m.ncon, m.nvar) == size(A)
    for var = 1:A.n, k = A.colptr[var] : (A.colptr[var + 1] - 1)
        m.lin_constrs[A.rowval[k]][var] = A.nzval[k]
        m.j_counts[var] += 1
    end
end

function load_A!(m::AmplNLMathProgModel, A::Matrix{Float64})
    @assert (m.ncon, m.nvar) == size(A)
    for con = 1:m.ncon, var = 1:m.nvar
        val = A[con, var]
        if val != 0
            m.lin_constrs[A.rowval[k]][var] = A.nzval[k]
            m.j_counts[var] += 1
        end
    end
end

function loadcommon!(m::AmplNLMathProgModel, x_l, x_u, g_l, g_u, sense)
    @assert m.nvar == length(x_l) == length(x_u)
    @assert m.ncon == length(g_l) == length(g_u)

    m.x_l, m.x_u = x_l, x_u
    m.g_l, m.g_u = g_l, g_u
    m.sense = sense

    m.lin_constrs = [Dict{Int, Float64}() for _ in 1:m.ncon]
    m.j_counts = zeros(Int, m.nvar)

    m.r_codes = Array(Int, m.ncon)

    m.varlinearities_con = fill(:Lin, m.nvar)
    m.varlinearities_obj = fill(:Lin, m.nvar)
    m.conlinearities = fill(:Lin, m.ncon)
    m.objlinearity = :Lin

    m.vartypes = fill(:Cont, m.nvar)
    m.x_0 = zeros(m.nvar)
end

MathProgBase.getvartype(m::AmplNLMathProgModel) = copy(m.vartypes)
function MathProgBase.setvartype!(m::AmplNLMathProgModel, cat::Vector{Symbol})
    @assert all(x-> (x in [:Cont,:Bin,:Int]), cat)
    m.vartypes = copy(cat)
end

function MathProgBase.setwarmstart!(m::AmplNLMathProgModel, v::Vector{Float64})
    m.x_0 = v
end

function MathProgBase.optimize!(m::AmplNLMathProgModel)
    m.status = :NotSolved
    m.solve_exitcode = -1
    m.solve_result_num = -1
    m.solve_result = "?"
    m.solve_message = ""

    # There is no non-linear binary type, only non-linear discrete, so make
    # sure binary vars have bounds in [0, 1]
    for i in 1:m.nvar
        if m.vartypes[i] == :Bin
            if m.x_l[i] < 0
                m.x_l[i] = 0
            end
            if m.x_u[i] > 1
                m.x_u[i] = 1
            end
        end
    end

    make_var_index!(m)
    make_con_index!(m)

    m.probfile = joinpath(Pkg.dir("AmplNLWriter"), ".solverdata", "model.nl")
    m.solfile = joinpath(Pkg.dir("AmplNLWriter"), ".solverdata", "model.sol")

    write_nl_file(m)

    # Construct keyword params
    options = ["$name=$value" for (name, value) in m.options]

    # Run solver and save exitcode
    proc = spawn(pipeline(`$(m.solver_command) $(m.probfile) -AMPL $options`, stdout=STDOUT))
    wait(proc)
    kill(proc)
    m.solve_exitcode = proc.exitcode

    if m.solve_exitcode == 0
        read_results(m)
    else
        m.status = :Error
        m.solve_result = "failure"
        m.solve_result_num = 999
    end
end

function process_expression!(nonlin_expr::Expr, lin_expr::Dict{Int, Float64},
                             varlinearities::Vector{Symbol})
    # Get list of all variables in the expression
    extract_variables!(lin_expr, nonlin_expr)
    # Extract linear and constant terms from non-linear expression
    tree = LinearityExpr(nonlin_expr)
    tree = pull_up_constants(tree)
    _, tree, constant = prune_linear_terms!(tree, lin_expr)
    # Make sure all terms remaining in the tree are .nl-compatible
    nonlin_expr = convert_formula(tree)

    # Track which variables appear nonlinearly
    nonlin_vars = Dict{Int, Float64}()
    extract_variables!(nonlin_vars, nonlin_expr)
    for j in keys(nonlin_vars)
        varlinearities[j] = :Nonlin
    end

    # Remove variables at coeff 0 that aren't also in the nonlinear tree
    for (j, coeff) in lin_expr
        if coeff == 0 && !(j in keys(nonlin_vars))
            delete!(lin_expr, j)
        end
    end

    # Mark constraint as nonlinear if anything is left in the tree
    linearity = nonlin_expr != 0 ? :Nonlin : :Lin

    return nonlin_expr, constant, linearity
end

MathProgBase.status(m::AmplNLMathProgModel) = m.status
MathProgBase.getsolution(m::AmplNLMathProgModel) = copy(m.solution)
MathProgBase.getobjval(m::AmplNLMathProgModel) = m.objval

# Access to AMPL solve result items
get_solve_result(m::AmplNLMathProgModel) = m.solve_result
get_solve_result_num(m::AmplNLMathProgModel) = m.solve_result_num
get_solve_message(m::AmplNLMathProgModel) = m.solve_message
get_solve_exitcode(m::AmplNLMathProgModel) = m.solve_exitcode

# We need to track linear coeffs of all variables present in the expression tree
extract_variables!(lin_constr::Dict{Int, Float64}, c) = c
extract_variables!(lin_constr::Dict{Int, Float64}, c::LinearityExpr) =
    extract_variables!(lin_constr, c.c)
function extract_variables!(lin_constr::Dict{Int, Float64}, c::Expr)
    if c.head == :ref
        if c.args[1] == :x
            @assert isa(c.args[2], Int)
            lin_constr[c.args[2]] = 0
        else
            error("Unrecognized reference expression $c")
        end
    else
        map(arg -> extract_variables!(lin_constr, arg), c.args)
    end
end

add_constant(c, constant::Real) = c + constant
add_constant(c::Expr, constant::Real) = Expr(:call, :+, c, constant)

function make_var_index!(m::AmplNLMathProgModel)
    nonlin_cont = Int[]
    nonlin_int = Int[]
    lin_cont = Int[]
    lin_int = Int[]
    lin_bin = Int[]

    for i in 1:m.nvar
        if m.varlinearities_obj[i] == :Nonlin ||
           m.varlinearities_con[i] == :Nonlin
            if m.vartypes[i] == :Cont
                push!(nonlin_cont, i)
            else
                push!(nonlin_int, i)
            end
        else
            if m.vartypes[i] == :Cont
                push!(lin_cont, i)
            elseif m.vartypes[i] == :Int
                push!(lin_int, i)
            else
                push!(lin_bin, i)
            end
        end
    end

    # Index variables in required order
    for var_list in (nonlin_cont, nonlin_int, lin_cont, lin_bin, lin_int)
        add_to_index_maps!(m.v_index_map, m.v_index_map_rev, var_list)
    end
end

function make_con_index!(m::AmplNLMathProgModel)
    nonlin_cons = Int[]
    lin_cons = Int[]

    for i in 1:m.ncon
        if m.conlinearities[i] == :Nonlin
            push!(nonlin_cons, i)
        else
            push!(lin_cons, i)
        end
    end
    for con_list in (nonlin_cons, lin_cons)
        add_to_index_maps!(m.c_index_map, m.c_index_map_rev, con_list)
    end
end

function add_to_index_maps!(forward_map::Dict{Int, Int},
                            backward_map::Dict{Int, Int},
                            inds::Array{Int})
    for i in inds
        # Indices are 0-prefixed so the next index is the current dict length
        index = length(forward_map)
        forward_map[i] = index
        backward_map[index] = i
    end
end

function read_results(m::AmplNLMathProgModel)
    did_read_solution = read_sol(m)

    # Convert solve_result
    if 0 <= m.solve_result_num < 100
        m.status = :Optimal
        m.solve_result = "solved"
    elseif 100 <= m.solve_result_num < 200
        # Used to indicate solution present but likely incorrect.
        m.status = :Optimal
        m.solve_result = "solved?"
        warn("The solver has returned the status :Optimal, but indicated that there might be an error in the solution. The status code returned by the solver was $(m.solve_result_num). Check the solver documentation for more info.""")
    elseif 200 <= m.solve_result_num < 300
        m.status = :Infeasible
        m.solve_result = "infeasible"
    elseif 300 <= m.solve_result_num < 400
        m.status = :Unbounded
        m.solve_result = "unbounded"
    elseif 400 <= m.solve_result_num < 500
        m.status = :UserLimit
        m.solve_result = "limit"
    elseif 500 <= m.solve_result_num < 600
        m.status = :Error
        m.solve_result = "failure"
    end

    # If we didn't get a valid solve_result_num, try to get the status from the
    # solve_message string.
    # Some solvers (e.g. SCIP) don't ever print the suffixes so we need this.
    if m.status == :NotSolved
        message = lowercase(m.solve_message)
        if contains(message, "optimal")
            m.status = :Optimal
        elseif contains(message, "infeasible")
            m.status = :Infeasible
        elseif contains(message, "unbounded")
            m.status = :Unbounded
        elseif contains(message, "limit")
            m.status = :UserLimit
        elseif contains(message, "error")
            m.status = :Error
        end
    end

    if did_read_solution
        # Calculate objective value from nonlinear and linear parts
        obj_nonlin = eval(substitute_vars!(deepcopy(m.obj), m.solution))
        obj_lin = evaluate_linear(m.lin_obj, m.solution)
        m.objval = obj_nonlin + obj_lin
    end
end

function read_sol(m::AmplNLMathProgModel)
    # Reference implementation:
    # https://github.com/ampl/mp/tree/master/src/asl/solvers/readsol.c

    f = open(m.solfile, "r")
    stat = :Undefined

    # Throw away any empty lines at start
    line = ""
    while true
        line = readline(f)
        strip(chomp(line)) != "" && break
    end

    # Keep building solver message by reading until empty line
    while true
        m.solve_message *= line
        line = readline(f)
        strip(chomp(line)) == "" && break
    end

    # Read through all the options. Direct copy of reference implementation.
    @assert chomp(readline(f)) == "Options"
    options = [parse(Int, chomp(readline(f))) for _ in 1:3]
    num_options = options[1]
    3 <= num_options <= 9 || error("expected num_options between 3 and 9; " *
                                   "got $num_options")
    need_vbtol = false
    if options[3] == 3
        num_options -= 2
        need_vbtol = true
    end
    for j = 3:num_options
        eof(f) && error()
        push!(options, parse(Int, chomp(readline(f))))
    end

    # Read number of constraints
    num_cons = parse(Int, chomp(readline(f)))
    @assert(num_cons == m.ncon)

    # Read number of duals to read in
    num_duals_to_read = parse(Int, chomp(readline(f)))
    @assert(num_duals_to_read in [0; m.ncon])

    # Read number of variables
    num_vars = parse(Int, chomp(readline(f)))
    @assert(num_vars == m.nvar)

    # Read number of variables to read in
    num_vars_to_read = parse(Int, chomp(readline(f)))
    @assert(num_vars_to_read in [0; m.nvar])

    # Skip over vbtol line if present
    need_vbtol && readline(f)

    # Skip over duals
    # TODO do something with these?
    for index in 0:(num_duals_to_read - 1)
        eof(f) && error("End of file while reading duals.")
        line = readline(f)
    end

    # Next, read for the variable values
    x = fill(NaN, m.nvar)
    m.objval = NaN
    for index in 0:(num_vars_to_read - 1)
        eof(f) && error("End of file while reading variables.")
        line = readline(f)

        i = m.v_index_map_rev[index]
        x[i] = float(chomp(line))
    end
    m.solution = x

    # Check for status code
    while !eof(f)
        line = readline(f)
        linevals = split(chomp(line), " ")
        num_vals = length(linevals)
        if num_vals > 0 && linevals[1] == "objno"
            # Check for objno == 0
            @assert parse(Int, linevals[2]) == 0
            # Get solve_result
            m.solve_result_num = parse(Int, linevals[3])

            # We can stop looking for the 'objno' line
            break
        end
    end
    return num_vars_to_read > 0
end

substitute_vars!(c, x::Array{Float64}) = c
function substitute_vars!(c::Expr, x::Array{Float64})
    if c.head == :ref
        if c.args[1] == :x
            index = c.args[2]
            @assert isa(index, Int)
            c = x[index]
        else
            error("Unrecognized reference expression $c")
        end
    else
        if c.head == :call
            # Convert .nl unary minus (:neg) back to :-
            if c.args[1] == :neg
                c.args[1] = :-
            # Convert .nl :sum back to :+
            elseif c.args[1] == :sum
                c.args[1] = :+
            end
        end
        map!(arg -> substitute_vars!(arg, x), c.args)
    end
    c
end

function evaluate_linear(linear_coeffs::Dict{Int, Float64}, x::Array{Float64})
    total = 0.0
    for (i, coeff) in linear_coeffs
        total += coeff * x[i]
    end
    total
end

end
