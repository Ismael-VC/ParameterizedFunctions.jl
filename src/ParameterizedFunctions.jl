module ParameterizedFunctions
using SymEngine, DataStructures
import Base: getindex,ctranspose

### Basic Functionality

abstract ParameterizedFunction <: Function
getindex{s}(p::ParameterizedFunction,::Val{s}) = getfield(p,s) ## Val for type-stability

### Macros

#=
function build_indep_var_dict(ex)

  indvar_dict,syms
end
=#

macro ode_def(name,ex,params...)
  origex = ex # Save the original expression

  ## Build independent variable dictionary
  indvar_dict,syms = build_indvar_dict(ex)
  ## Build parameter and inline dictionaries
  param_dict, inline_dict = build_paramdicts(params)

  # Run find replace to make the function expression
  symex = copy(ex) # Different expression for symbolic computations
  ode_findreplace(ex,symex,indvar_dict,param_dict,inline_dict)
  push!(ex.args,nothing) # Make the return void
  fex = ex # Save this expression as the expression for the call

  # Get the component functions
  funcs = Vector{Expr}(0) # Get all of the functions for symbolic computation
  for (i,arg) in enumerate(symex.args)
    if i%2 == 0
      ex = arg.args[2]
      if typeof(ex) <: Symbol
        push!(funcs,:(1*$ex))
      else # It's an expression, just push
        push!(funcs,arg.args[2])
      end
    end
  end

  # Declare the symbols
  symstr = symarr_to_symengine(syms)
  symdefineex = Expr(:(=),parse("("*symstr*")"),SymEngine.symbols(symstr))
  symtup = parse("("*symstr*")")
  @eval $symdefineex
  symtup = @eval $symtup # symtup is the tuple of SymEngine symbols

  #try
    # Build the Jacobian Matrix of SymEngine Expressions
    numsyms = length(symtup)
    symjac = Matrix{SymEngine.Basic}(numsyms,numsyms)
    for i in eachindex(funcs)
      funcex = funcs[i]
      symfunc = @eval $funcex
      for j in eachindex(symtup)
        symjac[i,j] = diff(symfunc,symtup[j])
      end
    end

    # Build the Julia function
    Jex = build_jac_func(symjac,indvar_dict,param_dict,inline_dict)
    jac_exists = true
  #catch
  #  jac_exists = false
  #  Jex = (t,u,J) -> nothing
  #end
  
  # Build the type
  f = maketype(name,param_dict,origex,funcs,syms)
  # Export the type
  exportex = :(export $name)
  @eval $exportex
  # Overload the Call
  overloadex = :(((p::$name))(t,u,du) = $fex)
  @eval $overloadex

  @eval Base.ctranspose(p::$name) = $Jex
  return f
end

function ode_findreplace(ex,symex,indvar_dict,param_dict,inline_dict)
  for (i,arg) in enumerate(ex.args)
    if isa(arg,Expr)
      ode_findreplace(arg,symex.args[i],indvar_dict,param_dict,inline_dict)
    elseif isa(arg,Symbol)
      s = string(arg)
      if haskey(indvar_dict,arg)
        ex.args[i] = :(u[$(indvar_dict[arg])]) # replace with u[i]
      elseif haskey(inline_dict,arg)
        ex.args[i] = :($(inline_dict[arg])) # inline from inline_dict
        symex.args[i] = :($(inline_dict[arg])) # also do in symbolic
      elseif haskey(param_dict,arg)
        ex.args[i] = :(p.$arg) # replace with p.arg
        symex.args[i] = :($(param_dict[arg])) # also do in symbolic
      elseif length(string(arg))>1 && haskey(indvar_dict,Symbol(s[nextind(s, 1):end])) && Symbol(s[1])==:d
        tmp = Symbol(s[nextind(s, 1):end]) # Remove the first letter, the d
        ex.args[i] = :(du[$(indvar_dict[tmp])])
        symex.args[i] = :(du[$(indvar_dict[tmp])]) #also do in symbolic
      end
    end
  end
end

function build_jac_func(symjac,indvar_dict,param_dict,inline_dict)
  Jex = :()
  for i in 1:size(symjac,1)
    for j in 1:size(symjac,2)
      ex = parse(string(symjac[i,j]))
      if typeof(ex) <: Expr
        ode_findreplace(ex,ex,indvar_dict,param_dict,inline_dict)
      else
        ex = ode_symbol_findreplace(ex,indvar_dict,param_dict,inline_dict)
      end
      push!(Jex.args,:(J[$i,$j] = $ex))
    end
  end
  Jex.head = :block
  push!(Jex.args,nothing)
  Jex = :(jac = (t,u,J)->$Jex)
end

function ode_symbol_findreplace(ex,indvar_dict,param_dict,inline_dict)
  if haskey(indvar_dict,ex)
    ex = :(u[$(indvar_dict[ex])]) # replace with u[i]
  end
  :(1*$ex) # Add the 1 to make it an expression not a Symbol
end

function maketype(name,param_dict,origex,funcs,syms)
    @eval type $name <: ParameterizedFunction
        origex#::Expr
        funcs::Vector{Expr}
        syms::Vector{Symbol}
        $((:($x::$(typeof(t))) for (x, t) in param_dict)...)
    end

    # Make the default constructor
    new_ex = Meta.quot(origex)
    constructorex = :($(name)(;$(Expr(:kw,:origex,new_ex)),
                  $(Expr(:kw,:funcs,funcs)),
                  $(Expr(:kw,:syms,syms)),
                  $((Expr(:kw,x,t) for (x, t) in param_dict)...)) =
                  $(name)(origex,funcs,syms,$(((x for x in keys(param_dict))...))))
    eval(constructorex)

    # Make the type instance using the default constructor
    eval(name)()
end

function build_indvar_dict(ex)
  indvar_dict = OrderedDict{Symbol,Int}()
  for i in 2:2:length(ex.args) #Every odd line is line number
    arg = ex.args[i].args[1] #Get the first thing, should be dsomething
    nodarg = Symbol(string(arg)[2:end]) #Take off the d
    if !haskey(indvar_dict,nodarg)
      s = string(arg)
      indvar_dict[Symbol(string(arg)[2:end])] = i/2 # and label it the next int if not seen before
    end
  end
  syms = indvar_dict.keys
  indvar_dict,syms
end

function build_paramdicts(params)
  param_dict = OrderedDict{Symbol,Any}(); inline_dict = OrderedDict{Symbol,Any}()
  for i in 1:length(params)
    if params[i].head == :(=>)
      param_dict[params[i].args[1]] = params[i].args[2] # works for k=3, or k=>3
    elseif params[i].head == :(=)
      inline_dict[params[i].args[1]] = params[i].args[2] # works for k=3, or k=>3
    end
  end
  param_dict,inline_dict
end

macro fem_def(sig,name,ex,params...)
  origex = ex
  ## Build Symbol dictionary
  indvar_dict,syms = build_indvar_dict(ex)

  param_dict, inline_dict = build_paramdicts(params)

  # Run find replace
  fem_findreplace(ex,indvar_dict,syms,param_dict,inline_dict)
  funcs = Vector{Expr}(0) # Get all of the functions
  for (i,arg) in enumerate(ex.args)
    if i%2 == 0
      push!(funcs,arg.args[2])
    end
  end
  if length(syms)==1
    ex = funcs[1]
  else
    ex = Expr(:hcat,funcs...)
  end
  # Build the type
  f = maketype(name,param_dict,origex,funcs,syms)
  # Overload the Call
  newsig = :($(sig.args...))
  overloadex = :(((p::$name))($(sig.args...)) = $ex)
  @eval $overloadex
  # Export the type
  exportex = :(export $name)
  @eval $exportex
  return f
end

function fem_findreplace(ex,indvar_dict,syms,param_dict,inline_dict)
  for (i,arg) in enumerate(ex.args)
    if isa(arg,Expr)
      fem_findreplace(arg,indvar_dict,syms,param_dict,inline_dict)
    elseif isa(arg,Symbol)
      if haskey(indvar_dict,arg)
        ex.args[i] = :(u[:,$(indvar_dict[arg])])
      elseif haskey(inline_dict,arg)
        ex.args[i] = :($(inline_dict[arg])) # Inline if in inline_dict
      elseif haskey(param_dict,arg)
        ex.args[i] = :(p.$arg) # replace with p.arg
      elseif haskey(FEM_SYMBOL_DICT,arg)
        ex.args[i] = FEM_SYMBOL_DICT[arg]
      end
    end
  end
end


### Utility Functions

"""
symarr_to_symengine(symarr::Vector{Symbol})

Converts a Vector{Symbol} into a string for SymEngine parsing

Symbol[:x,:y] --> "x,y"
"""
function symarr_to_symengine(symarr::Vector{Symbol})
  str = ""
  for sym in symarr
    str = str*string(sym)*","
  end
  str[1:end-1]
end

const FEM_SYMBOL_DICT = Dict{Symbol,Expr}(:x=>:(x[:,1]),:y=>:(x[:,2]),:z=>:(x[:,3]))

export ParameterizedFunction, @ode_def, @fem_def
end # module
