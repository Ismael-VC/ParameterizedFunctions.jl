function ode_def_opts(name::Symbol,opts::Dict{Symbol,Bool},ex::Expr,params...;M=I,depvar=:t)
  # depvar is the dependent variable. Defaults to t
  # M is the mass matrix in RosW, must be a constant!

  origex = copy(ex) # Save the original expression

  ## Build independent variable dictionary
  indvar_dict,syms = build_indvar_dict(ex)
  ## Build parameter and inline dictionaries
  param_dict, inline_dict = build_paramdicts(params)

  ####
  # Build the Expressions

  # Run find replace to make the function expression
  symex = copy(ex) # Different expression for symbolic computations
  ode_findreplace(ex,symex,indvar_dict,param_dict,inline_dict)
  push!(ex.args,nothing) # Make the return void
  fex = ex # Save this expression as the expression for the call

  # Parameter-Explicit Functions
  pex = copy(origex) # Build it from the original expression
  # Parameter find/replace
  ode_findreplace(pex,copy(ex),indvar_dict,param_dict,inline_dict;params_from_function=false)

  ######
  # Build the Functions

  # Get the component functions
  funcs = build_component_funcs(symex)

  numsyms = length(indvar_dict)
  numparams = length(param_dict)

  # Parameter Functions
  paramfuncs = Vector{Vector{Expr}}(numparams)
  for i in 1:numparams
    tmp_pfunc = Vector{Expr}(length(funcs))
    for j in eachindex(funcs)
      tmp_pfunc[j] = copy(funcs[j])
    end
    paramfuncs[i] = tmp_pfunc
  end
  pfuncs = build_p_funcs(paramfuncs,indvar_dict,param_dict,inline_dict)

  # Symbolic Setup
  symfuncs = Vector{SymEngine.Basic}(0)
  symtgrad = Vector{SymEngine.Basic}(0)
  symjac   = Matrix{SymEngine.Basic}(0,0)
  expjac   = Matrix{SymEngine.Basic}(0,0)
  invjac   = Matrix{SymEngine.Basic}(0,0)
  symhes   = Matrix{SymEngine.Basic}(0,0)
  invhes   = Matrix{SymEngine.Basic}(0,0)
  syminvW  = Matrix{SymEngine.Basic}(0,0)
  syminvW_t= Matrix{SymEngine.Basic}(0,0)
  param_symjac = Matrix{SymEngine.Basic}(0,0)
  tgradex = :(error("t-gradient Does Not Exist"))
  tgrad_exists = false
  Jex = :(error("Jacobian Does Not Exist"))
  jac_exists = false
  expJex = :(error("Exponential Jacobian Does Not Exist"))
  expjac_exists = false
  invJex = :(error("Inverse Jacobian Does Not Exist"))
  invjac_exists = false
  invWex = :(error("Inverse Rosenbrock-W Does Not Exist"))
  invW_exists = false
  invWex_t = :(error("Inverse Rosenbrock-W Transformed Does Not Exist"))
  invW__t_exists = false
  Hex = :(error("Hessian Does Not Exist"))
  hes_exists = false
  invHex = :(error("Inverse Hessian Does Not Exist"))
  invhes_exists = false
  param_Jex = :(error("Parameter Jacobian Does Not Exist"))
  param_jac_exists = false

  d_pfuncs = Vector{Expr}(0)
  param_symjac = Matrix{SymEngine.Basic}(numsyms,numparams)
  pderiv_exists = false

  try #do symbolic calculations

    # Declare the SymEngine symbols
    symtup,paramtup = symbolize(syms,param_dict.keys)
    depvar_to_sym_ex = Expr(:(=),depvar,symbols(string(depvar)))
    @eval $depvar_to_sym_ex

    # Set Internal γ, used as a symbol for letting users pass an extra scalar
    γ = symbols("internal_γ")

    # Build the symbolic functions

    symfuncs = Vector{SymEngine.Basic}(numsyms)

    for i in eachindex(funcs)
      funcex = funcs[i]
      tmp = @eval $funcex
      symfuncs[i] = SymEngine.Basic(tmp)
    end

    if opts[:build_tgrad]
      try
        symtgrad = Vector{SymEngine.Basic}(numsyms)
        for i in eachindex(symfuncs)
          symtgrad[i] = diff(SymEngine.Basic(symfuncs[i]),depvar)
        end
        tgrad_exists = true
        tgradex = build_tgrad_func(symtgrad,indvar_dict,param_dict,inline_dict)
      catch err
        warn("Time Derivative Gradient could not invert")
      end
    end

    if opts[:build_jac]
      try #Jacobians and Hessian
        # Build the Jacobian Matrix of SymEngine Expressions
        symjac = Matrix{SymEngine.Basic}(numsyms,numsyms)
        for i in eachindex(funcs)
          funcex = funcs[i]
          symfunc = @eval $funcex
          for j in eachindex(symtup)
            symjac[i,j] = diff(SymEngine.Basic(symfuncs[i]),symtup[j])
          end
        end

        # Build the Julia function
        Jex = build_jac_func(symjac,indvar_dict,param_dict,inline_dict)
        jac_exists = true

        if opts[:build_expjac]
          try
            expjac = expm(γ*symjac) # This does not work, which is why disabled
            expJex = build_jac_func(expjac,indvar_dict,param_dict,inline_dict)
            expjac_exists = true
          catch
            warn("Jacobian could not exponentiate")
          end
        end

        if opts[:build_invjac]
          try # Jacobian Inverse
            invjac = inv(symjac)
            invJex = build_jac_func(invjac,indvar_dict,param_dict,inline_dict)
            invjac_exists = true
          catch err
            warn("Jacobian could not invert")
          end
        end
        if opts[:build_invW]
          try # Rosenbrock-W Inverse
            syminvW = inv(M - γ*symjac)
            syminvW_t = inv(M/γ - symjac)
            invWex = build_jac_func(syminvW,indvar_dict,param_dict,inline_dict)
            invW_exists = true
            invWex_t = build_jac_func(syminvW_t,indvar_dict,param_dict,inline_dict)
            invW_t_exists = true
          catch err
            warn("Rosenbrock-W could not invert")
          end
        end
        if opts[:build_hes]
          try # Hessian
            symhes = Matrix{SymEngine.Basic}(numsyms,numsyms)
            for i in eachindex(funcs), j in eachindex(symtup)
              symhes[i,j] = diff(symjac[i,j],symtup[j])
            end
            # Build the Julia function
            Hex = build_jac_func(symhes,indvar_dict,param_dict,inline_dict)
            hes_exists = true
            if opts[:build_invhes]
              try # Hessian Inverse
                invhes = inv(symhes)
                invHex = build_jac_func(invhes,indvar_dict,param_dict,inline_dict)
                invhes_exists = true
              catch err
                warn("Hessian could not invert")
              end
            end
          end
        end
      catch err
        warn("Failed to build the Jacoboian. This means the Hessian is not built as well.")
      end
    end # End Jacobian tree

    if opts[:build_dpfuncs]
      try # Parameter Gradients
        d_paramfuncs  = Vector{Vector{Expr}}(numparams)
        for i in eachindex(paramtup)
          tmp_dpfunc = Vector{Expr}(length(funcs))
          for j in eachindex(funcs)
            funcex = funcs[j]
            symfunc = @eval $funcex
            d_curr = diff(SymEngine.Basic(symfunc),paramtup[i])
            param_symjac[j,i] = d_curr
            symfunc_str = parse(string(d_curr))
            if typeof(symfunc_str) <: Number
              tmp_dpfunc[j] = :(1*$symfunc_str)
            elseif typeof(symfunc_str) <: Symbol
              tmp_dpfunc[j] = :(1*$symfunc_str)
            else
              tmp_dpfunc[j] = symfunc_str
            end
          end
          d_paramfuncs[i] = tmp_dpfunc
        end
        d_pfuncs = build_p_funcs(d_paramfuncs,indvar_dict,param_dict,inline_dict)
        pderiv_exists = true

        # Now build the parameter Jacobian
        param_symjac_ex = Matrix{Expr}(numsyms,numparams)
        for i in 1:numparams
          param_symjac_ex[:,i] = d_paramfuncs[i]
        end

        param_Jex = build_jac_func(param_symjac_ex,indvar_dict,param_dict,inline_dict,params_from_function=false)
        param_jac_exists = true
      catch err
        warn("Failed to build the parameter derivatives.")
      end
    end
  catch err
    warn("Symbolic calculations could not initiate. Likely there's a function which is not differentiable by SymEngine.")
  end

  # Build the type
  f = maketype(name,param_dict,origex,funcs,syms,fex,pex=pex,
               symfuncs=symfuncs,symtgrad=symtgrad,tgradex=tgradex,
               symjac=symjac,Jex=Jex,expjac=expjac,expJex=expJex,invjac=invjac,
               invWex=invWex,invWex_t=invWex_t,syminvW=syminvW,
               syminvW_t=syminvW_t,invJex=invJex,symhes=symhes,invhes=invhes,Hex=Hex,
               invHex=invHex,params=param_dict.keys,
               pfuncs=pfuncs,d_pfuncs=d_pfuncs,
               param_symjac=param_symjac,param_Jex=param_Jex)
  # Overload the Call
  overloadex = :(((p::$name))(t::Number,u,du) = $fex)
  @eval $overloadex
  # Value Dispatches for the Parameters
  params = param_dict.keys
  for i in 1:length(params)
    param = Symbol(params[i])
    param_func = pfuncs[i]
    param_valtype = Val{param}
    overloadex = :(((p::$name))(::Type{$param_valtype},t,u,$param,du) = $param_func)
    @eval $overloadex
  end

  # Build the Function
  overloadex = :(((p::$name))(t::Number,u,params,du) = $pex)
  @eval $overloadex

  # Value Dispatches for the Parameter Derivatives
  if pderiv_exists
    for i in 1:length(params)
      param = Symbol(params[i])
      param_func = d_pfuncs[i]
      param_valtype = Val{param}
      overloadex = :(((p::$name))(::Type{Val{:deriv}},::Type{$param_valtype},t,u,$param,du) = $param_func)
      @eval $overloadex
    end
  end

  # Add the t gradient
  if tgrad_exists
    overloadex = :(((p::$name))(::Type{Val{:tgrad}},t,u,grad) = $tgradex)
    @eval $overloadex
  end

  # Add the Jacobian
  if jac_exists
    overloadex = :(((p::$name))(::Type{Val{:jac}},t,u,J) = $Jex)
    @eval $overloadex
  end
  # Add the Exponential Jacobian
  if expjac_exists
    overloadex = :(((p::$name))(::Type{Val{:expjac}},t,u,internal_γ,J) = $expJex)
    @eval $overloadex
  end
  # Add the Inverse Jacobian
  if invjac_exists
    overloadex = :(((p::$name))(::Type{Val{:invjac}},t,u,J) = $invJex)
    @eval $overloadex
  end
  # Add the Inverse Rosenbrock-W
  if invW_exists
    overloadex = :(((p::$name))(::Type{Val{:invW}},t,u,internal_γ,J) = $invWex)
    @eval $overloadex
  end
  # Add the Inverse Rosenbrock-W Transformed
  if invW_exists
    overloadex = :(((p::$name))(::Type{Val{:invW_t}},t,u,internal_γ,J) = $invWex_t)
    @eval $overloadex
  end
  # Add the Hessian
  if hes_exists
    overloadex = :(((p::$name))(::Type{Val{:hes}},t,u,J) = $Hex)
    @eval $overloadex
  end
  # Add the Inverse Hessian
  if invhes_exists
    overloadex = :(((p::$name))(::Type{Val{:invhes}},t,u,J) = $invHex)
    @eval $overloadex
  end
  # Add Parameter Jacobian
  if param_jac_exists
    overloadex = :(((p::$name))(::Type{Val{:paramjac}},t,u,params,J) = $param_Jex)
    @eval $overloadex
  end

  return f
end
